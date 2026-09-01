/* Strict iOS document import and safe-area bridge.
 *
 * The document picker is only an ingress UI. A selected file is coordinated,
 * validated, copied into KO_BOOKS_HOME, protected, and atomically moved to its
 * final name before Lua can see it. Provider URLs are never returned or kept.
 * UIKit work stays on the main thread; potentially slow provider and file I/O
 * runs on a private serial queue. Lua drives the bridge with start + poll.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define KO_IOS_EXPORT __attribute__((visibility("default"), used))
#define KO_IMPORT_MAX_BYTES (2ULL * 1024ULL * 1024ULL * 1024ULL)
#define KO_IMPORT_MAX_FILENAME_BYTES 220U

typedef enum {
    KO_IMPORT_IDLE = 0,
    KO_IMPORT_PENDING = 1,
    KO_IMPORT_DONE_OK = 2,
    KO_IMPORT_DONE_CANCEL = 3,
    KO_IMPORT_DONE_ERROR = 4,
} ko_import_state_t;

static ko_import_state_t g_import_state = KO_IMPORT_IDLE;
static NSString *g_imported_path = nil;
static NSString *g_import_error = nil;

static NSLock *ko_import_state_lock(void) {
    static NSLock *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSLock alloc] init];
        lock.name = @"rocks.koreader.ios.import-state";
    });
    return lock;
}

static dispatch_queue_t ko_import_io_queue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("rocks.koreader.ios.import-io",
                                      DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static void ko_finish_import(ko_import_state_t state, NSString *path,
                             NSString *message) {
    NSLock *lock = ko_import_state_lock();
    [lock lock];
    if (g_import_state == KO_IMPORT_PENDING) {
        g_imported_path = state == KO_IMPORT_DONE_OK ? [path copy] : nil;
        g_import_error = state == KO_IMPORT_DONE_ERROR ? [message copy] : nil;
        g_import_state = state;
    }
    [lock unlock];
}

static NSError *ko_import_error(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"rocks.koreader.ios.import"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL ko_url_is_at_or_inside_directory(NSURL *url, NSURL *directory) {
    NSString *path = url.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
    NSString *root = directory.URLByResolvingSymlinksInPath.URLByStandardizingPath.path;
    return path && root
        && ([path isEqualToString:root]
            || [path hasPrefix:[root stringByAppendingString:@"/"]]);
}

static NSSet<NSString *> *ko_allowed_extensions(void) {
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        /* This is intentionally narrower than "all data". It mirrors formats
         * readable by KOReader while excluding executable scripts, settings,
         * sidecars, and generic archives. */
        extensions = [NSSet setWithArray:@[
            @"azw", @"chm", @"doc", @"docm", @"docx", @"epub", @"epub3",
            @"fb2", @"fb2.zip", @"fb3", @"htm", @"htm.zip", @"html",
            @"html.zip", @"htmlz", @"log", @"log.zip", @"md", @"md.zip",
            @"mobi", @"odt", @"pdb", @"prc", @"rtf", @"rtf.zip", @"svg",
            @"tcr", @"txt", @"txt.zip", @"xhtml", @"xml",
            @"djv", @"djvu", @"gif", @"jpeg", @"jpg", @"png", @"webp",
            @"cbr", @"cbt", @"cbz", @"cfb", @"pdf", @"pptx", @"xlsx",
            @"xps", @"hdp", @"j2k", @"jp2", @"jxr", @"pam", @"pbm",
            @"pgm", @"pnm", @"ppm", @"tif", @"tiff", @"wdp",
        ]];
    });
    return extensions;
}

static NSString *ko_allowed_extension(NSString *filename) {
    NSString *lowercaseName = filename.lowercaseString;
    NSString *bestMatch = nil;
    for (NSString *extension in ko_allowed_extensions()) {
        NSString *suffix = [@"." stringByAppendingString:extension];
        if ([lowercaseName hasSuffix:suffix]
                && (!bestMatch || extension.length > bestMatch.length)) {
            bestMatch = extension;
        }
    }
    return bestMatch;
}

static NSString *ko_truncate_utf8(NSString *value, NSUInteger byteLimit) {
    if ([value dataUsingEncoding:NSUTF8StringEncoding].length <= byteLimit) {
        return value;
    }

    NSMutableString *result = [NSMutableString string];
    [value enumerateSubstringsInRange:NSMakeRange(0, value.length)
                              options:NSStringEnumerationByComposedCharacterSequences
                           usingBlock:^(NSString *substring, NSRange substringRange,
                                        NSRange enclosingRange, BOOL *stop) {
        (void)substringRange;
        (void)enclosingRange;
        NSString *candidate = [result stringByAppendingString:substring];
        if ([candidate dataUsingEncoding:NSUTF8StringEncoding].length > byteLimit) {
            *stop = YES;
        } else {
            [result appendString:substring];
        }
    }];
    return result;
}

static NSString *ko_safe_stem(NSString *filename, NSString *extension) {
    NSUInteger suffixLength = extension.length + 1;
    NSString *stem = filename.length > suffixLength
        ? [filename substringToIndex:filename.length - suffixLength]
        : @"Book";
    stem = [stem precomposedStringWithCanonicalMapping];

    NSMutableCharacterSet *unsafe = [NSCharacterSet controlCharacterSet].mutableCopy;
    [unsafe formUnionWithCharacterSet:NSCharacterSet.illegalCharacterSet];
    [unsafe addCharactersInString:@"/\\:"];
    NSMutableString *sanitized = [NSMutableString string];
    [stem enumerateSubstringsInRange:NSMakeRange(0, stem.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *substring, NSRange substringRange,
                                       NSRange enclosingRange, BOOL *stop) {
        (void)substringRange;
        (void)enclosingRange;
        (void)stop;
        if ([substring rangeOfCharacterFromSet:unsafe].location == NSNotFound) {
            [sanitized appendString:substring];
        } else {
            [sanitized appendString:@"_"];
        }
    }];

    stem = [sanitized stringByTrimmingCharactersInSet:
                          NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([stem hasPrefix:@"."]) {
        stem = [stem substringFromIndex:1];
    }
    if (stem.length == 0) {
        stem = @"Book";
    }
    return stem;
}

static NSURL *ko_available_destination(NSURL *booksURL, NSString *stem,
                                       NSString *extension, NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSUInteger extensionBytes =
        [extension dataUsingEncoding:NSUTF8StringEncoding].length + 1;

    for (NSUInteger number = 1; number <= 10000; ++number) {
        NSString *collisionSuffix = number == 1
            ? @""
            : [NSString stringWithFormat:@" (%lu)", (unsigned long)number];
        NSUInteger suffixBytes =
            [collisionSuffix dataUsingEncoding:NSUTF8StringEncoding].length;
        if (extensionBytes + suffixBytes >= KO_IMPORT_MAX_FILENAME_BYTES) {
            break;
        }
        NSString *boundedStem = ko_truncate_utf8(
            stem, KO_IMPORT_MAX_FILENAME_BYTES - extensionBytes - suffixBytes);
        NSString *filename = [NSString stringWithFormat:@"%@%@.%@",
                                                        boundedStem,
                                                        collisionSuffix,
                                                        extension];
        NSURL *destination = [booksURL URLByAppendingPathComponent:filename
                                                        isDirectory:NO];
        if (![fileManager fileExistsAtPath:destination.path]) {
            return destination;
        }
    }

    if (error) {
        *error = ko_import_error(10, @"Could not choose a private destination name");
    }
    return nil;
}

static BOOL ko_validate_source(NSURL *url, NSString **filename,
                               NSString **extension, NSError **error) {
    if (!url.isFileURL) {
        if (error) *error = ko_import_error(20, @"The selected item is not a file");
        return NO;
    }

    NSArray<NSURLResourceKey> *keys = @[
        NSURLNameKey,
        NSURLIsRegularFileKey,
        NSURLIsDirectoryKey,
        NSURLIsSymbolicLinkKey,
        NSURLFileSizeKey,
    ];
    NSError *resourceError = nil;
    NSDictionary<NSURLResourceKey, id> *values =
        [url resourceValuesForKeys:keys error:&resourceError];
    if (!values) {
        if (error) *error = ko_import_error(21, @"The selected file is unavailable");
        return NO;
    }
    if ([values[NSURLIsDirectoryKey] boolValue]
            || [values[NSURLIsSymbolicLinkKey] boolValue]
            || ![values[NSURLIsRegularFileKey] boolValue]) {
        if (error) *error = ko_import_error(22, @"Only regular document files can be imported");
        return NO;
    }
    unsigned long long size = [values[NSURLFileSizeKey] unsignedLongLongValue];
    if (size > KO_IMPORT_MAX_BYTES) {
        if (error) *error = ko_import_error(23, @"The selected document is too large");
        return NO;
    }

    NSString *sourceName = values[NSURLNameKey] ?: url.lastPathComponent;
    NSString *allowedExtension = ko_allowed_extension(sourceName);
    if (!allowedExtension) {
        if (error) *error = ko_import_error(24, @"This document type is not allowed");
        return NO;
    }

    *filename = sourceName;
    *extension = allowedExtension;
    return YES;
}

static NSString *ko_copy_document_to_books(NSURL *sourceURL, NSError **error) {
    const char *booksHome = getenv("KO_BOOKS_HOME");
    if (!booksHome || booksHome[0] == '\0') {
        if (error) *error = ko_import_error(30, @"Private Books storage is unavailable");
        return nil;
    }

    NSURL *booksURL = [NSURL fileURLWithFileSystemRepresentation:booksHome
                                                    isDirectory:YES
                                                  relativeToURL:nil];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    __block NSString *resultPath = nil;
    __block NSError *operationError = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc]
        initWithFilePresenter:nil];
    NSError *coordinationError = nil;

    [coordinator coordinateReadingItemAtURL:sourceURL
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&coordinationError
                                 byAccessor:^(NSURL *coordinatedURL) {
        NSString *sourceName = nil;
        NSString *extension = nil;
        if (!ko_validate_source(coordinatedURL, &sourceName, &extension,
                                &operationError)) {
            return;
        }

        NSString *stem = ko_safe_stem(sourceName, extension);
        NSURL *temporaryURL = [booksURL URLByAppendingPathComponent:
            [NSString stringWithFormat:@".ko-import-%@.tmp",
                                       NSUUID.UUID.UUIDString]
                                                    isDirectory:NO];
        @try {
            if (![fileManager copyItemAtURL:coordinatedURL
                                      toURL:temporaryURL
                                      error:&operationError]) {
                operationError = ko_import_error(31, @"The selected document could not be copied");
                return;
            }

            struct stat info;
            if (lstat(temporaryURL.fileSystemRepresentation, &info) != 0
                    || !S_ISREG(info.st_mode) || S_ISLNK(info.st_mode)) {
                operationError = ko_import_error(32, @"The copied item is not a regular file");
                return;
            }
            if ((unsigned long long)info.st_size > KO_IMPORT_MAX_BYTES) {
                operationError = ko_import_error(33, @"The copied document is too large");
                return;
            }

            NSDictionary<NSFileAttributeKey, id> *attributes = @{
                NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
            };
            if (![fileManager setAttributes:attributes
                               ofItemAtPath:temporaryURL.path
                                      error:&operationError]) {
                operationError = ko_import_error(34, @"The copied document could not be protected");
                return;
            }

            NSURL *destination = ko_available_destination(booksURL, stem,
                                                          extension,
                                                          &operationError);
            if (!destination) return;
            if (![fileManager moveItemAtURL:temporaryURL
                                      toURL:destination
                                      error:&operationError]) {
                operationError = ko_import_error(35, @"The copied document could not be finalized");
                return;
            }
            resultPath = destination.path;
        } @finally {
            if ([fileManager fileExistsAtPath:temporaryURL.path]) {
                [fileManager removeItemAtURL:temporaryURL error:nil];
            }
        }
    }];

    if (!resultPath && !operationError && coordinationError) {
        operationError = ko_import_error(36, @"The selected document could not be coordinated");
    }
    if (!resultPath && !operationError) {
        operationError = ko_import_error(37, @"The selected document could not be imported");
    }
    if (error) *error = operationError;
    return resultPath;
}

static UIWindow *ko_ios_key_window(void) {
    NSCAssert(NSThread.isMainThread, @"UIKit must be queried on the main thread");
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState != UISceneActivationStateForegroundActive
                && scene.activationState != UISceneActivationStateForegroundInactive) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (!window) window = ((UIWindowScene *)scene).windows.firstObject;
        if (window) break;
    }
    return window;
}

static UIViewController *ko_ios_top_view_controller(void) {
    UIWindow *window = ko_ios_key_window();
    if (!window) return nil;
    UIViewController *controller = window.rootViewController;
    while (controller) {
        if (controller.presentedViewController
                && !controller.presentedViewController.isBeingDismissed) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            controller = ((UINavigationController *)controller).visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else {
            break;
        }
    }
    return controller;
}

@interface KOIOSImportDelegate : NSObject
    <UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate>
@property(nonatomic) BOOL selectionHandled;
@end

@implementation KOIOSImportDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    self.selectionHandled = YES;
    if (urls.count != 1) {
        ko_finish_import(KO_IMPORT_DONE_ERROR, nil,
                         @"The picker did not return one document");
        return;
    }

    NSURL *sourceURL = urls.firstObject;
    dispatch_async(ko_import_io_queue(), ^{
        @autoreleasepool {
            BOOL hasSecurityScope = [sourceURL startAccessingSecurityScopedResource];
            NSError *error = nil;
            NSString *path = nil;
            @try {
                path = ko_copy_document_to_books(sourceURL, &error);
            } @finally {
                /* asCopy:YES gives the app a temporary private copy that is
                 * otherwise retained until process exit. Our durable copy is
                 * already in Books, so release the picker copy promptly. */
                if (path) {
                    NSURL *homeURL = [NSURL fileURLWithPath:NSHomeDirectory()
                                                 isDirectory:YES];
                    const char *booksHome = getenv("KO_BOOKS_HOME");
                    NSURL *booksURL = booksHome
                        ? [NSURL fileURLWithFileSystemRepresentation:booksHome
                                                       isDirectory:YES
                                                     relativeToURL:nil]
                        : nil;
                    if (ko_url_is_at_or_inside_directory(sourceURL, homeURL)
                            && (!booksURL
                                || !ko_url_is_at_or_inside_directory(sourceURL, booksURL))) {
                        [NSFileManager.defaultManager removeItemAtURL:sourceURL error:nil];
                    }
                }
                if (hasSecurityScope) {
                    [sourceURL stopAccessingSecurityScopedResource];
                }
            }
            if (path) {
                ko_finish_import(KO_IMPORT_DONE_OK, path, nil);
            } else {
                ko_finish_import(KO_IMPORT_DONE_ERROR, nil,
                                 error.localizedDescription ?: @"Import failed");
            }
        }
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    self.selectionHandled = YES;
    ko_finish_import(KO_IMPORT_DONE_CANCEL, nil, nil);
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    if (!self.selectionHandled) {
        ko_finish_import(KO_IMPORT_DONE_CANCEL, nil, nil);
    }
}

@end


static KOIOSImportDelegate *g_import_delegate = nil;

KO_IOS_EXPORT bool ko_ios_import_document_start(void) {
    NSLock *lock = ko_import_state_lock();
    [lock lock];
    if (g_import_state != KO_IMPORT_IDLE) {
        [lock unlock];
        return false;
    }
    g_import_state = KO_IMPORT_PENDING;
    g_imported_path = nil;
    g_import_error = nil;
    [lock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            UIViewController *top = ko_ios_top_view_controller();
            if (!top) {
                ko_finish_import(KO_IMPORT_DONE_ERROR, nil,
                                 @"No active view controller is available");
                return;
            }
            if (!g_import_delegate) {
                g_import_delegate = [[KOIOSImportDelegate alloc] init];
            }
            g_import_delegate.selectionHandled = NO;

            UIDocumentPickerViewController *picker =
                [[UIDocumentPickerViewController alloc]
                    initForOpeningContentTypes:@[UTTypeData]
                                       asCopy:YES];
            /* Accessing presentationController freezes the controller type
             * for the current presentation style, so choose the style first. */
            picker.modalPresentationStyle = UIModalPresentationFullScreen;
            picker.delegate = g_import_delegate;
            picker.presentationController.delegate = g_import_delegate;
            picker.allowsMultipleSelection = NO;
            [top presentViewController:picker animated:YES completion:nil];
        }
    });
    return true;
}

static BOOL ko_copy_c_string(NSString *value, char *output, size_t capacity) {
    if (!output || capacity == 0) return NO;
    const char *utf8 = value.UTF8String ?: "";
    size_t length = strlen(utf8);
    if (length >= capacity) {
        output[0] = '\0';
        return NO;
    }
    memcpy(output, utf8, length + 1);
    return YES;
}

KO_IOS_EXPORT ko_import_state_t
ko_ios_import_document_poll(char *outPath, size_t pathCapacity,
                            char *outError, size_t errorCapacity) {
    if (outPath && pathCapacity > 0) outPath[0] = '\0';
    if (outError && errorCapacity > 0) outError[0] = '\0';

    NSLock *lock = ko_import_state_lock();
    [lock lock];
    ko_import_state_t state = g_import_state;
    if (state < KO_IMPORT_DONE_OK) {
        [lock unlock];
        return state;
    }

    if (state == KO_IMPORT_DONE_OK
            && !ko_copy_c_string(g_imported_path, outPath, pathCapacity)) {
        state = KO_IMPORT_DONE_ERROR;
        ko_copy_c_string(@"Private destination path is too long",
                         outError, errorCapacity);
    } else if (state == KO_IMPORT_DONE_ERROR) {
        ko_copy_c_string(g_import_error ?: @"Import failed",
                         outError, errorCapacity);
    }

    g_import_state = KO_IMPORT_IDLE;
    g_imported_path = nil;
    g_import_error = nil;
    [lock unlock];
    return state;
}

/* Read safe-area values entirely on the UIKit main thread, then expose only
 * primitive pixel values to the caller. */
KO_IOS_EXPORT void ko_ios_get_safe_area_pixels(int *outTop, int *outRight,
                                               int *outBottom, int *outLeft) {
    if (outTop) *outTop = 0;
    if (outRight) *outRight = 0;
    if (outBottom) *outBottom = 0;
    if (outLeft) *outLeft = 0;

    __block CGFloat top = 0;
    __block CGFloat right = 0;
    __block CGFloat bottom = 0;
    __block CGFloat left = 0;
    __block CGFloat scale = 1;
    void (^readSafeArea)(void) = ^{
        UIWindow *window = ko_ios_key_window();
        if (!window) return;
        [window layoutIfNeeded];
        UIEdgeInsets insets = window.safeAreaInsets;
        top = insets.top;
        right = insets.right;
        bottom = insets.bottom;
        left = insets.left;
        scale = window.screen.nativeScale;
    };

    if (NSThread.isMainThread) {
        readSafeArea();
    } else {
        dispatch_sync(dispatch_get_main_queue(), readSafeArea);
    }

    if (outTop) *outTop = (int)ceil(top * scale);
    if (outRight) *outRight = (int)ceil(right * scale);
    if (outBottom) *outBottom = (int)ceil(bottom * scale);
    if (outLeft) *outLeft = (int)ceil(left * scale);
}

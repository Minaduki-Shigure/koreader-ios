/* Strict iOS document and folder import plus safe-area bridge.
 *
 * The document picker is only an ingress UI. Selected items are coordinated,
 * validated, copied into an app-private staging directory, protected,
 * and atomically finalized before Lua can see them. Provider URLs are never
 * returned or kept. UIKit work stays on the main thread; potentially slow
 * provider and file I/O runs on a private serial queue. Lua drives the bridge
 * with start + poll.
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
#define KO_IMPORT_MAX_AGGREGATE_BYTES (4ULL * 1024ULL * 1024ULL * 1024ULL)
#define KO_IMPORT_MAX_SELECTED_ITEMS 64U
#define KO_IMPORT_MAX_DOCUMENTS 512U
#define KO_IMPORT_MAX_SCANNED_ITEMS 8192U
#define KO_IMPORT_MAX_DIRECTORY_DEPTH 32U
#define KO_IMPORT_MAX_RELATIVE_PATH_BYTES 2048U
#define KO_IMPORT_MAX_FILENAME_BYTES 220U
#define KO_IMPORT_MAX_DIRECTORY_NAME_BYTES 180U
#define KO_IMPORT_MAX_PRIVATE_PATH_BYTES 960U

typedef enum {
    KO_IMPORT_IDLE = 0,
    KO_IMPORT_PENDING = 1,
    KO_IMPORT_DONE_OK = 2,
    KO_IMPORT_DONE_CANCEL = 3,
    KO_IMPORT_DONE_ERROR = 4,
} ko_import_state_t;

typedef enum {
    KO_IMPORT_SELECT_FILES = 0,
    KO_IMPORT_SELECT_FOLDERS = 1,
} ko_import_selection_mode_t;

static ko_import_state_t g_import_state = KO_IMPORT_IDLE;
static NSString *g_imported_path = nil;
static NSString *g_import_error = nil;
static uint32_t g_imported_count = 0;
static uint32_t g_skipped_count = 0;
static BOOL g_imported_is_collection = NO;

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
                             NSString *message, NSUInteger importedCount,
                             NSUInteger skippedCount, BOOL isCollection) {
    NSLock *lock = ko_import_state_lock();
    [lock lock];
    if (g_import_state == KO_IMPORT_PENDING) {
        g_imported_path = state == KO_IMPORT_DONE_OK ? [path copy] : nil;
        g_import_error = state == KO_IMPORT_DONE_ERROR ? [message copy] : nil;
        g_imported_count = state == KO_IMPORT_DONE_OK
            ? (uint32_t)importedCount : 0;
        g_skipped_count = state == KO_IMPORT_DONE_OK
            ? (uint32_t)skippedCount : 0;
        g_imported_is_collection = state == KO_IMPORT_DONE_OK && isCollection;
        g_import_state = state;
    }
    [lock unlock];
}

static NSError *ko_import_error(NSInteger code, NSString *description) {
    return [NSError errorWithDomain:@"rocks.koreader.ios.import"
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

static BOOL ko_lstat_url(NSURL *url, struct stat *info, NSError **error) {
    if (lstat(url.fileSystemRepresentation, info) == 0) {
        return YES;
    }
    if (error) {
        *error = ko_import_error(19, @"A selected filesystem item is unavailable");
    }
    return NO;
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

static NSString *ko_safe_component(NSString *value, NSString *fallback,
                                   NSUInteger byteLimit) {
    value = [value precomposedStringWithCanonicalMapping];

    NSMutableCharacterSet *unsafe = [NSCharacterSet controlCharacterSet].mutableCopy;
    [unsafe formUnionWithCharacterSet:NSCharacterSet.illegalCharacterSet];
    [unsafe addCharactersInString:@"/\\:"];
    NSMutableString *sanitized = [NSMutableString string];
    [value enumerateSubstringsInRange:NSMakeRange(0, value.length)
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

    NSString *result = [sanitized stringByTrimmingCharactersInSet:
                                   NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([result hasPrefix:@"."]) {
        result = [result substringFromIndex:1];
    }
    while ([result hasSuffix:@"."]) {
        result = [result substringToIndex:result.length - 1];
    }
    result = ko_truncate_utf8(result, byteLimit);
    if (result.length == 0 || [result isEqualToString:@"."]
            || [result isEqualToString:@".."]) {
        result = fallback;
    }
    return result;
}

static NSString *ko_safe_stem(NSString *filename, NSString *extension) {
    NSUInteger suffixLength = extension.length + 1;
    NSString *stem = filename.length > suffixLength
        ? [filename substringToIndex:filename.length - suffixLength]
        : @"Book";
    return ko_safe_component(stem, @"Book", KO_IMPORT_MAX_FILENAME_BYTES);
}

static BOOL ko_name_is_sidecar(NSString *name) {
    NSString *lowercaseName = name.lowercaseString;
    if ([lowercaseName hasPrefix:@"."] || [lowercaseName hasPrefix:@"._"]
            || [lowercaseName hasSuffix:@".sdr"]) {
        return YES;
    }
    static NSSet<NSString *> *sidecars;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sidecars = [NSSet setWithArray:@[
            @"desktop.ini", @"thumbs.db", @"metadata.calibre",
            @"calibre_bookmarks.txt",
        ]];
    });
    return [sidecars containsObject:lowercaseName];
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
        if (boundedStem.length == 0) {
            boundedStem = @"Book";
        }
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

static NSURL *ko_available_directory(NSURL *parentURL, NSString *name,
                                     NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *safeName = ko_safe_component(name, @"Imported Books",
                                            KO_IMPORT_MAX_DIRECTORY_NAME_BYTES);
    for (NSUInteger number = 1; number <= 10000; ++number) {
        NSString *collisionSuffix = number == 1
            ? @""
            : [NSString stringWithFormat:@" (%lu)", (unsigned long)number];
        NSUInteger suffixBytes =
            [collisionSuffix dataUsingEncoding:NSUTF8StringEncoding].length;
        if (suffixBytes >= KO_IMPORT_MAX_DIRECTORY_NAME_BYTES) break;
        NSString *boundedName = ko_truncate_utf8(
            safeName, KO_IMPORT_MAX_DIRECTORY_NAME_BYTES - suffixBytes);
        NSString *candidateName = [boundedName stringByAppendingString:collisionSuffix];
        NSURL *candidate = [parentURL URLByAppendingPathComponent:candidateName
                                                      isDirectory:YES];
        if (![fileManager fileExistsAtPath:candidate.path]) {
            return candidate;
        }
    }

    if (error) {
        *error = ko_import_error(11, @"Could not choose a private directory name");
    }
    return nil;
}

static BOOL ko_create_protected_directory(NSURL *url, NSError **error) {
    NSDictionary<NSFileAttributeKey, id> *attributes = @{
        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
    };
    return [NSFileManager.defaultManager createDirectoryAtURL:url
                                  withIntermediateDirectories:NO
                                                   attributes:attributes
                                                        error:error];
}

static NSURL *ko_import_staging_root(NSError **error) {
    const char *dataHome = getenv("KO_HOME");
    if (!dataHome || dataHome[0] == '\0') {
        if (error) *error = ko_import_error(12, @"Private app storage is unavailable");
        return nil;
    }

    NSURL *dataURL = [NSURL fileURLWithFileSystemRepresentation:dataHome
                                                    isDirectory:YES
                                                  relativeToURL:nil];
    struct stat dataInfo;
    if (!ko_lstat_url(dataURL, &dataInfo, error)
            || !S_ISDIR(dataInfo.st_mode) || S_ISLNK(dataInfo.st_mode)) {
        if (error && !*error) {
            *error = ko_import_error(12, @"Private app storage is unavailable");
        }
        return nil;
    }

    NSURL *rootURL = [dataURL URLByAppendingPathComponent:@"ImportStaging"
                                               isDirectory:YES];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager fileExistsAtPath:rootURL.path]
            && !ko_create_protected_directory(rootURL, error)) {
        return nil;
    }

    struct stat rootInfo;
    if (!ko_lstat_url(rootURL, &rootInfo, error)
            || !S_ISDIR(rootInfo.st_mode) || S_ISLNK(rootInfo.st_mode)) {
        if (error && !*error) {
            *error = ko_import_error(13,
                @"Private import staging storage is unavailable");
        }
        return nil;
    }

    NSDictionary<NSFileAttributeKey, id> *attributes = @{
        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
    };
    NSNumber *excludedFromBackup = @YES;
    if (![fileManager setAttributes:attributes
                   ofItemAtPath:rootURL.path
                          error:error]
            || ![rootURL setResourceValue:excludedFromBackup
                                    forKey:NSURLIsExcludedFromBackupKey
                                     error:error]) {
        return nil;
    }
    return rootURL;
}

static void ko_remove_stale_staging_items(NSURL *stagingRootURL) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSArray<NSURL *> *items = [fileManager contentsOfDirectoryAtURL:stagingRootURL
                                          includingPropertiesForKeys:nil
                                                             options:0
                                                               error:nil];
    for (NSURL *itemURL in items) {
        NSString *name = itemURL.lastPathComponent;
        if (![name hasSuffix:@".tmp"]) {
            continue;
        }
        NSString *uuidString = [name substringToIndex:name.length - 4];
        if (![[NSUUID alloc] initWithUUIDString:uuidString]) {
            continue;
        }
        struct stat info;
        if (lstat(itemURL.fileSystemRepresentation, &info) != 0
                || S_ISLNK(info.st_mode) || !S_ISDIR(info.st_mode)) {
            continue;
        }
        [fileManager removeItemAtURL:itemURL error:nil];
    }
}

static BOOL ko_validate_source(NSURL *url, NSString **filename,
                               NSString **extension,
                               unsigned long long *fileSize,
                               NSError **error) {
    if (!url.isFileURL) {
        if (error) *error = ko_import_error(20, @"The selected item is not a file");
        return NO;
    }

    struct stat sourceInfo;
    if (!ko_lstat_url(url, &sourceInfo, error)) {
        return NO;
    }
    if (!S_ISREG(sourceInfo.st_mode) || S_ISLNK(sourceInfo.st_mode)) {
        if (error) {
            *error = ko_import_error(22,
                @"Only regular document files can be imported");
        }
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
    if (fileSize) *fileSize = size;
    return YES;
}

@interface KOIOSImportBatchContext : NSObject
@property(nonatomic) NSUInteger importedCount;
@property(nonatomic) NSUInteger skippedCount;
@property(nonatomic) NSUInteger scannedCount;
@property(nonatomic) unsigned long long aggregateBytes;
@property(nonatomic, strong) NSURL *stageURL;
@property(nonatomic, strong) NSMutableArray<NSURL *> *copiedURLs;
@end

@implementation KOIOSImportBatchContext
@end

@interface KOIOSImportResult : NSObject
@property(nonatomic, copy) NSString *path;
@property(nonatomic) NSUInteger importedCount;
@property(nonatomic) NSUInteger skippedCount;
@property(nonatomic) BOOL isCollection;
@end

@implementation KOIOSImportResult
@end

static NSURL *ko_copy_document_to_stage(NSURL *sourceURL,
                                        NSURL *destinationDirectory,
                                        KOIOSImportBatchContext *context,
                                        NSError **error) {
    NSString *sourceName = nil;
    NSString *extension = nil;
    unsigned long long reportedSize = 0;
    if (!ko_validate_source(sourceURL, &sourceName, &extension, &reportedSize,
                            error)) {
        return nil;
    }
    if (context.importedCount >= KO_IMPORT_MAX_DOCUMENTS) {
        if (error) {
            *error = ko_import_error(25,
                @"A batch may contain at most 512 supported documents");
        }
        return nil;
    }
    if (reportedSize > KO_IMPORT_MAX_AGGREGATE_BYTES
            || context.aggregateBytes
                > KO_IMPORT_MAX_AGGREGATE_BYTES - reportedSize) {
        if (error) {
            *error = ko_import_error(26,
                @"The total imported size may not exceed 4 GiB");
        }
        return nil;
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    __block NSError *operationError = nil;
    NSURL *temporaryURL = [context.stageURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@".ko-item-%@.tmp", NSUUID.UUID.UUIDString]
                                                       isDirectory:NO];
    NSURL *resultURL = nil;
    @try {
        if (![fileManager copyItemAtURL:sourceURL
                                  toURL:temporaryURL
                                  error:&operationError]) {
            operationError = ko_import_error(31,
                @"A selected document could not be copied");
            return nil;
        }

        struct stat info;
        if (lstat(temporaryURL.fileSystemRepresentation, &info) != 0
                || !S_ISREG(info.st_mode) || S_ISLNK(info.st_mode)) {
            operationError = ko_import_error(32,
                @"A copied item is not a regular file");
            return nil;
        }
        unsigned long long actualSize = (unsigned long long)info.st_size;
        if (actualSize > KO_IMPORT_MAX_BYTES) {
            operationError = ko_import_error(33,
                @"A copied document exceeds the 2 GiB file limit");
            return nil;
        }
        if (actualSize > KO_IMPORT_MAX_AGGREGATE_BYTES
                || context.aggregateBytes
                    > KO_IMPORT_MAX_AGGREGATE_BYTES - actualSize) {
            operationError = ko_import_error(26,
                @"The total imported size may not exceed 4 GiB");
            return nil;
        }

        NSDictionary<NSFileAttributeKey, id> *attributes = @{
            NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
        };
        if (![fileManager setAttributes:attributes
                           ofItemAtPath:temporaryURL.path
                                  error:&operationError]) {
            operationError = ko_import_error(34,
                @"A copied document could not be protected");
            return nil;
        }

        NSString *stem = ko_safe_stem(sourceName, extension);
        NSURL *destination = ko_available_destination(destinationDirectory, stem,
                                                      extension, &operationError);
        if (!destination) return nil;
        if ([destination.path dataUsingEncoding:NSUTF8StringEncoding].length
                > KO_IMPORT_MAX_PRIVATE_PATH_BYTES) {
            operationError = ko_import_error(38,
                @"An imported destination exceeds the private path limit");
            return nil;
        }
        if (![fileManager moveItemAtURL:temporaryURL
                                  toURL:destination
                                  error:&operationError]) {
            operationError = ko_import_error(35,
                @"A copied document could not be finalized");
            return nil;
        }

        context.importedCount += 1;
        context.aggregateBytes += actualSize;
        [context.copiedURLs addObject:destination];
        resultURL = destination;
    } @finally {
        if ([fileManager fileExistsAtPath:temporaryURL.path]) {
            [fileManager removeItemAtURL:temporaryURL error:nil];
        }
        if (error && !resultURL) *error = operationError;
    }
    return resultURL;
}

static NSArray<NSString *> *ko_relative_components(NSURL *itemURL,
                                                   NSURL *rootURL,
                                                   NSError **error) {
    NSString *rootPath = rootURL.URLByStandardizingPath.path;
    NSString *itemPath = itemURL.URLByStandardizingPath.path;
    NSString *prefix = [rootPath stringByAppendingString:@"/"];
    if (!rootPath || !itemPath || ![itemPath hasPrefix:prefix]) {
        if (error) {
            *error = ko_import_error(40,
                @"A folder provider returned an item outside the selected folder");
        }
        return nil;
    }
    NSString *relativePath = [itemPath substringFromIndex:prefix.length];
    if ([relativePath dataUsingEncoding:NSUTF8StringEncoding].length
            > KO_IMPORT_MAX_RELATIVE_PATH_BYTES) {
        if (error) {
            *error = ko_import_error(41,
                @"A folder item exceeds the 2048-byte relative path limit");
        }
        return nil;
    }
    NSArray<NSString *> *components = relativePath.pathComponents;
    if (components.count == 0
            || [components containsObject:@"."]
            || [components containsObject:@".."]) {
        if (error) {
            *error = ko_import_error(42, @"A folder contains an invalid path");
        }
        return nil;
    }
    if (components.count > KO_IMPORT_MAX_DIRECTORY_DEPTH + 1) {
        if (error) {
            *error = ko_import_error(43,
                @"A folder exceeds the 32-level directory depth limit");
        }
        return nil;
    }
    return components;
}

static NSURL *ko_ensure_relative_directory(
        NSArray<NSString *> *components, NSURL *baseURL,
        NSMutableDictionary<NSString *, NSURL *> *directoryMap,
        NSError **error) {
    NSURL *parentURL = baseURL;
    NSMutableArray<NSString *> *sourcePath = [NSMutableArray array];
    for (NSString *component in components) {
        [sourcePath addObject:component];
        NSString *key = [sourcePath componentsJoinedByString:@"/"];
        NSURL *existing = directoryMap[key];
        if (existing) {
            parentURL = existing;
            continue;
        }

        NSURL *directoryURL = ko_available_directory(parentURL, component, error);
        if (!directoryURL) return nil;
        if ([directoryURL.path dataUsingEncoding:NSUTF8StringEncoding].length
                > KO_IMPORT_MAX_PRIVATE_PATH_BYTES) {
            if (error) {
                *error = ko_import_error(48,
                    @"An imported directory exceeds the private path limit");
            }
            return nil;
        }
        if (!ko_create_protected_directory(directoryURL, error)) {
            if (error && !*error) {
                *error = ko_import_error(44,
                    @"An imported directory could not be created");
            }
            return nil;
        }
        directoryMap[key] = directoryURL;
        parentURL = directoryURL;
    }
    return parentURL;
}

static BOOL ko_import_directory(NSURL *sourceRoot, NSURL *destinationRoot,
                                KOIOSImportBatchContext *context,
                                NSError **error) {
    NSArray<NSURLResourceKey> *keys = @[
        NSURLNameKey,
        NSURLIsRegularFileKey,
        NSURLIsDirectoryKey,
        NSURLIsSymbolicLinkKey,
        NSURLIsHiddenKey,
        NSURLIsPackageKey,
        NSURLFileSizeKey,
    ];
    __block NSError *enumerationError = nil;
    NSDirectoryEnumerator<NSURL *> *enumerator =
        [NSFileManager.defaultManager enumeratorAtURL:sourceRoot
                           includingPropertiesForKeys:keys
                                              options:0
                                         errorHandler:^BOOL(NSURL *url,
                                                             NSError *itemError) {
        (void)url;
        enumerationError = itemError ?: ko_import_error(45,
            @"A selected folder could not be enumerated");
        return NO;
    }];
    if (!enumerator) {
        if (error) {
            *error = enumerationError ?: ko_import_error(45,
                @"A selected folder could not be enumerated");
        }
        return NO;
    }

    NSMutableDictionary<NSString *, NSURL *> *directoryMap =
        [NSMutableDictionary dictionary];
    for (NSURL *itemURL in enumerator) {
        if (enumerationError) break;
        context.scannedCount += 1;
        if (context.scannedCount > KO_IMPORT_MAX_SCANNED_ITEMS) {
            if (error) {
                *error = ko_import_error(46,
                    @"Selected folders may contain at most 8192 entries");
            }
            return NO;
        }

        NSError *itemError = nil;
        NSDictionary<NSURLResourceKey, id> *values =
            [itemURL resourceValuesForKeys:keys error:&itemError];
        if (!values) {
            if (error) {
                *error = itemError ?: ko_import_error(47,
                    @"A selected folder item is unavailable");
            }
            return NO;
        }
        NSString *name = values[NSURLNameKey] ?: itemURL.lastPathComponent;
        struct stat sourceInfo;
        if (!ko_lstat_url(itemURL, &sourceInfo, &itemError)) {
            if (error) *error = itemError;
            return NO;
        }
        BOOL isDirectory = S_ISDIR(sourceInfo.st_mode);
        BOOL isRegular = S_ISREG(sourceInfo.st_mode);
        BOOL isSymlink = S_ISLNK(sourceInfo.st_mode)
            || [values[NSURLIsSymbolicLinkKey] boolValue];
        BOOL isHidden = [values[NSURLIsHiddenKey] boolValue];
        BOOL isPackage = [values[NSURLIsPackageKey] boolValue];
        if (isSymlink || isHidden || ko_name_is_sidecar(name)
                || (isDirectory && isPackage)) {
            if (isDirectory) [enumerator skipDescendants];
            context.skippedCount += 1;
            continue;
        }

        NSArray<NSString *> *components =
            ko_relative_components(itemURL, sourceRoot, &itemError);
        if (!components) {
            if (error) *error = itemError;
            return NO;
        }
        if (isDirectory) continue;
        if (!isRegular || ![values[NSURLIsRegularFileKey] boolValue]) {
            context.skippedCount += 1;
            continue;
        }
        if (!ko_allowed_extension(name)) {
            context.skippedCount += 1;
            continue;
        }
        if ([values[NSURLFileSizeKey] unsignedLongLongValue] > KO_IMPORT_MAX_BYTES) {
            if (error) {
                *error = ko_import_error(23,
                    @"A selected document exceeds the 2 GiB file limit");
            }
            return NO;
        }

        NSArray<NSString *> *directoryComponents = components.count > 1
            ? [components subarrayWithRange:NSMakeRange(0, components.count - 1)]
            : @[];
        NSURL *destinationDirectory = ko_ensure_relative_directory(
            directoryComponents, destinationRoot, directoryMap, &itemError);
        if (!destinationDirectory) {
            if (error) *error = itemError;
            return NO;
        }
        BOOL hasItemSecurityScope =
            [itemURL startAccessingSecurityScopedResource];
        if (!hasItemSecurityScope) {
            if (error) {
                *error = ko_import_error(56,
                    @"Access to a document inside the selected folder could not be started");
            }
            return NO;
        }
        NSURL *copiedURL = nil;
        @try {
            copiedURL = ko_copy_document_to_stage(itemURL,
                                                  destinationDirectory,
                                                  context,
                                                  &itemError);
        } @finally {
            [itemURL stopAccessingSecurityScopedResource];
        }
        if (!copiedURL) {
            if (error) *error = itemError;
            return NO;
        }
    }

    if (enumerationError) {
        if (error) *error = enumerationError;
        return NO;
    }
    return YES;
}

static BOOL ko_import_selected_url(NSURL *sourceURL, BOOL groupTopLevel,
                                   KOIOSImportBatchContext *context,
                                   BOOL *isDirectoryResult,
                                   NSString **directoryNameResult,
                                   NSError **error) {
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc]
        initWithFilePresenter:nil];
    __block NSError *operationError = nil;
    __block BOOL operationSucceeded = NO;
    NSError *coordinationError = nil;

    [coordinator coordinateReadingItemAtURL:sourceURL
                                    options:NSFileCoordinatorReadingWithoutChanges
                                      error:&coordinationError
                                 byAccessor:^(NSURL *coordinatedURL) {
        if (!coordinatedURL.isFileURL) {
            operationError = ko_import_error(20,
                @"The selected item is not a file or folder");
            return;
        }
        NSArray<NSURLResourceKey> *keys = @[
            NSURLNameKey,
            NSURLIsRegularFileKey,
            NSURLIsDirectoryKey,
            NSURLIsSymbolicLinkKey,
            NSURLIsHiddenKey,
            NSURLIsPackageKey,
            NSURLFileSizeKey,
        ];
        NSDictionary<NSURLResourceKey, id> *values =
            [coordinatedURL resourceValuesForKeys:keys error:&operationError];
        if (!values) return;

        NSString *name = values[NSURLNameKey] ?: coordinatedURL.lastPathComponent;
        struct stat sourceInfo;
        if (!ko_lstat_url(coordinatedURL, &sourceInfo, &operationError)) return;
        BOOL isDirectory = S_ISDIR(sourceInfo.st_mode);
        BOOL isRegular = S_ISREG(sourceInfo.st_mode);
        BOOL isSymlink = S_ISLNK(sourceInfo.st_mode)
            || [values[NSURLIsSymbolicLinkKey] boolValue];
        if (isDirectoryResult) *isDirectoryResult = isDirectory;
        if (isDirectory && directoryNameResult) *directoryNameResult = [name copy];

        if (isSymlink
                || [values[NSURLIsHiddenKey] boolValue]
                || ko_name_is_sidecar(name)
                || (isDirectory && [values[NSURLIsPackageKey] boolValue])) {
            context.skippedCount += 1;
            operationSucceeded = YES;
            return;
        }
        if (isDirectory) {
            NSURL *destinationRoot = context.stageURL;
            if (groupTopLevel) {
                destinationRoot = ko_available_directory(context.stageURL, name,
                                                         &operationError);
                if (!destinationRoot
                        || !ko_create_protected_directory(destinationRoot,
                                                          &operationError)) {
                    return;
                }
            }
            NSUInteger countBefore = context.importedCount;
            operationSucceeded = ko_import_directory(coordinatedURL,
                                                     destinationRoot,
                                                     context,
                                                     &operationError);
            if (groupTopLevel && operationSucceeded
                    && context.importedCount == countBefore) {
                [NSFileManager.defaultManager removeItemAtURL:destinationRoot
                                                         error:nil];
            }
            return;
        }
        if (!isRegular || ![values[NSURLIsRegularFileKey] boolValue]
                || !ko_allowed_extension(name)) {
            context.skippedCount += 1;
            operationSucceeded = YES;
            return;
        }
        if ([values[NSURLFileSizeKey] unsignedLongLongValue] > KO_IMPORT_MAX_BYTES) {
            operationError = ko_import_error(23,
                @"A selected document exceeds the 2 GiB file limit");
            return;
        }
        operationSucceeded = ko_copy_document_to_stage(
            coordinatedURL, context.stageURL, context, &operationError) != nil;
    }];

    if (!operationSucceeded && !operationError && coordinationError) {
        operationError = ko_import_error(36,
            @"A selected item could not be coordinated");
    }
    if (!operationSucceeded && !operationError) {
        operationError = ko_import_error(37,
            @"A selected item could not be imported");
    }
    if (error) *error = operationError;
    return operationSucceeded;
}

static KOIOSImportResult *ko_copy_selection_to_books(
        NSArray<NSURL *> *sourceURLs, BOOL requireSecurityScope,
        NSError **error) {
    if (sourceURLs.count == 0 || sourceURLs.count > KO_IMPORT_MAX_SELECTED_ITEMS) {
        if (error) {
            *error = ko_import_error(50,
                @"Select between 1 and 64 top-level files or folders");
        }
        return nil;
    }

    const char *booksHome = getenv("KO_BOOKS_HOME");
    if (!booksHome || booksHome[0] == '\0') {
        if (error) *error = ko_import_error(30, @"Private Books storage is unavailable");
        return nil;
    }

    NSURL *booksURL = [NSURL fileURLWithFileSystemRepresentation:booksHome
                                                    isDirectory:YES
                                                  relativeToURL:nil];
    NSFileManager *fileManager = NSFileManager.defaultManager;
    struct stat booksInfo;
    if (lstat(booksURL.fileSystemRepresentation, &booksInfo) != 0
            || !S_ISDIR(booksInfo.st_mode) || S_ISLNK(booksInfo.st_mode)) {
        if (error) *error = ko_import_error(30, @"Private Books storage is unavailable");
        return nil;
    }
    NSError *operationError = nil;
    NSURL *stagingRootURL = ko_import_staging_root(&operationError);
    if (!stagingRootURL) {
        if (error) *error = operationError;
        return nil;
    }
    ko_remove_stale_staging_items(stagingRootURL);

    NSURL *stageURL = [stagingRootURL URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.tmp", NSUUID.UUID.UUIDString]
                                               isDirectory:YES];
    if (!ko_create_protected_directory(stageURL, &operationError)) {
        if (error) {
            *error = ko_import_error(51,
                @"A private import staging directory could not be created");
        }
        return nil;
    }

    KOIOSImportBatchContext *context = [[KOIOSImportBatchContext alloc] init];
    context.stageURL = stageURL;
    context.copiedURLs = [NSMutableArray array];
    BOOL collection = sourceURLs.count > 1;
    NSString *singleDirectoryName = nil;
    KOIOSImportResult *result = nil;
    @try {
        for (NSURL *sourceURL in sourceURLs) {
            BOOL selectedDirectory = NO;
            NSString *directoryName = nil;
            BOOL hasSecurityScope = [sourceURL startAccessingSecurityScopedResource];
            BOOL imported = NO;
            if (requireSecurityScope && !hasSecurityScope) {
                operationError = ko_import_error(55,
                    @"Access to a selected folder could not be started");
                return nil;
            }
            @try {
                imported = ko_import_selected_url(sourceURL, sourceURLs.count > 1,
                                                  context, &selectedDirectory,
                                                  &directoryName,
                                                  &operationError);
            } @finally {
                if (hasSecurityScope) {
                    [sourceURL stopAccessingSecurityScopedResource];
                }
            }
            if (!imported) {
                return nil;
            }
            if (selectedDirectory) {
                collection = YES;
                if (sourceURLs.count == 1) singleDirectoryName = directoryName;
            }
        }
        if (context.importedCount == 0) {
            operationError = ko_import_error(52,
                @"No supported documents were found in the selection");
            return nil;
        }

        NSURL *finalURL = nil;
        if (collection) {
            NSString *collectionName = sourceURLs.count == 1
                ? (singleDirectoryName ?: @"Imported Books")
                : @"Imported Books";
            finalURL = ko_available_directory(booksURL, collectionName,
                                              &operationError);
            if (finalURL
                    && [finalURL.path dataUsingEncoding:NSUTF8StringEncoding].length
                        > KO_IMPORT_MAX_PRIVATE_PATH_BYTES) {
                operationError = ko_import_error(48,
                    @"The imported collection exceeds the private path limit");
                finalURL = nil;
            }
            if (!finalURL
                    || ![fileManager moveItemAtURL:stageURL
                                             toURL:finalURL
                                             error:&operationError]) {
                if (!operationError) {
                    operationError = ko_import_error(53,
                        @"The imported collection could not be finalized");
                }
                return nil;
            }
        } else {
            NSURL *stagedFile = context.copiedURLs.firstObject;
            NSString *extension = ko_allowed_extension(stagedFile.lastPathComponent);
            NSString *stem = ko_safe_stem(stagedFile.lastPathComponent, extension);
            finalURL = ko_available_destination(booksURL, stem, extension,
                                                &operationError);
            if (!finalURL
                    || ![fileManager moveItemAtURL:stagedFile
                                             toURL:finalURL
                                             error:&operationError]) {
                if (!operationError) {
                    operationError = ko_import_error(54,
                        @"The imported document could not be finalized");
                }
                return nil;
            }
        }

        result = [[KOIOSImportResult alloc] init];
        result.path = finalURL.path;
        result.importedCount = context.importedCount;
        result.skippedCount = context.skippedCount;
        result.isCollection = collection;
    } @finally {
        if ([fileManager fileExistsAtPath:stageURL.path]) {
            [fileManager removeItemAtURL:stageURL error:nil];
        }
        if (error && !result) *error = operationError;
    }
    return result;
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
    if (urls.count == 0 || urls.count > KO_IMPORT_MAX_SELECTED_ITEMS) {
        ko_finish_import(KO_IMPORT_DONE_ERROR, nil,
                         @"Select between 1 and 64 top-level files or folders",
                         0, 0, NO);
        return;
    }

    NSArray<NSURL *> *sourceURLs = [urls copy];
    dispatch_async(ko_import_io_queue(), ^{
        @autoreleasepool {
            NSError *error = nil;
            KOIOSImportResult *result =
                ko_copy_selection_to_books(sourceURLs, YES, &error);
            if (result) {
                ko_finish_import(KO_IMPORT_DONE_OK, result.path, nil,
                                 result.importedCount, result.skippedCount,
                                 result.isCollection);
            } else {
                ko_finish_import(KO_IMPORT_DONE_ERROR, nil,
                                 error.localizedDescription ?: @"Import failed",
                                 0, 0, NO);
            }
        }
    });
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    self.selectionHandled = YES;
    ko_finish_import(KO_IMPORT_DONE_CANCEL, nil, nil, 0, 0, NO);
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    if (!self.selectionHandled) {
        ko_finish_import(KO_IMPORT_DONE_CANCEL, nil, nil, 0, 0, NO);
    }
}

@end


static KOIOSImportDelegate *g_import_delegate = nil;

KO_IOS_EXPORT bool
ko_ios_import_document_start(ko_import_selection_mode_t selectionMode) {
    if (selectionMode != KO_IMPORT_SELECT_FILES
            && selectionMode != KO_IMPORT_SELECT_FOLDERS) {
        return false;
    }

    NSLock *lock = ko_import_state_lock();
    [lock lock];
    if (g_import_state != KO_IMPORT_IDLE) {
        [lock unlock];
        return false;
    }
    g_import_state = KO_IMPORT_PENDING;
    g_imported_path = nil;
    g_import_error = nil;
    g_imported_count = 0;
    g_skipped_count = 0;
    g_imported_is_collection = NO;
    [lock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            UIViewController *top = ko_ios_top_view_controller();
            if (!top) {
                ko_finish_import(KO_IMPORT_DONE_ERROR, nil,
                                 @"No active view controller is available",
                                 0, 0, NO);
                return;
            }
            if (!g_import_delegate) {
                g_import_delegate = [[KOIOSImportDelegate alloc] init];
            }
            g_import_delegate.selectionHandled = NO;

            BOOL selectsFiles = selectionMode == KO_IMPORT_SELECT_FILES;
            NSArray<UTType *> *contentTypes =
                selectsFiles ? @[UTTypeData] : @[UTTypeFolder];
            UIDocumentPickerViewController *picker =
                [[UIDocumentPickerViewController alloc]
                    initForOpeningContentTypes:contentTypes
                                       asCopy:NO];
            /* Accessing presentationController freezes the controller type
             * for the current presentation style, so choose the style first. */
            picker.modalPresentationStyle = UIModalPresentationFullScreen;
            picker.delegate = g_import_delegate;
            picker.presentationController.delegate = g_import_delegate;
            picker.allowsMultipleSelection = selectsFiles;
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
                            char *outError, size_t errorCapacity,
                            uint32_t *outImportedCount,
                            uint32_t *outSkippedCount,
                            int *outIsCollection) {
    if (outPath && pathCapacity > 0) outPath[0] = '\0';
    if (outError && errorCapacity > 0) outError[0] = '\0';
    if (outImportedCount) *outImportedCount = 0;
    if (outSkippedCount) *outSkippedCount = 0;
    if (outIsCollection) *outIsCollection = 0;

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
    } else if (state == KO_IMPORT_DONE_OK) {
        if (outImportedCount) *outImportedCount = g_imported_count;
        if (outSkippedCount) *outSkippedCount = g_skipped_count;
        if (outIsCollection) *outIsCollection = g_imported_is_collection ? 1 : 0;
    }

    g_import_state = KO_IMPORT_IDLE;
    g_imported_path = nil;
    g_import_error = nil;
    g_imported_count = 0;
    g_skipped_count = 0;
    g_imported_is_collection = NO;
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

/* iOS launcher for KOReader.

   Counterpart of base/osx_loader.c. SDL3's iOS support replaces
   `main` with a wrapper that calls UIApplicationMain first; once
   the runloop is up, it invokes our `SDL_main` (this file's main),
   which then boots Lua and hands off to reader.lua.

   Differences vs. macOS:
   - iOS apps have a flat bundle (no Contents/), and the working
     directory at launch is opaque, so we resolve paths via NSBundle.
   - `_NSGetExecutablePath` + `chdir(dirname/../koreader)` would land
     somewhere unrelated to the bundle.
*/

#import <Foundation/Foundation.h>

#include <SDL3/SDL_main.h>

#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#define LOGNAME "iOS loader"
#define LANGUAGE "en_US.UTF-8"
#define LUA_ERROR "failed to run lua chunk: %s\n"

static BOOL create_private_directory(NSFileManager *fileManager, NSURL *url,
                                     BOOL excludeFromBackup, NSError **error) {
    NSDictionary<NSFileAttributeKey, id> *attributes = @{
        NSFileProtectionKey: NSFileProtectionCompleteUntilFirstUserAuthentication,
    };
    if (![fileManager createDirectoryAtURL:url
               withIntermediateDirectories:YES
                                attributes:attributes
                                     error:error]) {
        return NO;
    }
    struct stat info;
    if (lstat(url.fileSystemRepresentation, &info) != 0
            || !S_ISDIR(info.st_mode) || S_ISLNK(info.st_mode)) {
        if (error) {
            *error = [NSError errorWithDomain:@"rocks.koreader.ios.storage"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Private storage is not a regular directory"}];
        }
        return NO;
    }
    if (![fileManager setAttributes:attributes
                       ofItemAtPath:url.path
                              error:error]) {
        return NO;
    }
    if (excludeFromBackup) {
        NSNumber *excluded = @YES;
        if (![url setResourceValue:excluded
                            forKey:NSURLIsExcludedFromBackupKey
                             error:error]) {
            return NO;
        }
    }
    return YES;
}

static BOOL configure_private_storage(NSString **dataPath, NSString **booksPath,
                                      NSError **error) {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSURL *applicationSupport = [fileManager URLsForDirectory:NSApplicationSupportDirectory
                                                    inDomains:NSUserDomainMask].firstObject;
    if (!applicationSupport) {
        if (error) {
            *error = [NSError errorWithDomain:@"rocks.koreader.ios.storage"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    @"Application Support is unavailable"}];
        }
        return NO;
    }

    NSURL *root = [applicationSupport URLByAppendingPathComponent:@"KOReader"
                                                       isDirectory:YES];
    NSURL *data = [root URLByAppendingPathComponent:@"Data" isDirectory:YES];
    NSURL *books = [root URLByAppendingPathComponent:@"Books" isDirectory:YES];
    NSURL *cache = [data URLByAppendingPathComponent:@"cache" isDirectory:YES];

    if (!create_private_directory(fileManager, root, NO, error)
            || !create_private_directory(fileManager, data, NO, error)
            || !create_private_directory(fileManager, books, NO, error)
            || !create_private_directory(fileManager, cache, YES, error)) {
        return NO;
    }

    *dataPath = data.path;
    *booksPath = books.path;
    return YES;
}

static void set_lua_args(lua_State *L, int argc, char *argv[]) {
    lua_createtable(L, argc > 1 ? argc - 1 : 0, 0);
    for (int i = 1; i < argc; ++i) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *resourcePath = [[NSBundle mainBundle] resourcePath];
        if (!resourcePath) {
            fprintf(stderr, "[%s]: NSBundle resourcePath is nil\n", LOGNAME);
            return EXIT_FAILURE;
        }

        // The asset directory is `app/` rather than `koreader/` because the
        // launcher exec is named `KOReader` and APFS is case-insensitive by
        // default — `KOReader.app/KOReader` (file) and `KOReader.app/koreader/`
        // (dir) would collide.
        NSString *koreaderDir = [resourcePath stringByAppendingPathComponent:@"app"];
        if (chdir([koreaderDir fileSystemRepresentation]) != 0) {
            fprintf(stderr, "[%s]: chdir(%s) failed\n", LOGNAME,
                    [koreaderDir fileSystemRepresentation]);
            return EXIT_FAILURE;
        }

        if (setenv("LC_ALL", LANGUAGE, 1) != 0) {
            fprintf(stderr, "[%s]: setenv LC_ALL failed\n", LOGNAME);
            return EXIT_FAILURE;
        }

        /* On iOS the SDL window must match the display, otherwise the
         * default 600x800 emulator window leaves touches outside its
         * bounds doing nothing. Triggering the SDL_FULLSCREEN code path
         * makes SDL query SDL_GetCurrentDisplayMode and size to the
         * actual screen. */
        setenv("SDL_FULLSCREEN", "1", 1);

        /* Disable SDL's synthesis of mouse events from touches. On iOS
         * SDL3 fires both a FINGER_DOWN and a synthetic MOUSE_BUTTON_DOWN
         * for every tap, and the synthesized event isn't reliably tagged
         * with SDL_TOUCH_MOUSEID — so KOReader's input filter accepts
         * both and registers each tap twice. We have the real finger
         * events; we don't need fake mouse ones. */
        setenv("SDL_TOUCH_MOUSE_EVENTS", "0", 1);

        /* Tell Lua plugins (e.g. iosfilepicker.koplugin) we're on iOS.
         * KOReader still self-identifies as the SDL emulator otherwise. */
        setenv("KO_IOS", "1", 1);

        /* Keep executable settings and imported documents in private,
         * protected Application Support directories. Imported documents
         * enter Books only through the copy-in bridge; KOReader never
         * receives a document-provider or Inbox path. */
        NSString *dataPath = nil;
        NSString *booksPath = nil;
        NSError *storageError = nil;
        if (!configure_private_storage(&dataPath, &booksPath, &storageError)) {
            fprintf(stderr, "[%s]: private storage setup failed: %s\n", LOGNAME,
                    storageError.localizedDescription.UTF8String ?: "unknown error");
            return EXIT_FAILURE;
        }
        if (setenv("KO_HOME", dataPath.fileSystemRepresentation, 1) != 0
                || setenv("KO_BOOKS_HOME", booksPath.fileSystemRepresentation, 1) != 0
                || setenv("KO_IOS_STRICT_OFFLINE", "1", 1) != 0) {
            fprintf(stderr, "[%s]: failed to configure private storage environment\n",
                    LOGNAME);
            return EXIT_FAILURE;
        }

        lua_State *L = luaL_newstate();
        if (!L) {
            fprintf(stderr, "[%s]: failed to allocate Lua state\n", LOGNAME);
            return EXIT_FAILURE;
        }
        luaL_openlibs(L);

        /* Build arg directly through the Lua C API. Treating argv values as
         * Lua source would make quotes and control characters executable. */
        set_lua_args(L, argc, argv);

        int retval = luaL_dofile(L, "reader.lua");
        if (retval) {
            fprintf(stderr, LUA_ERROR, lua_tostring(L, -1));
        }

        lua_close(L);
        unsetenv("LC_ALL");
        unsetenv("KO_HOME");
        unsetenv("KO_BOOKS_HOME");
        unsetenv("KO_IOS_STRICT_OFFLINE");
        unsetenv("SDL_FULLSCREEN");
        unsetenv("SDL_TOUCH_MOUSE_EVENTS");
        unsetenv("KO_IOS");
        return retval;
    }
}

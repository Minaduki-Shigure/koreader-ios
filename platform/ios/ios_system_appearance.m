/* iOS system-appearance bridge for KOReader.
 *
 * UIKit traits are observed on the main thread. Changes cross into KOReader's
 * Lua event loop through a dynamically allocated SDL user event, so Lua is
 * never called reentrantly from a UIKit callback and no polling is required.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#include <SDL3/SDL.h>

#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>

#define KO_IOS_EXPORT __attribute__((visibility("default"), used))

typedef NS_ENUM(int32_t, KOIOSAppearanceState) {
    KOIOSAppearanceStateUnavailable = -1,
    KOIOSAppearanceStateLight = 0,
    KOIOSAppearanceStateDark = 1,
};

static atomic_int_least32_t ko_current_appearance =
    ATOMIC_VAR_INIT(KOIOSAppearanceStateUnavailable);
static atomic_uint_least32_t ko_appearance_event_type = ATOMIC_VAR_INIT(0);

static int32_t ko_normalized_appearance(UIUserInterfaceStyle style) {
    return style == UIUserInterfaceStyleDark
        ? KOIOSAppearanceStateDark
        : KOIOSAppearanceStateLight;
}

static NSObject *ko_appearance_event_lock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [[NSObject alloc] init];
    });
    return lock;
}

static Uint32 ko_register_appearance_event(void) {
    Uint32 eventType =
        (Uint32)atomic_load_explicit(&ko_appearance_event_type,
                                    memory_order_acquire);
    if (eventType != 0) {
        return eventType;
    }

    @synchronized(ko_appearance_event_lock()) {
        eventType =
            (Uint32)atomic_load_explicit(&ko_appearance_event_type,
                                        memory_order_relaxed);
        if (eventType == 0) {
            eventType = SDL_RegisterEvents(1);
            if (eventType != 0) {
                atomic_store_explicit(&ko_appearance_event_type, eventType,
                                      memory_order_release);
            }
        }
    }
    return eventType;
}

static UIWindow *ko_active_window(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIWindow *fallback = nil;

    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        BOOL foreground =
            windowScene.activationState == UISceneActivationStateForegroundActive
            || windowScene.activationState == UISceneActivationStateForegroundInactive;
        for (UIWindow *window in windowScene.windows) {
            if (!fallback && window.rootViewController) {
                fallback = window;
            }
            if (foreground && window.isKeyWindow && window.rootViewController) {
                return window;
            }
        }
    }
    return fallback;
}

@interface KOIOSAppearanceTraitView : UIView
@end

@interface KOIOSAppearanceTraitView ()
- (void)ko_userInterfaceStyleDidChange API_AVAILABLE(ios(17.0));
@end

@interface KOIOSSystemAppearanceObserver : NSObject

@property(nonatomic, strong) KOIOSAppearanceTraitView *traitView;
@property(nonatomic) int32_t lastQueuedAppearance;

+ (KOIOSSystemAppearanceObserver *)sharedObserver;
- (void)start;
- (void)publishCurrentAppearanceFromView:(UIView *)view enqueue:(BOOL)enqueue;

@end

@implementation KOIOSAppearanceTraitView

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.userInteractionEnabled = NO;
        self.accessibilityElementsHidden = YES;
        self.backgroundColor = UIColor.clearColor;

        if (@available(iOS 17.0, *)) {
            [self registerForTraitChanges:@[ UITraitUserInterfaceStyle.class ]
                              withAction:@selector(ko_userInterfaceStyleDidChange)];
        }
    }
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    KOIOSSystemAppearanceObserver *observer =
        [KOIOSSystemAppearanceObserver sharedObserver];
    [observer publishCurrentAppearanceFromView:self enqueue:YES];
}

- (void)ko_userInterfaceStyleDidChange API_AVAILABLE(ios(17.0)) {
    KOIOSSystemAppearanceObserver *observer =
        [KOIOSSystemAppearanceObserver sharedObserver];
    [observer publishCurrentAppearanceFromView:self enqueue:YES];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 17.0, *)) {
        return;
    }
    if (!previousTraitCollection
            || previousTraitCollection.userInterfaceStyle
                != self.traitCollection.userInterfaceStyle) {
        KOIOSSystemAppearanceObserver *observer =
            [KOIOSSystemAppearanceObserver sharedObserver];
        [observer publishCurrentAppearanceFromView:self enqueue:YES];
    }
}

@end


@implementation KOIOSSystemAppearanceObserver

static KOIOSSystemAppearanceObserver *sharedObserver;

+ (KOIOSSystemAppearanceObserver *)sharedObserver {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedObserver = [[self alloc] init];
        sharedObserver.lastQueuedAppearance = KOIOSAppearanceStateUnavailable;
    });
    return sharedObserver;
}

- (void)start {
    NSAssert(NSThread.isMainThread, @"Appearance observer requires main thread");
    if (!self.traitView) {
        self.traitView = [[KOIOSAppearanceTraitView alloc] init];
        NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
        [notifications addObserver:self
                          selector:@selector(applicationWindowChanged:)
                              name:UIWindowDidBecomeKeyNotification
                            object:nil];
        [notifications addObserver:self
                          selector:@selector(applicationWindowChanged:)
                              name:UIApplicationDidBecomeActiveNotification
                            object:nil];
    }
    [self attachToActiveWindowAndPublish:NO];
}

- (void)applicationWindowChanged:(NSNotification *)notification {
    (void)notification;
    [self attachToActiveWindowAndPublish:YES];
}

- (void)attachToActiveWindowAndPublish:(BOOL)enqueue {
    NSAssert(NSThread.isMainThread, @"Appearance observer requires main thread");
    UIWindow *window = ko_active_window();
    if (!window) {
        return;
    }
    if (self.traitView.superview != window) {
        [self.traitView removeFromSuperview];
        [window addSubview:self.traitView];
    }
    [self publishCurrentAppearanceFromView:self.traitView enqueue:enqueue];
}

- (void)publishCurrentAppearanceFromView:(UIView *)view enqueue:(BOOL)enqueue {
    NSAssert(NSThread.isMainThread, @"Appearance observer requires main thread");
    if (!view.window) {
        return;
    }

    int32_t appearance =
        ko_normalized_appearance(view.traitCollection.userInterfaceStyle);
    int32_t previous =
        atomic_exchange_explicit(&ko_current_appearance, appearance,
                                 memory_order_acq_rel);

    if (!enqueue) {
        self.lastQueuedAppearance = appearance;
        return;
    }
    if (previous == appearance && self.lastQueuedAppearance == appearance) {
        return;
    }

    Uint32 eventType = (Uint32)atomic_load_explicit(
        &ko_appearance_event_type, memory_order_acquire);
    if (eventType == 0) {
        return;
    }

    SDL_Event event = { 0 };
    event.type = eventType;
    event.user.type = eventType;
    event.user.code = appearance;
    if (SDL_PushEvent(&event)) {
        self.lastQueuedAppearance = appearance;
    } else {
        NSLog(@"[iOS appearance] SDL_PushEvent failed: %s", SDL_GetError());
    }
}

@end


KO_IOS_EXPORT bool ko_ios_system_appearance_start(void) {
    if (ko_register_appearance_event() == 0) {
        return false;
    }

    void (^startOnMainThread)(void) = ^{
        [[KOIOSSystemAppearanceObserver sharedObserver] start];
    };
    if (NSThread.isMainThread) {
        startOnMainThread();
    } else {
        dispatch_sync(dispatch_get_main_queue(), startOnMainThread);
    }
    return true;
}

KO_IOS_EXPORT uint32_t ko_ios_system_appearance_event_type(void) {
    return (uint32_t)atomic_load_explicit(&ko_appearance_event_type,
                                          memory_order_acquire);
}

KO_IOS_EXPORT int32_t ko_ios_system_appearance_current(void) {
    return atomic_load_explicit(&ko_current_appearance, memory_order_acquire);
}

/* iOS lifecycle bridge for KOReader.
 *
 * SDL 3 delivers the six mobile application lifecycle events only to event
 * watchers. KOReader's input loop consumes the regular SDL queue, so copy
 * those small value-only events into that queue while still inside the
 * required watcher callback. SDL_PeepEvents bypasses event watchers, avoiding
 * callback recursion, and is documented as thread-safe.
 */

#include <SDL3/SDL.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>

#define KO_IOS_EXPORT __attribute__((visibility("default"), used))

static atomic_bool ko_lifecycle_started = ATOMIC_VAR_INIT(false);

static bool SDLCALL ko_ios_lifecycle_event_watch(void *userdata,
                                                 SDL_Event *event) {
    (void)userdata;

    switch (event->type) {
    case SDL_EVENT_TERMINATING:
    case SDL_EVENT_LOW_MEMORY:
    case SDL_EVENT_WILL_ENTER_BACKGROUND:
    case SDL_EVENT_DID_ENTER_BACKGROUND:
    case SDL_EVENT_WILL_ENTER_FOREGROUND:
    case SDL_EVENT_DID_ENTER_FOREGROUND: {
        SDL_Event queued = { 0 };
        queued.type = event->type;
        queued.common.timestamp = event->common.timestamp;
        (void)SDL_PeepEvents(&queued, 1, SDL_ADDEVENT, 0, 0);
        break;
    }
    default:
        break;
    }
    return true;
}

KO_IOS_EXPORT bool ko_ios_lifecycle_start(void) {
    bool expected = false;
    if (!atomic_compare_exchange_strong_explicit(
            &ko_lifecycle_started, &expected, true,
            memory_order_acq_rel, memory_order_acquire)) {
        return true;
    }

    if (!SDL_AddEventWatch(ko_ios_lifecycle_event_watch, NULL)) {
        atomic_store_explicit(&ko_lifecycle_started, false,
                              memory_order_release);
        return false;
    }
    return true;
}

KO_IOS_EXPORT void ko_ios_lifecycle_stop(void) {
    if (atomic_exchange_explicit(&ko_lifecycle_started, false,
                                 memory_order_acq_rel)) {
        SDL_RemoveEventWatch(ko_ios_lifecycle_event_watch, NULL);
    }
}

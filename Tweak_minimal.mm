#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <os/log.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <string.h>

static os_log_t gLog;
static dispatch_queue_t gQueue;
static volatile uint64_t gUpdateHits;
static volatile uint64_t gRemoteHits;
static volatile uint64_t gCurHits;
static volatile int gInstalled;

extern "C" void MSHookFunction(void *symbol, void *replace, void **result)
    __attribute__((weak_import));

typedef void (*VoidMethod)(void *, void *);
static VoidMethod gOrigUpdate;
static VoidMethod gOrigRemote;
static VoidMethod gOrigCurrent;

static void logMessage(NSString *message) {
    if (!gLog) gLog = os_log_create("userovo1", "passive");
    os_log(gLog, "%{public}@", message);
    NSLog(@"%@", message);
}

static uintptr_t moduleBase(const char *name) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *imageName = _dyld_get_image_name(i);
        if (!imageName || !strstr(imageName, name)) continue;
        const struct mach_header_64 *header =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (header) return (uintptr_t)header;
    }
    return 0;
}

static void reportCounters(void) {
    logMessage([NSString stringWithFormat:
        @"[passive] hits update=%llu remote=%llu current=%llu",
        gUpdateHits, gRemoteHits, gCurHits]);
}

static BOOL installReadOnlyHook(uintptr_t target, void *replacement,
                                void **original, const char *name) {
    if (!MSHookFunction) {
        logMessage(@"[passive] substrate_backend_missing");
        return NO;
    }
    if (!target) {
        logMessage([NSString stringWithFormat:
            @"[passive] skip name=%s target=%p reason=invalid",
            name, (void *)target]);
        return NO;
    }
    MSHookFunction((void *)target, replacement, original);
    logMessage([NSString stringWithFormat:
        @"[passive] hooked name=%s target=%p", name, (void *)target]);
    return YES;
}

static void hookedUpdate(void *self, void *position) {
    gUpdateHits++;
    if (gOrigUpdate) gOrigUpdate(self, position);
}

static void hookedRemote(void *self, void *position) {
    gRemoteHits++;
    if (gOrigRemote) gOrigRemote(self, position);
}

static void hookedCurrent(void *self, void *position) {
    gCurHits++;
    if (gOrigCurrent) gOrigCurrent(self, position);
}

static void installPassiveHooks(void) {
    if (gInstalled) return;
    uintptr_t base = moduleBase("UnityFramework");
    if (!base) {
        logMessage(@"[passive] UnityFramework not loaded");
        return;
    }

    const uintptr_t rvaUpdate = 0x2F96F2C;
    const uintptr_t rvaRemote = 0x2EBC998;
    const uintptr_t rvaCurrent = 0x2EBC9BC;

    logMessage([NSString stringWithFormat:
        @"[passive] UnityFramework base=%p", (void *)base]);
    BOOL a = installReadOnlyHook(base + rvaUpdate,
        (void *)&hookedUpdate, (void **)&gOrigUpdate,
        "ActorLinker.UpdatePosition");
    BOOL b = installReadOnlyHook(base + rvaRemote,
        (void *)&hookedRemote, (void **)&gOrigRemote,
        "MoveComponent.set_RemotePosition");
    BOOL c = installReadOnlyHook(base + rvaCurrent,
        (void *)&hookedCurrent, (void **)&gOrigCurrent,
        "MoveComponent.get_CurPosition");
    gInstalled = (a || b || c) ? 1 : 0;
    logMessage([NSString stringWithFormat:
        @"[passive] install_result update=%d remote=%d current=%d",
        a, b, c]);
}

__attribute__((constructor))
static void userovoConstructor(void) {
    gQueue = dispatch_queue_create("userovo1.passive", DISPATCH_QUEUE_SERIAL);
    logMessage(@"[passive] session begin observer_only=1 writes=0 calls=0 ui=0");
    dispatch_async(gQueue, ^{
        for (NSUInteger attempt = 0; attempt < 120; attempt++) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                installPassiveHooks();
            });
            if (gInstalled) break;
            [NSThread sleepForTimeInterval:0.5];
        }
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
            2 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            reportCounters();
        });
        dispatch_resume(timer);
    });
}

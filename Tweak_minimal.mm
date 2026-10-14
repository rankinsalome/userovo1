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
static volatile int gInstalled;
static BOOL gHookAttempted;
static uintptr_t gLoggedBase;
static uintptr_t gLoggedMismatchBase;
static BOOL gLoggedNoModule;

typedef uintptr_t (*UpdatePositionFn)(void *, void *, void *);
extern "C" void MSHookFunction(void *symbol, void *replace, void **result);
static UpdatePositionFn gOrigUpdate;

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
    logMessage([NSString stringWithFormat:@"[passive] hits update=%llu",
        gUpdateHits]);
}

static uintptr_t hookedUpdate(void *self, void *position, void *methodInfo);

static BOOL updateTargetMatches(uintptr_t base, uintptr_t target) {
    static const uint8_t expected[] = {
        0xEB, 0x2B, 0xB8, 0x6D, 0xE9, 0x23, 0x01, 0x6D,
        0xFC, 0x6F, 0x02, 0xA9, 0xFA, 0x67, 0x03, 0xA9
    };
    Dl_info info = {0};
    if (!target || dladdr((const void *)target, &info) == 0 ||
        (uintptr_t)info.dli_fbase != base) {
        return NO;
    }
    return memcmp((const void *)target, expected, sizeof(expected)) == 0;
}

static BOOL installUpdateHook(uintptr_t target) {
    uintptr_t base = moduleBase("UnityFramework");
    if (!updateTargetMatches(base, target)) {
        if (gLoggedMismatchBase != base) {
            logMessage(@"[passive] skip UpdatePosition: image/prologue mismatch");
            gLoggedMismatchBase = base;
        }
        return NO;
    }
    gHookAttempted = YES;
    MSHookFunction((void *)target, (void *)&hookedUpdate,
                   (void **)&gOrigUpdate);
    if (!gOrigUpdate) {
        logMessage(@"[passive] UpdatePosition hook missing original trampoline");
        return NO;
    }
    logMessage([NSString stringWithFormat:
        @"[passive] hooked name=ActorLinker.UpdatePosition target=%p",
        (void *)target]);
    return YES;
}

static uintptr_t hookedUpdate(void *self, void *position, void *methodInfo) {
    gUpdateHits++;
    return gOrigUpdate ? gOrigUpdate(self, position, methodInfo) : 0;
}

static void installPassiveHooks(void) {
    if (gInstalled || gHookAttempted) return;
    uintptr_t base = moduleBase("UnityFramework");
    if (!base) {
        if (!gLoggedNoModule) {
            logMessage(@"[passive] UnityFramework not loaded");
            gLoggedNoModule = YES;
        }
        return;
    }

    const uintptr_t rvaUpdate = 0x2F96F2C;
    if (gLoggedBase != base) {
        logMessage([NSString stringWithFormat:
            @"[passive] UnityFramework base=%p", (void *)base]);
        gLoggedBase = base;
    }
    BOOL a = installUpdateHook(base + rvaUpdate);
    gInstalled = a ? 1 : 0;
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

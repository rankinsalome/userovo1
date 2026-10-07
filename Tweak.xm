#import <substrate.h>
#import <mach-o/dyld.h>

static uintptr_t unityBase = 0;
static float (*orig_GetRate)(void);
static float g_targetRate = 1.5f;

static float hook_GetRate(void) {
    float ret = orig_GetRate();
    return ret * g_targetRate;
}

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *n = _dyld_get_image_name(i);
            if (n && strstr(n, "UnityFramework")) {
                unityBase = (uintptr_t)_dyld_get_image_header(i);
                break;
            }
        }
        if (unityBase) {
            MSHookFunction((void *)(unityBase + 0x1DCB5AC),
                           (void *)hook_GetRate,
                           (void **)&orig_GetRate);
        }
    });
}
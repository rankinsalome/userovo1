#import <substrate.h>
#import <mach-o/dyld.h>
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <string.h>

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *n = _dyld_get_image_name(i);
            if (n && strstr(n, "UnityFramework")) {
                NSLog(@"[GameHack] unityBase=0x%lx",
                      (uintptr_t)_dyld_get_image_header(i));
                break;
            }
        }
    });
}
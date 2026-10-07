#import <substrate.h>
#import <mach-o/dyld.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <string.h>

static uintptr_t unityBase = 0;

@interface HUDWindow : UIWindow
@end
@implementation HUDWindow
@end

static HUDWindow *g_hud = nil;

static void doRead(void) {
    if (!unityBase) {
        NSLog(@"[GameHack] unityBase not set");
        return;
    }
    // 读 GetCameraHeightRateValue 入口指令
    uint32_t insn = *(uint32_t *)(unityBase + 0x1DCB5AC);
    NSLog(@"[GameHack] insn @ 0x1DCB5AC = 0x%08x", insn);

    // 读 GameSettings 类指针全局槽
    uintptr_t slot = unityBase + 0x1355AC68;
    uintptr_t klass = *(uintptr_t *)slot;
    NSLog(@"[GameHack] klass = 0x%lx", klass);

    if (klass) {
        uintptr_t staticFields = *(uintptr_t *)(klass + 0xB8);
        NSLog(@"[GameHack] staticFields = 0x%lx", staticFields);
        if (staticFields) {
            int32_t cameraHeight = *(int32_t *)(staticFields + 0x1AC);
            NSLog(@"[GameHack] cameraHeight = %d", cameraHeight);

            // 四个 TssSdtFloat 字段的原始字节
            uint32_t f128 = *(uint32_t *)(staticFields + 0x128);
            uint32_t f130 = *(uint32_t *)(staticFields + 0x130);
            uint32_t f138 = *(uint32_t *)(staticFields + 0x138);
            uint32_t f140 = *(uint32_t *)(staticFields + 0x140);
            NSLog(@"[GameHack] TSS 0x128=0x%08x 0x130=0x%08x 0x138=0x%08x 0x140=0x%08x",
                  f128, f130, f138, f140);
        }
    }
}

static void showHUD(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        g_hud = [[HUDWindow alloc] initWithFrame:CGRectMake(20, 100, 220, 160)];
        g_hud.windowLevel = UIWindowLevelAlert + 1;
        g_hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
        g_hud.rootViewController = [UIViewController new];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 200, 30)];
        label.text = @"GameHack 只读";
        label.textColor = [UIColor whiteColor];
        [g_hud.rootViewController.view addSubview:label];

        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        btn.frame = CGRectMake(10, 50, 200, 40);
        [btn setTitle:@"读取" forState:UIControlStateNormal];
        [btn addTarget:nil action:@selector(readTapped)
      forControlEvents:UIControlEventTouchUpInside];
        [g_hud.rootViewController.view addSubview:btn];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(10, 100, 200, 40);
        [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
        [closeBtn addTarget:nil action:@selector(closeTapped)
           forControlEvents:UIControlEventTouchUpInside];
        [g_hud.rootViewController.view addSubview:closeBtn];

        g_hud.hidden = NO;
    });
}
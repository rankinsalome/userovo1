#import <substrate.h>
#import <mach-o/dyld.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <string.h>

static uintptr_t unityBase = 0;

@interface HUDWindow : UIWindow
- (void)onPan:(UIPanGestureRecognizer *)g;
@end
@implementation HUDWindow
- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    CGPoint c = self.center;
    self.center = CGPointMake(c.x + t.x, c.y + t.y);
    [g setTranslation:CGPointZero inView:self];
}
@end

static HUDWindow *g_hud = nil;
static UITextView *g_output = nil;

static NSString *readAll(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"unityBase: 0x%lx\n", unityBase];
    if (!unityBase) {
        [s appendString:@"UnityFramework 未找到\n"];
        return s;
    }

    uint32_t insn = *(uint32_t *)(unityBase + 0x1DCB5AC);
    [s appendFormat:@"insn@0x1DCB5AC: 0x%08x\n", insn];

    uintptr_t slot = unityBase + 0x1355AC68;
    uintptr_t klass = *(uintptr_t *)slot;
    [s appendFormat:@"klass: 0x%lx\n", klass];

    if (klass) {
        uintptr_t staticFields = *(uintptr_t *)(klass + 0xB8);
        [s appendFormat:@"staticFields: 0x%lx\n", staticFields];
        if (staticFields) {
            int32_t cameraHeight = *(int32_t *)(staticFields + 0x1AC);
            [s appendFormat:@"cameraHeight: %d\n", cameraHeight];

            uint32_t f128 = *(uint32_t *)(staticFields + 0x128);
            uint32_t f130 = *(uint32_t *)(staticFields + 0x130);
            uint32_t f138 = *(uint32_t *)(staticFields + 0x138);
            uint32_t f140 = *(uint32_t *)(staticFields + 0x140);
            [s appendFormat:@"TSS 0x128: 0x%08x\n", f128];
            [s appendFormat:@"TSS 0x130: 0x%08x\n", f130];
            [s appendFormat:@"TSS 0x138: 0x%08x\n", f138];
            [s appendFormat:@"TSS 0x140: 0x%08x\n", f140];
        } else {
            [s appendString:@"staticFields 为 0\n"];
        }
    } else {
        [s appendString:@"klass 为 0，槽地址或偏移可能错\n"];
    }
    return s;
}

static void showHUD(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGFloat w = 300, h = 380;
        g_hud = [[HUDWindow alloc] initWithFrame:CGRectMake(20, 80, w, h)];
        g_hud.windowLevel = UIWindowLevelAlert + 1;
        g_hud.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
        g_hud.layer.cornerRadius = 12;
        g_hud.layer.masksToBounds = YES;

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        g_hud.rootViewController = vc;

        UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 44)];
        titleBar.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        [vc.view addSubview:titleBar];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 0, 200, 44)];
        title.text = @"GameHack 只读";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:16];
        [titleBar addSubview:title];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:g_hud action:@selector(onPan:)];
        [titleBar addGestureRecognizer:pan];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(w - 44, 0, 44, 44);
        [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:20];
        [closeBtn addAction:[UIAction actionWithHandler:^(UIAction *a) {
            g_hud.hidden = YES;
        }] forControlEvents:UIControlEventTouchUpInside];
        [titleBar addSubview:closeBtn];

        UIButton *readBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        readBtn.frame = CGRectMake(12, 56, w - 24, 40);
        [readBtn setTitle:@"读取" forState:UIControlStateNormal];
        [readBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        readBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:1];
        readBtn.layer.cornerRadius = 8;
        [readBtn addAction:[UIAction actionWithHandler:^(UIAction *a) {
            if (g_output) g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:readBtn];

        g_output = [[UITextView alloc] initWithFrame:CGRectMake(12, 106, w - 24, h - 118)];
        g_output.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
        g_output.textColor = [UIColor greenColor];
        g_output.font = [UIFont fontWithName:@"Menlo" size:11];
        g_output.editable = NO;
        g_output.text = @"点读取";
        [vc.view addSubview:g_output];

        g_hud.hidden = NO;
    });
}

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *n = _dyld_get_image_name(i);
            if (n && strstr(n, "UnityFramework")) {
                unityBase = (uintptr_t)_dyld_get_image_header(i);
                break;
            }
        }
        showHUD();
    });
}
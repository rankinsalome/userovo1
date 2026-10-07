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
static UIVisualEffectView *g_panel = nil;
static CAGradientLayer *g_gradient = nil;

static uintptr_t getStaticFields(void) {
    if (!unityBase) return 0;
    uintptr_t slot = unityBase + 0x1355AC68;
    uintptr_t klass = *(uintptr_t *)slot;
    if (!klass) return 0;
    return *(uintptr_t *)(klass + 0xB8);
}

static NSString *readAll(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"unityBase: 0x%lx\n", unityBase];
    if (!unityBase) { [s appendString:@"UnityFramework 未找到\n"]; return s; }

    uintptr_t sf = getStaticFields();
    [s appendFormat:@"staticFields: 0x%lx\n", sf];
    if (sf) {
        int32_t ch = *(int32_t *)(sf + 0x1AC);
        [s appendFormat:@"cameraHeight: %d\n", ch];
        uint32_t f128 = *(uint32_t *)(sf + 0x128);
        uint32_t f130 = *(uint32_t *)(sf + 0x130);
        uint32_t f138 = *(uint32_t *)(sf + 0x138);
        uint32_t f140 = *(uint32_t *)(sf + 0x140);
        [s appendFormat:@"TSS 0x128: 0x%08x\n", f128];
        [s appendFormat:@"TSS 0x130: 0x%08x\n", f130];
        [s appendFormat:@"TSS 0x138: 0x%08x\n", f138];
        [s appendFormat:@"TSS 0x140: 0x%08x\n", f140];
    }
    return s;
}

static void writeCameraHeight(int32_t v) {
    uintptr_t sf = getStaticFields();
    if (!sf) return;
    *(int32_t *)(sf + 0x1AC) = v;
    NSLog(@"[GameHack] cameraHeight -> %d", v);
}

static void updateHUDLayout(void) {
    if (!g_hud || !g_panel) return;

    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;

    CGRect gameBounds = window.bounds;
    CGFloat safeInset = 20.0;
    CGFloat maxW = MIN(330.0, CGRectGetWidth(gameBounds) - safeInset * 2);
    CGFloat maxH = MIN(470.0, CGRectGetHeight(gameBounds) - safeInset * 2);
    CGFloat w = MAX(280.0, maxW);
    CGFloat h = MAX(360.0, maxH);

    CGFloat x = CGRectGetMidX(gameBounds);
    CGFloat y = CGRectGetMidY(gameBounds);
    CGFloat left = safeInset;
    CGFloat top = safeInset;
    CGFloat right = CGRectGetWidth(gameBounds) - safeInset;
    CGFloat bottom = CGRectGetHeight(gameBounds) - safeInset;

    if (g_hud.center.x < left + w / 2.0) x = left + w / 2.0;
    if (g_hud.center.x > right - w / 2.0) x = right - w / 2.0;
    if (g_hud.center.y < top + h / 2.0) y = top + h / 2.0;
    if (g_hud.center.y > bottom - h / 2.0) y = bottom - h / 2.0;

    g_hud.frame = CGRectMake(x - w / 2.0, y - h / 2.0, w, h);
    g_hud.rootViewController.view.frame = g_hud.bounds;
    g_panel.frame = g_hud.bounds;
    if (g_gradient) g_gradient.frame = g_panel.bounds;
}

static void showHUD(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        CGRect gameBounds = window ? window.bounds : [UIScreen mainScreen].bounds;
        CGFloat w = MIN(330.0, CGRectGetWidth(gameBounds) - 40.0);
        CGFloat h = MIN(470.0, CGRectGetHeight(gameBounds) - 40.0);
        w = MAX(w, 280.0);
        h = MAX(h, 360.0);

        g_hud = [[HUDWindow alloc] initWithFrame:CGRectMake(20, 80, w, h)];
        g_hud.windowLevel = UIWindowLevelAlert + 1;
        g_hud.backgroundColor = [UIColor clearColor];
        g_hud.layer.shadowColor = [UIColor blackColor].CGColor;
        g_hud.layer.shadowOpacity = 0.28;
        g_hud.layer.shadowRadius = 18;
        g_hud.layer.shadowOffset = CGSizeMake(0, 8);
        g_hud.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
            UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleTopMargin |
            UIViewAutoresizingFlexibleBottomMargin;

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        g_hud.rootViewController = vc;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        g_panel = [[UIVisualEffectView alloc] initWithEffect:blur];
        g_panel.frame = CGRectMake(0, 0, w, h);
        g_panel.layer.cornerRadius = 22;
        g_panel.layer.masksToBounds = YES;
        [vc.view addSubview:g_panel];

        g_gradient = [CAGradientLayer layer];
        g_gradient.frame = g_panel.bounds;
        g_gradient.colors = @[
            (id)[UIColor colorWithRed:0.08 green:0.11 blue:0.19 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.10 green:0.14 blue:0.24 alpha:1.0].CGColor
        ];
        g_gradient.locations = @[@0.0, @1.0];
        [g_panel.contentView.layer insertSublayer:g_gradient atIndex:0];

        UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 58)];
        titleBar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
        [g_panel.contentView addSubview:titleBar];

        UIImageView *logo = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sparkles"]];
        logo.frame = CGRectMake(16, 15, 28, 28);
        logo.tintColor = [UIColor colorWithRed:0.55 green:0.73 blue:1.0 alpha:1.0];
        [titleBar addSubview:logo];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(52, 0, 180, 58)];
        title.text = @"GameHack";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:18];
        [titleBar addSubview:title];

        UILabel *subtitle = [[UILabel alloc] initWithFrame:CGRectMake(52, 31, 180, 18)];
        subtitle.text = @"Camera Utility";
        subtitle.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        subtitle.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
        [titleBar addSubview:subtitle];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:g_hud action:@selector(onPan:)];
        [titleBar addGestureRecognizer:pan];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(w - 48, 10, 32, 32);
        closeBtn.tintColor = [UIColor whiteColor];
        [closeBtn setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        closeBtn.layer.cornerRadius = 16;
        closeBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        [closeBtn addAction:[UIAction actionWithHandler:^(UIAction *a) {
            g_hud.hidden = YES;
        }] forControlEvents:UIControlEventTouchUpInside];
        [titleBar addSubview:closeBtn];

        UILabel *section = [[UILabel alloc] initWithFrame:CGRectMake(20, 78, w - 40, 20)];
        section.text = @"镜头参数";
        section.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        section.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [g_panel.contentView addSubview:section];

        UIView *buttonGroup = [[UIView alloc] initWithFrame:CGRectMake(20, 104, w - 40, 90)];
        buttonGroup.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
        buttonGroup.layer.cornerRadius = 16;
        [g_panel.contentView addSubview:buttonGroup];

        UIButton *readBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        readBtn.frame = CGRectMake(14, 12, buttonGroup.bounds.size.width - 28, 32);
        [readBtn setTitle:@"读取当前状态" forState:UIControlStateNormal];
        [readBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        readBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        readBtn.backgroundColor = [UIColor colorWithRed:0.25 green:0.45 blue:0.96 alpha:1.0];
        readBtn.layer.cornerRadius = 10;
        [readBtn addAction:[UIAction actionWithHandler:^(UIAction *a) {
            if (g_output) g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [buttonGroup addSubview:readBtn];

        CGFloat btnW = (buttonGroup.bounds.size.width - 28) / 2;
        UIButton *btn0 = [UIButton buttonWithType:UIButtonTypeSystem];
        btn0.frame = CGRectMake(14, 54, btnW, 28);
        [btn0 setTitle:@"近景 · 0" forState:UIControlStateNormal];
        [btn0 setTitleColor:[UIColor colorWithWhite:0.1 alpha:1.0] forState:UIControlStateNormal];
        btn0.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        btn0.backgroundColor = [UIColor colorWithRed:0.68 green:0.92 blue:0.78 alpha:1.0];
        btn0.layer.cornerRadius = 9;
        [btn0 addAction:[UIAction actionWithHandler:^(UIAction *a) {
            writeCameraHeight(0);
            if (g_output) g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [buttonGroup addSubview:btn0];

        UIButton *btn1 = [UIButton buttonWithType:UIButtonTypeSystem];
        btn1.frame = CGRectMake(14 + btnW + 14, 54, btnW, 28);
        [btn1 setTitle:@"标准 · 1" forState:UIControlStateNormal];
        [btn1 setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn1.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        btn1.backgroundColor = [UIColor colorWithRed:0.94 green:0.62 blue:0.48 alpha:1.0];
        btn1.layer.cornerRadius = 9;
        [btn1 addAction:[UIAction actionWithHandler:^(UIAction *a) {
            writeCameraHeight(1);
            if (g_output) g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [buttonGroup addSubview:btn1];

        UILabel *outputLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 214, w - 40, 18)];
        outputLabel.text = @"运行信息";
        outputLabel.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        outputLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [g_panel.contentView addSubview:outputLabel];

        g_output = [[UITextView alloc] initWithFrame:CGRectMake(20, 238, w - 40, h - 266)];
        g_output.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.36];
        g_output.textColor = [UIColor colorWithRed:0.63 green:0.96 blue:0.74 alpha:1.0];
        g_output.font = [UIFont fontWithName:@"Menlo" size:11];
        g_output.editable = NO;
        g_output.text = @"未读取，点击上方按钮查看状态。";
        g_output.layer.cornerRadius = 12;
        g_output.layer.borderWidth = 1;
        g_output.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
        g_output.textContainerInset = UIEdgeInsetsMake(10, 10, 10, 10);
        [g_panel.contentView addSubview:g_output];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIWindowDidBecomeKeyNotification
            object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *notification) {
                updateHUDLayout();
            }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification
            object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *notification) {
                updateHUDLayout();
            }];

        updateHUDLayout();
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
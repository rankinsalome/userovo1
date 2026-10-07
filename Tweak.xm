#import <substrate.h>
#import <mach-o/dyld.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#include <string.h>

/* ── memory read slot (kept from original tweak) ── */
#define RVA_FOW_APPLY         0x16C4598  // FogOfWarSettings$$Apply
#define RVA_FOW_UPDATE        0x16C9DCC  // PartitionedFog$$UpdateFogState

#define DATA_SLOT_STATICFIELDS 0x1355AC68
uintptr_t unityBase = 0;

/* ── Original function pointers ── */


/* ── State ── */
static bool g_fogDisabled = false;
static bool g_mapHackEnabled = false;
bool g_mapHackInstalled = false;

/* ESP externs */
extern bool g_espEnabled;
extern void showESPOverlay(void);
extern void hideESPOverlay(void);
extern void updateESPMatrices(void);
extern void updateESPEntities(void);
extern void installMapHack(void);
extern bool g_mapHackInstalled;


/* ═══════════════════════════════════════════ */
/*  HOOK: generic fog visibility bypass     */
/*  Forces all units visible when enabled   */
/* ═══════════════════════════════════════════ */
static bool hook_get_bVisible(void *self) {
    if (g_mapHackEnabled) {
        if (self) *(uint8_t *)((uintptr_t)self + 0xC) = 1;
        return true;
    }
    /* Inline original: read bVisible_bool field at offset 0xC */
    if (self) return *(uint8_t *)((uintptr_t)self + 0xC) != 0;
    return false;
}


/* ── HUD Window ── */
@interface HUDViewController : UIViewController
@end
@implementation HUDViewController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAll;
}
- (BOOL)shouldAutorotate {
    return YES;
}
@end

@interface HUDWindow : UIWindow
@property (nonatomic, weak) UIView *ballView;
@property (nonatomic, weak) UIView *panelView;
- (void)onBallPan:(UIPanGestureRecognizer *)g;
- (void)onBallTap:(UITapGestureRecognizer *)g;
@end
@implementation HUDWindow

/* Pass through all touches that don't hit ball or panel */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01) return nil;
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) {
        return nil;
    }
    return hit;
}

- (void)onBallPan:(UIPanGestureRecognizer *)g {
    if (!self.ballView || self.ballView.hidden) return;
    if (g.state == UIGestureRecognizerStateBegan) {
        // Scale up slightly during drag for feedback
        [UIView animateWithDuration:0.15 animations:^{
            self.ballView.transform = CGAffineTransformMakeScale(1.12, 1.12);
        }];
    }
    CGPoint t = [g translationInView:self];
    CGPoint c = self.ballView.center;
    self.ballView.center = CGPointMake(c.x + t.x, c.y + t.y);
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        // Snap back to normal scale
        [UIView animateWithDuration:0.2 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.5
            options:0 animations:^{
                self.ballView.transform = CGAffineTransformIdentity;
            } completion:nil];
        // Clamp to screen bounds
        [self clampBallToBounds];
    }
}

- (void)onBallTap:(UITapGestureRecognizer *)g {
    if (!self.ballView || !self.panelView) return;
    if (g.state != UIGestureRecognizerStateEnded) return;

    BOOL opening = self.panelView.hidden;
    if (opening) {
        [self showPanel];
    } else {
        [self hidePanel];
    }
}

- (void)clampBallToBounds {
    if (!self.ballView) return;
    CGPoint c = self.ballView.center;
    CGFloat r = self.ballView.bounds.size.width / 2.0;
    CGFloat bw = self.bounds.size.width;
    CGFloat bh = self.bounds.size.height;
    CGFloat safe = 8.0;
    if (c.x < r + safe) c.x = r + safe;
    if (c.x > bw - r - safe) c.x = bw - r - safe;
    if (c.y < r + safe + 44) c.y = r + safe + 44;
    if (c.y > bh - r - safe - 34) c.y = bh - r - safe - 34;
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.65 initialSpringVelocity:0.3
        options:UIViewAnimationOptionAllowUserInteraction animations:^{
            self.ballView.center = c;
        } completion:nil];
}

- (void)showPanel {
    if (!self.ballView || !self.panelView || !self.panelView.hidden) return;
    CGPoint bc = self.ballView.center;
    CGFloat pw = self.panelView.bounds.size.width;
    CGFloat ph = self.panelView.bounds.size.height;
    CGFloat sw = self.bounds.size.width;
    CGFloat sh = self.bounds.size.height;
    CGFloat px, py;
    if (bc.x + pw + 16 < sw) px = bc.x + 12; else px = bc.x - pw - 12;
    if (bc.y + ph + 16 < sh) py = bc.y + 12; else py = bc.y - ph - 12;
    if (px < 8) px = 8;
    if (px + pw > sw - 8) px = sw - pw - 8;
    if (py < 44) py = 44;
    if (py + ph > sh - 16) py = sh - ph - 16;
    self.panelView.frame = CGRectMake(px, py, pw, ph);
    self.panelView.transform = CGAffineTransformMakeScale(0.3, 0.3);
    self.panelView.alpha = 0;
    self.panelView.hidden = NO;

    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.72 initialSpringVelocity:0.4
        options:UIViewAnimationOptionAllowUserInteraction animations:^{
            self.ballView.alpha = 0;
            self.ballView.transform = CGAffineTransformMakeScale(0.1, 0.1);
            self.panelView.alpha = 1;
            self.panelView.transform = CGAffineTransformIdentity;
        } completion:^(BOOL done) {
            self.ballView.alpha = 1;
            self.ballView.hidden = YES;
            self.ballView.transform = CGAffineTransformIdentity;
        }];
}

- (void)hidePanel {
    if (!self.ballView || !self.panelView || self.panelView.hidden) return;
    self.ballView.alpha = 0;
    self.ballView.transform = CGAffineTransformMakeScale(0.2, 0.2);
    self.ballView.hidden = NO;
    CGPoint bc = self.panelView.center;
    self.ballView.center = bc;

    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5
        options:UIViewAnimationOptionAllowUserInteraction animations:^{
            self.panelView.alpha = 0;
            self.panelView.transform = CGAffineTransformMakeScale(0.25, 0.25);
            self.ballView.alpha = 1;
            self.ballView.transform = CGAffineTransformIdentity;
        } completion:^(BOOL done) {
            self.panelView.hidden = YES;
            self.panelView.transform = CGAffineTransformIdentity;
            self.panelView.alpha = 1;
        }];
}

- (void)clampPanelToBounds {
    if (!self.panelView) return;
    CGFloat w = self.panelView.bounds.size.width;
    CGFloat h = self.panelView.bounds.size.height;
    CGFloat bw = self.bounds.size.width;
    CGFloat bh = self.bounds.size.height;
    CGPoint c = self.panelView.center;
    if (c.x - w/2 < 4) c.x = w/2 + 4;
    if (c.x + w/2 > bw - 4) c.x = bw - w/2 - 4;
    if (c.y - h/2 < 20) c.y = h/2 + 20;
    if (c.y + h/2 > bh - 4) c.y = bh - h/2 - 4;
    self.panelView.center = c;
}
@end

static HUDWindow *g_hud = nil;
static UITextView *g_output = nil;
static UIVisualEffectView *g_panel = nil;
static CAGradientLayer *g_gradient = nil;
static UIView *g_statusDot = nil;
static UILabel *g_statusLabel = nil;

/* ── Status UI ── */
static void updateStatusUI(void) {
    if (!g_statusDot || !g_statusLabel) return;
    if (g_mapHackEnabled) {
        g_statusDot.backgroundColor = [UIColor colorWithRed:0.36 green:0.96 blue:0.53 alpha:1.0];
        g_statusLabel.text = g_fogDisabled ? @"全图" : @"全可见";
        g_statusLabel.textColor = [UIColor colorWithRed:0.58 green:0.96 blue:0.72 alpha:1.0];
    } else {
        g_statusDot.backgroundColor = [UIColor colorWithWhite:0.38 alpha:1.0];
        g_statusLabel.text = @"空闲";
        g_statusLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
    }
}

/* ── Memory helpers ── */
static uintptr_t getStaticFields(void) {
    if (!unityBase) return 0;
    // Bounds check: slot must be within reasonable range
    if (DATA_SLOT_STATICFIELDS > 0x20000000) return 0;
    uintptr_t slot = unityBase + DATA_SLOT_STATICFIELDS;
    uintptr_t klass = *(uintptr_t *)slot;
    if (!klass || klass < 0x1000 || klass > 0x200000000) return 0;
    uintptr_t sf = *(uintptr_t *)(klass + 0xB8);
    if (!sf || sf < 0x1000) return 0;
    return sf;
}

static NSString *readAll(void) {
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"UnityFramework  0x%lx\n", unityBase];
    if (!unityBase) { [s appendString:@"[!] UnityFramework missing\n"]; return s; }

    uintptr_t sf = getStaticFields();
    [s appendFormat:@"StaticFields     0x%lx\n", sf];

    if (sf) {
        int32_t ch = *(int32_t *)(sf + 0x1AC);
        [s appendFormat:@"CameraHeight     %d\n", ch];
        uint32_t f128 = *(uint32_t *)(sf + 0x128);
        uint32_t f130 = *(uint32_t *)(sf + 0x130);
        uint32_t f138 = *(uint32_t *)(sf + 0x138);
        uint32_t f140 = *(uint32_t *)(sf + 0x140);
        [s appendFormat:@"FogParam[128]    0x%08X\n", f128];
        [s appendFormat:@"FogParam[130]    0x%08X\n", f130];
        [s appendFormat:@"FogParam[138]    0x%08X\n", f138];
        [s appendFormat:@"FogParam[140]    0x%08X\n", f140];
    }

    [s appendString:@"\n-- HOOKS --\n"];
    [s appendFormat:@"MapHackHook     %s\n",
        g_mapHackInstalled ? "INSTALLED" : "NOT INSTALLED"];
    

    [s appendString:@"\n-- STATE --\n"];
    [s appendFormat:@"MapHack        %s\n", g_mapHackEnabled ? "ON" : "OFF"];
    [s appendFormat:@"VisualFog      %s\n", g_fogDisabled ? "CLEAR" : "标准"];

    return s;
}

static void writeCameraHeight(int32_t v) {
    uintptr_t sf = getStaticFields();
    if (!sf) return;
    *(int32_t *)(sf + 0x1AC) = v;
}

/* ── Layout ── */


/* ── UI factories ── */
static UIButton *mkBtn(NSString *ttl, UIColor *bg, UIColor *fg, CGFloat fs) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:ttl forState:UIControlStateNormal];
    [btn setTitleColor:fg forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:fs weight:UIFontWeightSemibold];
    btn.backgroundColor = bg;
    btn.layer.cornerRadius = 9;
    return btn;
}

static UILabel *mkSec(NSString *txt) {
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = txt;
    lbl.textColor = [UIColor colorWithWhite:0.68 alpha:1.0];
    lbl.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    return lbl;
}

/* ═══════════════════════════════════════════ */
/*  BUILD HUD                                */
/* ═══════════════════════════════════════════ */
static void showHUD(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        CGRect gb = [UIScreen mainScreen].bounds;
        CGFloat w = MIN(280.0, CGRectGetWidth(gb) * 0.55);
        CGFloat h = MIN(380.0, CGRectGetHeight(gb) * 0.58);
        w = MAX(w, 220.0); h = MAX(h, 300.0);
        CGFloat pad = 16.0, cw = w - pad * 2;

        g_hud = [[HUDWindow alloc] initWithFrame:gb];
        g_hud.windowLevel = UIWindowLevelAlert + 1;
        g_hud.backgroundColor = [UIColor clearColor];
        g_hud.layer.shadowColor = [UIColor blackColor].CGColor;
        g_hud.layer.shadowOpacity = 0.30;
        g_hud.layer.shadowRadius = 20;
        g_hud.layer.shadowOffset = CGSizeMake(0, 10);

        HUDViewController *vc = [HUDViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        g_hud.rootViewController = vc;

        /* ── Floating Ball ── */
        CGFloat ballSize = 48.0;
        UIView *ball = [[UIView alloc] initWithFrame:CGRectMake(gb.size.width - ballSize - 20, 160, ballSize, ballSize)];
        ball.layer.cornerRadius = ballSize / 2.0;
        ball.layer.masksToBounds = NO;
        ball.backgroundColor = [UIColor clearColor];

        // Ball shadow
        ball.layer.shadowColor = [UIColor blackColor].CGColor;
        ball.layer.shadowOpacity = 0.35;
        ball.layer.shadowRadius = 10;
        ball.layer.shadowOffset = CGSizeMake(0, 4);

        // Ball blur background
        UIVisualEffectView *ballBlur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        ballBlur.frame = ball.bounds;
        ballBlur.layer.cornerRadius = ballSize / 2.0;
        ballBlur.layer.masksToBounds = YES;
        [ball addSubview:ballBlur];

        // Ball icon
        UIImageView *ballIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"circle.grid.2x2.fill"]];
        ballIcon.frame = CGRectMake(12, 12, ballSize - 24, ballSize - 24);
        ballIcon.tintColor = [UIColor colorWithRed:0.55 green:0.73 blue:1.0 alpha:1.0];
        ballIcon.contentMode = UIViewContentModeScaleAspectFit;
        [ball addSubview:ballIcon];

        // Ball gestures
        UIPanGestureRecognizer *ballPan = [[UIPanGestureRecognizer alloc]
            initWithTarget:g_hud action:@selector(onBallPan:)];
        ballPan.minimumNumberOfTouches = 1;
        ballPan.maximumNumberOfTouches = 1;
        [ball addGestureRecognizer:ballPan];

        UITapGestureRecognizer *ballTap = [[UITapGestureRecognizer alloc]
            initWithTarget:g_hud action:@selector(onBallTap:)];
        ballTap.numberOfTapsRequired = 1;
        [ball addGestureRecognizer:ballTap];

        [vc.view addSubview:ball];
        g_hud.ballView = ball;

        /* ── Panel (initially hidden, shown on ball tap) ── */
        g_panel = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        g_panel.frame = CGRectMake(0, 0, w, h);
        g_panel.layer.cornerRadius = 22;
        g_panel.layer.masksToBounds = YES;
        g_panel.hidden = YES;
        [vc.view addSubview:g_panel];
        g_hud.panelView = g_panel;

        g_gradient = [CAGradientLayer layer];
        g_gradient.frame = g_panel.bounds;
        g_gradient.colors = @[
            (id)[UIColor colorWithRed:0.06 green:0.09 blue:0.16 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.10 green:0.14 blue:0.24 alpha:1.0].CGColor
        ];
        g_gradient.locations = @[@0.0, @1.0];
        [g_panel.contentView.layer insertSublayer:g_gradient atIndex:0];

        /* ── Title bar ── */
        UIView *tb = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 50)];
        tb.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
        [g_panel.contentView addSubview:tb];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 0, 180, 50)];
        title.text = @"GameHack Pro 王者辅助 王者辅助";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:16];
        [tb addSubview:title];

        g_statusDot = [[UIView alloc] initWithFrame:CGRectMake(w - 105, 17, 8, 8)];
        g_statusDot.layer.cornerRadius = 4;
        g_statusDot.backgroundColor = [UIColor colorWithWhite:0.38 alpha:1.0];
        [tb addSubview:g_statusDot];

        g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 92, 15, 64, 14)];
        g_statusLabel.text = @"空闲";
        g_statusLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
        g_statusLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        [tb addSubview:g_statusLabel];


        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(w - 48, 8, 34, 34);
        close.tintColor = [UIColor whiteColor];
        [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"]
               forState:UIControlStateNormal];
        close.layer.cornerRadius = 17;
        close.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        [close addAction:[UIAction actionWithHandler:^(UIAction *a) {
            [g_hud hidePanel];
        }] forControlEvents:UIControlEventTouchUpInside];
        [tb addSubview:close];

        CGFloat y = 62.0;

        /* ── FOG OF WAR SECTION ── */
        UILabel *fogSec = mkSec(@"战争迷雾 / 地图透视");
        fogSec.frame = CGRectMake(pad, y, cw, 16);
        [g_panel.contentView addSubview:fogSec];
        y += 20;

        UIView *fogBox = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 88)];
        fogBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
        fogBox.layer.cornerRadius = 14;
        [g_panel.contentView addSubview:fogBox];

        UIButton *btnMapHack = mkBtn(@"开启全图透视",
            [UIColor colorWithRed:0.22 green:0.65 blue:0.42 alpha:1.0],
            [UIColor whiteColor], 13);
        btnMapHack.frame = CGRectMake(12, 10, cw - 24, 36);
        btnMapHack.layer.cornerRadius = 10;
        [btnMapHack addAction:[UIAction actionWithHandler:^(UIAction *act) {
            if (!g_mapHackInstalled && unityBase) installMapHack();
            if (!g_mapHackInstalled) {
                g_output.text = @"[!] Hooks failed - wrong game version.\nCheck RVA offsets match binary.";
                return;
            }
            g_mapHackEnabled = !g_mapHackEnabled;
            g_fogDisabled = g_mapHackEnabled;
            NSString *t = g_mapHackEnabled ? @"关闭全图透视" : @"开启全图透视";
            UIColor *c = g_mapHackEnabled
                ? [UIColor colorWithRed:0.88 green:0.38 blue:0.33 alpha:1.0]
                : [UIColor colorWithRed:0.22 green:0.65 blue:0.42 alpha:1.0];
            [act.sender setTitle:t forState:UIControlStateNormal];
            ((UIButton *)act.sender).backgroundColor = c;
            updateStatusUI();
            g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [fogBox addSubview:btnMapHack];

        CGFloat sw = (cw - 40) / 2;

        UIButton *btnFogVis = mkBtn(@"清除视觉迷雾",
            [UIColor colorWithRed:0.18 green:0.45 blue:0.78 alpha:1.0],
            [UIColor whiteColor], 11);
        btnFogVis.frame = CGRectMake(12, 54, sw, 26);
        [btnFogVis addAction:[UIAction actionWithHandler:^(UIAction *act) {
            if (!g_mapHackInstalled && unityBase) installMapHack();
            g_fogDisabled = !g_fogDisabled;
            NSString *t = g_fogDisabled ? @"恢复视觉迷雾" : @"清除视觉迷雾";
            [act.sender setTitle:t forState:UIControlStateNormal];
            updateStatusUI();
            g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [fogBox addSubview:btnFogVis];

        UIButton *btnReset = mkBtn(@"重置全部迷雾",
            [UIColor colorWithWhite:0.24 alpha:1.0],
            [UIColor lightGrayColor], 11);
        btnReset.frame = CGRectMake(24 + sw, 54, sw, 26);
        [btnReset addAction:[UIAction actionWithHandler:^(UIAction *act) {
            g_mapHackEnabled = false;
            g_fogDisabled = false;
            updateStatusUI();
            g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [fogBox addSubview:btnReset];

        y += 100;

        UIButton *btnESP = mkBtn(@"透视",
            [UIColor colorWithRed:0.55 green:0.22 blue:0.72 alpha:1.0],
            [UIColor whiteColor], 13);
        btnESP.frame = CGRectMake(pad, y, cw, 34);
        btnESP.layer.cornerRadius = 10;
        [btnESP addAction:[UIAction actionWithHandler:^(UIAction *act) {
            g_espEnabled = !g_espEnabled;
            if (g_espEnabled) {
                showESPOverlay();
                updateESPMatrices();
                [act.sender setTitle:@"关闭" forState:UIControlStateNormal];
                ((UIButton *)act.sender).backgroundColor = [UIColor colorWithRed:0.88 green:0.38 blue:0.33 alpha:1.0];
            } else {
                hideESPOverlay();
                [act.sender setTitle:@"透视" forState:UIControlStateNormal];
                ((UIButton *)act.sender).backgroundColor = [UIColor colorWithRed:0.55 green:0.22 blue:0.72 alpha:1.0];
            }
            g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [g_panel.contentView addSubview:btnESP];
        y += 44;

        /* ── CAMERA SECTION ── */
        UILabel *camSec = mkSec(@"镜头控制");
        camSec.frame = CGRectMake(pad, y, cw, 16);
        [g_panel.contentView addSubview:camSec];
        y += 20;

        UIView *camBox = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 122)];
        camBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
        camBox.layer.cornerRadius = 14;
        [g_panel.contentView addSubview:camBox];

        UIButton *btnRead = mkBtn(@"读取内存状态",
            [UIColor colorWithRed:0.28 green:0.48 blue:0.92 alpha:1.0],
            [UIColor whiteColor], 13);
        btnRead.frame = CGRectMake(12, 12, cw - 24, 34);
        btnRead.layer.cornerRadius = 10;
        [btnRead addAction:[UIAction actionWithHandler:^(UIAction *act) {
            g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [camBox addSubview:btnRead];

        CGFloat pw = (cw - 40) / 2;
        NSArray *presets = @[
            @{@"t":@"超近景", @"v":@0,
              @"c":[UIColor colorWithRed:0.22 green:0.74 blue:0.52 alpha:1.0]},
            @{@"t":@"近景", @"v":@1,
              @"c":[UIColor colorWithRed:0.26 green:0.62 blue:0.88 alpha:1.0]},
            @{@"t":@"标准", @"v":@2,
              @"c":[UIColor colorWithRed:0.88 green:0.55 blue:0.35 alpha:1.0]},
            @{@"t":@"远景", @"v":@5,
              @"c":[UIColor colorWithRed:0.62 green:0.48 blue:0.88 alpha:1.0]},
        ];
        for (int i = 0; i < 4; i++) {
            NSDictionary *p = presets[i];
            UIButton *pb = mkBtn(p[@"t"], p[@"c"], [UIColor whiteColor], 11);
            pb.frame = CGRectMake(12 + (i % 2) * (pw + 12), 54 + (i / 2) * 30, pw, 26);
            int32_t val = [p[@"v"] intValue];
            [pb addAction:[UIAction actionWithHandler:^(UIAction *act) {
                writeCameraHeight(val);
                g_output.text = readAll();
            }] forControlEvents:UIControlEventTouchUpInside];
            [camBox addSubview:pb];
        }

        y += 134;

        /* ── OUTPUT SECTION ── */
        UILabel *outSec = mkSec(@"运行状态");
        outSec.frame = CGRectMake(pad, y, cw, 16);
        [g_panel.contentView addSubview:outSec];
        y += 20;

        CGFloat oh = h - y - pad;
        g_output = [[UITextView alloc] initWithFrame:CGRectMake(pad, y, cw, oh)];
        g_output.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
        g_output.textColor = [UIColor colorWithRed:0.62 green:0.94 blue:0.72 alpha:1.0];
        g_output.font = [UIFont fontWithName:@"Menlo" size:10];
        g_output.editable = NO;
        g_output.text = @"";
        g_output.layer.cornerRadius = 12;
        g_output.layer.borderWidth = 1;
        g_output.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.06].CGColor;
        g_output.textContainerInset = UIEdgeInsetsMake(8, 10, 8, 10);
        [g_panel.contentView addSubview:g_output];


        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3000 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
                g_output.text = readAll();
            });
        g_hud.hidden = NO;
    });
}

/* ── IL2CPP runtime function typedefs ── */
typedef void* (*il2cpp_class_from_name_t)(void* image, const char* ns, const char* name);
typedef struct { void* methodPointer; uint8_t _pad[48]; } Il2CppMethodInfo;
typedef Il2CppMethodInfo* (*il2cpp_class_get_method_from_name_t)(void* klass, const char* name, int args);

il2cpp_class_from_name_t p_il2cpp_class_from_name = NULL;
il2cpp_class_get_method_from_name_t p_il2cpp_class_get_method_from_name = NULL;

bool initIl2CppAPI(void) {
    if (p_il2cpp_class_from_name && p_il2cpp_class_get_method_from_name)
        return true;

    p_il2cpp_class_from_name = (il2cpp_class_from_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    p_il2cpp_class_get_method_from_name = (il2cpp_class_get_method_from_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");

    if (!p_il2cpp_class_from_name || !p_il2cpp_class_get_method_from_name) {
        NSLog(@"[GameHack] dlsym: il2cpp API not found in UnityFramework");
        return false;
    }
    NSLog(@"[GameHack] il2cpp API resolved via dlsym");
    return true;
}

static void* resolveIl2CppMethod(const char* ns, const char* klassName, const char* methodName, int args) {
    if (!initIl2CppAPI()) return NULL;

    void* klass = p_il2cpp_class_from_name(NULL, ns, klassName);
    if (!klass) {
        NSLog(@"[GameHack] class not found: %s.%s", ns, klassName);
        return NULL;
    }

    Il2CppMethodInfo* method = p_il2cpp_class_get_method_from_name(klass, methodName, args);
    if (!method || !method->methodPointer) {
        NSLog(@"[GameHack] method not found: %s.%s$$%s", ns, klassName, methodName);
        return NULL;
    }

    NSLog(@"[GameHack] resolved %s.%s$$%s @ 0x%lx",
          ns, klassName, methodName, (uintptr_t)method->methodPointer);
    return method->methodPointer;
}

%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *n = _dyld_get_image_name(i);
            if (n && strstr(n, "UnityFramework")) {
                unityBase = (uintptr_t)_dyld_get_image_header(i);
                break;
            }
        }
        NSLog(@"[GameHack] UnityFramework base: 0x%lx", unityBase);
        // Hooks installed on-demand by button press (not at startup)
        showHUD();
    });
}

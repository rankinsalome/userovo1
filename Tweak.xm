#import <substrate.h>
#import <mach-o/dyld.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#include <string.h>

/* ── RVA offsets from UnityFramework base (from smoba IL2CPP dump) ── */
#define RVA_GET_BVISIBLE      0x164CE50  // FowVisibleResult$$get_bVisible
#define RVA_FOW_APPLY         0x16C4598  // FogOfWarSettings$$Apply
#define RVA_FOW_UPDATE        0x16C9DCC  // PartitionedFog$$UpdateFogState

#define DATA_SLOT_STATICFIELDS 0x1355AC68

static uintptr_t unityBase = 0;

/* ── Original function pointers ── */
static bool (*orig_get_bVisible)(void *self);
static void (*orig_fowApply)(void *color, float dist, float thresh, float intensity, float fowIntensity);
static void (*orig_fowUpdate)(void *self);

/* ── State ── */
static bool g_fogDisabled = false;
static bool g_mapHackEnabled = false;

/* ═══════════════════════════════════════════ */
/*  HOOK: FowVisibleResult.get_bVisible      */
/*  Forces all units visible when enabled    */
/* ═══════════════════════════════════════════ */
static bool hook_get_bVisible(void *self) {
    if (g_mapHackEnabled) {
        if (self) *(uint8_t *)((uintptr_t)self + 0xC) = 1;
        return true;
    }
    return orig_get_bVisible(self);
}

/* ═══════════════════════════════════════════ */
/*  HOOK: FogOfWarSettings.Apply             */
/*  Forces fog intensity to zero             */
/* ═══════════════════════════════════════════ */
static void hook_fowApply(void *color, float dist, float thresh, float intensity, float fowIntensity) {
    if (g_fogDisabled)
        orig_fowApply(color, dist, thresh, 0.0f, 0.0f);
    else
        orig_fowApply(color, dist, thresh, intensity, fowIntensity);
}

/* ═══════════════════════════════════════════ */
/*  HOOK: PartitionedFog.UpdateFogState       */
/*  Skips per-frame fog updates when disabled */
/* ═══════════════════════════════════════════ */
static void hook_fowUpdate(void *self) {
    if (!g_fogDisabled)
        orig_fowUpdate(self);
}

/* ── HUD Window ── */
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
static UIView *g_statusDot = nil;
static UILabel *g_statusLabel = nil;

/* ── Status UI ── */
static void updateStatusUI(void) {
    if (!g_statusDot || !g_statusLabel) return;
    if (g_mapHackEnabled) {
        g_statusDot.backgroundColor = [UIColor colorWithRed:0.36 green:0.96 blue:0.53 alpha:1.0];
        g_statusLabel.text = g_fogDisabled ? @"FULLMAP" : @"VIS ALL";
        g_statusLabel.textColor = [UIColor colorWithRed:0.58 green:0.96 blue:0.72 alpha:1.0];
    } else {
        g_statusDot.backgroundColor = [UIColor colorWithWhite:0.38 alpha:1.0];
        g_statusLabel.text = @"IDLE";
        g_statusLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
    }
}

/* ── Memory helpers ── */
static uintptr_t getStaticFields(void) {
    if (!unityBase) return 0;
    uintptr_t slot = unityBase + DATA_SLOT_STATICFIELDS;
    uintptr_t klass = *(uintptr_t *)slot;
    if (!klass) return 0;
    return *(uintptr_t *)(klass + 0xB8);
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
    [s appendFormat:@"get_bVisible   0x%lX  %s\n",
        unityBase + RVA_GET_BVISIBLE, g_mapHackEnabled ? "ACTIVE" : "idle"];
    [s appendFormat:@"FogOfWar.Apply 0x%lX  %s\n",
        unityBase + RVA_FOW_APPLY, g_fogDisabled ? "FORCED zero" : "pass-through"];
    [s appendFormat:@"Fog.Update     0x%lX  %s\n",
        unityBase + RVA_FOW_UPDATE, g_fogDisabled ? "SKIPPED" : "active"];

    [s appendString:@"\n-- STATE --\n"];
    [s appendFormat:@"MapHack        %s\n", g_mapHackEnabled ? "ON" : "OFF"];
    [s appendFormat:@"VisualFog      %s\n", g_fogDisabled ? "CLEAR" : "NORMAL"];

    return s;
}

static void writeCameraHeight(int32_t v) {
    uintptr_t sf = getStaticFields();
    if (!sf) return;
    *(int32_t *)(sf + 0x1AC) = v;
}

/* ── Layout ── */
static void updateHUDLayout(void) {
    if (!g_hud || !g_panel) return;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) return;

    CGRect gb = window.bounds;
    CGFloat si = 20.0;
    CGFloat mw = MIN(330.0, CGRectGetWidth(gb) - si * 2);
    CGFloat mh = MIN(500.0, CGRectGetHeight(gb) - si * 2);
    CGFloat w = MAX(290.0, mw);
    CGFloat h = MAX(420.0, mh);

    CGFloat x = CGRectGetMidX(gb), y = CGRectGetMidY(gb);
    CGFloat l = si, t = si, r = CGRectGetWidth(gb) - si, b = CGRectGetHeight(gb) - si;
    if (g_hud.center.x < l + w / 2.0) x = l + w / 2.0;
    if (g_hud.center.x > r - w / 2.0) x = r - w / 2.0;
    if (g_hud.center.y < t + h / 2.0) y = t + h / 2.0;
    if (g_hud.center.y > b - h / 2.0) y = b - h / 2.0;

    g_hud.frame = CGRectMake(x - w / 2.0, y - h / 2.0, w, h);
    g_hud.rootViewController.view.frame = g_hud.bounds;
    g_panel.frame = g_hud.bounds;
    if (g_gradient) g_gradient.frame = g_panel.bounds;
}

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
        UIWindow *window = [UIApplication sharedApplication].keyWindow;
        CGRect gb = window ? window.bounds : [UIScreen mainScreen].bounds;
        CGFloat w = MIN(340.0, CGRectGetWidth(gb) - 36.0);
        CGFloat h = MIN(520.0, CGRectGetHeight(gb) - 36.0);
        w = MAX(w, 290.0); h = MAX(h, 420.0);
        CGFloat pad = 16.0, cw = w - pad * 2;

        g_hud = [[HUDWindow alloc] initWithFrame:CGRectMake(18, 70, w, h)];
        g_hud.windowLevel = UIWindowLevelAlert + 1;
        g_hud.backgroundColor = [UIColor clearColor];
        g_hud.layer.shadowColor = [UIColor blackColor].CGColor;
        g_hud.layer.shadowOpacity = 0.30;
        g_hud.layer.shadowRadius = 20;
        g_hud.layer.shadowOffset = CGSizeMake(0, 10);

        UIViewController *vc = [UIViewController new];
        vc.view.backgroundColor = [UIColor clearColor];
        g_hud.rootViewController = vc;

        /* ── Panel ── */
        g_panel = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        g_panel.frame = CGRectMake(0, 0, w, h);
        g_panel.layer.cornerRadius = 22;
        g_panel.layer.masksToBounds = YES;
        [vc.view addSubview:g_panel];

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
        title.text = @"GameHack Pro";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:16];
        [tb addSubview:title];

        g_statusDot = [[UIView alloc] initWithFrame:CGRectMake(w - 105, 17, 8, 8)];
        g_statusDot.layer.cornerRadius = 4;
        g_statusDot.backgroundColor = [UIColor colorWithWhite:0.38 alpha:1.0];
        [tb addSubview:g_statusDot];

        g_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 92, 15, 64, 14)];
        g_statusLabel.text = @"IDLE";
        g_statusLabel.textColor = [UIColor colorWithWhite:0.58 alpha:1.0];
        g_statusLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        [tb addSubview:g_statusLabel];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:g_hud action:@selector(onPan:)];
        [tb addGestureRecognizer:pan];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(w - 48, 8, 34, 34);
        close.tintColor = [UIColor whiteColor];
        [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"]
               forState:UIControlStateNormal];
        close.layer.cornerRadius = 17;
        close.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08];
        [close addAction:[UIAction actionWithHandler:^(UIAction *a) {
            g_hud.hidden = YES;
        }] forControlEvents:UIControlEventTouchUpInside];
        [tb addSubview:close];

        CGFloat y = 62.0;

        /* ── FOG OF WAR SECTION ── */
        UILabel *fogSec = mkSec(@"WAR FOG / MAP HACK");
        fogSec.frame = CGRectMake(pad, y, cw, 16);
        [g_panel.contentView addSubview:fogSec];
        y += 20;

        UIView *fogBox = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 88)];
        fogBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
        fogBox.layer.cornerRadius = 14;
        [g_panel.contentView addSubview:fogBox];

        UIButton *btnMapHack = mkBtn(@"ENABLE MAP HACK",
            [UIColor colorWithRed:0.22 green:0.65 blue:0.42 alpha:1.0],
            [UIColor whiteColor], 13);
        btnMapHack.frame = CGRectMake(12, 10, cw - 24, 36);
        btnMapHack.layer.cornerRadius = 10;
        [btnMapHack addAction:[UIAction actionWithHandler:^(UIAction *act) {
            g_mapHackEnabled = !g_mapHackEnabled;
            g_fogDisabled = g_mapHackEnabled;
            NSString *t = g_mapHackEnabled ? @"DISABLE MAP HACK" : @"ENABLE MAP HACK";
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

        UIButton *btnFogVis = mkBtn(@"Clear Visual Fog",
            [UIColor colorWithRed:0.18 green:0.45 blue:0.78 alpha:1.0],
            [UIColor whiteColor], 11);
        btnFogVis.frame = CGRectMake(12, 54, sw, 26);
        [btnFogVis addAction:[UIAction actionWithHandler:^(UIAction *act) {
            g_fogDisabled = !g_fogDisabled;
            NSString *t = g_fogDisabled ? @"Restore Visual Fog" : @"Clear Visual Fog";
            [act.sender setTitle:t forState:UIControlStateNormal];
            updateStatusUI();
            g_output.text = readAll();
        }] forControlEvents:UIControlEventTouchUpInside];
        [fogBox addSubview:btnFogVis];

        UIButton *btnReset = mkBtn(@"Reset All Fog",
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

        /* ── CAMERA SECTION ── */
        UILabel *camSec = mkSec(@"CAMERA CONTROL");
        camSec.frame = CGRectMake(pad, y, cw, 16);
        [g_panel.contentView addSubview:camSec];
        y += 20;

        UIView *camBox = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 122)];
        camBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
        camBox.layer.cornerRadius = 14;
        [g_panel.contentView addSubview:camBox];

        UIButton *btnRead = mkBtn(@"READ MEMORY STATE",
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
            @{@"t":@"ULTRA CLOSE", @"v":@0,
              @"c":[UIColor colorWithRed:0.22 green:0.74 blue:0.52 alpha:1.0]},
            @{@"t":@"CLOSE", @"v":@1,
              @"c":[UIColor colorWithRed:0.26 green:0.62 blue:0.88 alpha:1.0]},
            @{@"t":@"NORMAL", @"v":@2,
              @"c":[UIColor colorWithRed:0.88 green:0.55 blue:0.35 alpha:1.0]},
            @{@"t":@"FAR VIEW", @"v":@5,
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
        UILabel *outSec = mkSec(@"RUNTIME STATUS");
        outSec.frame = CGRectMake(pad, y, cw, 16);
        [g_panel.contentView addSubview:outSec];
        y += 20;

        CGFloat oh = h - y - pad;
        g_output = [[UITextView alloc] initWithFrame:CGRectMake(pad, y, cw, oh)];
        g_output.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
        g_output.textColor = [UIColor colorWithRed:0.62 green:0.94 blue:0.72 alpha:1.0];
        g_output.font = [UIFont fontWithName:@"Menlo" size:10];
        g_output.editable = NO;
        g_output.text = @"Initializing...";
        g_output.layer.cornerRadius = 12;
        g_output.layer.borderWidth = 1;
        g_output.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.06].CGColor;
        g_output.textContainerInset = UIEdgeInsetsMake(8, 10, 8, 10);
        [g_panel.contentView addSubview:g_output];

        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIWindowDidBecomeKeyNotification object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { updateHUDLayout(); }];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidChangeStatusBarOrientationNotification object:nil
            queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *n) { updateHUDLayout(); }];
#pragma clang diagnostic pop

        updateHUDLayout();
        g_hud.hidden = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
                g_output.text = readAll();
            });
    });
}

/* ═══════════════════════════════════════════ */
/*  HOOK INSTALL                             */
/* ═══════════════════════════════════════════ */
static void installHooks(void) {
    if (!unityBase) return;

    void *a1 = (void *)(unityBase + RVA_GET_BVISIBLE);
    MSHookFunction(a1, (void *)hook_get_bVisible, (void **)&orig_get_bVisible);
    NSLog(@"[GameHack] FowVisibleResult.get_bVisible @ 0x%lx", (uintptr_t)a1);

    void *a2 = (void *)(unityBase + RVA_FOW_APPLY);
    MSHookFunction(a2, (void *)hook_fowApply, (void **)&orig_fowApply);
    NSLog(@"[GameHack] FogOfWarSettings.Apply @ 0x%lx", (uintptr_t)a2);

    void *a3 = (void *)(unityBase + RVA_FOW_UPDATE);
    MSHookFunction(a3, (void *)hook_fowUpdate, (void **)&orig_fowUpdate);
    NSLog(@"[GameHack] PartitionedFog.UpdateFogState @ 0x%lx", (uintptr_t)a3);

    NSLog(@"[GameHack] All 3 fog hooks installed");
}

/* ── Constructor ── */
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
        if (unityBase) installHooks();
        showHUD();
    });
}

#import <substrate.h>
#import <mach-o/dyld.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#include <string.h>
#include <math.h>
#include <stdio.h>
#include <os/log.h>

static os_log_t g_runtimeLog;
static BOOL g_runtimeLogPrepared = NO;
static const unsigned long long kRuntimeLogLimit = 512ULL * 1024ULL;

static NSString *gamehackDocumentsLogPath(NSString *name) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsCandidate = (NSString *)[paths firstObject];
    NSString *documents = [documentsCandidate length] ? documentsCandidate : NSTemporaryDirectory();
    NSString *dir = [documents stringByAppendingPathComponent:@"gamehack_logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:name];
}

static NSString *gamehackCompatLogPath(NSString *name) {
    NSString *dir = @"/var/mobile/Library/Logs/gamehack";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:name];
}

static BOOL appendLineToPath(NSString *line, NSString *path, NSError **outError) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSString *dir = [path stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
        if (outError) *outError = error;
        return NO;
    }
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
    NSNumber *existingSize = attributes[NSFileSize];
    if (existingSize && existingSize.unsignedLongLongValue > kRuntimeLogLimit) {
        [fm removeItemAtPath:path error:NULL];
    }
    if (![fm fileExistsAtPath:path]) {
        if (![fm createFileAtPath:path contents:data attributes:nil]) {
            if (outError) *outError = [NSError errorWithDomain:@"gamehack.log" code:1 userInfo:@{NSLocalizedDescriptionKey: @"createFileAtPath failed"}];
            return NO;
        }
        return YES;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        if (outError) *outError = [NSError errorWithDomain:@"gamehack.log" code:2 userInfo:@{NSLocalizedDescriptionKey: @"fileHandleForWritingAtPath returned nil"}];
        return NO;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } @catch (NSException *exception) {
        [handle closeFile];
        if (outError) *outError = [NSError errorWithDomain:@"gamehack.log" code:3 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"write exception"}];
        return NO;
    }
    return YES;
}

static void runtimeLog(NSString *message) {
    if (!g_runtimeLog) g_runtimeLog = os_log_create("gamehack", "runtime");
    if (!g_runtimeLogPrepared) {
        g_runtimeLogPrepared = YES;
        message = [NSString stringWithFormat:@"runtime session begin; log cap=%llu bytes; %@",
                   kRuntimeLogLimit, message ?: @""];
    }
    os_log(g_runtimeLog, "%{public}@", message ?: @"");
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message ?: @""];
    NSString *primary = gamehackDocumentsLogPath(@"runtime.log");
    NSString *compat = gamehackCompatLogPath(@"runtime.log");
    NSError *error = nil;
    BOOL primaryOK = appendLineToPath(line, primary, &error);
    if (!primaryOK) os_log(g_runtimeLog, "primary log write failed: %{public}@", error.localizedDescription ?: @"unknown");
    NSError *compatError = nil;
    BOOL compatOK = appendLineToPath(line, compat, &compatError);
    if (!compatOK) os_log(g_runtimeLog, "compat log write failed: %{public}@", compatError.localizedDescription ?: @"unknown");
    if (!primaryOK && !compatOK) NSLog(@"[GameHack] no writable log path; primary=%@ compat=%@", primary, compat);
}

static void runtimeLogOnce(BOOL *flag, NSString *message) {
    if (!flag || *flag) return;
    *flag = YES;
    runtimeLog(message);
}

/* ── memory read slot (kept from original tweak) ── */
#define RVA_FOW_APPLY         0x16C4598  // FogOfWarSettings$$Apply
#define RVA_FOW_UPDATE        0x16C9DCC  // PartitionedFog$$UpdateFogState

#define DATA_SLOT_STATICFIELDS 0x1355AC68
uintptr_t unityBase = 0;

/* ── Original function pointers ── */


/* ── State ── */
static bool g_fogDisabled = false;
bool g_mapHackEnabled = false;
bool g_mapHackInstalled = false;
static bool g_cameraProbeValid = false;

/* ESP externs */
extern bool g_espEnabled;
extern void showESPOverlay(void);
extern void hideESPOverlay(void);
extern void updateESPMatrices(void);
extern void updateESPEntities(void);
extern void espBeginEntitySnapshot(void);
extern void espAppendEntitySnapshot(float x, float y, float z, float sx, float sy, float sz,
                                    const char *className, const char *namespaceName);
extern void espCommitEntitySnapshot(void);
extern void espClearEntitySnapshot(void);
extern void espSetRuntimeDiagnostics(int actorCount, int playerCount, bool cameraValid);
extern void espSetRuntimeEntityCount(int count);
extern void espSetUnityViewport(float width, float height);
extern void espSetPaused(bool paused);
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

- (void)layoutSubviews {
    [super layoutSubviews];
    [self clampBallToBounds];
    if (self.panelView && !self.panelView.hidden) {
        CGFloat w = self.panelView.bounds.size.width;
        CGFloat h = self.panelView.bounds.size.height;
        CGFloat maxW = self.bounds.size.width - 16.0;
        CGFloat maxH = self.bounds.size.height - 40.0;
        if (w > maxW || h > maxH) {
            self.panelView.bounds = CGRectMake(0, 0, MIN(w, maxW), MIN(h, maxH));
        }
        [self clampPanelToBounds];
    }
}

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
    NSArray *documentsPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsCandidate = (NSString *)[documentsPaths firstObject];
    NSString *documents = [documentsCandidate length] ? documentsCandidate : NSTemporaryDirectory();
    NSString *logDir = [documents stringByAppendingPathComponent:@"gamehack_logs"];
    [s appendString:@"\n-- RUNTIME PROBES --\n"];
    [s appendFormat:@"ESP camera     %s (Camera.main probe)\n",
        g_cameraProbeValid ? "VERIFIED" : "UNRESOLVED"];
    [s appendString:@"ESP entities   COUNTS ONLY (object probe safety-gated)\n"];
    [s appendFormat:@"ESP log         %@\nRuntime log     %@\n", [logDir stringByAppendingPathComponent:@"esp.log"], [logDir stringByAppendingPathComponent:@"runtime.log"]];
    [s appendString:@"Compat logs     /var/mobile/Library/Logs/gamehack/esp.log\n                /var/mobile/Library/Logs/gamehack/runtime.log\n"];

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
        g_panel.frame = CGRectMake(0, 0, w, MIN(h, CGRectGetHeight(gb) - 40.0));
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

        UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 50, w, g_panel.bounds.size.height - 50)];
        scroll.alwaysBounceVertical = YES;
        scroll.showsVerticalScrollIndicator = YES;
        scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
        scroll.delaysContentTouches = NO;
        [g_panel.contentView addSubview:scroll];
        UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 720)];
        content.backgroundColor = UIColor.clearColor;
        [scroll addSubview:content];
        scroll.contentSize = CGSizeMake(w, 720);

        CGFloat y = 12.0;

        /* ── FOG OF WAR SECTION ── */
        UILabel *fogSec = mkSec(@"战争迷雾 / 地图透视");
        fogSec.frame = CGRectMake(pad, y, cw, 16);
        [content addSubview:fogSec];
        y += 20;

        UIView *fogBox = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 88)];
        fogBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
        fogBox.layer.cornerRadius = 14;
        [content addSubview:fogBox];

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
        [content addSubview:btnESP];
        y += 44;

        /* ── CAMERA SECTION ── */
        UILabel *camSec = mkSec(@"镜头控制");
        camSec.frame = CGRectMake(pad, y, cw, 16);
        [content addSubview:camSec];
        y += 20;

        UIView *camBox = [[UIView alloc] initWithFrame:CGRectMake(pad, y, cw, 122)];
        camBox.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
        camBox.layer.cornerRadius = 14;
        [content addSubview:camBox];

        UIButton *btnRead = mkBtn(@"读取内存状态",
            [UIColor colorWithRed:0.28 green:0.48 blue:0.92 alpha:1.0],
            [UIColor whiteColor], 13);
        btnRead.frame = CGRectMake(12, 12, cw - 24, 34);
        btnRead.layer.cornerRadius = 10;
        [btnRead addAction:[UIAction actionWithHandler:^(UIAction *act) {
            runtimeLog(@"manual state read requested");
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
        [content addSubview:outSec];
        y += 20;

        CGFloat oh = 200.0;
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
        [content addSubview:g_output];
        y += oh + 16.0;
        content.frame = CGRectMake(0, 0, w, MAX(720.0, y + pad));
        scroll.contentSize = CGSizeMake(w, CGRectGetHeight(content.frame));


        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3000 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{
                g_output.text = readAll();
            });
        g_hud.hidden = NO;
    });
}

/* ── IL2CPP runtime function typedefs ── */
typedef struct Il2CppMethodInfo Il2CppMethodInfo;
typedef struct Il2CppObject Il2CppObject;
typedef struct Il2CppException Il2CppException;
typedef void* (*il2cpp_domain_get_t)(void);
typedef const void** (*il2cpp_domain_get_assemblies_t)(void* domain, size_t* size);
typedef void* (*il2cpp_assembly_get_image_t)(const void* assembly);
typedef const char* (*il2cpp_image_get_name_t)(const void* image);
typedef const char* (*il2cpp_image_get_filename_t)(const void* image);
typedef size_t (*il2cpp_image_get_class_count_t)(const void* image);
typedef void* (*il2cpp_image_get_class_t)(const void* image, size_t index);
typedef const char* (*il2cpp_class_get_name_t)(void* klass);
typedef const char* (*il2cpp_class_get_namespace_t)(void* klass);
typedef void* (*il2cpp_class_from_name_t)(void* image, const char* ns, const char* name);
typedef void* (*il2cpp_object_get_class_t)(Il2CppObject *obj);
/* Keep IL2CPP runtime types opaque.  A MethodInfo layout is version-specific;
 * runtime_invoke must receive the pointer returned by the exported resolver. */
typedef Il2CppObject* (*il2cpp_runtime_invoke_t)(const Il2CppMethodInfo *method, void* obj, void** params, Il2CppException** exc);
typedef const Il2CppMethodInfo* (*il2cpp_class_get_method_from_name_t)(void* klass, const char* name, int args);
typedef void* (*il2cpp_object_unbox_t)(Il2CppObject *obj);
typedef struct { float x, y, z; } Il2CppVector3;

static void probeCandidateMethods(void *klass, const char *imageName, const char *classNs, const char *className);
static BOOL isReadableExecutablePointer(void *ptr);
static const Il2CppMethodInfo *resolveMethod(void *klass, const char *name, int args);

il2cpp_domain_get_t p_il2cpp_domain_get = NULL;
il2cpp_domain_get_assemblies_t p_il2cpp_domain_get_assemblies = NULL;
il2cpp_assembly_get_image_t p_il2cpp_assembly_get_image = NULL;
il2cpp_image_get_name_t p_il2cpp_image_get_name = NULL;
il2cpp_image_get_filename_t p_il2cpp_image_get_filename = NULL;
il2cpp_image_get_class_count_t p_il2cpp_image_get_class_count = NULL;
il2cpp_image_get_class_t p_il2cpp_image_get_class = NULL;
il2cpp_class_get_name_t p_il2cpp_class_get_name = NULL;
il2cpp_class_get_namespace_t p_il2cpp_class_get_namespace = NULL;
il2cpp_class_from_name_t p_il2cpp_class_from_name = NULL;
il2cpp_object_get_class_t p_il2cpp_object_get_class = NULL;
il2cpp_class_get_method_from_name_t p_il2cpp_class_get_method_from_name = NULL;
il2cpp_runtime_invoke_t p_il2cpp_runtime_invoke = NULL;
il2cpp_object_unbox_t p_il2cpp_object_unbox = NULL;

bool initIl2CppAPI(void) {
    if (p_il2cpp_domain_get && p_il2cpp_domain_get_assemblies &&
        p_il2cpp_assembly_get_image && p_il2cpp_image_get_name &&
        p_il2cpp_image_get_class_count && p_il2cpp_image_get_class &&
        p_il2cpp_class_get_name && p_il2cpp_class_get_namespace &&
        p_il2cpp_class_from_name && p_il2cpp_class_get_method_from_name)
        return true;

    p_il2cpp_domain_get = (il2cpp_domain_get_t)dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    p_il2cpp_domain_get_assemblies = (il2cpp_domain_get_assemblies_t)dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    p_il2cpp_assembly_get_image = (il2cpp_assembly_get_image_t)dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    p_il2cpp_image_get_name = (il2cpp_image_get_name_t)dlsym(RTLD_DEFAULT, "il2cpp_image_get_name");
    p_il2cpp_image_get_filename = (il2cpp_image_get_filename_t)dlsym(RTLD_DEFAULT, "il2cpp_image_get_filename");
    p_il2cpp_image_get_class_count = (il2cpp_image_get_class_count_t)dlsym(RTLD_DEFAULT, "il2cpp_image_get_class_count");
    p_il2cpp_image_get_class = (il2cpp_image_get_class_t)dlsym(RTLD_DEFAULT, "il2cpp_image_get_class");
    p_il2cpp_class_get_name = (il2cpp_class_get_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_name");
    p_il2cpp_class_get_namespace = (il2cpp_class_get_namespace_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_namespace");
    p_il2cpp_class_from_name = (il2cpp_class_from_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    p_il2cpp_object_get_class = (il2cpp_object_get_class_t)dlsym(RTLD_DEFAULT, "il2cpp_object_get_class");
    p_il2cpp_class_get_method_from_name = (il2cpp_class_get_method_from_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
    p_il2cpp_runtime_invoke = (il2cpp_runtime_invoke_t)dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    p_il2cpp_object_unbox = (il2cpp_object_unbox_t)dlsym(RTLD_DEFAULT, "il2cpp_object_unbox");

    if (!p_il2cpp_domain_get || !p_il2cpp_domain_get_assemblies ||
        !p_il2cpp_assembly_get_image || !p_il2cpp_image_get_name ||
        !p_il2cpp_image_get_class_count || !p_il2cpp_image_get_class ||
        !p_il2cpp_class_get_name || !p_il2cpp_class_get_namespace ||
        !p_il2cpp_class_from_name || !p_il2cpp_class_get_method_from_name ||
        !p_il2cpp_object_get_class) {
        runtimeLog([NSString stringWithFormat:@"il2cpp API incomplete domain=%d assemblies=%d image=%d name=%d filename=%d classCount=%d classAt=%d className=%d classNs=%d class=%d method=%d",
            p_il2cpp_domain_get != NULL, p_il2cpp_domain_get_assemblies != NULL,
            p_il2cpp_assembly_get_image != NULL, p_il2cpp_image_get_name != NULL,
            p_il2cpp_image_get_filename != NULL,
            p_il2cpp_image_get_class_count != NULL, p_il2cpp_image_get_class != NULL,
            p_il2cpp_class_get_name != NULL, p_il2cpp_class_get_namespace != NULL,
            p_il2cpp_class_from_name != NULL, p_il2cpp_class_get_method_from_name != NULL]);
        runtimeLog([NSString stringWithFormat:@"il2cpp object_get_class=%d", p_il2cpp_object_get_class != NULL]);
        return false;
    }
    runtimeLog([NSString stringWithFormat:@"il2cpp API resolved via dlsym runtime_invoke=%d object_unbox=%d object_get_class=%d",
        p_il2cpp_runtime_invoke != NULL, p_il2cpp_object_unbox != NULL, p_il2cpp_object_get_class != NULL]);
    return true;
}

static BOOL isTargetImage(const char *name) {
    if (!name) return NO;
    static const char *targets[] = {
        "Scripts.GamePlay.dll", "Scripts.GameCore.dll", "Scripts.System.dll",
        "Scripts.Base.dll", "UnityEngine.CoreModule.dll"
    };
    for (NSUInteger i = 0; i < sizeof(targets) / sizeof(targets[0]); i++)
        if (strcmp(name, targets[i]) == 0) return YES;
    return NO;
}

static BOOL classNameMatches(const char *name) {
    if (!name) return NO;
    static const char *keywords[] = {
        "World", "Player", "Actor", "Entity", "Camera", "Transform", "Game"
    };
    for (NSUInteger i = 0; i < sizeof(keywords) / sizeof(keywords[0]); i++)
        if (strstr(name, keywords[i])) return YES;
    return NO;
}

static BOOL isHighValueClass(const char *name) {
    if (!name) return NO;
    static const char *classes[] = {
        "Camera", "CameraSystem", "ActorManager", "GamePlayerCenter",
        "Player", "Transform"
    };
    for (NSUInteger i = 0; i < sizeof(classes) / sizeof(classes[0]); i++)
        if (strcmp(name, classes[i]) == 0) return YES;
    return NO;
}

static void enumerateTargetClasses(void) {
    if (!initIl2CppAPI()) return;
    void *domain = p_il2cpp_domain_get();
    size_t count = 0;
    const void **assemblies = domain ? p_il2cpp_domain_get_assemblies(domain, &count) : NULL;
    if (!assemblies || count == 0 || count > 4096) {
        runtimeLog(@"il2cpp class enumeration skipped: assemblies unavailable");
        return;
    }
    for (size_t i = 0; i < count; i++) {
        const void *assembly = assemblies[i];
        void *image = assembly ? p_il2cpp_assembly_get_image(assembly) : NULL;
        const char *imageName = image ? p_il2cpp_image_get_name(image) : NULL;
        if (!image || !isTargetImage(imageName)) continue;
        size_t classCount = p_il2cpp_image_get_class_count(image);
        runtimeLog([NSString stringWithFormat:@"il2cpp target image=%s classes=%lu",
            imageName ?: "", (unsigned long)classCount]);
        if (classCount > 100000) continue;
        for (size_t ci = 0; ci < classCount; ci++) {
            void *klass = p_il2cpp_image_get_class(image, ci);
            const char *className = klass ? p_il2cpp_class_get_name(klass) : NULL;
            const char *classNs = klass ? p_il2cpp_class_get_namespace(klass) : NULL;
            if (className && (classNameMatches(className) && isHighValueClass(className))) {
                runtimeLog([NSString stringWithFormat:@"il2cpp class image=%s ns=%s name=%s",
                    imageName ?: "", classNs ?: "", className]);
                probeCandidateMethods(klass, imageName, classNs, className);
            }
        }
    }
}

static void probeCandidateMethods(void *klass, const char *imageName, const char *classNs, const char *className) {
    if (!klass || !className) return;
    static const char *methods[] = {
        "get_main", "get_camera", "GetCamera", "get_instance", "Instance",
        "get_transform", "get_position", "GetPosition", "GetActor",
        "GetActors", "GetPlayer", "GetPlayers", "get_world", "GetWorld"
    };
    for (NSUInteger i = 0; i < sizeof(methods) / sizeof(methods[0]); i++) {
        for (int args = 0; args <= 3; args++) {
            const Il2CppMethodInfo *method = p_il2cpp_class_get_method_from_name(klass, methods[i], args);
            if (method) {
                runtimeLog([NSString stringWithFormat:@"il2cpp candidate image=%s ns=%s class=%s method=%s args=%d MethodInfo=0x%lx",
                    imageName ?: "", classNs ?: "", className, methods[i], args,
                    (uintptr_t)method]);
                break;
            }
        }
    }
}

static BOOL isReadableExecutablePointer(void *ptr) {
    uintptr_t p = (uintptr_t)ptr;
    if (!p || (p & 0x3) != 0) return NO;
    uintptr_t base = unityBase;
    if (!base) return NO;
    return p >= base && p < base + 0x30000000ULL;
}

static void *findIl2CppImageNamed(const char *wanted) {
    if (!wanted || !initIl2CppAPI()) return NULL;
    void *domain = p_il2cpp_domain_get ? p_il2cpp_domain_get() : NULL;
    size_t count = 0;
    const void **assemblies = domain ? p_il2cpp_domain_get_assemblies(domain, &count) : NULL;
    if (!assemblies || count == 0 || count > 4096) return NULL;
    for (size_t i = 0; i < count; i++) {
        void *image = assemblies[i] ? p_il2cpp_assembly_get_image(assemblies[i]) : NULL;
        const char *name = image ? p_il2cpp_image_get_name(image) : NULL;
        if (name && strcmp(name, wanted) == 0) return image;
    }
    return NULL;
}

static void logCompactRuntimeBootstrap(void) {
    static BOOL logged = NO;
    if (logged) return;
    logged = YES;
    if (!initIl2CppAPI()) {
        runtimeLog(@"bootstrap api=0");
        return;
    }
    void *domain = p_il2cpp_domain_get ? p_il2cpp_domain_get() : NULL;
    size_t assemblyCount = 0;
    const void **assemblies = domain && p_il2cpp_domain_get_assemblies
        ? p_il2cpp_domain_get_assemblies(domain, &assemblyCount) : NULL;
    void *core = assemblies ? findIl2CppImageNamed("Scripts.GameCore.dll") : NULL;
    void *base = assemblies ? findIl2CppImageNamed("Scripts.Base.dll") : NULL;
    void *unity = assemblies ? findIl2CppImageNamed("UnityEngine.CoreModule.dll") : NULL;
    void *actor = core ? p_il2cpp_class_from_name(core, "Assets.Scripts.GameLogic", "ActorManager") : NULL;
    void *players = core ? p_il2cpp_class_from_name(core, "Assets.Scripts.GameLogic", "GamePlayerCenter") : NULL;
    void *linker = base ? p_il2cpp_class_from_name(base, "Assets.Scripts.GameLogic", "IActorLinker") : NULL;
    void *camera = unity ? p_il2cpp_class_from_name(unity, "UnityEngine", "Camera") : NULL;
    BOOL chainMethods = actor && resolveMethod(actor, "get_instance", 0) &&
        resolveMethod(actor, "GetHeroActorCount", 0) &&
        resolveMethod(actor, "GetHeroActorByIndex", 1) && linker &&
        resolveMethod(linker, "get_Position", 0);
    runtimeLog([NSString stringWithFormat:
        @"bootstrap api=1 assemblies=%lu images(core=%d base=%d unity=%d) classes(actor=%d players=%d linker=%d camera=%d) heroChainMethods=%d",
        (unsigned long)assemblyCount, core != NULL, base != NULL, unity != NULL,
        actor != NULL, players != NULL, linker != NULL, camera != NULL, chainMethods]);
}

static const Il2CppMethodInfo *resolveMethod(void *klass, const char *name, int args) {
    return (klass && name && p_il2cpp_class_get_method_from_name)
        ? p_il2cpp_class_get_method_from_name(klass, name, args) : NULL;
}

static Il2CppObject *invokeMethod(const Il2CppMethodInfo *method, Il2CppObject *object,
                                  void **params, Il2CppException **exception) {
    if (!method || !p_il2cpp_runtime_invoke) return NULL;
    return p_il2cpp_runtime_invoke(method, object, params, exception);
}

static BOOL readObjectClassName(Il2CppObject *object, char *name, size_t nameCap,
                                char *ns, size_t nsCap) {
    if (name && nameCap) name[0] = 0;
    if (ns && nsCap) ns[0] = 0;
    if (!object || !p_il2cpp_object_get_class || !p_il2cpp_class_get_name) return NO;
    void *klass = p_il2cpp_object_get_class(object);
    if (!klass) return NO;
    const char *cn = p_il2cpp_class_get_name(klass);
    const char *nn = p_il2cpp_class_get_namespace ? p_il2cpp_class_get_namespace(klass) : NULL;
    if (name && nameCap && cn) strncpy(name, cn, nameCap - 1);
    if (ns && nsCap && nn) strncpy(ns, nn, nsCap - 1);
    return cn != NULL;
}

static BOOL readObjectPosition(Il2CppObject *object, Il2CppVector3 *outPosition) {
    if (!object || !outPosition || !p_il2cpp_object_get_class || !p_il2cpp_object_unbox) return NO;
    void *objectClass = p_il2cpp_object_get_class(object);
    const Il2CppMethodInfo *getTransform = resolveMethod(objectClass, "get_transform", 0);
    if (!getTransform) {
        const Il2CppMethodInfo *getDirectPosition = resolveMethod(objectClass, "get_Position", 0);
        if (!getDirectPosition) {
            void *baseImage = findIl2CppImageNamed("Scripts.Base.dll");
            void *actorInterface = baseImage ? p_il2cpp_class_from_name(baseImage, "Assets.Scripts.GameLogic", "IActorLinker") : NULL;
            getDirectPosition = resolveMethod(actorInterface, "get_Position", 0);
        }
        if (getDirectPosition) {
            Il2CppException *directException = NULL;
            Il2CppObject *boxedDirect = invokeMethod(getDirectPosition, object, NULL, &directException);
            void *directRaw = (!directException && boxedDirect) ? p_il2cpp_object_unbox(boxedDirect) : NULL;
            if (directRaw) {
                *outPosition = *(Il2CppVector3 *)directRaw;
                return isfinite(outPosition->x) && isfinite(outPosition->y) && isfinite(outPosition->z);
            }
        }
        void *coreImage = findIl2CppImageNamed("UnityEngine.CoreModule.dll");
        void *componentClass = coreImage ? p_il2cpp_class_from_name(coreImage, "UnityEngine", "Component") : NULL;
        getTransform = resolveMethod(componentClass, "get_transform", 0);
    }
    if (!getTransform) return NO;
    Il2CppException *exception = NULL;
    Il2CppObject *transform = invokeMethod(getTransform, object, NULL, &exception);
    if (!transform || exception) return NO;
    void *transformClass = p_il2cpp_object_get_class(transform);
    const Il2CppMethodInfo *getPosition = resolveMethod(transformClass, "get_position", 0);
    if (!getPosition) {
        void *coreImage = findIl2CppImageNamed("UnityEngine.CoreModule.dll");
        void *transformType = coreImage ? p_il2cpp_class_from_name(coreImage, "UnityEngine", "Transform") : NULL;
        getPosition = resolveMethod(transformType, "get_position", 0);
    }
    if (!getPosition) return NO;
    exception = NULL;
    Il2CppObject *boxed = invokeMethod(getPosition, transform, NULL, &exception);
    if (!boxed || exception) return NO;
    void *raw = p_il2cpp_object_unbox(boxed);
    if (!raw) return NO;
    *outPosition = *(Il2CppVector3 *)raw;
    return isfinite(outPosition->x) && isfinite(outPosition->y) && isfinite(outPosition->z);
}

static Il2CppObject *g_projectionCamera = NULL;
static const Il2CppMethodInfo *g_worldToScreenMethod = NULL;

static void resetProjectionContext(void) {
    g_projectionCamera = NULL;
    g_worldToScreenMethod = NULL;
}

static BOOL prepareProjectionContext(void) {
    if (g_projectionCamera && g_worldToScreenMethod) return YES;
    void *coreImage = findIl2CppImageNamed("UnityEngine.CoreModule.dll");
    void *cameraClass = coreImage ? p_il2cpp_class_from_name(coreImage, "UnityEngine", "Camera") : NULL;
    const Il2CppMethodInfo *getMain = resolveMethod(cameraClass, "get_main", 0);
    if (!getMain) return NO;
    Il2CppException *exception = NULL;
    Il2CppObject *camera = invokeMethod(getMain, NULL, NULL, &exception);
    if (!camera || exception) return NO;
    void *runtimeCameraClass = p_il2cpp_object_get_class ? p_il2cpp_object_get_class(camera) : cameraClass;
    const Il2CppMethodInfo *worldToScreen = resolveMethod(runtimeCameraClass, "WorldToScreenPoint", 1);
    if (!worldToScreen) worldToScreen = resolveMethod(cameraClass, "WorldToScreenPoint", 1);
    if (!worldToScreen) return NO;
    g_projectionCamera = camera;
    g_worldToScreenMethod = worldToScreen;
    return YES;
}

static BOOL projectWorldPosition(Il2CppVector3 position, Il2CppVector3 *outScreen) {
    if (!outScreen || !p_il2cpp_runtime_invoke || !prepareProjectionContext()) return NO;
    Il2CppException *exception = NULL;
    void *params[1] = { &position };
    Il2CppObject *boxedScreen = invokeMethod(g_worldToScreenMethod, g_projectionCamera, params, &exception);
    if (!boxedScreen || exception || !p_il2cpp_object_unbox) return NO;
    void *raw = p_il2cpp_object_unbox(boxedScreen);
    if (!raw) return NO;
    *outScreen = *(Il2CppVector3 *)raw;
    return isfinite(outScreen->x) && isfinite(outScreen->y) && isfinite(outScreen->z);
}

static int readManagerCount(void *klass, Il2CppObject *manager, const char *methodName) {
    const Il2CppMethodInfo *method = resolveMethod(klass, methodName, 0);
    if (!method || !manager || !p_il2cpp_object_unbox) return 0;
    Il2CppException *exception = NULL;
    Il2CppObject *boxed = invokeMethod(method, manager, NULL, &exception);
    if (!boxed || exception) return 0;
    int32_t *value = (int32_t *)p_il2cpp_object_unbox(boxed);
    return value ? *value : 0;
}

static void probeEntityObjects(void *gameCoreImage) {
    if (!gameCoreImage || !p_il2cpp_runtime_invoke || !p_il2cpp_object_get_class) return;
    void *centerClass = p_il2cpp_class_from_name(gameCoreImage, "Assets.Scripts.GameLogic", "GamePlayerCenter");
    const Il2CppMethodInfo *getInstance = resolveMethod(centerClass, "get_instance", 0);
    const Il2CppMethodInfo *getPlayer = resolveMethod(centerClass, "GetPlayer", 1);
    const Il2CppMethodInfo *getPlayersList = resolveMethod(centerClass, "get_PlayersListCache", 0);
    if (!centerClass || !getInstance || (!getPlayer && !getPlayersList)) {
        runtimeLog(@"entity objects unresolved GamePlayerCenter/get_instance/player-list");
        espBeginEntitySnapshot();
        espCommitEntitySnapshot();
        return;
    }
    Il2CppException *exception = NULL;
    Il2CppObject *center = invokeMethod(getInstance, NULL, NULL, &exception);
    if (!center || exception) {
        runtimeLog([NSString stringWithFormat:@"entity objects center unavailable object=0x%lx exception=0x%lx",
                    (uintptr_t)center, (uintptr_t)exception]);
        espBeginEntitySnapshot();
        espCommitEntitySnapshot();
        return;
    }
    int count = readManagerCount(centerClass, center, "GetPlayerNum");
    if (count < 0 || count > 128) count = 0;
    Il2CppObject *playersList = NULL;
    const Il2CppMethodInfo *getListItem = NULL;
    if (getPlayersList) {
        exception = NULL;
        playersList = invokeMethod(getPlayersList, center, NULL, &exception);
        if (!exception && playersList && p_il2cpp_object_get_class) {
            void *listClass = p_il2cpp_object_get_class(playersList);
            getListItem = resolveMethod(listClass, "get_Item", 1);
        }
    }
    runtimeLog([NSString stringWithFormat:@"entity player source list=%d listItem=%d getPlayerById=%d count=%d",
                playersList != NULL, getListItem != NULL, getPlayer != NULL, count]);
    resetProjectionContext();
    prepareProjectionContext();
    espBeginEntitySnapshot();
    int valid = 0;
    for (int index = 0; index < count; index++) {
        int32_t indexValue = index;
        void *params[1] = { &indexValue };
        exception = NULL;
        Il2CppObject *player = NULL;
        if (playersList && getListItem) player = invokeMethod(getListItem, playersList, params, &exception);
        else if (getPlayer) player = invokeMethod(getPlayer, center, params, &exception);
        if (!player || exception) continue;
        char className[96] = {0};
        char namespaceName[96] = {0};
        readObjectClassName(player, className, sizeof(className), namespaceName, sizeof(namespaceName));
        Il2CppVector3 world = {0, 0, 0};
        if (!readObjectPosition(player, &world)) {
            runtimeLog([NSString stringWithFormat:@"entity object index=%d class=%s position=unresolved",
                        index, className[0] ? className : "unknown"]);
            continue;
        }
        Il2CppVector3 screen = {-1, -1, -1};
        BOOL screenOK = projectWorldPosition(world, &screen);
        float drawX = screenOK ? screen.x : -1.0f;
        float drawY = screenOK ? screen.y : -1.0f;
        espAppendEntitySnapshot(world.x, world.y, world.z, drawX, drawY, screen.z,
                                className, namespaceName);
        valid++;
        if (valid <= 16) {
            runtimeLog([NSString stringWithFormat:@"entity object index=%d ptr=0x%lx class=%s ns=%s world=(%.2f,%.2f,%.2f) screen=%s",
                        index, (uintptr_t)player, className[0] ? className : "unknown",
                        namespaceName[0] ? namespaceName : "", world.x, world.y, world.z,
                        screenOK ? "ok" : "unresolved"]);
        }
    }
    /* ActorManager exposes category/index accessors, but runtime-11 showed a
       native crash immediately after the first non-zero actor count. Keep
       count sampling active while the returned interface/handle ABI is
       isolated; do not invoke the item accessor in the live match path. */
    static const BOOL kEnableActorObjectEnumeration = NO;
    void *actorClass = p_il2cpp_class_from_name(gameCoreImage, "Assets.Scripts.GameLogic", "ActorManager");
    const Il2CppMethodInfo *actorGetter = resolveMethod(actorClass, "get_instance", 0);
    Il2CppObject *actorManager = NULL;
    if (actorGetter) {
        exception = NULL;
        actorManager = invokeMethod(actorGetter, NULL, NULL, &exception);
    }
    struct ActorSource { const char *countName; const char *itemName; } actorSources[] = {
        { "GetHeroActorCount", "GetHeroActorByIndex" },
        { "GetOrganActorCount", "GetOrganActorByIndex" },
        { "GetSoldierActorCount", "GetSoldierActorByIndex" },
        { "GetBuffMonsterCount", "GetBuffMonsterByIndex" },
        { "GetDragonActorCount", "GetDragonActorByIndex" }
    };
    int actorValid = 0;
    if (actorManager && actorClass && kEnableActorObjectEnumeration) {
        for (NSUInteger sourceIndex = 0; sourceIndex < sizeof(actorSources) / sizeof(actorSources[0]); sourceIndex++) {
            const Il2CppMethodInfo *countMethod = resolveMethod(actorClass, actorSources[sourceIndex].countName, 0);
            const Il2CppMethodInfo *itemMethod = resolveMethod(actorClass, actorSources[sourceIndex].itemName, 1);
            int sourceCount = 0;
            if (countMethod && p_il2cpp_object_unbox) {
                exception = NULL;
                Il2CppObject *boxed = invokeMethod(countMethod, actorManager, NULL, &exception);
                int32_t *value = (!exception && boxed) ? (int32_t *)p_il2cpp_object_unbox(boxed) : NULL;
                if (value) sourceCount = *value;
            }
            if (sourceCount < 0 || sourceCount > 256) sourceCount = 0;
            for (int index = 0; index < sourceCount && actorValid < 64; index++) {
                int32_t indexValue = index;
                void *params[1] = { &indexValue };
                exception = NULL;
                Il2CppObject *actor = itemMethod ? invokeMethod(itemMethod, actorManager, params, &exception) : NULL;
                if (!actor || exception) continue;
                char className[96] = {0};
                char namespaceName[96] = {0};
                readObjectClassName(actor, className, sizeof(className), namespaceName, sizeof(namespaceName));
                Il2CppVector3 world = {0, 0, 0};
                if (!readObjectPosition(actor, &world)) continue;
                Il2CppVector3 screen = {-1, -1, -1};
                BOOL screenOK = projectWorldPosition(world, &screen);
                espAppendEntitySnapshot(world.x, world.y, world.z,
                                        screenOK ? screen.x : -1.0f,
                                        screenOK ? screen.y : -1.0f,
                                        screen.z, className, namespaceName);
                actorValid++;
                if (actorValid <= 16) {
                    runtimeLog([NSString stringWithFormat:@"actor object source=%s index=%d ptr=0x%lx class=%s ns=%s world=(%.2f,%.2f,%.2f) screen=%s",
                                actorSources[sourceIndex].itemName, index, (uintptr_t)actor,
                                className[0] ? className : "unknown", namespaceName[0] ? namespaceName : "",
                                world.x, world.y, world.z, screenOK ? "ok" : "unresolved"]);
                }
            }
        }
    } else if (actorManager && actorClass) {
        runtimeLog(@"actor object enumeration skipped safety-gate=runtime-11-crash-after-nonzero-count");
    }
    espCommitEntitySnapshot();
    runtimeLog([NSString stringWithFormat:@"entity snapshot players=%d valid=%d actorValid=%d total=%d",
                count, valid, actorValid, valid + actorValid]);
}

static int g_lastHeroCount = -1;
static int g_stableHeroSamples = 0;
static BOOL g_singleHeroAttempted = NO;
static BOOL g_singleHeroSuccess = NO;
static BOOL g_singleHeroFailureLogged = NO;
static int g_lastHeroCategoryCounts[5] = { -2, -2, -2, -2, -2 };
static int g_actorSnapshot50Valid = 0;
static NSString *g_actorSnapshot50Signature = nil;
static NSTimeInterval g_lastActorGeometryLog = 0.0;
static float g_lastUnityViewportWidth = 0.0f;
static float g_lastUnityViewportHeight = 0.0f;

typedef struct {
    Il2CppObject *object;
    char displayName[128];
    char namespaceName[96];
} ActorPositionRef50;

static ActorPositionRef50 g_actorPositionRefs50[64];
static int g_actorPositionRefCount50 = 0;
static int g_positionRefreshValid50 = 0;
static uint64_t g_positionRefreshCount = 0;
static NSTimeInterval g_lastPositionRefreshLog = 0.0;

static int readBoxedIntResult(const Il2CppMethodInfo *method, Il2CppObject *object,
                              void **params, BOOL *ok) {
    if (ok) *ok = NO;
    if (!method || !p_il2cpp_object_unbox) return -1;
    Il2CppException *exception = NULL;
    Il2CppObject *boxed = invokeMethod(method, object, params, &exception);
    int32_t *raw = (!exception && boxed) ? (int32_t *)p_il2cpp_object_unbox(boxed) : NULL;
    if (!raw) return -1;
    if (ok) *ok = YES;
    return *raw;
}

static void updateProjectionViewport(void) {
    float width = (float)[UIScreen mainScreen].bounds.size.width;
    float height = (float)[UIScreen mainScreen].bounds.size.height;
    if (g_projectionCamera && p_il2cpp_object_get_class) {
        void *cameraClass = p_il2cpp_object_get_class(g_projectionCamera);
        BOOL widthOK = NO;
        BOOL heightOK = NO;
        int cameraWidth = readBoxedIntResult(resolveMethod(cameraClass, "get_pixelWidth", 0),
                                             g_projectionCamera, NULL, &widthOK);
        int cameraHeight = readBoxedIntResult(resolveMethod(cameraClass, "get_pixelHeight", 0),
                                              g_projectionCamera, NULL, &heightOK);
        if (widthOK && cameraWidth > 0 && cameraWidth < 10000) width = (float)cameraWidth;
        if (heightOK && cameraHeight > 0 && cameraHeight < 10000) height = (float)cameraHeight;
    }
    espSetUnityViewport(width, height);
    if (fabsf(width - g_lastUnityViewportWidth) > 0.5f ||
        fabsf(height - g_lastUnityViewportHeight) > 0.5f) {
        g_lastUnityViewportWidth = width;
        g_lastUnityViewportHeight = height;
        runtimeLog([NSString stringWithFormat:@"projection viewport unity=(%.0f,%.0f) overlay=(%.0f,%.0f) scale=%.2f",
                    width, height, [UIScreen mainScreen].bounds.size.width,
                    [UIScreen mainScreen].bounds.size.height,
                    [UIScreen mainScreen].scale]);
    }
}

static void probePlayerSemanticCounts(void *centerClass, Il2CppObject *center,
                                      int getPlayerNumValue) {
    static int lastNum = -2;
    static int lastPlayerCount = -2;
    static int lastCacheCount = -2;
    static int lastAllCount = -2;
    static BOOL errorLogged = NO;
    if (!centerClass || !center) return;
    const Il2CppMethodInfo *playerCountMethod = resolveMethod(centerClass, "get_PlayerCount", 0);
    const Il2CppMethodInfo *cacheMethod = resolveMethod(centerClass, "get_PlayersListCache", 0);
    const Il2CppMethodInfo *allMethod = resolveMethod(centerClass, "GetAllPlayers", 0);
    BOOL ok = NO;
    int playerCount = readBoxedIntResult(playerCountMethod, center, NULL, &ok);
    if (!ok) playerCount = -1;
    int cacheCount = -1;
    int allCount = -1;
    Il2CppException *exception = NULL;
    Il2CppObject *cache = cacheMethod ? invokeMethod(cacheMethod, center, NULL, &exception) : NULL;
    if (!exception && cache && p_il2cpp_object_get_class) {
        void *listClass = p_il2cpp_object_get_class(cache);
        const Il2CppMethodInfo *listCountMethod = resolveMethod(listClass, "get_Count", 0);
        cacheCount = readBoxedIntResult(listCountMethod, cache, NULL, &ok);
        if (!ok) cacheCount = -1;
    }
    exception = NULL;
    Il2CppObject *all = allMethod ? invokeMethod(allMethod, center, NULL, &exception) : NULL;
    if (!exception && all && p_il2cpp_object_get_class) {
        void *listClass = p_il2cpp_object_get_class(all);
        const Il2CppMethodInfo *listCountMethod = resolveMethod(listClass, "get_Count", 0);
        allCount = readBoxedIntResult(listCountMethod, all, NULL, &ok);
        if (!ok) allCount = -1;
    }
    if (playerCount == lastPlayerCount && cacheCount == lastCacheCount &&
        allCount == lastAllCount && getPlayerNumValue == lastNum) return;
    lastNum = getPlayerNumValue;
    lastPlayerCount = playerCount;
    lastCacheCount = cacheCount;
    lastAllCount = allCount;
    runtimeLog([NSString stringWithFormat:
        @"player semantics getPlayerNum=%d playerCount=%d cacheCount=%d allPlayersCount=%d",
        getPlayerNumValue, playerCount, cacheCount, allCount]);
    if (!playerCountMethod || !cacheMethod || !allMethod ||
        (cacheCount < 0 && allCount < 0)) {
        if (!errorLogged) {
            errorLogged = YES;
            runtimeLog([NSString stringWithFormat:
                @"player semantics incomplete methods(playerCount=%d cache=%d all=%d)",
                playerCountMethod != NULL, cacheMethod != NULL, allMethod != NULL]);
        }
    }
}

/* One-object ABI check. It deliberately waits for three identical non-zero
 * hero counts, then invokes only Hero[0]. No batch enumeration is performed. */
static void probeSingleHeroActor(void *gameCoreImage, Il2CppObject *actorManager, void *actorClass) {
    if (g_singleHeroAttempted) return;
    if (!gameCoreImage || !actorManager || !actorClass || !p_il2cpp_object_unbox) {
        static BOOL missingLogged = NO;
        runtimeLogOnce(&missingLogged, @"actor chain waiting manager/class/unbox");
        return;
    }
    const Il2CppMethodInfo *countMethod = resolveMethod(actorClass, "GetHeroActorCount", 0);
    const Il2CppMethodInfo *itemMethod = resolveMethod(actorClass, "GetHeroActorByIndex", 1);
    if (!countMethod || !itemMethod) {
        static BOOL methodLogged = NO;
        runtimeLogOnce(&methodLogged, [NSString stringWithFormat:
            @"actor chain unresolved count=%d item=%d", countMethod != NULL, itemMethod != NULL]);
        return;
    }
    Il2CppException *exception = NULL;
    Il2CppObject *boxedCount = invokeMethod(countMethod, actorManager, NULL, &exception);
    int heroCount = -1;
    int32_t *countValue = (!exception && boxedCount) ? (int32_t *)p_il2cpp_object_unbox(boxedCount) : NULL;
    if (countValue) heroCount = *countValue;
    if (heroCount < 0 || heroCount > 128) heroCount = -1;
    if (heroCount <= 0) {
        g_lastHeroCount = heroCount;
        g_stableHeroSamples = 0;
        return;
    }
    if (heroCount == g_lastHeroCount) g_stableHeroSamples++;
    else g_stableHeroSamples = 1;
    g_lastHeroCount = heroCount;
    if (g_stableHeroSamples < 3) {
        if (g_stableHeroSamples == 1) {
            runtimeLog([NSString stringWithFormat:@"actor chain waiting heroCount=%d stable=%d/3",
                        heroCount, g_stableHeroSamples]);
        }
        return;
    }

    g_singleHeroAttempted = YES;
    int32_t indexValue = 0;
    void *params[1] = { &indexValue };
    exception = NULL;
    Il2CppObject *actor = invokeMethod(itemMethod, actorManager, params, &exception);
    if (!actor || exception) {
        if (!g_singleHeroFailureLogged) {
            g_singleHeroFailureLogged = YES;
            runtimeLog([NSString stringWithFormat:
                @"actor chain hero[0] unresolved ptr=0x%lx exception=0x%lx",
                (uintptr_t)actor, (uintptr_t)exception]);
        }
        return;
    }
    char className[96] = {0};
    char namespaceName[96] = {0};
    BOOL classOK = readObjectClassName(actor, className, sizeof(className),
                                       namespaceName, sizeof(namespaceName));
    Il2CppVector3 world = {0, 0, 0};
    BOOL positionOK = readObjectPosition(actor, &world);
    Il2CppVector3 screen = {-1, -1, -1};
    BOOL screenOK = positionOK && projectWorldPosition(world, &screen);
    espBeginEntitySnapshot();
    if (positionOK) {
        espAppendEntitySnapshot(world.x, world.y, world.z,
                                screenOK ? screen.x : -1.0f,
                                screenOK ? screen.y : -1.0f,
                                screenOK ? screen.z : -1.0f,
                                className, namespaceName);
        g_singleHeroSuccess = YES;
    }
    espCommitEntitySnapshot();
    runtimeLog([NSString stringWithFormat:
        @"actor chain hero[0] ptr=0x%lx class=%s ns=%s classOK=%d positionOK=%d world=(%.2f,%.2f,%.2f) screenOK=%d screen=(%.1f,%.1f,%.2f)",
        (uintptr_t)actor, className[0] ? className : "unknown",
        namespaceName[0] ? namespaceName : "", classOK, positionOK,
        world.x, world.y, world.z, screenOK, screen.x, screen.y, screen.z]);
}

static void logActorCategoryCounts(void *actorClass, Il2CppObject *actorManager) {
    static const char *names[] = {
        "GetHeroActorCount", "GetOrganActorCount", "GetSoldierActorCount",
        "GetBuffMonsterCount", "GetDragonActorCount"
    };
    int values[5] = { -1, -1, -1, -1, -1 };
    BOOL changed = NO;
    for (NSUInteger i = 0; i < 5; i++) {
        values[i] = readManagerCount(actorClass, actorManager, names[i]);
        if (values[i] != g_lastHeroCategoryCounts[i]) changed = YES;
    }
    if (!changed) return;
    memcpy(g_lastHeroCategoryCounts, values, sizeof(values));
    runtimeLog([NSString stringWithFormat:
        @"actor categories hero=%d organ=%d soldier=%d buffMonster=%d dragon=%d",
        values[0], values[1], values[2], values[3], values[4]]);
}

static BOOL isUsableActorWorld(Il2CppVector3 world) {
    if (!isfinite(world.x) || !isfinite(world.y) || !isfinite(world.z)) return NO;
    /* ActorManager returns this stable placeholder for an uninitialized slot. */
    if (fabsf(world.x - 1000.0f) < 0.01f &&
        fabsf(world.y + 100.0f) < 0.01f &&
        fabsf(world.z - 1000.0f) < 0.01f) return NO;
    return YES;
}

static BOOL isUsableActorScreen(Il2CppVector3 screen) {
    return isfinite(screen.x) && isfinite(screen.y) && isfinite(screen.z) && screen.z > 0.0f;
}

static BOOL appendActorPositionSnapshot(const ActorPositionRef50 *ref) {
    if (!ref || !ref->object) return NO;
    Il2CppVector3 world = {0, 0, 0};
    if (!readObjectPosition(ref->object, &world) || !isUsableActorWorld(world)) return NO;
    Il2CppVector3 screen = {-1, -1, -1};
    if (!projectWorldPosition(world, &screen) || !isUsableActorScreen(screen)) return NO;
    espAppendEntitySnapshot(world.x, world.y, world.z,
                            screen.x, screen.y, screen.z,
                            ref->displayName, ref->namespaceName);
    return YES;
}

static void refreshActorSnapshotPositions(void) {
    if (!g_singleHeroSuccess || g_actorPositionRefCount50 <= 0) return;
    if (!prepareProjectionContext()) return;

    espBeginEntitySnapshot();
    int valid = 0;
    for (int i = 0; i < g_actorPositionRefCount50 && valid < 50; i++) {
        if (appendActorPositionSnapshot(&g_actorPositionRefs50[i])) valid++;
    }
    espCommitEntitySnapshot();
    g_positionRefreshValid50 = valid;
    g_actorSnapshot50Valid = valid;
    espSetRuntimeEntityCount(valid);
    g_positionRefreshCount++;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (g_lastPositionRefreshLog <= 0.0 || now - g_lastPositionRefreshLog >= 5.0) {
        static uint64_t previousCount = 0;
        NSTimeInterval elapsed = g_lastPositionRefreshLog > 0.0
            ? now - g_lastPositionRefreshLog : 5.0;
        uint64_t delta = g_positionRefreshCount - previousCount;
        double rate = elapsed > 0.0 ? (double)delta / elapsed : 0.0;
        previousCount = g_positionRefreshCount;
        g_lastPositionRefreshLog = now;
        runtimeLog([NSString stringWithFormat:
            @"position refresh count=%llu refs=%d valid=%d rate=%.1fHz",
            (unsigned long long)g_positionRefreshCount, g_actorPositionRefCount50,
            g_positionRefreshValid50, rate]);
    }
}

static void cacheActorPositionRef50(Il2CppObject *actor, const char *displayName,
                                    const char *namespaceName) {
    if (!actor) return;
    for (int i = 0; i < g_actorPositionRefCount50; i++) {
        if (g_actorPositionRefs50[i].object == actor) return;
    }
    if (g_actorPositionRefCount50 >= 64) return;
    ActorPositionRef50 *ref = &g_actorPositionRefs50[g_actorPositionRefCount50++];
    ref->object = actor;
    if (displayName) strncpy(ref->displayName, displayName, sizeof(ref->displayName) - 1);
    if (namespaceName) strncpy(ref->namespaceName, namespaceName, sizeof(ref->namespaceName) - 1);
}

static int appendSupplementalActorList(void *actorClass, Il2CppObject *actorManager,
                                       const char *getterName, const char *sourceName,
                                       int *valid, char *signature, size_t signatureCap,
                                       size_t *signatureUsed) {
    if (!actorClass || !actorManager || !getterName || !sourceName || !valid) return 0;
    const Il2CppMethodInfo *getter = resolveMethod(actorClass, getterName, 0);
    if (!getter) return 0;
    Il2CppException *exception = NULL;
    Il2CppObject *list = invokeMethod(getter, actorManager, NULL, &exception);
    if (!list || exception || !p_il2cpp_object_get_class) return 0;
    void *listClass = p_il2cpp_object_get_class(list);
    const char *listClassName = (listClass && p_il2cpp_class_get_name)
        ? p_il2cpp_class_get_name(listClass) : NULL;
    const Il2CppMethodInfo *countMethod = resolveMethod(listClass, "get_Count", 0);
    const Il2CppMethodInfo *itemMethod = resolveMethod(listClass, "get_Item", 1);
    BOOL countOK = NO;
    int count = readBoxedIntResult(countMethod, list, NULL, &countOK);
    if (!countOK || count < 0 || count > 256) count = 0;
    static int lastCounts[2] = { -1, -1 };
    int slot = strcmp(sourceName, "CallMonster") == 0 ? 0 : 1;
    if (lastCounts[slot] != count) {
        lastCounts[slot] = count;
        runtimeLog([NSString stringWithFormat:
            @"actor supplemental source=%s listClass=%s count=%d countMethod=%d itemMethod=%d",
            sourceName, listClassName ?: "unknown", count,
            countMethod != NULL, itemMethod != NULL]);
    }
    if (!itemMethod || count <= 0) return 0;

    int appended = 0;
    static BOOL itemTypeLogged[2] = { NO, NO };
    int itemTypeSlot = strcmp(sourceName, "CallMonster") == 0 ? 0 : 1;
    for (int index = 0; index < count && *valid < 50; index++) {
        int32_t indexValue = index;
        void *params[1] = { &indexValue };
        exception = NULL;
        Il2CppObject *item = invokeMethod(itemMethod, list, params, &exception);
        if (!item || exception) continue;
        char className[96] = {0};
        char namespaceName[96] = {0};
        if (!readObjectClassName(item, className, sizeof(className),
                                 namespaceName, sizeof(namespaceName))) continue;
        if (!itemTypeLogged[itemTypeSlot]) {
            itemTypeLogged[itemTypeSlot] = YES;
            runtimeLog([NSString stringWithFormat:
                @"actor supplemental itemType source=%s class=%s ns=%s",
                sourceName, className[0] ? className : "unknown",
                namespaceName[0] ? namespaceName : ""]);
        }
        if (strcmp(className, "ActorLinker") != 0) continue;
        char displayName[128] = {0};
        snprintf(displayName, sizeof(displayName), "%s[%d] %s", sourceName, index, className);
        Il2CppVector3 world = {0, 0, 0};
        if (!readObjectPosition(item, &world) || !isUsableActorWorld(world)) continue;
        cacheActorPositionRef50(item, displayName, namespaceName);
        Il2CppVector3 screen = {-1, -1, -1};
        if (!projectWorldPosition(world, &screen) || !isUsableActorScreen(screen)) continue;
        espAppendEntitySnapshot(world.x, world.y, world.z, screen.x, screen.y, screen.z,
                                displayName, namespaceName);
        (*valid)++;
        appended++;
        if (signature && signatureUsed && *signatureUsed + 48 < signatureCap) {
            int written = snprintf(signature + *signatureUsed, signatureCap - *signatureUsed,
                                   "%s[%d]=%s;", sourceName, index, className);
            if (written > 0) *signatureUsed += (size_t)written;
        }
    }
    return appended;
}

static void probeActorSnapshot50(void *actorClass, Il2CppObject *actorManager) {
    static const char *countNames[] = {
        "GetHeroActorCount", "GetOrganActorCount", "GetSoldierActorCount",
        "GetBuffMonsterCount", "GetDragonActorCount"
    };
    static const char *itemNames[] = {
        "GetHeroActorByIndex", "GetOrganActorByIndex", "GetSoldierActorByIndex",
        "GetBuffMonsterByIndex", "GetDragonActorByIndex"
    };
    static const char *sourceNames[] = { "Hero", "Organ", "Soldier", "BuffMonster", "Dragon" };
    g_actorSnapshot50Valid = 0;
    g_actorPositionRefCount50 = 0;
    memset(g_actorPositionRefs50, 0, sizeof(g_actorPositionRefs50));
    if (!g_singleHeroSuccess || !actorClass || !actorManager) {
        espClearEntitySnapshot();
        return;
    }

    resetProjectionContext();
    if (!prepareProjectionContext()) {
        espClearEntitySnapshot();
        return;
    }
    updateProjectionViewport();
    espBeginEntitySnapshot();
    char signature[512] = {0};
    size_t signatureUsed = 0;
    char geometry[1024] = {0};
    size_t geometryUsed = 0;
    for (NSUInteger source = 0; source < 5 && g_actorSnapshot50Valid < 50; source++) {
        const Il2CppMethodInfo *countMethod = resolveMethod(actorClass, countNames[source], 0);
        const Il2CppMethodInfo *itemMethod = resolveMethod(actorClass, itemNames[source], 1);
        if (!countMethod || !itemMethod) continue;
        BOOL countOK = NO;
        int sourceCount = readBoxedIntResult(countMethod, actorManager, NULL, &countOK);
        if (!countOK || sourceCount <= 0) continue;
        if (sourceCount > 64) sourceCount = 64;
        for (int index = 0; index < sourceCount && g_actorSnapshot50Valid < 50; index++) {
            int32_t indexValue = index;
            void *params[1] = { &indexValue };
            Il2CppException *exception = NULL;
            Il2CppObject *actor = invokeMethod(itemMethod, actorManager, params, &exception);
            if (!actor || exception) continue;

            char className[96] = {0};
            char namespaceName[96] = {0};
            readObjectClassName(actor, className, sizeof(className), namespaceName, sizeof(namespaceName));
            Il2CppVector3 world = {0, 0, 0};
            if (!readObjectPosition(actor, &world) || !isUsableActorWorld(world)) continue;
            Il2CppVector3 screen = {-1, -1, -1};
            BOOL screenOK = projectWorldPosition(world, &screen) && isUsableActorScreen(screen);

            char displayName[96] = {0};
            snprintf(displayName, sizeof(displayName), "%s[%d] %s", sourceNames[source], index,
                     className[0] ? className : "Actor");
            if (g_actorPositionRefCount50 < 64) {
                ActorPositionRef50 *ref = &g_actorPositionRefs50[g_actorPositionRefCount50++];
                ref->object = actor;
                strncpy(ref->displayName, displayName, sizeof(ref->displayName) - 1);
                strncpy(ref->namespaceName, namespaceName, sizeof(ref->namespaceName) - 1);
            }
            if (!screenOK) continue;
            espAppendEntitySnapshot(world.x, world.y, world.z, screen.x,
                                    screen.y, screen.z,
                                    displayName, namespaceName);
            g_actorSnapshot50Valid++;
            if (signatureUsed + 32 < sizeof(signature)) {
                int written = snprintf(signature + signatureUsed, sizeof(signature) - signatureUsed,
                                       "%s[%d]=%s;", sourceNames[source], index,
                                       className[0] ? className : "Actor");
                if (written > 0) signatureUsed += (size_t)written;
            }
            if (g_actorSnapshot50Valid <= 3 && geometryUsed + 220 < sizeof(geometry)) {
                int written = snprintf(geometry + geometryUsed, sizeof(geometry) - geometryUsed,
                                       "%s[%d] world=(%.2f,%.2f,%.2f) unityScreen=(%.1f,%.1f,%.2f);",
                                       sourceNames[source], index, world.x, world.y, world.z,
                                       screen.x, screen.y, screen.z);
                if (written > 0) geometryUsed += (size_t)written;
            }
        }
    }
    int supplementalValid = 0;
    supplementalValid += appendSupplementalActorList(actorClass, actorManager,
                                                      "GetCallMonsterActors", "CallMonster",
                                                      &g_actorSnapshot50Valid, signature,
                                                      sizeof(signature), &signatureUsed);
    supplementalValid += appendSupplementalActorList(actorClass, actorManager,
                                                      "GetCallActors", "CallActor",
                                                      &g_actorSnapshot50Valid, signature,
                                                      sizeof(signature), &signatureUsed);
    if (supplementalValid > 0) {
        runtimeLog([NSString stringWithFormat:
            @"actor supplemental appended=%d total=%d", supplementalValid,
            g_actorSnapshot50Valid]);
    }
    espCommitEntitySnapshot();

    NSString *currentSignature = [NSString stringWithUTF8String:signature] ?: @"";
    if (![currentSignature isEqualToString:g_actorSnapshot50Signature ?: @""]) {
        g_actorSnapshot50Signature = [currentSignature copy];
        runtimeLog([NSString stringWithFormat:
            @"actor snapshot50 drawn=%d composition=%@", g_actorSnapshot50Valid,
            currentSignature.length ? currentSignature : @"empty"]);
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (geometryUsed > 0 && (g_lastActorGeometryLog <= 0.0 || now - g_lastActorGeometryLog >= 10.0)) {
        g_lastActorGeometryLog = now;
        runtimeLog([NSString stringWithFormat:@"actor geometry50 first=%s", geometry]);
    }
}

static void probeEntityManagers(void) {
    if (!initIl2CppAPI() || !p_il2cpp_runtime_invoke) {
        runtimeLog(@"entity manager probe skipped: IL2CPP invoke unavailable");
        return;
    }
    void *domain = p_il2cpp_domain_get();
    size_t count = 0;
    const void **assemblies = domain ? p_il2cpp_domain_get_assemblies(domain, &count) : NULL;
    if (!assemblies || count == 0 || count > 4096) {
        runtimeLog(@"entity manager probe skipped: assemblies unavailable");
        return;
    }
    void *gameCoreImage = NULL;
    for (size_t i = 0; i < count; i++) {
        void *image = assemblies[i] ? p_il2cpp_assembly_get_image(assemblies[i]) : NULL;
        const char *name = image ? p_il2cpp_image_get_name(image) : NULL;
        if (name && strcmp(name, "Scripts.GameCore.dll") == 0) {
            gameCoreImage = image;
            break;
        }
    }
    if (!gameCoreImage) {
        runtimeLog(@"entity manager probe skipped: Scripts.GameCore image not found");
        return;
    }

    struct ManagerProbe { const char *ns; const char *name; const char *getter; } probes[] = {
        { "Assets.Scripts.GameLogic", "ActorManager", "get_instance" },
        { "Assets.Scripts.GameLogic", "GamePlayerCenter", "get_instance" }
    };
    int sampledActorCount = -1;
    int sampledPlayerCount = -1;
    Il2CppObject *actorManagerForChain = NULL;
    void *actorClassForChain = NULL;
    Il2CppObject *playerCenterForSemantics = NULL;
    void *playerCenterClassForSemantics = NULL;
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
        void *klass = p_il2cpp_class_from_name(gameCoreImage, probes[i].ns, probes[i].name);
        const Il2CppMethodInfo *getter = klass ?
            p_il2cpp_class_get_method_from_name(klass, probes[i].getter, 0) : NULL;
        if (!klass || !getter) {
            static BOOL unresolvedLogged[2] = { NO, NO };
            if (!unresolvedLogged[i]) {
                unresolvedLogged[i] = YES;
                runtimeLog([NSString stringWithFormat:@"manager unresolved class=%s method=%s",
                    probes[i].name, probes[i].getter]);
            }
            continue;
        }
        Il2CppException *exception = NULL;
        Il2CppObject *manager = p_il2cpp_runtime_invoke(getter, NULL, NULL, &exception);
        if (!exception && strcmp(probes[i].name, "ActorManager") == 0) {
            actorManagerForChain = manager;
            actorClassForChain = klass;
        } else if (!exception && strcmp(probes[i].name, "GamePlayerCenter") == 0) {
            playerCenterForSemantics = manager;
            playerCenterClassForSemantics = klass;
        }
        if (!manager || exception) continue;

        const char *countMethodName = strcmp(probes[i].name, "ActorManager") == 0 ?
            "GetActorTotalCount" : "GetPlayerNum";
        const Il2CppMethodInfo *countMethod =
            p_il2cpp_class_get_method_from_name(klass, countMethodName, 0);
        if (!countMethod) {
            static BOOL countUnresolvedLogged[2] = { NO, NO };
            if (!countUnresolvedLogged[i]) {
                countUnresolvedLogged[i] = YES;
                runtimeLog([NSString stringWithFormat:@"manager count unresolved class=%s method=%s",
                    probes[i].name, countMethodName]);
            }
            continue;
        }
        exception = NULL;
        Il2CppObject *boxedCount = p_il2cpp_runtime_invoke(countMethod, manager, NULL, &exception);
        if (boxedCount && !exception && p_il2cpp_object_unbox) {
            int32_t *value = (int32_t *)p_il2cpp_object_unbox(boxedCount);
            if (value) {
                if (strcmp(probes[i].name, "ActorManager") == 0)
                    sampledActorCount = *value;
                else
                    sampledPlayerCount = *value;
            }
        }
    }
    logActorCategoryCounts(actorClassForChain, actorManagerForChain);
    probePlayerSemanticCounts(playerCenterClassForSemantics, playerCenterForSemantics,
                              sampledPlayerCount);
    probeSingleHeroActor(gameCoreImage, actorManagerForChain, actorClassForChain);
    probeActorSnapshot50(actorClassForChain, actorManagerForChain);
    espSetRuntimeDiagnostics(sampledActorCount, sampledPlayerCount, g_cameraProbeValid);
    espSetRuntimeEntityCount(g_actorSnapshot50Valid);
    runtimeLog([NSString stringWithFormat:@"entity summary actor=%d player=%d camera=%d heroCount=%d hero0=%d drawn50=%d",
        sampledActorCount, sampledPlayerCount, g_cameraProbeValid ? 1 : 0,
        g_lastHeroCount, g_singleHeroSuccess ? 1 : 0, g_actorSnapshot50Valid]);

    /* Player objects are not dereferenced in the live sampling path yet.
       Keep the count signal and diagnostic overlay active while the object ABI
       is isolated in a separate test build. */
    static const BOOL kEnablePlayerObjectEnumeration = NO;
    if (kEnablePlayerObjectEnumeration) {
        probeEntityObjects(gameCoreImage);
    } else if (!g_singleHeroSuccess) {
        espClearEntitySnapshot();
    }
}

/* 0 means run until the process enters background. */
static const NSTimeInterval kEntitySamplingDuration = 0.0;
static const NSTimeInterval kEntitySamplingInterval = 2.0;
static const NSTimeInterval kEntityPositionRefreshInterval = 1.0 / 30.0;
static int g_entitySample = 0;
static bool g_entitySampling = false;
static bool g_entitySamplingActive = false;
static bool g_entityPositionSampling = false;
static bool g_runtimePaused = false;
static NSTimeInterval g_entitySamplingStartedAt = 0.0;

static void scheduleNextEntityManagerSample(void);
static void scheduleNextEntityPositionRefresh(void);

static NSTimeInterval entitySamplingElapsed(void) {
    if (g_entitySamplingStartedAt <= 0.0) return 0.0;
    return MAX(0.0, [NSDate timeIntervalSinceReferenceDate] - g_entitySamplingStartedAt);
}

static BOOL entitySamplingExpired(void) {
    return kEntitySamplingDuration > 0.0 && entitySamplingElapsed() >= kEntitySamplingDuration;
}

static void finishEntityManagerSampling(NSString *reason) {
    if (!g_entitySamplingActive) return;
    g_entitySamplingActive = false;
    g_entityPositionSampling = false;
    runtimeLog([NSString stringWithFormat:
        @"entity manager sampling finished samples=%d elapsed=%.1fs reason=%@",
        g_entitySample, entitySamplingElapsed(), reason ?: @"unknown"]);
}

static void runEntityPositionRefresh(void) {
    if (!g_entityPositionSampling || g_runtimePaused) return;
    if (g_entitySampling) {
        scheduleNextEntityPositionRefresh();
        return;
    }
    @try {
        refreshActorSnapshotPositions();
    } @catch (NSException *exception) {
        runtimeLog([NSString stringWithFormat:@"position refresh exception=%@",
            exception.reason ?: @"unknown"]);
    }
    scheduleNextEntityPositionRefresh();
}

static void scheduleNextEntityPositionRefresh(void) {
    if (!g_entityPositionSampling || g_runtimePaused) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(kEntityPositionRefreshInterval * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (g_entityPositionSampling && !g_runtimePaused) runEntityPositionRefresh();
        });
}

static void scheduleEntityPositionSampling(void) {
    if (g_runtimePaused || g_entityPositionSampling) return;
    g_entityPositionSampling = true;
    runtimeLog([NSString stringWithFormat:
        @"position sampling started interval=%.3fs", kEntityPositionRefreshInterval]);
    scheduleNextEntityPositionRefresh();
}

static void runEntityManagerSample(void) {
    if (!g_entitySamplingActive || g_entitySampling || g_runtimePaused) return;
    if (entitySamplingExpired()) {
        finishEntityManagerSampling(@"duration");
        return;
    }
    g_entitySampling = true;
    int sample = ++g_entitySample;
    runtimeLog([NSString stringWithFormat:@"entity manager sample=%d elapsed=%.1fs",
        sample, entitySamplingElapsed()]);
    @try {
        probeEntityManagers();
    } @catch (NSException *exception) {
        runtimeLog([NSString stringWithFormat:@"entity manager sample exception=%@",
            exception.reason ?: @"unknown"]);
    }
    g_entitySampling = false;
    if (entitySamplingExpired()) {
        finishEntityManagerSampling(@"duration");
    } else {
        scheduleNextEntityManagerSample();
    }
}

static void scheduleNextEntityManagerSample(void) {
    if (!g_entitySamplingActive) return;
    NSTimeInterval remaining = kEntitySamplingDuration > 0.0
        ? kEntitySamplingDuration - entitySamplingElapsed() : kEntitySamplingInterval;
    if (entitySamplingExpired()) {
        finishEntityManagerSampling(@"duration");
        return;
    }
    NSTimeInterval delay = MIN(kEntitySamplingInterval, remaining);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
            if (g_entitySamplingActive) runEntityManagerSample();
        });
}

static void scheduleEntityManagerSampling(void) {
    if (g_runtimePaused || g_entitySamplingActive) return;
    g_entitySample = 0;
    g_entitySampling = false;
    g_entitySamplingActive = true;
    g_entitySamplingStartedAt = [NSDate timeIntervalSinceReferenceDate];
    runtimeLog([NSString stringWithFormat:
        @"entity manager sampling started duration=%@ interval=%.1fs",
        kEntitySamplingDuration > 0.0 ? [NSString stringWithFormat:@"%.1fs", kEntitySamplingDuration] : @"until-background",
        kEntitySamplingInterval]);
    scheduleEntityPositionSampling();
    scheduleNextEntityManagerSample();
}

static void probeMainCameraGetter(void) {
    g_cameraProbeValid = false;
    if (!initIl2CppAPI()) return;
    if (!p_il2cpp_runtime_invoke) {
        runtimeLog(@"camera getter probe skipped: il2cpp_runtime_invoke unavailable");
        return;
    }
    void *domain = p_il2cpp_domain_get();
    size_t count = 0;
    const void **assemblies = domain ? p_il2cpp_domain_get_assemblies(domain, &count) : NULL;
    if (!assemblies || count > 4096) {
        runtimeLog(@"camera getter probe skipped: assemblies unavailable");
        return;
    }
    for (size_t i = 0; i < count; i++) {
        void *image = assemblies[i] ? p_il2cpp_assembly_get_image(assemblies[i]) : NULL;
        const char *imageName = image ? p_il2cpp_image_get_name(image) : NULL;
        if (!imageName || strcmp(imageName, "UnityEngine.CoreModule.dll") != 0) continue;
        void *klass = p_il2cpp_class_from_name(image, "UnityEngine", "Camera");
        const Il2CppMethodInfo *method = klass ? p_il2cpp_class_get_method_from_name(klass, "get_main", 0) : NULL;
        if (!method) {
            runtimeLog(@"camera getter probe skipped: MethodInfo unresolved");
            return;
        }
        Il2CppException *exception = NULL;
        Il2CppObject *camera = p_il2cpp_runtime_invoke(method, NULL, NULL, &exception);
        runtimeLog([NSString stringWithFormat:@"camera getter result camera=0x%lx exception=0x%lx",
            (uintptr_t)camera, (uintptr_t)exception]);
        if (!camera || exception) return;

        const Il2CppMethodInfo *getTransform =
            p_il2cpp_class_get_method_from_name(klass, "get_transform", 0);
        if (!getTransform) {
            runtimeLog(@"camera transform probe skipped: MethodInfo unresolved");
            return;
        }
        exception = NULL;
        Il2CppObject *transform = p_il2cpp_runtime_invoke(getTransform, camera, NULL, &exception);
        runtimeLog([NSString stringWithFormat:@"camera transform result transform=0x%lx exception=0x%lx",
            (uintptr_t)transform, (uintptr_t)exception]);
        if (!transform || exception) return;

        void *transformImage = NULL;
        for (size_t j = 0; j < count; j++) {
            void *candidateImage = assemblies[j] ? p_il2cpp_assembly_get_image(assemblies[j]) : NULL;
            const char *candidateName = candidateImage ? p_il2cpp_image_get_name(candidateImage) : NULL;
            if (candidateName && strcmp(candidateName, "UnityEngine.CoreModule.dll") == 0) {
                transformImage = candidateImage;
                break;
            }
        }
        void *transformClass = transformImage ?
            p_il2cpp_class_from_name(transformImage, "UnityEngine", "Transform") : NULL;
        const Il2CppMethodInfo *getPosition = transformClass ?
            p_il2cpp_class_get_method_from_name(transformClass, "get_position", 0) : NULL;
        if (!getPosition) {
            runtimeLog(@"transform position probe skipped: MethodInfo unresolved");
            return;
        }
        exception = NULL;
        Il2CppObject *boxedPosition = p_il2cpp_runtime_invoke(getPosition, transform, NULL, &exception);
        runtimeLog([NSString stringWithFormat:@"transform position result boxed=0x%lx exception=0x%lx",
            (uintptr_t)boxedPosition, (uintptr_t)exception]);
        if (boxedPosition && !exception && p_il2cpp_object_unbox) {
            Il2CppVector3 *position = (Il2CppVector3 *)p_il2cpp_object_unbox(boxedPosition);
            if (position) {
                g_cameraProbeValid = isfinite(position->x) &&
                    isfinite(position->y) && isfinite(position->z);
                runtimeLog([NSString stringWithFormat:@"transform position value x=%.5f y=%.5f z=%.5f",
                    position->x, position->y, position->z]);
            } else {
                runtimeLog(@"transform position unbox returned null");
            }
        } else if (boxedPosition && !exception) {
            runtimeLog(@"transform position value returned boxed Vector3; object_unbox unavailable");
        }
        return;
    }
    runtimeLog(@"camera getter probe skipped: Camera class not found");
}

static void enumerateIl2CppAssemblies(void) {
    if (!initIl2CppAPI()) return;
    void *domain = p_il2cpp_domain_get();
    if (!domain) {
        runtimeLog(@"il2cpp domain is null");
        return;
    }
    size_t count = 0;
    const void **assemblies = p_il2cpp_domain_get_assemblies(domain, &count);
    runtimeLog([NSString stringWithFormat:@"il2cpp assemblies count=%lu", (unsigned long)count]);
    if (!assemblies || count == 0 || count > 4096) {
        runtimeLog(@"il2cpp assemblies unavailable or count out of range");
        return;
    }
    for (size_t i = 0; i < count; i++) {
        const void *assembly = assemblies[i];
        void *image = assembly ? p_il2cpp_assembly_get_image(assembly) : NULL;
        const char *name = image ? p_il2cpp_image_get_name(image) : NULL;
        const char *filename = (image && p_il2cpp_image_get_filename) ? p_il2cpp_image_get_filename(image) : NULL;
        if (name && name[0]) {
            runtimeLog([NSString stringWithFormat:@"il2cpp image[%lu] name=%s file=%s",
                (unsigned long)i, name, filename ? filename : ""]);
        }
    }
}

static const Il2CppMethodInfo* resolveIl2CppMethod(const char* ns, const char* klassName, const char* methodName, int args) {
    if (!initIl2CppAPI()) return NULL;

    void* klass = p_il2cpp_class_from_name(NULL, ns, klassName);
    if (!klass) {
        NSLog(@"[GameHack] class not found: %s.%s", ns, klassName);
        runtimeLog([NSString stringWithFormat:@"class unresolved %s.%s", ns, klassName]);
        return NULL;
    }

    const Il2CppMethodInfo* method = p_il2cpp_class_get_method_from_name(klass, methodName, args);
    if (!method) {
        NSLog(@"[GameHack] method not found: %s.%s$$%s", ns, klassName, methodName);
        runtimeLog([NSString stringWithFormat:@"method unresolved %s.%s::%s args=%d", ns, klassName, methodName, args]);
        return NULL;
    }

    NSLog(@"[GameHack] resolved %s.%s$$%s MethodInfo @ 0x%lx",
          ns, klassName, methodName, (uintptr_t)method);
    runtimeLog([NSString stringWithFormat:@"method resolved %s.%s::%s MethodInfo=0x%lx",
        ns, klassName, methodName, (uintptr_t)method]);
    return method;
}

static void scheduleEntityManagerSampling(void);

static void installRuntimeLifecycleObservers(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
        g_runtimePaused = true;
        g_entitySamplingActive = false;
        g_entityPositionSampling = false;
        espSetPaused(true);
        espClearEntitySnapshot();
        runtimeLog(@"runtime paused reason=did-enter-background");
    }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
        g_runtimePaused = false;
        espSetPaused(false);
        runtimeLog(@"runtime resumed reason=will-enter-foreground");
        scheduleEntityManagerSampling();
    }];
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
        runtimeLog([NSString stringWithFormat:@"UnityFramework base=0x%lx", unityBase]);
        installRuntimeLifecycleObservers();
        logCompactRuntimeBootstrap();
        probeMainCameraGetter();
        scheduleEntityManagerSampling();
        // Hooks installed on-demand by button press (not at startup)
        showHUD();
    });
}

// ESP + MapHack - safe memory approach, no IL2CPP calls, no MSHookFunction
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <os/log.h>
#import <sys/stat.h>
#import <unistd.h>
#include <math.h>
#include <string.h>
#include <os/lock.h>

typedef struct { float m[16]; } M4x4;
typedef struct { float x, y, z; } Vec3;

bool g_espEnabled = false;
bool g_espDebugMode = false;
M4x4 g_viewMat, g_projMat;
bool g_matValid = false;
bool g_screenValid = false;
UIWindow *g_espWin = nil;
static os_log_t g_espLog;
static uint64_t g_espTicks = 0;
static int g_runtimeEntityCount = 0;
static uint64_t g_lastDiagnosticMs = 0;

typedef struct {
    int actorCount;
    int playerCount;
    bool cameraValid;
} EspRuntimeDiagnostics;
static EspRuntimeDiagnostics g_runtimeDiagnostics = {-1, -1, false};
static os_unfair_lock g_runtimeDiagnosticsLock = OS_UNFAIR_LOCK_INIT;

typedef struct {
    int liveCount;
    int displayCount;
    int staleCount;
    int screenCount;
    int buffCount;
    uint64_t sample;
} EspSourceDiagnostics;
static EspSourceDiagnostics g_sourceDiagnostics = {0, 0, 0, 0, 0, 0};

typedef struct {
    Vec3 pos;
    Vec3 screen;
    float hp, maxHp;
    int team;
    bool ok;
    bool screenValid;
    char className[96];
    char namespaceName[96];
} EEnt;
static const int kMaxESPEntries = 512;
EEnt g_ents[kMaxESPEntries];
int g_entCnt=0;
static EEnt g_pendingEnts[kMaxESPEntries];
static int g_pendingEntCnt = 0;
static os_unfair_lock g_entLock = OS_UNFAIR_LOCK_INIT;
static float g_unityViewportWidth = 0.0f;
static float g_unityViewportHeight = 0.0f;
static os_unfair_lock g_viewportLock = OS_UNFAIR_LOCK_INIT;

extern uintptr_t unityBase;
extern bool g_mapHackEnabled;
extern bool g_mapHackInstalled;

void espSetUnityViewport(float width, float height) {
    if (!isfinite(width) || !isfinite(height) || width <= 0.0f || height <= 0.0f ||
        width > 20000.0f || height > 20000.0f) return;
    os_unfair_lock_lock(&g_viewportLock);
    g_unityViewportWidth = width;
    g_unityViewportHeight = height;
    os_unfair_lock_unlock(&g_viewportLock);
}

void espSetRuntimeDiagnostics(int actorCount, int playerCount, bool cameraValid) {
    os_unfair_lock_lock(&g_runtimeDiagnosticsLock);
    g_runtimeDiagnostics.actorCount = actorCount;
    g_runtimeDiagnostics.playerCount = playerCount;
    g_runtimeDiagnostics.cameraValid = cameraValid;
    os_unfair_lock_unlock(&g_runtimeDiagnosticsLock);
}

void espSetRuntimeEntityCount(int count) {
    os_unfair_lock_lock(&g_runtimeDiagnosticsLock);
    g_runtimeEntityCount = MAX(0, MIN(count, kMaxESPEntries));
    os_unfair_lock_unlock(&g_runtimeDiagnosticsLock);
}

void espSetSourceDiagnostics(int liveCount, int displayCount, int staleCount,
                             int screenCount, int buffCount, uint64_t sample) {
    os_unfair_lock_lock(&g_runtimeDiagnosticsLock);
    g_sourceDiagnostics.liveCount = MAX(0, liveCount);
    g_sourceDiagnostics.displayCount = MAX(0, displayCount);
    g_sourceDiagnostics.staleCount = MAX(0, staleCount);
    g_sourceDiagnostics.screenCount = MAX(0, screenCount);
    g_sourceDiagnostics.buffCount = MAX(0, buffCount);
    g_sourceDiagnostics.sample = sample;
    os_unfair_lock_unlock(&g_runtimeDiagnosticsLock);
}

static void espLog(NSString *message) {
    if (!g_espLog) g_espLog = os_log_create("gamehack", "esp");
    os_log(g_espLog, "%{public}@", message ?: @"");
}

static NSArray<NSString *> *espLogPaths(void) {
    NSArray *documentsPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsCandidate = (NSString *)[documentsPaths firstObject];
    NSString *documents = [documentsCandidate length] ? documentsCandidate : NSTemporaryDirectory();
    NSString *documentsDir = [documents stringByAppendingPathComponent:@"gamehack_logs"];
    NSString *compatDir = @"/var/mobile/Library/Logs/gamehack";
    return @[[documentsDir stringByAppendingPathComponent:@"esp.log"],
             [compatDir stringByAppendingPathComponent:@"esp.log"]];
}

static BOOL appendESPLogToPath(NSData *data, NSString *path, NSError **outError) {
    NSString *dir = [path stringByDeletingLastPathComponent];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
        if (outError) *outError = error;
        return NO;
    }
    if (![fm fileExistsAtPath:path]) {
        if (![fm createFileAtPath:path contents:data attributes:nil]) {
            if (outError) *outError = [NSError errorWithDomain:@"gamehack.esp.log" code:1 userInfo:@{NSLocalizedDescriptionKey: @"createFileAtPath failed"}];
            return NO;
        }
        return YES;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        if (outError) *outError = [NSError errorWithDomain:@"gamehack.esp.log" code:2 userInfo:@{NSLocalizedDescriptionKey: @"fileHandleForWritingAtPath returned nil"}];
        return NO;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } @catch (NSException *exception) {
        [handle closeFile];
        if (outError) *outError = [NSError errorWithDomain:@"gamehack.esp.log" code:3 userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: @"write exception"}];
        return NO;
    }
    return YES;
}

static void appendESPLog(NSString *message) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSArray<NSString *> *paths = espLogPaths();
    BOOL wroteAny = NO;
    for (NSUInteger i = 0; i < paths.count; i++) {
        NSError *error = nil;
        if (appendESPLogToPath(data, paths[i], &error)) {
            wroteAny = YES;
        } else {
            NSLog(@"[GameHack] ESP log write failed (%@): %@", i == 0 ? @"Documents" : @"compat", error.localizedDescription ?: @"unknown");
        }
    }
    if (!wroteAny) NSLog(@"[GameHack] ESP log unavailable; attempted paths: %@", paths);
    espLog(message);
}

static void logESPState(NSString *reason) {
    appendESPLog([NSString stringWithFormat:@"state reason=%@ enabled=%d matValid=%d entityCount=%d unityBase=0x%lx mapHack=%d",
        reason ?: @"unknown", g_espEnabled, g_matValid, g_entCnt, unityBase, g_mapHackInstalled]);
}

/* Runtime probe bridge. Tweak.xm commits only validated objects and screen points. */
void espBeginEntitySnapshot(void) {
    os_unfair_lock_lock(&g_entLock);
    g_pendingEntCnt = 0;
    memset(g_pendingEnts, 0, sizeof(g_pendingEnts));
}

void espAppendEntitySnapshot(float x, float y, float z,
                             float sx, float sy, float sz,
                             const char *className, const char *namespaceName) {
    if (g_pendingEntCnt >= kMaxESPEntries) return;
    EEnt *e = &g_pendingEnts[g_pendingEntCnt++];
    e->pos = Vec3{x, y, z};
    e->screen = Vec3{sx, sy, sz};
    /* Negative/out-of-viewport coordinates are valid WorldToScreenPoint
       results for off-screen actors.  Keep them for edge rendering. */
    e->screenValid = isfinite(sx) && isfinite(sy) && isfinite(sz);
    e->ok = e->screenValid;
    e->team = 0;
    e->hp = 0.0f;
    e->maxHp = 0.0f;
    if (className) strncpy(e->className, className, sizeof(e->className) - 1);
    if (namespaceName) strncpy(e->namespaceName, namespaceName, sizeof(e->namespaceName) - 1);
}

void espCommitEntitySnapshot(void) {
    memcpy(g_ents, g_pendingEnts, sizeof(g_ents));
    g_entCnt = g_pendingEntCnt;
    g_screenValid = g_entCnt > 0;
    os_unfair_lock_unlock(&g_entLock);
}

void espClearEntitySnapshot(void) {
    os_unfair_lock_lock(&g_entLock);
    memset(g_ents, 0, sizeof(g_ents));
    g_entCnt = 0;
    g_screenValid = false;
    os_unfair_lock_unlock(&g_entLock);
}

Vec3 W2S(Vec3 w, M4x4 v, M4x4 p, float sw, float sh) {
    float *vm=v.m,*pm=p.m;
    float vx=vm[0]*w.x+vm[4]*w.y+vm[8]*w.z+vm[12];
    float vy=vm[1]*w.x+vm[5]*w.y+vm[9]*w.z+vm[13];
    float vz=vm[2]*w.x+vm[6]*w.y+vm[10]*w.z+vm[14];
    float vw=vm[3]*w.x+vm[7]*w.y+vm[11]*w.z+vm[15];
    float cx=pm[0]*vx+pm[4]*vy+pm[8]*vz+pm[12]*vw;
    float cy=pm[1]*vx+pm[5]*vy+pm[9]*vz+pm[13]*vw;
    float cz=pm[2]*vx+pm[6]*vy+pm[10]*vz+pm[14]*vw;
    float cw=pm[3]*vx+pm[7]*vy+pm[11]*vz+pm[15]*vw;
    Vec3 r={-1,-1,0};
    if(cw<=0.001f)return r;
    r.x=(cx/cw+1.f)*0.5f*sw;
    r.y=(1.f-cy/cw)*0.5f*sh;
    r.z=cz/cw;
    return r;
}

void updateESPMatrices(void) {
    /* Screen-space points are supplied by Camera.WorldToScreenPoint. */
}

void updateESPEntities(void) {
    /* Entity snapshots are supplied by Tweak.xm through the bridge above. */
}

static uintptr_t getStaticFields(void) {
    if(!unityBase)return 0;
    uintptr_t slot=unityBase+0x1355AC68;
    uintptr_t klass=*(uintptr_t*)slot;
    if(!klass||klass<0x1000)return 0;
    return *(uintptr_t*)(klass+0xB8);
}

void installMapHack(void) {
    uintptr_t sf=getStaticFields();
    if(!sf){NSLog(@"[GameHack] MapHack: static fields not found"); appendESPLog(@"map probe failed: static fields not found"); return;}
    *(uint32_t*)(sf+0x128)=0;
    *(uint32_t*)(sf+0x130)=0;
    *(uint32_t*)(sf+0x138)=0;
    *(uint32_t*)(sf+0x140)=0;
    g_mapHackInstalled=true;
    g_mapHackEnabled=true;
    NSLog(@"[GameHack] MapHack: fog params zeroed");
    appendESPLog(@"map state changed: fog parameter writes completed");
}

void enableMapHack(void) {
    g_mapHackEnabled=true;
}

void disableMapHack(void) {
    g_mapHackEnabled=false;
}

@interface EspView : UIView
@property CADisplayLink *dl;
@end
static EspView *g_espView = nil;
@implementation EspView
- (id)initWithFrame:(CGRect)f {
    self=[super initWithFrame:f];
    self.backgroundColor=[UIColor clearColor];
    self.opaque=NO;self.userInteractionEnabled=NO;
    _dl=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return self;
}
- (void)tick{
    g_espTicks++;
    if ((g_espTicks % 30) == 0) {
        updateESPMatrices();
        updateESPEntities();
    }
    [self setNeedsDisplay];
}
- (void)drawRect:(CGRect)r{
    if(!g_espEnabled)return;
    CGContextRef c=UIGraphicsGetCurrentContext();
    float sw=self.bounds.size.width,sh=self.bounds.size.height;
    EspRuntimeDiagnostics diagnostics;
    EspSourceDiagnostics sources;
    int runtimeEntityCount = 0;
    os_unfair_lock_lock(&g_runtimeDiagnosticsLock);
    diagnostics = g_runtimeDiagnostics;
    sources = g_sourceDiagnostics;
    runtimeEntityCount = g_runtimeEntityCount;
    os_unfair_lock_unlock(&g_runtimeDiagnosticsLock);

    /* Stable diagnostic layer: it uses only validated counters and the
       overlay viewport, so it remains available while entity probing is off. */
    CGRect panel = CGRectMake(12.0f, 28.0f, MIN(sw - 24.0f, 360.0f), 48.0f);
    CGContextSetFillColorWithColor(c, [UIColor colorWithWhite:0.0 alpha:0.62].CGColor);
    CGContextFillRect(c, panel);
    NSString *actorText = diagnostics.actorCount >= 0
        ? [NSString stringWithFormat:@"%d", diagnostics.actorCount] : @"-";
    NSString *playerText = diagnostics.playerCount >= 0
        ? [NSString stringWithFormat:@"%d", diagnostics.playerCount] : @"-";
    NSString *diagText = [NSString stringWithFormat:@"DIAG A:%@ Pslot:%@ E:%d CAM:%@",
        actorText, playerText, runtimeEntityCount, diagnostics.cameraValid ? @"OK" : @"WAIT"];
    NSString *sourceText = [NSString stringWithFormat:@"S%llu LIVE:%d DISP:%d STALE:%d SCR:%d BUF:%d",
        (unsigned long long)sources.sample, sources.liveCount, sources.displayCount,
        sources.staleCount, sources.screenCount, sources.buffCount];
    NSDictionary *diagAttrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold],
                                 NSForegroundColorAttributeName: UIColor.whiteColor };
    [diagText drawAtPoint:CGPointMake(panel.origin.x + 8.0f, panel.origin.y + 8.0f)
            withAttributes:diagAttrs];
    [sourceText drawAtPoint:CGPointMake(panel.origin.x + 8.0f, panel.origin.y + 25.0f)
              withAttributes:diagAttrs];

    /* Center marker confirms that the transparent overlay itself is visible. */
    CGFloat cx = sw * 0.5f, cy = sh * 0.5f;
    CGContextSetStrokeColorWithColor(c, [UIColor colorWithRed:0.35 green:0.95 blue:0.65 alpha:0.9].CGColor);
    CGContextSetLineWidth(c, 1.0f);
    CGContextMoveToPoint(c, cx - 8.0f, cy);
    CGContextAddLineToPoint(c, cx + 8.0f, cy);
    CGContextMoveToPoint(c, cx, cy - 8.0f);
    CGContextAddLineToPoint(c, cx, cy + 8.0f);
    CGContextStrokePath(c);

    EEnt local[kMaxESPEntries]; int localCount = 0;
    os_unfair_lock_lock(&g_entLock);
    localCount = g_entCnt;
    if (localCount > kMaxESPEntries) localCount = kMaxESPEntries;
    memcpy(local, g_ents, sizeof(EEnt) * localCount);
    os_unfair_lock_unlock(&g_entLock);
    float unityWidth = 0.0f;
    float unityHeight = 0.0f;
    os_unfair_lock_lock(&g_viewportLock);
    unityWidth = g_unityViewportWidth;
    unityHeight = g_unityViewportHeight;
    os_unfair_lock_unlock(&g_viewportLock);
    for(int i=0;i<localCount;i++){
        EEnt*e=&local[i];if(!e->ok)continue;
        Vec3 sp=e->screenValid ? e->screen : W2S(e->pos,g_viewMat,g_projMat,sw,sh);
        if (e->screenValid) {
            /* Camera.WorldToScreenPoint uses a bottom-left origin and usually
               reports pixel coordinates. UIKit uses top-left points. */
            if (unityWidth > 0.0f && unityHeight > 0.0f) {
                sp.x = sp.x * sw / unityWidth;
                sp.y = sh - sp.y * sh / unityHeight;
            } else {
                sp.y = sh - sp.y;
            }
        }
        BOOL behind = e->screen.z <= 0.0f;
        if (behind) {
            /* Unity returns a mirrored projection for points behind the
               camera.  Flip around the viewport center before clamping. */
            sp.x = sw - sp.x;
            sp.y = sh - sp.y;
        }
        BOOL offscreen = sp.x < 0.0f || sp.y < 0.0f || sp.x > sw || sp.y > sh;
        if (offscreen) {
            CGFloat margin = 16.0f;
            CGFloat dx = sp.x - sw * 0.5f;
            CGFloat dy = sp.y - sh * 0.5f;
            CGFloat scaleX = fabs(dx) > 0.001f ? (sw * 0.5f - margin) / fabs(dx) : 100000.0f;
            CGFloat scaleY = fabs(dy) > 0.001f ? (sh * 0.5f - margin) / fabs(dy) : 100000.0f;
            CGFloat scale = MIN(1.0f, MIN(scaleX, scaleY));
            sp.x = sw * 0.5f + dx * scale;
            sp.y = sh * 0.5f + dy * scale;
            CGContextSetStrokeColorWithColor(c, [UIColor colorWithRed:1.0 green:0.75 blue:0.15 alpha:0.9].CGColor);
            CGContextSetLineWidth(c, 1.0f);
            CGContextMoveToPoint(c, sw * 0.5f, sh * 0.5f);
            CGContextAddLineToPoint(c, sp.x, sp.y);
            CGContextStrokePath(c);
        }
        float cr=10;
        UIColor*cl=e->team!=1?UIColor.redColor:UIColor.greenColor;
        CGContextSetStrokeColorWithColor(c,cl.CGColor);
        CGContextSetLineWidth(c,1.5);
        CGContextStrokeEllipseInRect(c,CGRectMake(sp.x-cr,sp.y-cr,cr*2,cr*2));
        float bw=28,bh=4,hf=e->maxHp>0?e->hp/e->maxHp:0;
        CGContextSetFillColorWithColor(c,[UIColor colorWithWhite:0 alpha:0.55].CGColor);
        CGContextFillRect(c,CGRectMake(sp.x-bw/2,sp.y-cr-10,bw,bh));
        UIColor*hc=hf>0.5?UIColor.greenColor:(hf>0.25?UIColor.yellowColor:UIColor.redColor);
        CGContextSetFillColorWithColor(c,hc.CGColor);
        CGContextFillRect(c,CGRectMake(sp.x-bw/2,sp.y-cr-10,bw*hf,bh));
        NSString *label = [NSString stringWithUTF8String:e->className];
        if (label.length == 0) label = @"Object";
        if (offscreen) label = [NSString stringWithFormat:@"[EDGE] %@", label];
        NSString *ns = [NSString stringWithUTF8String:e->namespaceName];
        if (ns.length > 0 && ![label hasPrefix:[ns stringByAppendingString:@"."]])
            label = [NSString stringWithFormat:@"%@.%@", ns, label];
        NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightMedium],
                                 NSForegroundColorAttributeName: UIColor.whiteColor };
        [label drawAtPoint:CGPointMake(sp.x + cr + 3, sp.y - 7) withAttributes:attrs];
    }
}
@end

void showESPOverlay(void){
    if(g_espWin)return;
    CGRect s=UIScreen.mainScreen.bounds;
    g_espWin=[[UIWindow alloc]initWithFrame:s];
    g_espWin.windowLevel=UIWindowLevelAlert;
    g_espWin.backgroundColor=[UIColor clearColor]; g_espWin.opaque=NO; g_espWin.userInteractionEnabled=NO;
    g_espWin.rootViewController=[UIViewController new]; g_espWin.rootViewController.view.backgroundColor=[UIColor clearColor];
    EspView*ev=[[EspView alloc]initWithFrame:s]; g_espView = ev; [g_espWin.rootViewController.view addSubview:ev]; g_espWin.hidden=NO;
    appendESPLog(@"overlay enabled");
}
void hideESPOverlay(void){if(g_espWin){g_espWin.hidden=YES;g_espWin=nil;g_espView=nil;espClearEntitySnapshot();appendESPLog(@"overlay disabled");}}
void espSetPaused(bool paused) {
    if (g_espView) g_espView.dl.paused = paused;
}

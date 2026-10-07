// ESP + MapHack - safe memory approach, no IL2CPP calls, no MSHookFunction
#import <UIKit/UIKit.h>
#import <substrate.h>

typedef struct { float m[16]; } M4x4;
typedef struct { float x, y, z; } Vec3;

bool g_espEnabled = false;
M4x4 g_viewMat, g_projMat;
bool g_matValid = false;
UIWindow *g_espWin = nil;
bool g_mapHackEnabled = false;

extern uintptr_t unityBase;

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

typedef struct { Vec3 pos; float hp,maxHp; int team; bool ok; } EEnt;
EEnt g_ents[64];
int g_entCnt=0;

void updateESPMatrices(void) {
    g_matValid=false;
}

void updateESPEntities(void) {
    g_entCnt=0;
}

static uintptr_t getStaticFields(void) {
    if(!unityBase)return 0;
    uintptr_t slot=unityBase+0x1355AC68;
    uintptr_t klass=*(uintptr_t*)slot;
    if(!klass||klass<0x1000)return 0;
    return *(uintptr_t*)(klass+0xB8);
}

void enableMapHack(void) {
    uintptr_t sf=getStaticFields();
    if(!sf){NSLog(@"[GameHack] MapHack: static fields not found");return;}
    *(uint32_t*)(sf+0x128)=0;
    *(uint32_t*)(sf+0x130)=0;
    *(uint32_t*)(sf+0x138)=0;
    *(uint32_t*)(sf+0x140)=0;
    g_mapHackEnabled=true;
    NSLog(@"[GameHack] MapHack: fog params zeroed");
}

void disableMapHack(void) {
    g_mapHackEnabled=false;
}

@interface EspView : UIView
@property CADisplayLink *dl;
@end
@implementation EspView
- (id)initWithFrame:(CGRect)f {
    self=[super initWithFrame:f];
    self.backgroundColor=[UIColor clearColor];
    self.opaque=NO;self.userInteractionEnabled=NO;
    _dl=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    [_dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    return self;
}
- (void)tick{[self setNeedsDisplay];}
- (void)drawRect:(CGRect)r{
    if(!g_espEnabled||!g_matValid)return;
    CGContextRef c=UIGraphicsGetCurrentContext();
    float sw=self.bounds.size.width,sh=self.bounds.size.height;
    for(int i=0;i<g_entCnt;i++){
        EEnt*e=&g_ents[i];if(!e->ok)continue;
        Vec3 sp=W2S(e->pos,g_viewMat,g_projMat,sw,sh);
        if(sp.x<0||sp.y<0||sp.x>sw||sp.y>sh)continue;
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
    }
}
@end

void showESPOverlay(void){if(g_espWin)return;CGRect s=UIScreen.mainScreen.bounds;g_espWin=[[UIWindow alloc]initWithFrame:s];g_espWin.windowLevel=UIWindowLevelAlert;g_espWin.backgroundColor=[UIColor clearColor];g_espWin.opaque=NO;g_espWin.userInteractionEnabled=NO;g_espWin.rootViewController=[UIViewController new];g_espWin.rootViewController.view.backgroundColor=[UIColor clearColor];EspView*ev=[[EspView alloc]initWithFrame:s];[g_espWin.rootViewController.view addSubview:ev];g_espWin.hidden=NO;}
void hideESPOverlay(void){if(g_espWin){g_espWin.hidden=YES;g_espWin=nil;}}

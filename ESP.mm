// ESP + MapHack for Honor of Kings - IL2CPP dynamic resolution
#import <UIKit/UIKit.h>
#import <substrate.h>
#import <dlfcn.h>

typedef struct { float m[16]; } M4x4;
typedef struct { float x, y, z; } Vec3;
typedef void* (*icfn_t)(void*, const char*, const char*);
typedef struct { void* mp; char _pad[48]; } Il2CppMethod;
typedef Il2CppMethod* (*icgmfn_t)(void*, const char*, int);

bool g_espEnabled = false;
M4x4 g_viewMat, g_projMat;
bool g_matValid = false;
UIWindow *g_espWin = nil;
bool g_mapHackInstalled = false;

extern uintptr_t unityBase;
extern icfn_t p_il2cpp_class_from_name;
extern icgmfn_t p_il2cpp_class_get_method_from_name;
extern bool initIl2CppAPI(void);

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
    if(!initIl2CppAPI()||!unityBase)return;
    void* cc=p_il2cpp_class_from_name(NULL,"UnityEngine","Camera");
    if(!cc)return;
    Il2CppMethod* gm=p_il2cpp_class_get_method_from_name(cc,"get_main",0);
    if(!gm||!gm->mp)return;
    typedef void*(*gmf)(void);
    void* cam=((gmf)gm->mp)();
    if(!cam)return;
    Il2CppMethod* gv=p_il2cpp_class_get_method_from_name(cc,"get_worldToCameraMatrix",0);
    if(gv&&gv->mp){typedef void(*gvf)(void*,M4x4*);((gvf)gv->mp)(cam,&g_viewMat);}
    Il2CppMethod* gp=p_il2cpp_class_get_method_from_name(cc,"get_projectionMatrix",0);
    if(gp&&gp->mp){typedef void(*gpf)(void*,M4x4*);((gpf)gp->mp)(cam,&g_projMat);}
    g_matValid=true;
}

typedef struct { Vec3 pos; float hp,maxHp; int team,cfgId; bool ok; } EEnt;
EEnt g_ents[64];
int g_entCnt=0;

static void* readPtr(void* obj, int off) {
    if(!obj)return 0;
    return *(void**)((uintptr_t)obj+off);
}
static int32_t readI32(void* obj, int off) {
    if(!obj)return 0;
    return *(int32_t*)((uintptr_t)obj+off);
}

void updateESPEntities(void) {
    g_entCnt=0;
    if(!initIl2CppAPI()||!unityBase)return;
    void* amClass=p_il2cpp_class_from_name(NULL,"Assets.Scripts.GameLogic","ActorManager");
    if(!amClass)return;
    void* sf=*(void**)((uintptr_t)amClass+0xB8);
    if(!sf)return;
    void* amInst=*(void**)((uintptr_t)sf+0x0);
    if(!amInst||(uintptr_t)amInst<0x1000)return;
    Il2CppMethod* gal=p_il2cpp_class_get_method_from_name(amClass,"get_ActorList",0);
    if(!gal||!gal->mp)return;
    typedef void*(*galf)(void*);
    void* actorList=((galf)gal->mp)(amInst);
    if(!actorList)return;
    void* items=*(void**)((uintptr_t)actorList+0x10);
    int count=*(int32_t*)((uintptr_t)actorList+0x18);
    if(!items||count<=0||count>200)return;
    int n=count<64?count:64;
    static void* alClass=0;
    static Il2CppMethod* gPos=0,*gCamp=0,*gCfg=0;
    if(!alClass){alClass=p_il2cpp_class_from_name(NULL,"Assets.Scripts.GameLogic","ActorLinker");
        if(alClass){gPos=p_il2cpp_class_get_method_from_name(alClass,"get_Position",0);
            gCamp=p_il2cpp_class_get_method_from_name(alClass,"get_objCamp",0);
            gCfg=p_il2cpp_class_get_method_from_name(alClass,"get_ConfigId",0);}}
    if(!gPos||!gCamp||!gCfg)return;
    for(int i=0;i<n;i++){void* actor=((void**)items)[i];
        if(!actor||(uintptr_t)actor<0x1000)continue;
        Vec3 pos={0,0,0};if(gPos->mp){typedef void(*gpf)(void*,Vec3*);((gpf)gPos->mp)(actor,&pos);}
        int team=0;if(gCamp->mp){typedef int(*gcf)(void*);team=((gcf)gCamp->mp)(actor);}
        int cfg=0;if(gCfg->mp){typedef int(*gcf)(void*);cfg=((gcf)gCfg->mp)(actor);}
        void* vc=readPtr(actor,0x3B8);int hp=readI32(vc,0x38);int maxHp=readI32(vc,0x3C);
        EEnt* e=&g_ents[g_entCnt++];
        e->pos=pos;e->hp=(float)hp;e->maxHp=(float)maxHp;e->team=team;e->cfgId=cfg;e->ok=true;
    }
}

void installMapHack(void) {
    if(!initIl2CppAPI()||!unityBase||g_mapHackInstalled)return;
    static bool (*orig_bv[3])(void*);
    static bool hook_bv(void* self) { return true; }
    const char* names[3]={"SpawnActorData","ActorPrepareData","FowVisibleResult"};
    int hooked=0;
    for(int i=0;i<3;i++){void* cls=p_il2cpp_class_from_name(NULL,"",names[i]);
        if(!cls)continue;Il2CppMethod* m=p_il2cpp_class_get_method_from_name(cls,"get_bVisible",0);
        if(!m||!m->mp)continue;MSHookFunction(m->mp,(void*)hook_bv,(void**)&orig_bv[i]);
        hooked++;NSLog(@"[GameHack] MapHack hooked %s.get_bVisible",names[i]);}
    if(hooked>0){g_mapHackInstalled=true;NSLog(@"[GameHack] MapHack: %d/3 installed",hooked);}
    else NSLog(@"[GameHack] MapHack: no targets resolved");
}

@interface EspView : UIView
@property CADisplayLink *dl;
@end
@implementation EspView
- (id)initWithFrame:(CGRect)f {self=[super initWithFrame:f];self.backgroundColor=[UIColor clearColor];self.opaque=NO;self.userInteractionEnabled=NO;_dl=[CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];[_dl addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];return self;}
- (void)tick {[self setNeedsDisplay];}
- (void)drawRect:(CGRect)r {if(!g_espEnabled||!g_matValid)return;CGContextRef c=UIGraphicsGetCurrentContext();float sw=self.bounds.size.width,sh=self.bounds.size.height;
    for(int i=0;i<g_entCnt;i++){EEnt*e=&g_ents[i];if(!e->ok)continue;Vec3 sp=W2S(e->pos,g_viewMat,g_projMat,sw,sh);
        if(sp.x<0||sp.y<0||sp.x>sw||sp.y>sh)continue;float cr=10;UIColor*cl=e->team!=1?UIColor.redColor:UIColor.greenColor;
        CGContextSetStrokeColorWithColor(c,cl.CGColor);CGContextSetLineWidth(c,1.5);CGContextStrokeEllipseInRect(c,CGRectMake(sp.x-cr,sp.y-cr,cr*2,cr*2));
        float bw=28,bh=4,hf=e->maxHp>0?e->hp/e->maxHp:0;CGContextSetFillColorWithColor(c,[UIColor colorWithWhite:0 alpha:0.55].CGColor);
        CGContextFillRect(c,CGRectMake(sp.x-bw/2,sp.y-cr-10,bw,bh));UIColor*hc=hf>0.5?UIColor.greenColor:(hf>0.25?UIColor.yellowColor:UIColor.redColor);
        CGContextSetFillColorWithColor(c,hc.CGColor);CGContextFillRect(c,CGRectMake(sp.x-bw/2,sp.y-cr-10,bw*hf,bh));}}
@end

void showESPOverlay(void) {if(g_espWin)return;CGRect s=UIScreen.mainScreen.bounds;g_espWin=[[UIWindow alloc]initWithFrame:s];g_espWin.windowLevel=UIWindowLevelAlert;g_espWin.backgroundColor=[UIColor clearColor];g_espWin.opaque=NO;g_espWin.userInteractionEnabled=NO;g_espWin.rootViewController=[UIViewController new];g_espWin.rootViewController.view.backgroundColor=[UIColor clearColor];EspView*ev=[[EspView alloc]initWithFrame:s];[g_espWin.rootViewController.view addSubview:ev];g_espWin.hidden=NO;}
void hideESPOverlay(void) {if(g_espWin){g_espWin.hidden=YES;g_espWin=nil;}}
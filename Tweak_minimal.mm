#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <dispatch/dispatch.h>
#import <os/log.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

typedef struct Il2CppObject Il2CppObject;
typedef struct Il2CppException Il2CppException;
typedef struct Il2CppMethodInfo Il2CppMethodInfo;
typedef struct { float x, y, z; } Vec3;
typedef void *(*domain_get_t)(void);
typedef const void **(*domain_get_assemblies_t)(void *, size_t *);
typedef void *(*assembly_get_image_t)(const void *);
typedef const char *(*image_get_name_t)(const void *);
typedef void *(*class_from_name_t)(void *, const char *, const char *);
typedef const Il2CppMethodInfo *(*class_get_method_t)(void *, const char *, int);
typedef Il2CppObject *(*runtime_invoke_t)(const Il2CppMethodInfo *, Il2CppObject *, void **, Il2CppException **);
typedef void *(*object_unbox_t)(Il2CppObject *);
typedef void *(*object_get_class_t)(Il2CppObject *);

static domain_get_t p_domain_get;
static domain_get_assemblies_t p_domain_get_assemblies;
static assembly_get_image_t p_assembly_get_image;
static image_get_name_t p_image_get_name;
static class_from_name_t p_class_from_name;
static class_get_method_t p_class_get_method;
static runtime_invoke_t p_runtime_invoke;
static object_unbox_t p_object_unbox;
static object_get_class_t p_object_get_class;
static os_log_t g_log;

static NSString *minimalLogPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    id firstPath = [paths firstObject];
    NSString *documents = ([firstPath isKindOfClass:[NSString class]] &&
                           [(NSString *)firstPath length] > 0)
        ? (NSString *)firstPath : NSTemporaryDirectory();
    NSString *directory = [documents stringByAppendingPathComponent:@"gamehack_logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:NULL];
    return [directory stringByAppendingPathComponent:@"runtime.log"];
}

static void logLine(NSString *message) {
    if (!g_log) g_log = os_log_create("gamehack", "minimal");
    NSString *text = message ?: @"";
    os_log(g_log, "%{public}@", text);
    NSLog(@"%@", text);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], text];
    NSString *path = minimalLogPath();
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) {
        [fm createFileAtPath:path contents:data attributes:nil];
        return;
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) return;
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } @catch (__unused NSException *exception) {
        [handle closeFile];
    }
}

static BOOL loadAPI(void) {
    p_domain_get = (domain_get_t)dlsym(RTLD_DEFAULT, "il2cpp_domain_get");
    p_domain_get_assemblies = (domain_get_assemblies_t)dlsym(RTLD_DEFAULT, "il2cpp_domain_get_assemblies");
    p_assembly_get_image = (assembly_get_image_t)dlsym(RTLD_DEFAULT, "il2cpp_assembly_get_image");
    p_image_get_name = (image_get_name_t)dlsym(RTLD_DEFAULT, "il2cpp_image_get_name");
    p_class_from_name = (class_from_name_t)dlsym(RTLD_DEFAULT, "il2cpp_class_from_name");
    p_class_get_method = (class_get_method_t)dlsym(RTLD_DEFAULT, "il2cpp_class_get_method_from_name");
    p_runtime_invoke = (runtime_invoke_t)dlsym(RTLD_DEFAULT, "il2cpp_runtime_invoke");
    p_object_unbox = (object_unbox_t)dlsym(RTLD_DEFAULT, "il2cpp_object_unbox");
    p_object_get_class = (object_get_class_t)dlsym(RTLD_DEFAULT, "il2cpp_object_get_class");
    return p_domain_get && p_domain_get_assemblies && p_assembly_get_image &&
        p_image_get_name && p_class_from_name && p_class_get_method &&
        p_runtime_invoke && p_object_unbox && p_object_get_class;
}

static void *findImage(const char *wanted) {
    void *domain = p_domain_get();
    size_t count = 0;
    const void **assemblies = domain ? p_domain_get_assemblies(domain, &count) : NULL;
    if (!assemblies || count == 0 || count > 4096) return NULL;
    for (size_t i = 0; i < count; i++) {
        void *image = assemblies[i] ? p_assembly_get_image(assemblies[i]) : NULL;
        const char *name = image ? p_image_get_name(image) : NULL;
        if (name && strcmp(name, wanted) == 0) return image;
    }
    return NULL;
}

static const Il2CppMethodInfo *method(void *klass, const char *name, int args) {
    return klass ? p_class_get_method(klass, name, args) : NULL;
}

static Il2CppObject *invoke(const Il2CppMethodInfo *info, Il2CppObject *object,
                            void **params, Il2CppException **exception) {
    return info ? p_runtime_invoke(info, object, params, exception) : NULL;
}

static BOOL finiteVec(Vec3 value) {
    return isfinite(value.x) && isfinite(value.y) && isfinite(value.z);
}

static BOOL readField(Il2CppObject *object, size_t offset, void *out, size_t size) {
    if (!object || !out || size == 0) return NO;
    memcpy(out, (uint8_t *)object + offset, size);
    return YES;
}

static void runMinimalMinimapProbe(void) {
    static BOOL methodsResolved = NO;
    static void *managerClass = NULL;
    static void *battleClass = NULL;
    static const Il2CppMethodInfo *getManager = NULL;
    static const Il2CppMethodInfo *getHostID = NULL;
    static const Il2CppMethodInfo *getHero = NULL;
    static const Il2CppMethodInfo *getBattle = NULL;
    static const Il2CppMethodInfo *getMap = NULL;
    static const Il2CppMethodInfo *project = NULL;
    static const Il2CppMethodInfo *getMapType = NULL;
    static const Il2CppMethodInfo *getMapInstance = NULL;
    static Il2CppObject *mapSystem = NULL;
    static Il2CppObject *battleSystem = NULL;
    if (!loadAPI()) { logLine(@"[MINIMAL] il2cpp_api=0"); return; }
    void *core = findImage("Scripts.GameCore.dll");
    if (!core) { logLine(@"[MINIMAL] core_image=0"); return; }
    if (!methodsResolved) {
        managerClass = p_class_from_name(core, "Assets.Scripts.GameLogic", "ActorManager");
        battleClass = p_class_from_name(core, "Assets.Scripts.GameSystem", "CBattleSystem");
        getManager = method(managerClass, "GetInstance", 0);
        getHostID = method(managerClass, "GetRawHostPlayerActorId", 0);
        getHero = method(managerClass, "GetHeroActorByIndex", 1);
        getBattle = method(battleClass, "GetInstance", 0);
        methodsResolved = YES;
        logLine([NSString stringWithFormat:@"[MINIMAL] classes manager=%d battle=%d methods=%d/%d/%d/%d", managerClass != NULL, battleClass != NULL, getManager != NULL, getHostID != NULL, getHero != NULL, getBattle != NULL]);
    }
    Il2CppException *exception = NULL;
    Il2CppObject *manager = invoke(getManager, NULL, NULL, &exception);
    if (!manager || exception) { logLine(@"[MINIMAL] manager=0"); return; }
    Il2CppObject *boxedHost = invoke(getHostID, manager, NULL, &exception);
    void *rawHost = boxedHost && !exception ? p_object_unbox(boxedHost) : NULL;
    uint32_t hostID = rawHost ? *(uint32_t *)rawHost : 0;
    if (!hostID) { logLine(@"[MINIMAL] host_id=0"); return; }
    Il2CppObject *host = NULL;
    for (int32_t index = 0; index < 64; index++) {
        void *params[1] = { &index };
        exception = NULL;
        Il2CppObject *candidate = invoke(getHero, manager, params, &exception);
        uint32_t objectID = 0;
        if (candidate && !exception) readField(candidate, 0x4AC, &objectID, sizeof(objectID));
        if (candidate && objectID == hostID) { host = candidate; break; }
    }
    if (!host) { logLine([NSString stringWithFormat:@"[MINIMAL] host_actor=0 id=%u", hostID]); return; }
    Vec3 world = {0, 0, 0};
    BOOL worldOK = readField(host, 0x4C4, &world, sizeof(world)) && finiteVec(world);
    if (!mapSystem && getBattle) {
        battleSystem = invoke(getBattle, NULL, NULL, &exception);
        if (battleSystem && p_object_get_class) {
            void *runtimeClass = p_object_get_class(battleSystem);
            getMap = method(runtimeClass, "get_TheMinimapSys", 0);
            mapSystem = invoke(getMap, battleSystem, NULL, &exception);
        }
    }
    if (mapSystem && !project && p_object_get_class) {
        void *runtimeClass = p_object_get_class(mapSystem);
        project = method(runtimeClass, "GetPositionInScreen", 2);
        getMapType = method(runtimeClass, "GetUsedMiniMapType", 0);
        getMapInstance = method(runtimeClass, "GetMiniMapInstance", 1);
    }
    int32_t mapType = 0;
    if (getMapType) {
        Il2CppObject *boxed = invoke(getMapType, mapSystem, NULL, &exception);
        void *raw = boxed && !exception ? p_object_unbox(boxed) : NULL;
        if (raw) mapType = *(int32_t *)raw;
    }
    Il2CppObject *mapInstance = NULL;
    if (getMapInstance) { void *params[1] = { &mapType }; mapInstance = invoke(getMapInstance, mapSystem, params, &exception); }
    Vec3 screen = {0, 0, 0}; BOOL screenOK = NO;
    if (worldOK && mapSystem && project && mapInstance) {
        void *params[2] = { &world, &mapType };
        exception = NULL;
        Il2CppObject *boxed = invoke(project, mapSystem, params, &exception);
        void *raw = boxed && !exception ? p_object_unbox(boxed) : NULL;
        if (raw) { screen = *(Vec3 *)raw; screenOK = finiteVec(screen); }
    }
    logLine([NSString stringWithFormat:@"[MINIMAL] host=%u world=%d(%.2f,%.2f,%.2f) map=%d type=%d instance=%d screen=%d(%.2f,%.2f,%.2f)", hostID, worldOK, world.x, world.y, world.z, mapSystem != NULL, mapType, mapInstance != NULL, screenOK, screen.x, screen.y, screen.z]);
}

__attribute__((constructor)) static void gamehackMinimalConstructor(void) {
    logLine(@"[MINIMAL] session begin observer-only=1 writes=0 ui=0 esp=0 callback=0");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        logLine(@"[MINIMAL] started observer-only=1 writes=0 ui=0 esp=0 callback=0");
        runMinimalMinimapProbe();
    });
}

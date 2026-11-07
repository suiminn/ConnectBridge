#import <Foundation/Foundation.h>
#import <dlfcn.h>

// Private API declarations (only used through the runtime; see poc-results.md Step 2)
@interface MPAVRoute : NSObject
- (NSString *)routeName;
- (NSString *)routeUID;
- (long long)routeType;
- (long long)routeSubtype;
- (BOOL)isPicked;
- (BOOL)isAirPlayRoute;
- (BOOL)isDeviceRoute;
- (BOOL)isVolumeControlAvailable;
@end

@interface MPAVRoutingController : NSObject
- (instancetype)initWithName:(NSString *)name;
- (void)setDiscoveryMode:(long long)mode;
- (long long)routeTypes;
- (void)setRouteTypes:(long long)t;
- (void)fetchAvailableRoutesWithCompletionQueue:(dispatch_queue_t)q completionHandler:(void (^)(NSArray *routes))handler;
- (BOOL)pickRoute:(MPAVRoute *)route withPassword:(NSString *)pw completion:(void (^)(void *err))completion;
@end

@interface MRAVOutputDevice : NSObject
- (NSString *)name;
- (NSString *)uid;
- (float)volume;
- (void)setVolume:(float)v;
- (BOOL)isVolumeControlAvailable;
- (BOOL)isLocalDevice;
- (unsigned)deviceType;
- (unsigned)deviceSubtype;
@end

@interface MRAVRoutingDiscoverySession : NSObject
+ (instancetype)discoverySessionWithEndpointFeatures:(unsigned)f;
- (void)setDiscoveryMode:(unsigned)m;
- (NSArray *)availableOutputDevices;
@end

@interface MRAVOutputContext : NSObject
+ (instancetype)sharedSystemAudioContext;
- (NSArray *)outputDevices;
- (void)setOutputDevices:(NSArray *)d withCallbackQueue:(dispatch_queue_t)q block:(void (^)(void *err))b;
@end

@interface AVSystemController : NSObject
+ (instancetype)sharedAVSystemController;
- (BOOL)getVolume:(float *)v forCategory:(NSString *)c;
- (BOOL)setVolumeTo:(float)v forCategory:(NSString *)c;
- (BOOL)getActiveCategoryVolume:(float *)v andName:(NSString **)n;
- (BOOL)currentRouteHasVolumeControl;
- (BOOL)setAttribute:(id)a forKey:(NSString *)k error:(NSError **)e;
@end

// usage: routetool list | pick <name substring> | local
static void spin(NSTimeInterval s) {
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:s]];
}

static NSArray *fetch(MPAVRoutingController *c) {
    __block NSArray *out = nil;
    __block BOOL done = NO;
    [c fetchAvailableRoutesWithCompletionQueue:dispatch_get_main_queue() completionHandler:^(NSArray *r) { out = r; done = YES; }];
    for (int i = 0; i < 100 && !done; i++) spin(0.1);
    return out;
}

static void printRoutes(NSArray *routes) {
    for (MPAVRoute *r in routes) {
        printf("%s name=\"%s\" uid=%s type=%lld sub=%lld airplay=%d device=%d vol=%d\n",
               r.isPicked ? "*" : " ", r.routeName.UTF8String, r.routeUID.UTF8String,
               r.routeType, r.routeSubtype, r.isAirPlayRoute, r.isDeviceRoute, r.isVolumeControlAvailable);
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_NOW);
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (argc < 2) { fprintf(stderr, "usage: routetool list | pick <name> | local\n"); return 64; }
        NSString *cmd = [NSString stringWithUTF8String:argv[1]];

        if ([cmd isEqualToString:@"np"]) {
            // Ask MediaRemote what the system believes is playing (the app that Siri / HomePod talk to).
            typedef void (*InfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
            typedef void (*NameFn)(dispatch_queue_t, void (^)(CFStringRef));
            typedef void (*BoolFn)(dispatch_queue_t, void (^)(Boolean));
            InfoFn info = (InfoFn)dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingInfo");
            NameFn app = (NameFn)dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingApplicationDisplayID");
            BoolFn playing = (BoolFn)dlsym(RTLD_DEFAULT, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
            __block int pending = 3;
            if (info) info(dispatch_get_main_queue(), ^(CFDictionaryRef d) {
                NSDictionary *dict = (__bridge NSDictionary *)d;
                printf("nowPlayingInfo: %lu keys\n", (unsigned long)dict.count);
                for (id k in dict) { id v = dict[k]; if ([v isKindOfClass:[NSData class]]) v = @"<data>"; printf("  %s = %s\n", [[k description] UTF8String], [[v description] UTF8String]); }
                pending--;
            }); else pending--;
            if (app) app(dispatch_get_main_queue(), ^(CFStringRef n) { printf("nowPlayingApp displayID: %s\n", n ? [(__bridge NSString *)n UTF8String] : "(none)"); pending--; }); else pending--;
            if (playing) playing(dispatch_get_main_queue(), ^(Boolean b) { printf("nowPlayingApp isPlaying: %d\n", b); pending--; }); else pending--;
            for (int i = 0; i < 50 && pending > 0; i++) spin(0.1);
            return 0;
        }
        if ([cmd isEqualToString:@"mr"]) {
            typedef void (*CopyFn)(dispatch_queue_t, void (^)(CFArrayRef));
            CopyFn fn = (CopyFn)dlsym(RTLD_DEFAULT, "MRMediaRemoteCopyPickableRoutes");
            __block BOOL done = NO;
            fn(dispatch_get_main_queue(), ^(CFArrayRef a) {
                NSArray *arr = (__bridge NSArray *)a;
                printf("MR pickable routes: %lu\n", (unsigned long)arr.count);
                for (id x in arr) printf("  %s\n", [[x description] UTF8String]);
                done = YES;
            });
            for (int i = 0; i < 100 && !done; i++) spin(0.1);
            return 0;
        }
        if ([cmd isEqualToString:@"mrav"]) {
            // mrav list | mrav pick <name> | mrav vol <name> [0..1]   (env F=features M=mode)
            unsigned F = getenv("F") ? (unsigned)strtoul(getenv("F"), NULL, 0) : 0xffffffff;
            unsigned M = getenv("M") ? (unsigned)strtoul(getenv("M"), NULL, 0) : 1;
            MRAVRoutingDiscoverySession *ds = [NSClassFromString(@"MRAVRoutingDiscoverySession") discoverySessionWithEndpointFeatures:F];
            [ds setDiscoveryMode:M];
            spin(getenv("WAIT") ? atof(getenv("WAIT")) : 5);
            NSArray *devs = [ds availableOutputDevices];
            MRAVOutputContext *ctx = [NSClassFromString(@"MRAVOutputContext") sharedSystemAudioContext];
            NSArray *cur = [ctx outputDevices];
            printf("F=0x%x M=%u: %lu available, %lu current\n", F, M, (unsigned long)devs.count, (unsigned long)cur.count);
            for (MRAVOutputDevice *c3 in cur) printf("current: \"%s\" uid=%s type=%u sub=%u\n", c3.name.UTF8String, c3.uid.UTF8String, c3.deviceType, c3.deviceSubtype);
            for (MRAVOutputDevice *d in devs) {
                BOOL isCur = NO;
                for (MRAVOutputDevice *c2 in cur) if ([c2.uid isEqual:d.uid]) isCur = YES;
                printf("%s name=\"%s\" uid=%s type=%u sub=%u local=%d volAvail=%d vol=%.3f\n", isCur ? "*" : " ",
                       d.name.UTF8String, d.uid.UTF8String, d.deviceType, d.deviceSubtype, d.isLocalDevice, d.isVolumeControlAvailable, d.volume);
            }
            if (argc > 3 && ([[NSString stringWithUTF8String:argv[2]] isEqualToString:@"pick"] || [[NSString stringWithUTF8String:argv[2]] isEqualToString:@"vol"])) {
                NSString *mode = [NSString stringWithUTF8String:argv[2]];
                NSString *q = [NSString stringWithUTF8String:argv[3]];
                MRAVOutputDevice *t = nil;
                for (MRAVOutputDevice *d in devs) if ([d.name rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) { t = d; break; }
                if (!t) { fprintf(stderr, "no matching device\n"); return 3; }
                if ([mode isEqualToString:@"pick"]) {
                    __block BOOL called = NO;
                    [ctx setOutputDevices:@[t] withCallbackQueue:dispatch_get_main_queue() block:^(void *err) { printf("pick completion err=%p\n", err); called = YES; }];
                    for (int i = 0; i < 100 && !called; i++) spin(0.1);
                    spin(2);
                    for (MRAVOutputDevice *c2 in [ctx outputDevices]) printf("now: %s\n", c2.name.UTF8String);
                    if (getenv("WATCH")) {
                        dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_NOW);
                        AVSystemController *sc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
                        NSString *nname = @"AVSystemController_SystemVolumeDidChangeNotification";
                        NSString *nname2 = @"AVSystemController_EffectiveVolumeDidChangeNotification";
                        NSString *subkey = getenv("SUBKEY") ? [NSString stringWithUTF8String:getenv("SUBKEY")] : @"AVSystemController_NotificationsToRegisterAttribute";
                        if ([sc respondsToSelector:@selector(setAttribute:forKey:error:)]) {
                            NSError *e = nil;
                            NSArray *names = @[nname, nname2, @"AVSystemController_MutedDidChangeNotification", @"AVSystemController_SoftMuteDidChangeNotification",
                                               @"AVSystemController_CurrentRouteHasVolumeControlDidChangeNotification", @"AVSystemController_ActiveAudioRouteDidChangeNotification",
                                               @"AVSystemController_PickableRoutesDidChangeNotification"];
                            NSError *e2 = nil;
                            BOOL w = [(id)sc setAttribute:@YES forKey:@"AVSystemController_AppWantsVolumeChangesAttribute" error:&e2];
                            printf("AppWantsVolumeChanges ok=%d err=%s\n", w, e2 ? [[e2 description] UTF8String] : "-");
                            BOOL r = [(id)sc setAttribute:names forKey:subkey error:&e];
                            printf("subscribe key=%s ok=%d err=%s\n", subkey.UTF8String, r, e ? [[e description] UTF8String] : "-");
                        } else printf("setAttribute:forKey:error: missing\n");
                        [[NSNotificationCenter defaultCenter] addObserverForName:nil object:nil queue:nil usingBlock:^(NSNotification *n) {
                            if ([n.name hasPrefix:@"AVSystemController"]) { printf("[any] %s\n", n.name.UTF8String); fflush(stdout); }
                        }];
                        for (NSString *nm in @[nname, nname2]) {
                            [[NSNotificationCenter defaultCenter] addObserverForName:nm object:nil queue:nil usingBlock:^(NSNotification *n) {
                                printf("[notif] %s %s\n", n.name.UTF8String, [[n.userInfo description] UTF8String]); fflush(stdout);
                            }];
                        }
                        NSArray *steps = getenv("STEPS") ? [[NSString stringWithUTF8String:getenv("STEPS")] componentsSeparatedByString:@","] : @[];
                        double stepSec = getenv("STEPSEC") ? atof(getenv("STEPSEC")) : 6;
                        double total = getenv("HOLD") ? atof(getenv("HOLD")) : 40;
                        float last = -2; NSString *cat = nil; int nextStep = 0;
                        NSDate *t0 = [NSDate date];
                        while (-[t0 timeIntervalSinceNow] < total) {
                            float v = -1; [sc getActiveCategoryVolume:&v andName:&cat];
                            if (fabsf(v - last) > 0.0005f) { printf("[%5.1fs] poll volume=%.3f (%s)\n", -[t0 timeIntervalSinceNow], v, cat.UTF8String); fflush(stdout); last = v; }
                            if (nextStep < (int)steps.count && -[t0 timeIntervalSinceNow] >= (nextStep + 1) * stepSec * 0 + nextStep * stepSec + 2) {
                                float nv = [steps[nextStep] floatValue];
                                printf("[%5.1fs] >>> setVolumeTo %.2f\n", -[t0 timeIntervalSinceNow], nv); fflush(stdout);
                                [sc setVolumeTo:nv forCategory:cat ?: @"Audio/Video"];
                                nextStep++;
                            }
                            spin(0.25);
                        }
                    } else if (getenv("HOLD")) { printf("holding %s s\n", getenv("HOLD")); fflush(stdout); spin(atof(getenv("HOLD"))); }
                } else if (argc > 4) {
                    [t setVolume:(float)atof(argv[4])];
                    spin(2);
                    printf("volume now %.3f\n", t.volume);
                }
            }
            return 0;
        }
        if ([cmd isEqualToString:@"sysvol"]) {
            dlopen("/System/Library/Frameworks/AVFoundation.framework/AVFoundation", RTLD_NOW);
            AVSystemController *sc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
            float v = -1; NSString *name = nil;
            BOOL ok = [sc getActiveCategoryVolume:&v andName:&name];
            printf("active category=%s volume=%.3f ok=%d routeHasVolumeControl=%d\n", name.UTF8String, v, ok, [sc currentRouteHasVolumeControl]);
            if (argc > 2) {
                BOOL r = [sc setVolumeTo:(float)atof(argv[2]) forCategory:name ?: @"Audio/Video"];
                spin(1);
                float v2 = -1; [sc getActiveCategoryVolume:&v2 andName:&name];
                printf("set %.2f -> ok=%d, now %.3f\n", atof(argv[2]), r, v2);
            }
            return 0;
        }
        MPAVRoutingController *c = [[NSClassFromString(@"MPAVRoutingController") alloc] initWithName:@"connectbridge"];
        if (!c) { fprintf(stderr, "MPAVRoutingController unavailable\n"); return 1; }
        fprintf(stderr, "default routeTypes=%lld\n", [c routeTypes]);
        if (getenv("RT")) [c setRouteTypes:strtoll(getenv("RT"), NULL, 0)];
        [c setDiscoveryMode:getenv("DISC") ? atoi(getenv("DISC")) : 2];
        spin(getenv("WAIT") ? atof(getenv("WAIT")) : 4);
        NSArray *routes = fetch(c);
        if (!routes) { fprintf(stderr, "fetch timed out\n"); return 2; }

        if ([cmd isEqualToString:@"list"]) {
            printRoutes(routes);
            return 0;
        }

        MPAVRoute *target = nil;
        if ([cmd isEqualToString:@"local"]) {
            for (MPAVRoute *r in routes) if (r.isDeviceRoute) { target = r; break; }
        } else if ([cmd isEqualToString:@"pick"] && argc > 2) {
            NSString *q = [NSString stringWithUTF8String:argv[2]];
            for (MPAVRoute *r in routes)
                if ([r.routeName rangeOfString:q options:NSCaseInsensitiveSearch].location != NSNotFound) { target = r; break; }
        }
        if (!target) { fprintf(stderr, "no matching route\n"); printRoutes(routes); return 3; }

        printf("picking \"%s\"\n", target.routeName.UTF8String);
        __block BOOL called = NO;
        BOOL ok = [c pickRoute:target withPassword:nil completion:^(void *err) {
            printf("completion err=%p\n", err);
            called = YES;
        }];
        printf("pickRoute returned %d\n", ok);
        for (int i = 0; i < 100 && !called; i++) spin(0.1);
        spin(2);
        printRoutes(fetch(c));
    }
    return 0;
}

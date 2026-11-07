#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>

// AVSYSCTL=1: also subscribe to AVSystemController's volume notifications while this process holds
// an active audio session (the routetool experiment had none) and log them next to a poll of the
// same volume, to see whether the notifications are delivered at all. AMP=0 makes the tone silent.
@interface AVSystemController : NSObject
+ (instancetype)sharedAVSystemController;
- (BOOL)setAttribute:(id)value forKey:(NSString *)key error:(NSError **)error;
- (BOOL)getActiveCategoryVolume:(float *)volume andName:(NSString **)name;
@end

@interface MRAVOutputContext : NSObject
+ (instancetype)sharedSystemAudioContext;
- (float)volume;
- (BOOL)supportsVolumeControl;
@end

@interface VolObserver : NSObject
@end
@implementation VolObserver
- (void)observeValueForKeyPath:(NSString *)k ofObject:(id)o change:(NSDictionary *)c context:(void *)ctx {
    NSLog(@"[KVO] outputVolume %@ -> %@", c[NSKeyValueChangeOldKey], c[NSKeyValueChangeNewKey]);
}
@end

// usage: audiotest [seconds]   (0 = forever)
int main(int argc, char **argv) {
    @autoreleasepool {
        double seconds = argc > 1 ? atof(argv[1]) : 5;
        static float amp; amp = getenv("AMP") ? (float)atof(getenv("AMP")) : 0.1f;

        NSError *err = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        if (![session setCategory:AVAudioSessionCategoryPlayback error:&err]) {
            NSLog(@"setCategory failed: %@", err);
            return 1;
        }
        if (![session setActive:YES error:&err]) {
            NSLog(@"setActive failed: %@", err);
            return 2;
        }
        NSLog(@"output route: %@", session.currentRoute.outputs);

        AVAudioEngine *engine = [AVAudioEngine new];
        AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
        __block double phase = 0;
        const double step = 2 * M_PI * 440.0 / 44100.0;
        AVAudioSourceNode *src = [[AVAudioSourceNode alloc] initWithFormat:fmt
            renderBlock:^OSStatus(BOOL *silence, const AudioTimeStamp *ts, AVAudioFrameCount frames, AudioBufferList *abl) {
                for (AVAudioFrameCount f = 0; f < frames; f++) {
                    float v = amp * (float)sin(phase);
                    phase += step;
                    if (phase > 2 * M_PI) phase -= 2 * M_PI;
                    for (UInt32 b = 0; b < abl->mNumberBuffers; b++) {
                        ((float *)abl->mBuffers[b].mData)[f] = v;
                    }
                }
                return noErr;
            }];
        [engine attachNode:src];
        [engine connect:src to:engine.mainMixerNode format:fmt];
        if (![engine startAndReturnError:&err]) {
            NSLog(@"engine start failed: %@", err);
            return 3;
        }
        NSLog(@"playing 440Hz (%.0fs)", seconds);

        static VolObserver *vo; vo = [VolObserver new];
        [session addObserver:vo forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:NULL];
        NSLog(@"outputVolume=%.3f", session.outputVolume);
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil
            usingBlock:^(NSNotification *n) {
                NSLog(@"route change reason=%@ now=%@", n.userInfo[AVAudioSessionRouteChangeReasonKey],
                      [[AVAudioSession sharedInstance].currentRoute.outputs valueForKey:@"portName"]);
            }];
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification object:engine queue:nil
            usingBlock:^(NSNotification *n) {
                NSError *e = nil;
                BOOL ok = [engine startAndReturnError:&e];
                NSLog(@"engine config change -> restart ok=%d running=%d err=%@", ok, engine.isRunning, e);
            }];
        [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) {
            NSLog(@"tick route=%@ engineRunning=%d", [[AVAudioSession sharedInstance].currentRoute.outputs valueForKey:@"portName"], engine.isRunning);
        }];

        if (getenv("AVSYSCTL")) {
            AVSystemController *sc = [NSClassFromString(@"AVSystemController") sharedAVSystemController];
            NSArray *names = @[@"AVSystemController_SystemVolumeDidChangeNotification",
                               @"AVSystemController_EffectiveVolumeDidChangeNotification",
                               @"AVSystemController_ActiveAudioRouteDidChangeNotification"];
            NSError *e1 = nil, *e2 = nil;
            BOOL a = [sc setAttribute:@YES forKey:@"AVSystemController_AppWantsVolumeChangesAttribute" error:&e1];
            BOOL b = [sc setAttribute:names forKey:@"AVSystemController_NotificationsToRegisterAttribute" error:&e2];
            NSLog(@"AVSC AppWantsVolumeChanges ok=%d err=%@, NotificationsToRegister ok=%d err=%@", a, e1, b, e2);
            [[NSNotificationCenter defaultCenter] addObserverForName:nil object:nil queue:nil usingBlock:^(NSNotification *n) {
                if ([n.name hasPrefix:@"AVSystemController"]) NSLog(@"AVSC notification %@ %@ (main=%d)", n.name, n.userInfo, [NSThread isMainThread]);
            }];
            static float last = -2;
            [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
                float v = -1; NSString *cat = nil;
                [[NSClassFromString(@"AVSystemController") sharedAVSystemController] getActiveCategoryVolume:&v andName:&cat];
                if (fabsf(v - last) > 0.0005f) { NSLog(@"AVSC poll volume=%.3f (%@)", v, cat); last = v; }
            }];
        }

        // MRVOL=1: MediaRemote's own volume notifications (MRAVOutputContextVolumeDidChangeNotification,
        // kMRMediaRemotePickedRouteVolumeDidChangeNotification, ...): log every notification whose name
        // mentions "Volume" (from any framework except AVSystemController, logged above) next to a poll
        // of MRAVOutputContext.volume.
        if (getenv("MRVOL")) {
            void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
            void (*registerFn)(dispatch_queue_t) = mr ? dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
            if (registerFn) registerFn(dispatch_get_main_queue());
            NSLog(@"MRVOL MediaRemote=%d registerForNowPlayingNotifications=%d", mr != NULL, registerFn != NULL);
            MRAVOutputContext *ctx = [NSClassFromString(@"MRAVOutputContext") sharedSystemAudioContext];
            NSLog(@"MRVOL context=%@ supportsVolumeControl=%d volume=%.3f", ctx, [ctx supportsVolumeControl], [ctx volume]);
            [[NSNotificationCenter defaultCenter] addObserverForName:nil object:nil queue:nil usingBlock:^(NSNotification *n) {
                if ([n.name rangeOfString:@"Volume" options:NSCaseInsensitiveSearch].location != NSNotFound && ![n.name hasPrefix:@"AVSystemController"]) {
                    NSLog(@"MRVOL notification %@ object=%@ %@", n.name, [n.object class], n.userInfo);
                }
            }];
            static float lastMr = -2;
            [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
                float v = [[NSClassFromString(@"MRAVOutputContext") sharedSystemAudioContext] volume];
                if (fabsf(v - lastMr) > 0.0005f) { NSLog(@"MRVOL poll context.volume=%.3f", v); lastMr = v; }
            }];
        }

        if (seconds > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ NSLog(@"done"); exit(0); });
        }
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}

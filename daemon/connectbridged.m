// connectbridged: supervises librespot (the Spotify Connect endpoint) and puts the system audio
// output route on the configured AirPlay device (HomePod) while this device is the selected
// Spotify Connect device; the route is given back when playback moves elsewhere.
//
// Findings this relies on (see docs/poc-results.md):
//  - the process that selects the route has to stay alive, otherwise AirPlay is torn down again;
//  - the route can be taken away by someone else (Control Center, the Spotify app on the iPhone),
//    so while the Connect device is selected it is checked and selected again;
//  - volume is bridged by librespot itself (CB_VOLUME_BRIDGE), not here.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <spawn.h>
#import <signal.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/sysctl.h>
#import <sys/wait.h>
#import <netinet/in.h>
#import <pthread/spawn.h>
#import <sys/qos.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import "route_policy.h"
#import "marker.h"

extern char **environ;

// libproc.h is not part of the iOS SDK; these functions are available in libSystem.
extern int proc_name(int pid, void *buffer, uint32_t buffersize);
extern int proc_listallpids(void *buffer, int buffersize);

static NSString *const kDataDir = @"/var/mobile/Library/ConnectBridge";
static NSString *const kStatePath = @"/var/mobile/Library/ConnectBridge/state";  // written by librespot: active / inactive
// What the output route is doing, for librespot (CB_ROUTE_FILE): "none" (nothing held), "pending"
// (not selected yet, or lost) or "ready" (the device is the system output). Replaced atomically.
static NSString *const kRoutePath = @"/var/mobile/Library/ConnectBridge/route";
static NSString *gPublishedRoute = nil;

static NSString *const kLibrespotPath = @"/var/jb/usr/libexec/connectbridge/librespot";
static const off_t kMaxLogBytes = 2 * 1024 * 1024;

// --- private MediaRemote API (declared for use through the runtime only) ---

@interface MRAVOutputDevice : NSObject
- (NSString *)name;
- (NSString *)uid;
- (BOOL)isLocalDevice;
@end

@interface MRAVRoutingDiscoverySession : NSObject
+ (instancetype)discoverySessionWithEndpointFeatures:(unsigned)features;
- (void)setDiscoveryMode:(unsigned)mode;
- (NSArray *)availableOutputDevices;
@end

@interface MRAVOutputContext : NSObject
+ (instancetype)sharedSystemAudioContext;
- (NSArray *)outputDevices;
- (void)setOutputDevices:(NSArray *)devices withCallbackQueue:(dispatch_queue_t)queue block:(void (^)(void *error))block;
@end

// --- configuration ---

static NSString *const kPrefsDomain = @"com.sui827.connectbridge";
static NSString *const kPrefsNotification = @"com.sui827.connectbridge/prefs";      // posted by the Settings pane
static NSString *const kRestartNotification = @"com.sui827.connectbridge/restart";  // "restart librespot" button

// Read through cfprefsd, like the Settings pane writes it: reading the plist file directly can
// lag behind the latest change.
static NSDictionary *loadConfig(void) {
    NSDictionary *defaults = @{
        @"Enabled": @YES,
        @"ConnectName": @"",  // empty: "<AirPlay device> (via <this iPhone>)"
        @"OutputDeviceName": @"",  // empty: no AirPlay device chosen yet, nothing is started
        @"ManageRoute": @YES,
        @"Bitrate": @160,
        @"AirPlayGuard": @YES,
        @"GuardResumeSeconds": @30,
        @"ReleaseDelay": @15,
        @"Verbose": @NO,
        @"VolumePolling": @NO,  // YES: read the route volume every 250 ms instead of waiting for MediaRemote's notification
    };
    NSMutableDictionary *config = [defaults mutableCopy];
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
    for (NSString *key in defaults) {
        CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kPrefsDomain);
        if (!value) continue;
        id object = (__bridge_transfer id)value;
        // A hand-edited plist can hold any type; a wrong one would crash on boolValue / intValue.
        Class expected = [defaults[key] isKindOfClass:[NSString class]] ? [NSString class] : [NSNumber class];
        if ([object isKindOfClass:expected]) config[key] = object;
        else NSLog(@"preferences: ignoring %@ (unexpected type)", key);
    }
    return config;
}

// The monitor reads the settings twice a second: use a copy that is refreshed when they change
// (Darwin notification, SIGHUP, librespot start) instead of going through cfprefsd every time.
static NSDictionary *gConfig = nil;

static void reloadConfig(void) {
    gConfig = loadConfig();
}

static NSDictionary *currentConfig(void) {
    if (!gConfig) reloadConfig();
    return gConfig;
}

static NSString *effectiveConnectName(NSDictionary *config);

// The settings that decide how librespot is started; a change in one of them needs a restart.
// The automatic name is not part of it: it depends on what discovery has found so far, which would
// restart librespot (and cut playback) without any setting having changed. It follows from
// ConnectName and OutputDeviceName, which are in the list.
static NSString *launchSignature(NSDictionary *config) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in @[@"Enabled", @"OutputDeviceName", @"ConnectName", @"Bitrate", @"Verbose", @"ManageRoute", @"AirPlayGuard", @"GuardResumeSeconds", @"VolumePolling"]) {
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, config[key]]];
    }
    return [parts componentsJoinedByString:@";"];
}

static void publishHeartbeat(void);

// Shown in the Settings pane (it cannot read our files).
static void publishState(NSString *state) {
    CFPreferencesSetAppValue(CFSTR("RuntimeState"), (__bridge CFStringRef)state, (__bridge CFStringRef)kPrefsDomain);
    publishHeartbeat();
}

// The Settings pane cannot tell a crashed daemon from an idle one by RuntimeState alone: the daemon
// also stamps the time, and the pane treats a stale stamp as "not running".
static void publishHeartbeat(void) {
    CFPreferencesSetAppValue(CFSTR("RuntimeHeartbeat"), (__bridge CFNumberRef)@([[NSDate date] timeIntervalSince1970]), (__bridge CFStringRef)kPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
}

// --- logging ---

static void cblog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void cblog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@", message);
}

// daemon.log is opened by this process (stderr), so it is rotated by renaming it and opening a new
// one. librespot.log is held open in append mode by a running librespot, so while it runs it is
// copied and truncated (off the main queue: it can be 2 MB); between two runs it is just renamed.
static NSString *daemonLogPath(void) { return [kDataDir stringByAppendingPathComponent:@"daemon.log"]; }
static NSString *librespotLogPath(void) { return [kDataDir stringByAppendingPathComponent:@"librespot.log"]; }

static void openDaemonLog(void) {
    int fd = open(daemonLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
    if (fd < 0) return;
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    close(fd);
}

static BOOL logTooBig(NSString *path) {
    struct stat st;
    return stat(path.fileSystemRepresentation, &st) == 0 && st.st_size > kMaxLogBytes;
}

static void rotateDaemonLog(void) {
    NSString *path = daemonLogPath();
    if (!logTooBig(path)) return;
    rename(path.fileSystemRepresentation, [path stringByAppendingString:@".1"].fileSystemRepresentation);
    openDaemonLog();
}

static void rotateLibrespotLog(BOOL running) {
    NSString *path = librespotLogPath();
    if (!logTooBig(path)) return;
    NSString *old = [path stringByAppendingString:@".1"];
    if (!running) {
        rename(path.fileSystemRepresentation, old.fileSystemRepresentation);
        return;
    }
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("connectbridge.logrotate", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm removeItemAtPath:old error:nil];
        if ([fm copyItemAtPath:path toPath:old error:nil]) truncate(path.fileSystemRepresentation, 0);
    });
}

// --- librespot supervision ---

static pid_t gChild = 0;
static dispatch_source_t gChildSource = nil;
static NSDate *gChildStart = nil;
static NSTimeInterval gBackoff = 2;
static BOOL gStopping = NO;
static BOOL gActive = NO;  // librespot reports this device as the selected Connect device

static void ensureDiscovery(void);
@class MRAVOutputDevice;
static MRAVOutputDevice *findOutputDevice(NSString *wanted, BOOL local);
static void startLibrespot(void);
static NSString *gLaunchSignature = nil;  // of the running librespot

// librespot does not exit on SIGTERM while it is playing/connected, so fall back to SIGKILL.
static void terminateChild(void) {
    pid_t pid = gChild;
    if (!pid) return;
    kill(pid, SIGTERM);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (gChild == pid) {
            cblog(@"librespot ignored SIGTERM, sending SIGKILL");
            kill(pid, SIGKILL);
        }
    });
}

// A previous daemon may have been killed without cleaning up its child, and launchd can SIGKILL a
// daemon during an upgrade: remove every librespot that is not our current child.
// proc_pidpath() fails for processes other than ourselves here, but proc_name() and the process
// arguments work. A stray of ours belongs to our user, has been re-parented to launchd and was
// started from our binary; a librespot that somebody else runs (another user, another binary) is
// left alone.
// The path the process was started from (KERN_PROCARGS2: argc, then the exec path), which works for
// processes of our own user. NO when it cannot be read.
static BOOL execPathOf(pid_t pid, NSString **path) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size <= sizeof(int)) return NO;
    char *buffer = malloc(size + 1);
    if (!buffer) return NO;
    BOOL ok = NO;
    if (sysctl(mib, 3, buffer, &size, NULL, 0) == 0 && size > sizeof(int)) {
        buffer[size] = 0;  // the exec path is NUL-terminated within the buffer
        *path = @(buffer + sizeof(int));
        ok = YES;
    }
    free(buffer);
    return ok;
}

static BOOL isOrphanOfOurs(pid_t pid) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info;
    size_t size = sizeof(info);
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) return NO;
    if (info.kp_eproc.e_ucred.cr_uid != getuid() || info.kp_eproc.e_ppid != 1) return NO;
    // Same name, user and parent is not enough: another librespot that somebody started with nohup
    // looks the same. Only the one that was started from our binary is ours.
    NSString *path = nil;
    if (!execPathOf(pid, &path)) {
        cblog(@"librespot (pid %d): cannot tell where it was started from, leaving it alone", pid);
        return NO;
    }
    return [path isEqualToString:kLibrespotPath];
}

static void killStrayLibrespots(void) {
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) return;
    pid_t *pids = calloc((size_t)count + 16, sizeof(pid_t));
    count = proc_listallpids(pids, (int)(((size_t)count + 16) * sizeof(pid_t)));
    for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 1 || pid == gChild) continue;
        char name[64] = {0};
        if (proc_name(pid, name, sizeof(name)) > 0 && strcmp(name, "librespot") == 0 && isOrphanOfOurs(pid)) {
            cblog(@"removing stray librespot (pid %d)", pid);
            kill(pid, SIGKILL);
        }
    }
    free(pids);
}

static BOOL gRestartRequested = NO;  // a restart we asked for (settings, SIGHUP, button), not a crash

static void scheduleRestart(void) {
    if (gStopping) return;
    if (gRestartRequested) {
        gRestartRequested = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ startLibrespot(); });
        return;
    }
    cblog(@"restarting librespot in %.0fs", gBackoff);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gBackoff * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ startLibrespot(); });
    gBackoff = MIN(gBackoff * 2, 30);
}

// librespot refuses anything but these and would exit at once, again and again.
static NSString *validBitrate(id value) {
    int bitrate = [value respondsToSelector:@selector(intValue)] ? [value intValue] : 0;
    return (bitrate == 96 || bitrate == 160 || bitrate == 320) ? [NSString stringWithFormat:@"%d", bitrate] : @"160";
}

static void startLibrespot(void) {
    if (gStopping || gChild) return;
    killStrayLibrespots();
    reloadConfig();
    NSDictionary *config = currentConfig();
    // Automatic name: the AirPlay device is only known once discovery has found it. Wait a little
    // for it at startup; after that fall back to the configured name.
    static NSDate *firstAttempt = nil;
    if (!firstAttempt) firstAttempt = [NSDate date];
    BOOL autoName = ![[config[@"ConnectName"] description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length;
    NSString *chosenDevice = [[config[@"OutputDeviceName"] description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (autoName && chosenDevice.length && [config[@"Enabled"] boolValue] && -[firstAttempt timeIntervalSinceNow] < 8) {
        ensureDiscovery();
        if (!findOutputDevice(chosenDevice, NO)) {
            // One pending retry is enough: a settings change during the wait calls us again, and
            // each call would otherwise start its own chain of retries.
            static BOOL retryPending = NO;
            if (!retryPending) {
                retryPending = YES;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    retryPending = NO;
                    startLibrespot();
                });
            }
            return;
        }
    }
    gLaunchSignature = launchSignature(config);
    NSString *connectName = effectiveConnectName(config);
    CFPreferencesSetAppValue(CFSTR("EffectiveConnectName"), (__bridge CFStringRef)connectName, (__bridge CFStringRef)kPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
    if (![config[@"Enabled"] boolValue]) {
        // Stay alive: the Settings pane can switch it on again.
        cblog(@"disabled in preferences, librespot is not started");
        publishState(@"disabled");
        return;
    }
    if (!chosenDevice.length) {
        // Without an AirPlay device the audio would come out of the iPhone: advertise nothing.
        cblog(@"no AirPlay device chosen, librespot is not started");
        publishState(@"setup");
        return;
    }

    NSString *logPath = librespotLogPath();
    [[NSFileManager defaultManager] createDirectoryAtPath:kDataDir withIntermediateDirectories:YES attributes:nil error:nil];
    rotateDaemonLog();
    rotateLibrespotLog(NO);  // no librespot is running at this point

    unlink(kStatePath.fileSystemRepresentation);  // a fresh librespot is inactive until it is selected
    unlink(kRoutePath.fileSystemRepresentation);
    gPublishedRoute = nil;

    // This daemon ignores SIGTERM / SIGINT / SIGHUP (it handles them itself); an ignored signal stays
    // ignored across exec, which is why librespot used to survive SIGTERM. Reset them for the child.
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    sigset_t allSignals, noSignals;
    sigfillset(&allSignals);
    sigemptyset(&noSignals);
    posix_spawnattr_setsigdefault(&attr, &allSignals);
    posix_spawnattr_setsigmask(&attr, &noSignals);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK);
    // Same level as the foreground app: otherwise the audio stutters while the phone is being used.
    posix_spawnattr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE);

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);

    NSArray<NSString *> *args = @[
        kLibrespotPath,
        @"--name", connectName,
        @"--cache", kDataDir,
        @"--disable-audio-cache",
        @"--backend", @"rodio",
        @"--bitrate", validBitrate(config[@"Bitrate"]),
    ];
    if ([config[@"Verbose"] boolValue]) args = [args arrayByAddingObject:@"-v"];
    char **argv = calloc(args.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < args.count; i++) argv[i] = strdup(args[i].UTF8String);

    NSMutableArray<NSString *> *env = [NSMutableArray array];
    for (char **e = environ; *e; e++) [env addObject:[NSString stringWithUTF8String:*e]];
    [env addObject:@"CB_VOLUME_BRIDGE=1"];
    [env addObject:@"CB_PASSTHROUGH_VOLUME=1"];
    [env addObject:@"CB_NOW_PLAYING=1"];
    // The route volume is read when the system says it changed (KVO of outputVolume), not every 250 ms
    // (VolumePolling brings the polling back).
    if (![config[@"VolumePolling"] boolValue]) [env addObject:@"CB_VOLUME_NOTIFY=1"];
    if (![config[@"Verbose"] boolValue]) {
        // Track titles are logged at info level by librespot_playback::player; keep them out of the
        // log unless Verbose is on. libmdns warns about every interface it cannot send on.
        [env addObject:@"RUST_LOG=libmdns=error,librespot=info,librespot_playback::player=warn"];
    }
    [env addObject:[@"CB_STATE_FILE=" stringByAppendingString:kStatePath]];
    // With the route managed, librespot waits for "ready" in this file before it syncs the volume.
    if ([config[@"ManageRoute"] boolValue]) [env addObject:[@"CB_ROUTE_FILE=" stringByAppendingString:kRoutePath]];
    if ([config[@"ManageRoute"] boolValue] && [config[@"AirPlayGuard"] boolValue]) {
        [env addObject:@"CB_REQUIRE_AIRPLAY=1"];
        [env addObject:[NSString stringWithFormat:@"CB_GUARD_RESUME_SECS=%d", MAX(1, [config[@"GuardResumeSeconds"] intValue])]];
    }
    char **envp = calloc(env.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < env.count; i++) envp[i] = strdup(env[i].UTF8String);

    pid_t pid = 0;
    int rc = posix_spawn(&pid, kLibrespotPath.fileSystemRepresentation, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    for (NSUInteger i = 0; argv[i]; i++) free(argv[i]);
    for (NSUInteger i = 0; envp[i]; i++) free(envp[i]);
    free(argv);
    free(envp);

    if (rc != 0) {
        cblog(@"posix_spawn librespot failed: %s", strerror(rc));
        scheduleRestart();
        return;
    }

    gChild = pid;
    gChildStart = [NSDate date];

    cblog(@"librespot started (pid %d, name \"%@\")", pid, connectName);
    // Replaces "disabled" / "setup" from an earlier start; routeTick only publishes on a change.
    publishState(gActive ? @"active" : @"inactive");

    gChildSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gChildSource, ^{
        int status = 0;
        waitpid(pid, &status, 0);
        cblog(@"librespot exited (status 0x%x)", status);
        dispatch_source_cancel(gChildSource);
        gChildSource = nil;
        gChild = 0;
        unlink(kStatePath.fileSystemRepresentation);
        if (-[gChildStart timeIntervalSinceNow] > 60) gBackoff = 2;
        scheduleRestart();
    });
    dispatch_resume(gChildSource);
}

// --- output route ---
//
// The route is only held while this device is the active Spotify Connect device (librespot writes
// "active" / "inactive" to the state file). When playback moves to another device the route is
// given back, so the HomePod is free for everything else.

static MRAVRoutingDiscoverySession *gDiscovery = nil;
static NSString *gRouteState = nil;

static void noteRouteState(NSString *state) {
    if ([gRouteState isEqualToString:state]) return;
    gRouteState = state;
    cblog(@"route: %@", state);
}

// Polled twice a second: the file is only read again when it has changed (librespot replaces it by
// rename, so the inode / mtime change).
static BOOL readActive(void) {
    static ino_t lastIno = 0;
    static struct timespec lastMtime;
    static BOOL lastValue = NO;
    struct stat st;
    if (stat(kStatePath.fileSystemRepresentation, &st) != 0) {
        lastIno = 0;
        return lastValue = NO;
    }
    if (st.st_ino == lastIno && st.st_mtimespec.tv_sec == lastMtime.tv_sec && st.st_mtimespec.tv_nsec == lastMtime.tv_nsec) return lastValue;
    lastIno = st.st_ino;
    lastMtime = st.st_mtimespec;
    NSString *state = [NSString stringWithContentsOfFile:kStatePath encoding:NSUTF8StringEncoding error:nil];
    return lastValue = [state hasPrefix:@"active"];
}

// These are private APIs, verified on iOS 15.8 only. If another iOS has changed them, a missing
// selector would crash the daemon and launchd would restart it over and over: check once, log, and
// leave the route alone instead.
static BOOL mediaRemoteAvailable(void) {
    static BOOL available = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class discovery = NSClassFromString(@"MRAVRoutingDiscoverySession");
        Class context = NSClassFromString(@"MRAVOutputContext");
        Class device = NSClassFromString(@"MRAVOutputDevice");
        available = discovery && context && device
            && [discovery respondsToSelector:@selector(discoverySessionWithEndpointFeatures:)]
            && [context respondsToSelector:@selector(sharedSystemAudioContext)]
            && [context instancesRespondToSelector:@selector(outputDevices)]
            && [context instancesRespondToSelector:@selector(setOutputDevices:withCallbackQueue:block:)]
            && [device instancesRespondToSelector:@selector(name)]
            && [device instancesRespondToSelector:@selector(uid)]
            && [device instancesRespondToSelector:@selector(isLocalDevice)];
        if (!available) cblog(@"MediaRemote routing API not available on this iOS version: the AirPlay route is not managed");
    });
    return available;
}

// Discovery is kept running so that the device is already known when the Connect device is selected.
static BOOL gDiscoveryUnsupported = NO;
static NSDate *gDiscoveryStart = nil;

static void ensureDiscovery(void) {
    if (gDiscovery || gDiscoveryUnsupported || !mediaRemoteAvailable()) return;
    MRAVRoutingDiscoverySession *session = [NSClassFromString(@"MRAVRoutingDiscoverySession") discoverySessionWithEndpointFeatures:1];
    // The session is an instance of a subclass: its methods cannot be checked on the class.
    if (![session respondsToSelector:@selector(setDiscoveryMode:)] || ![session respondsToSelector:@selector(availableOutputDevices)]) {
        cblog(@"MediaRemote discovery API not available on this iOS version: the AirPlay route is not managed");
        gDiscoveryUnsupported = YES;
        return;
    }
    gDiscovery = session;
    gDiscoveryStart = [NSDate date];
    // Mode 1 sees nothing but the built-in speaker while the screen is off (the device appeared
    // only after opening the AirPlay picker); mode 2, which the picker uses, does not have that problem.
    [gDiscovery setDiscoveryMode:2];
}

static MRAVOutputDevice *findOutputDevice(NSString *wanted, BOOL local) {
    // The discovery order is not stable: when several devices match, take the one with the
    // smallest uid so that the same device is chosen every time.
    MRAVOutputDevice *exact = nil, *partial = nil;
    for (MRAVOutputDevice *device in [gDiscovery availableOutputDevices]) {
        if (local) {
            if (device.isLocalDevice) return device;
        } else if (!device.isLocalDevice && wanted.length && device.name.length) {
            if ([device.name caseInsensitiveCompare:wanted] == NSOrderedSame) {  // exact name wins
                if (!exact || [device.uid compare:exact.uid] == NSOrderedAscending) exact = device;
            } else if ([device.name rangeOfString:wanted options:NSCaseInsensitiveSearch].location != NSNotFound) {
                if (!partial || [device.uid compare:partial.uid] == NSOrderedAscending) partial = device;
            }
        }
    }
    return exact ?: partial;
}

// The name of this iPhone as set in Settings > General > About.
static NSString *iPhoneName(void) {
    NSString *name = nil;  // not cached: a rename in Settings is picked up at the next librespot start
    void *handle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_NOW);
    typedef CFTypeRef (*MGCopyAnswerFn)(CFStringRef);
    MGCopyAnswerFn copyAnswer = handle ? (MGCopyAnswerFn)dlsym(handle, "MGCopyAnswer") : NULL;
    CFTypeRef value = copyAnswer ? copyAnswer(CFSTR("UserAssignedDeviceName")) : NULL;
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        name = (__bridge_transfer NSString *)value;
    } else {
        if (value) CFRelease(value);
        char host[256] = {0};
        gethostname(host, sizeof(host) - 1);
        name = [@(host) stringByReplacingOccurrencesOfString:@".local" withString:@""];
    }
    return name.length ? name : @"iPhone";
}

// "<AirPlay device> (via <this iPhone>)" unless a name is set in the preferences.
static NSString *effectiveConnectName(NSDictionary *config) {
    NSString *custom = [[config[@"ConnectName"] description] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (custom.length) return custom;
    NSString *wanted = [config[@"OutputDeviceName"] description];
    MRAVOutputDevice *target = (gDiscovery && wanted.length) ? findOutputDevice(wanted, NO) : nil;
    NSString *suffix = [NSString stringWithFormat:@" (via %@)", iPhoneName()];
    if (!target && wanted.length) {
        // Not discovered (yet): keep the name used last time if it came from this device, so that the
        // Spotify device (its id is derived from the name) does not change with discovery timing.
        CFPropertyListRef previous = CFPreferencesCopyAppValue(CFSTR("EffectiveConnectName"), (__bridge CFStringRef)kPrefsDomain);
        NSString *last = (__bridge_transfer id)previous;
        if ([last isKindOfClass:[NSString class]] && [last hasSuffix:suffix] && last.length > suffix.length
            && [last rangeOfString:wanted options:NSCaseInsensitiveSearch].location != NSNotFound) return last;
    }
    NSString *base = target ? target.name : (wanted.length ? wanted : @"AirPlay");
    return [base stringByAppendingString:suffix];
}

// For the picker in the Settings pane.
static NSArray<NSString *> *gPublishedDevices = nil;

static void publishOutputDevices(void) {
    NSMutableSet *names = [NSMutableSet set];
    for (MRAVOutputDevice *device in [gDiscovery availableOutputDevices]) {
        if (!device.isLocalDevice && device.name.length) [names addObject:device.name];
    }
    NSArray *sorted = [[names allObjects] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    if ([sorted isEqual:gPublishedDevices]) return;
    gPublishedDevices = sorted;
    CFPreferencesSetAppValue(CFSTR("AvailableOutputDevices"), (__bridge CFArrayRef)sorted, (__bridge CFStringRef)kPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kPrefsDomain);
}

// Selecting an AirPlay device takes a few seconds; asking again while it is still connecting can
// restart the connection, so a new request waits for kSelectRetryInterval.
static const NSTimeInterval kSelectRetryInterval = 8;
static NSDate *gLastSelect = nil;

// gHolding: we put the route on an output device and have not given it back yet.
// When the Connect device is deselected the route is kept for ReleaseDelay seconds: re-selecting
// the AirPlay device takes a few seconds, and short interruptions (a reconnect, switching to
// another device and back) should not cost a reconnect. A new selection cancels the release.
static BOOL gHolding = NO;
static NSDate *gReleaseAt = nil;  // when the next release attempt is due

// The devices we may have put the route on (uid and name from discovery). They are what gets
// released, whatever the settings say by then. They are also written to the "holding" marker: the
// route stays on the AirPlay device when this daemon dies (crash, upgrade, launchctl unload), so the
// next daemon finds out from the marker what the previous one still owed. The marker is only
// removed when the release worked or it is clear that none of the devices holds the route.
//
// A record is replaced only once the system output really is the new device: while moving from A
// to B, A stays on record (next to B, in case the selection takes effect and we die before we
// notice), so that a failed selection of B does not lose A.
static NSString *const kHoldingPath = @"/var/mobile/Library/ConnectBridge/holding";
static NSArray<NSDictionary *> *gOwned = nil;  // @[ @{ uid, name }, ... ]

static void publishRouteReadiness(NSString *state) {
    if ([gPublishedRoute isEqualToString:state]) return;
    if ([state writeToFile:kRoutePath atomically:YES encoding:NSUTF8StringEncoding error:nil]) gPublishedRoute = state;
}

static NSDictionary *ownedEntry(MRAVOutputDevice *device) {
    return @{ @"uid": device.uid ?: @"", @"name": device.name ?: @"" };
}

static void writeOwnership(void) {
    if (![@{ @"devices": gOwned } writeToFile:kHoldingPath atomically:YES]) cblog(@"route: could not write %@", kHoldingPath);
}

// The system output is `device` now: it is the only one on record.
static void confirmOwnership(MRAVOutputDevice *device) {
    NSDictionary *entry = ownedEntry(device);
    static NSDate *lastTouch = nil;
    if (gOwned.count == 1 && [gOwned[0] isEqual:entry]) {
        // The marker's age tells how long a daemon has been gone: keep it fresh while we hold.
        if (!lastTouch || -[lastTouch timeIntervalSinceNow] > 600) {  // nil: the record came from an earlier process
            lastTouch = [NSDate date];
            utimes(kHoldingPath.fileSystemRepresentation, NULL);
        }
        return;
    }
    gOwned = @[entry];
    lastTouch = [NSDate date];
    writeOwnership();
}

// `device` is about to be selected: keep what is on record and add it.
static void addPendingOwnership(MRAVOutputDevice *device) {
    NSDictionary *entry = ownedEntry(device);
    if ([gOwned containsObject:entry]) return;
    gOwned = [(gOwned ?: @[]) arrayByAddingObject:entry];
    writeOwnership();
}

static void forgetOwnership(void) {
    gOwned = nil;
    gHolding = NO;
    gReleaseAt = nil;
    unlink(kHoldingPath.fileSystemRepresentation);
    publishRouteReadiness(@"none");
}

// The marker (see marker.h); an old-format one is rewritten in the current format, keeping its age.
static NSArray<NSDictionary *> *loadOwnership(BOOL *stale) {
    BOOL migrated = NO, invalid = NO;
    NSArray<NSDictionary *> *devices = cb_marker_load(kHoldingPath, stale, &migrated, &invalid);
    if (invalid) {
        cblog(@"route: the holding marker is unreadable, ignoring it");  // e.g. empty: nothing to say which device
        unlink(kHoldingPath.fileSystemRepresentation);
    } else if (migrated) {
        cblog(@"route: converted the holding marker to the current format");
    }
    return devices;
}

// Has discovery settled about the devices of a name? A second device of that name may just not
// have been found yet, so a name alone is not trusted before: the devices of that name (their
// uids) must be unchanged over several snapshots in a row.
static NSMutableDictionary<NSString *, NSDictionary *> *gNameWatch = nil;  // name -> @{ sig, count, since }

static void updateDiscoveryWatch(void) {
    if (!gDiscovery || !gOwned.count) return;
    if (!gNameWatch) gNameWatch = [NSMutableDictionary dictionary];
    for (NSDictionary *owned in gOwned) {
        NSString *name = owned[@"name"];
        NSMutableArray *uids = [NSMutableArray array];
        for (MRAVOutputDevice *device in [gDiscovery availableOutputDevices]) {
            if (!device.isLocalDevice && [device.name isEqual:name]) [uids addObject:device.uid ?: @""];
        }
        NSString *sig = [[uids sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
        NSDictionary *watch = gNameWatch[name];
        if ([watch[@"sig"] isEqual:sig]) {
            gNameWatch[name] = @{ @"sig": sig, @"count": @([watch[@"count"] intValue] + 1), @"since": watch[@"since"] };
        } else {
            gNameWatch[name] = @{ @"sig": sig, @"count": @1, @"since": [NSDate date] };
        }
    }
}

static BOOL discoveryStable(NSString *name) {
    NSDictionary *watch = gNameWatch[name];
    if (!watch || !gDiscoveryStart) return NO;
    return cb_discovery_stable([watch[@"count"] intValue], -[watch[@"since"] timeIntervalSinceNow], -[gDiscoveryStart timeIntervalSinceNow]);
}

// Is the system output the target? The context reports the selected device with a different uid
// than discovery does, so a uid match is not always possible; a name alone only counts when
// discovery has settled and no other device has that name (see cb_current_match).
static cb_match currentOutputMatch(MRAVOutputContext *context, MRAVOutputDevice *target) {
    NSArray *outputs = [context outputDevices];
    // Keep the strings alive in arrays while their C pointers are in use (as releaseOwnedRoute does).
    NSMutableArray<NSString *> *uids = [NSMutableArray array], *names = [NSMutableArray array];
    for (MRAVOutputDevice *current in outputs) {
        [uids addObject:current.uid ?: @""];
        [names addObject:current.name ?: @""];
    }
    const char *uidv[uids.count + 1], *namev[names.count + 1];
    for (NSUInteger i = 0; i < uids.count; i++) { uidv[i] = uids[i].UTF8String; namev[i] = names[i].UTF8String; }
    size_t sameName = 0;
    for (MRAVOutputDevice *device in [gDiscovery availableOutputDevices]) {
        if (!device.isLocalDevice && [device.name isEqual:target.name]) sameName++;
    }
    NSString *targetUid = target.uid ?: @"", *targetName = target.name ?: @"";
    return cb_current_match(targetUid.UTF8String, targetName.UTF8String, uidv, namev, uids.count, discoveryStable(target.name), sameName);
}

static void holdRoute(void) {
    if (!mediaRemoteAvailable()) return;
    NSString *wanted = [currentConfig()[@"OutputDeviceName"] description];
    MRAVOutputDevice *target = findOutputDevice(wanted, NO);
    if (!target) {
        publishRouteReadiness(@"pending");
        noteRouteState([NSString stringWithFormat:@"\"%@\" not found", wanted]);
        return;
    }
    MRAVOutputContext *context = [NSClassFromString(@"MRAVOutputContext") sharedSystemAudioContext];
    cb_match current = currentOutputMatch(context, target);
    if (current == CB_MATCH_YES) {
        confirmOwnership(target);  // only now: the output has been seen on the device
        publishRouteReadiness(@"ready");
        noteRouteState([NSString stringWithFormat:@"\"%@\" selected", target.name]);
        gLastSelect = nil;
        return;
    }
    publishRouteReadiness(@"pending");
    addPendingOwnership(target);
    if (gLastSelect && -[gLastSelect timeIntervalSinceNow] < kSelectRetryInterval) return;
    gLastSelect = [NSDate date];
    if (gRouteState && [context outputDevices].count) {
        NSMutableArray *names = [NSMutableArray array];
        for (MRAVOutputDevice *current in [context outputDevices]) [names addObject:current.name ?: @"?"];
        cblog(@"route: the system output is %@, not \"%@\"", [names componentsJoinedByString:@", "], target.name);
    }
    if (current == CB_MATCH_AMBIGUOUS) cblog(@"route: \"%@\" may be the output but cannot be told from a device of the same name; not ready", target.name);
    noteRouteState([NSString stringWithFormat:@"selecting \"%@\"", target.name]);
    [context setOutputDevices:@[target] withCallbackQueue:dispatch_get_main_queue() block:^(void *error) {
        if (error) cblog(@"route: selecting \"%@\" failed", target.name);
    }];
}

static BOOL gReleaseInFlight = NO;
static int gReleaseAttempts = 0;
static unsigned gReleaseGeneration = 0;  // a result that arrives for an older request is ignored

static void scheduleReleaseRetry(void) {
    switch (cb_after_release(NO, gReleaseAttempts)) {
        case CB_AFTER_RETRY: {
            double delay = cb_retry_delay(gReleaseAttempts);
            cblog(@"route: release not done (attempt %d), trying again in %.0fs", gReleaseAttempts, delay);
            gReleaseAt = [NSDate dateWithTimeIntervalSinceNow:delay];
            break;
        }
        default:
            cblog(@"route: giving up releasing for now; it is tried again at the next start");
            gReleaseAt = nil;  // gOwned and the marker stay
            break;
    }
}

// Gives the output back to the built-in speaker, but only if the system output still is the device
// we put it on: if somebody moved it elsewhere meanwhile, it is left alone.
// blocking: used while exiting, when the main queue is not served any more; the result is known on
// return and a failure leaves the record for the next start. Otherwise the result is handled later
// (and a failure is retried with a growing delay).
static BOOL releaseOwnedRoute(BOOL blocking) {
    gLastSelect = nil;
    if (!gOwned.count) { forgetOwnership(); return YES; }
    gReleaseAttempts++;
    BOOL stale = NO;
    loadOwnership(&stale);  // the marker's age; the content is gOwned
    MRAVOutputContext *context = mediaRemoteAvailable() ? [NSClassFromString(@"MRAVOutputContext") sharedSystemAudioContext] : nil;

    NSMutableArray<NSString *> *uids = [NSMutableArray array], *names = [NSMutableArray array];
    for (MRAVOutputDevice *current in [context outputDevices]) {
        [uids addObject:current.uid ?: @""];
        [names addObject:current.name ?: @""];
    }
    const char *uidv[uids.count + 1], *namev[names.count + 1];
    for (NSUInteger i = 0; i < uids.count; i++) { uidv[i] = uids[i].UTF8String; namev[i] = names[i].UTF8String; }
    cb_match match = CB_MATCH_NO;
    NSString *ownedNames = nil;
    for (NSDictionary *owned in gOwned) {
        NSString *uid = owned[@"uid"], *name = owned[@"name"];
        BOOL known = NO;  // does discovery know this very device?
        size_t sameName = 0;
        for (MRAVOutputDevice *device in [gDiscovery availableOutputDevices]) {
            if (device.isLocalDevice) continue;
            if ([device.name isEqual:name]) sameName++;
            if (uid.length && [device.uid isEqual:uid]) known = YES;
        }
        match = cb_match_merge(match, cb_owner_match(uid.UTF8String, name.UTF8String, uidv, namev, uids.count, known, discoveryStable(name), sameName));
        ownedNames = ownedNames ? [ownedNames stringByAppendingFormat:@", %@", name] : name;
    }
    MRAVOutputDevice *local = mediaRemoteAvailable() ? findOutputDevice(nil, YES) : nil;
    gRouteState = nil;

    switch (cb_release_decide(mediaRemoteAvailable(), stale, match, local != nil)) {
        case CB_ACTION_CLEAR:
            noteRouteState(stale ? @"nothing to release (the record is old)" : @"nothing to release");
            forgetOwnership();
            return YES;
        case CB_ACTION_RETRY:
            if (!blocking) scheduleReleaseRetry();
            return NO;
        case CB_ACTION_RELEASE:
            break;
    }

    // Before the output moves: librespot must stop touching the volume while the route is going
    // away, not only after it has gone (it would read the built-in speaker's volume as a change).
    publishRouteReadiness(@"none");
    noteRouteState([NSString stringWithFormat:@"releasing \"%@\" (back to \"%@\")", ownedNames, local.name]);
    if (blocking) {
        // Wait on another queue: the callback cannot be delivered to the main queue we are blocking.
        // The box lives on the heap so that a late callback does not touch a dead stack frame.
        NSMutableDictionary *box = [NSMutableDictionary dictionary];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [context setOutputDevices:@[local] withCallbackQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0) block:^(void *error) {
            box[@"ok"] = @(error == NULL);
            dispatch_semaphore_signal(done);
        }];
        BOOL arrived = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0;
        BOOL ok = arrived && [box[@"ok"] boolValue];
        if (ok) forgetOwnership(); else cblog(@"route: releasing %@", arrived ? @"failed" : @"timed out");
        return ok;
    }

    unsigned generation = ++gReleaseGeneration;
    gReleaseInFlight = YES;
    NSMutableDictionary *settled = [NSMutableDictionary dictionary];  // result or timeout, whichever comes first
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *why) {
        if (settled[@"done"]) return;
        settled[@"done"] = @YES;
        if (generation != gReleaseGeneration) return;  // selected again meanwhile: hold has taken over
        gReleaseInFlight = NO;
        if (ok) {
            forgetOwnership();
        } else {
            cblog(@"route: releasing %@", why);
            scheduleReleaseRetry();
        }
    };
    [context setOutputDevices:@[local] withCallbackQueue:dispatch_get_main_queue() block:^(void *error) {
        finish(error == NULL, @"failed");
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ finish(NO, @"timed out"); });
    return NO;
}

// The previous daemon may have died holding the route (see gOwned). Discovery needs a moment to
// find the devices, and Connect may be selected again in the meantime (which cancels the release).
static void releaseLeftoverRoute(void) {
    BOOL stale = NO;
    NSArray<NSDictionary *> *record = loadOwnership(&stale);
    if (!record) return;
    NSString *names = [[record valueForKey:@"name"] componentsJoinedByString:@", "];
    if (![currentConfig()[@"ManageRoute"] boolValue]) {
        cblog(@"route: ManageRoute is off, dropping the record of \"%@\"", names);
        unlink(kHoldingPath.fileSystemRepresentation);
        return;
    }
    gOwned = record;
    cblog(@"route: the previous daemon did not release \"%@\", checking in 10s", names);
    gHolding = YES;
    gReleaseAt = [NSDate dateWithTimeIntervalSinceNow:10];
}

static void routeTick(void) {
    ensureDiscovery();
    updateDiscoveryWatch();
    static int ticks = 0;
    if (ticks++ % 6 == 0) publishOutputDevices();  // the picker does not need it twice a second
    NSDictionary *config = currentConfig();
    BOOL manage = [config[@"ManageRoute"] boolValue];

    static NSDate *lastHeartbeat = nil;
    if (!lastHeartbeat || -[lastHeartbeat timeIntervalSinceNow] > 30) {
        lastHeartbeat = [NSDate date];
        publishHeartbeat();
    }

    static NSDate *lastLogCheck = nil;
    if (!lastLogCheck || -[lastLogCheck timeIntervalSinceNow] > 3600) {
        lastLogCheck = [NSDate date];
        rotateDaemonLog();
        rotateLibrespotLog(gChild != 0);
    }
    NSTimeInterval delay = MAX(0, [config[@"ReleaseDelay"] doubleValue]);
    BOOL active = readActive();

    if (active != gActive) {
        gActive = active;
        publishState(active ? @"active" : @"inactive");
        if (active) {
            cblog(@"connect: selected on this device");
            gReleaseAt = nil;
            gReleaseAttempts = 0;
            gReleaseGeneration++;  // an unfinished release is cancelled; holdRoute selects the device again
            gReleaseInFlight = NO;
            gHolding = manage;
            if (manage) publishRouteReadiness(@"pending");  // until holdRoute has seen the output on the device
            if (!manage && gOwned) forgetOwnership();  // ManageRoute was switched off: the old record is moot
        } else if (gHolding) {
            publishRouteReadiness(@"none");
            cblog(@"connect: not selected any more, releasing the route in %.0fs", delay);
            gReleaseAt = [NSDate dateWithTimeIntervalSinceNow:delay];
        } else {
            cblog(@"connect: not selected any more");
        }
    }

    if (!gHolding) return;
    if (gActive) {
        holdRoute();
    } else if (gReleaseAt && [gReleaseAt timeIntervalSinceNow] <= 0 && !gReleaseInFlight) {
        gReleaseAt = nil;
        releaseOwnedRoute(NO);
    }
}

// --- lifecycle ---

static void stopAndExit(void) {
    gStopping = YES;
    cblog(@"stopping%@", gOwned ? @" (releasing the route)" : @"");
    if (gChild) {
        BOOL reaped = NO;
        kill(gChild, SIGTERM);
        for (int i = 0; i < 10 && !reaped; i++) {  // up to ~1s
            int status;
            if (waitpid(gChild, &status, WNOHANG) == gChild) reaped = YES;
            else usleep(100 * 1000);
        }
        if (!reaped) kill(gChild, SIGKILL);  // never signal a pid that has been reaped: it may be reused
        gChild = 0;
    }
    unlink(kStatePath.fileSystemRepresentation);
    if (gOwned) releaseOwnedRoute(YES);  // do not leave the speaker held by a daemon that is gone; on failure the marker stays
    publishState(@"stopped");  // the pane shows "Not running"
    cblog(@"stopped");
    exit(0);
}

static void installSignalHandler(int sig, void (^handler)(void)) {
    signal(sig, SIG_IGN);
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sig, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(source, handler);
    dispatch_resume(source);
    CFRetain((__bridge CFTypeRef)source);  // keep alive for the life of the process
}

// Logs changes of the network connection, to tell dropped Spotify connections caused by the
// network from the ones caused by something else.
static void reachabilityChanged(SCNetworkReachabilityRef target, SCNetworkReachabilityFlags flags, void *info) {
    cblog(@"network: %@ (flags 0x%x%@)", (flags & kSCNetworkReachabilityFlagsReachable) ? @"reachable" : @"unreachable", flags,
          (flags & kSCNetworkReachabilityFlagsIsWWAN) ? @", cellular" : @"");
}

static void watchNetwork(void) {
    struct sockaddr_in any = {0};
    any.sin_len = sizeof(any);
    any.sin_family = AF_INET;
    SCNetworkReachabilityRef target = SCNetworkReachabilityCreateWithAddress(NULL, (const struct sockaddr *)&any);
    if (!target) return;
    SCNetworkReachabilitySetCallback(target, reachabilityChanged, NULL);
    SCNetworkReachabilityScheduleWithRunLoop(target, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
}

static void applyPreferences(BOOL forceRestart) {
    reloadConfig();  // also for the settings that do not need a restart (ReleaseDelay, ...)
    NSDictionary *config = currentConfig();
    BOOL changed = ![launchSignature(config) isEqualToString:gLaunchSignature ?: @""];
    if (!forceRestart && !changed) return;
    cblog(@"%@: restarting librespot", forceRestart ? @"restart requested" : @"preferences changed");
    if (gChild) {
        gRestartRequested = YES;
        terminateChild();  // the exit handler starts it again with the new settings
    } else {
        startLibrespot();
    }
}

static void darwinCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    BOOL restart = [(__bridge NSString *)name isEqualToString:kRestartNotification];
    cblog(@"notification: %@", (__bridge NSString *)name);
    // Give cfprefsd a moment to hand out the new values.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        applyPreferences(restart);
    });
}

int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);

        installSignalHandler(SIGTERM, ^{ stopAndExit(); });
        installSignalHandler(SIGINT, ^{ stopAndExit(); });
        // Sent by prerm before the service is unloaded: launchctl unload does not give the daemon
        // the chance to clean up, so the route is released on request instead. The route is not held
        // again while Connect stays selected (gHolding is off until the selection changes): prerm
        // relies on that for the seconds before the unload. Sent by hand to a running service, it
        // therefore leaves the route released until Connect is selected again.
        installSignalHandler(SIGUSR1, ^{
            cblog(@"SIGUSR1: releasing the route");
            // Stop holding first, whether or not anything is on record yet or the release works:
            // otherwise routeTick selects the device again (it may only just have been discovered,
            // or a failed release leaves gHolding on) before the service is unloaded.
            gHolding = NO;
            gReleaseAt = nil;
            gReleaseInFlight = NO;
            gReleaseGeneration++;  // the result of an unfinished release is ignored
            if (gOwned) releaseOwnedRoute(YES);  // on failure the record stays and the next start retries
        });
        installSignalHandler(SIGHUP, ^{
            cblog(@"SIGHUP: restarting librespot with the current preferences");
            reloadConfig();
            if (gChild) {
                gRestartRequested = YES;
                terminateChild();
            } else {
                startLibrespot();  // nothing to stop; do not leave a stale restart request behind
            }
        });

        // Everything we (and librespot) create is private to the mobile user: the data directory holds
        // the stored Spotify credentials.
        umask(077);
        [[NSFileManager defaultManager] createDirectoryAtPath:kDataDir withIntermediateDirectories:YES attributes:nil error:nil];
        chmod(kDataDir.fileSystemRepresentation, 0700);
        for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kDataDir error:nil]) {
            NSString *path = [kDataDir stringByAppendingPathComponent:name];
            BOOL isDirectory = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory) chmod(path.fileSystemRepresentation, 0600);
        }
        openDaemonLog();
        cblog(@"connectbridged starting");
        publishState(@"inactive");
        watchNetwork();
        ensureDiscovery();
        startLibrespot();
        releaseLeftoverRoute();

        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, darwinCallback, (__bridge CFStringRef)kPrefsNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(darwin, NULL, darwinCallback, (__bridge CFStringRef)kRestartNotification, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { routeTick(); }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}

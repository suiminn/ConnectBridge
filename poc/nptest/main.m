// nptest: plays a sine wave and publishes Now Playing info + remote commands, to find out what the
// system needs before it accepts a command-line process as the Now Playing application.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        double seconds = argc > 1 ? atof(argv[1]) : 40;
        NSLog(@"bundle id: %@", [[NSBundle mainBundle] bundleIdentifier]);

        NSError *err = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayback error:&err];
        [session setActive:YES error:&err];

        AVAudioEngine *engine = [AVAudioEngine new];
        AVAudioFormat *fmt = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
        __block double phase = 0;
        AVAudioSourceNode *src = [[AVAudioSourceNode alloc] initWithFormat:fmt
            renderBlock:^OSStatus(BOOL *silence, const AudioTimeStamp *ts, AVAudioFrameCount frames, AudioBufferList *abl) {
                for (AVAudioFrameCount f = 0; f < frames; f++) {
                    float v = 0.05f * (float)sin(phase);
                    phase += 2 * M_PI * 440.0 / 44100.0;
                    for (UInt32 b = 0; b < abl->mNumberBuffers; b++) ((float *)abl->mBuffers[b].mData)[f] = v;
                }
                return noErr;
            }];
        [engine attachNode:src];
        [engine connect:src to:engine.mainMixerNode format:fmt];
        [engine startAndReturnError:&err];

        MPRemoteCommandCenter *center = [MPRemoteCommandCenter sharedCommandCenter];
        for (MPRemoteCommand *c in @[center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.nextTrackCommand, center.previousTrackCommand]) {
            c.enabled = YES;
            [c addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
                NSLog(@"REMOTE COMMAND: %@", e.command);
                return MPRemoteCommandHandlerStatusSuccess;
            }];
        }
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = @{
            MPMediaItemPropertyTitle: @"nptest tone",
            MPMediaItemPropertyArtist: @"ConnectBridge",
            MPMediaItemPropertyPlaybackDuration: @(seconds),
            MPNowPlayingInfoPropertyElapsedPlaybackTime: @0,
            MPNowPlayingInfoPropertyPlaybackRate: @1,
        };
        [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStatePlaying;
        NSLog(@"published, playing %.0fs", seconds);

        // PHASES (env): at 8 s the state becomes "paused" while the audio engine keeps running;
        // at 16 s the engine is stopped as well. Used to see what makes the system say "playing".
        if (getenv("PHASES")) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = @{
                    MPMediaItemPropertyTitle: @"nptest tone",
                    MPNowPlayingInfoPropertyElapsedPlaybackTime: @8,
                    MPNowPlayingInfoPropertyPlaybackRate: @0,
                };
                [MPNowPlayingInfoCenter defaultCenter].playbackState = MPNowPlayingPlaybackStatePaused;
                NSLog(@"phase 2: state paused, engine still running");
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [engine stop];
                NSLog(@"phase 3: engine stopped");
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
        [[NSRunLoop mainRunLoop] run];
    }
    return 0;
}

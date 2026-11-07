#import <Foundation/Foundation.h>
#import <Preferences/PSSpecifier.h>
#import "CBRootListController.h"

// connectbridged publishes its state in the same preferences domain: RuntimeState,
// EffectiveConnectName and AvailableOutputDevices (the AirPlay devices it has discovered).
// Not declared in the (old) public headers.
@interface PSSpecifier (ConnectBridge)
- (void)setValues:(NSArray *)values titles:(NSArray *)titles;
@end

static NSString *const kDomain = @"com.sui827.connectbridge";
static NSString *const kRestartNotification = @"com.sui827.connectbridge/restart";

static id PublishedValue(NSString *key) {
	CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
	return (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)kDomain);
}

// A hand-edited plist can hold any type; messaging the wrong one (length, isEqualToString:) would
// crash the Settings pane every time it is opened. nil unless the value is a string.
static NSString *PublishedString(NSString *key) {
	id value = PublishedValue(key);
	return [value isKindOfClass:[NSString class]] ? value : nil;
}

@implementation CBRootListController

- (NSArray *)specifiers {
	if (!_specifiers) {
		_specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
		[self fillOutputDevices];
	}
	return _specifiers;
}

// The picker lists the AirPlay devices that are around right now, plus the current choice so that
// it stays visible (and selectable) while that device is offline.
- (void)fillOutputDevices {
	PSSpecifier *picker = [self specifierForID:@"outputDevice"];
	if (!picker) return;
	NSMutableArray<NSString *> *values = [NSMutableArray arrayWithObject:@""];
	NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithObject:@"Not Selected"];
	id published = PublishedValue(@"AvailableOutputDevices");
	if ([published isKindOfClass:[NSArray class]]) {
		for (id name in published) {
			if (![name isKindOfClass:[NSString class]] || ![name length]) continue;
			[values addObject:name];
			[titles addObject:name];
		}
	}
	NSString *current = PublishedString(@"OutputDeviceName");
	if (current.length && ![values containsObject:current]) {
		[values addObject:current];
		[titles addObject:[current stringByAppendingString:@" (not found)"]];
	}
	[picker setValues:values titles:titles];
}

- (void)viewWillAppear:(BOOL)animated {
	[super viewWillAppear:animated];
	// Status, name and device list may have changed since the pane was last shown.
	[self reloadSpecifiers];  // rebuilds the specifiers; -specifiers refills the device list
}

- (id)statusText:(PSSpecifier *)specifier {
	NSString *state = PublishedString(@"RuntimeState");
	// connectbridged stamps the time every ~30 s; an old stamp means it is not running (a crash leaves
	// the last state behind).
	id beat = PublishedValue(@"RuntimeHeartbeat");
	if (![beat isKindOfClass:[NSNumber class]] || [[NSDate date] timeIntervalSince1970] - [beat doubleValue] > 120) return @"Not running";
	if ([state isEqualToString:@"active"]) return @"Playing target";
	if ([state isEqualToString:@"inactive"]) return @"Idle";
	if ([state isEqualToString:@"disabled"]) return @"Disabled";
	if ([state isEqualToString:@"setup"]) return @"Choose an AirPlay device";
	return @"Not running";
}

- (id)connectNameText:(PSSpecifier *)specifier {
	return PublishedString(@"EffectiveConnectName") ?: @"-";
}

- (void)restartService:(PSSpecifier *)specifier {
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
		(__bridge CFStringRef)kRestartNotification, NULL, NULL, YES);
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Restarting"
		message:@"The device reappears in Spotify in a few seconds." preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self reloadSpecifiers]; });
}

@end

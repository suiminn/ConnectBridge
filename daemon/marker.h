// Reading and writing the "holding" marker (the devices the daemon may have put the route on).
// Foundation only, so that it can be tested on a Mac (scripts/test-daemon.sh).
//
//   current:  { devices = ( { uid = "..."; name = "..."; }, ... ); }
//   v0.1-dev: { uid = "..."; name = "..."; }            (one device; read as a list of one)
//
// A marker that is read in the old form is rewritten in the current one, but keeps its old
// modification time: the time stands for how long a daemon has been gone, and a rewrite must not
// make an old marker look fresh.

#ifndef CB_MARKER_H
#define CB_MARKER_H

#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include "route_policy.h"

// One valid entry: a non-empty string name; the uid is "" unless it is a string.
static inline NSDictionary *cb_marker_entry(id entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    id name = entry[@"name"], uid = entry[@"uid"];
    if (![name isKindOfClass:[NSString class]] || ![name length]) return nil;
    return @{ @"uid": [uid isKindOfClass:[NSString class]] ? uid : @"", @"name": name };
}

// The valid devices of a marker's content, and whether it was in the old single-device form.
static inline NSArray<NSDictionary *> *cb_marker_devices(id content, BOOL *legacy, BOOL *cleaned) {
    if (legacy) *legacy = NO;
    if (cleaned) *cleaned = NO;
    if (![content isKindOfClass:[NSDictionary class]]) return @[];
    NSMutableArray *devices = [NSMutableArray array];
    id list = content[@"devices"];
    if ([list isKindOfClass:[NSArray class]]) {
        for (id entry in list) {
            NSDictionary *valid = cb_marker_entry(entry);
            if (valid) [devices addObject:valid];
        }
        if (cleaned && devices.count != [list count]) *cleaned = YES;
    } else {
        NSDictionary *valid = cb_marker_entry(content);
        if (valid) [devices addObject:valid];
        if (legacy && valid) *legacy = YES;
    }
    return devices;
}

// Writes the marker in the current format. keep_age: when a marker exists, the new file gets its
// modification time (a record that this process has not confirmed must not look fresh because a
// device was added to it); a marker that does not exist yet, or keep_age NO, gets the current time.
static inline BOOL cb_marker_write(NSString *path, NSArray<NSDictionary *> *devices, BOOL keep_age) {
    struct stat st;
    BOOL had = keep_age && stat(path.fileSystemRepresentation, &st) == 0;
    if (![@{ @"devices": devices } writeToFile:path atomically:YES]) return NO;
    if (had) {
        struct timeval times[2] = {
            { .tv_sec = st.st_atimespec.tv_sec, .tv_usec = (__darwin_suseconds_t)(st.st_atimespec.tv_nsec / 1000) },
            { .tv_sec = st.st_mtimespec.tv_sec, .tv_usec = (__darwin_suseconds_t)(st.st_mtimespec.tv_nsec / 1000) },
        };
        utimes(path.fileSystemRepresentation, times);
    }
    return YES;
}

// Reads the marker at `path`. nil: no marker, or one that says nothing usable (the caller removes
// it when `*invalid` is set). Does not crash on any content.
static inline NSArray<NSDictionary *> *cb_marker_load(NSString *path, BOOL *stale, BOOL *migrated, BOOL *invalid) {
    if (stale) *stale = NO;
    if (migrated) *migrated = NO;
    if (invalid) *invalid = NO;
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return nil;
    BOOL legacy = NO, cleaned = NO;
    NSArray<NSDictionary *> *devices = cb_marker_devices([NSDictionary dictionaryWithContentsOfFile:path], &legacy, &cleaned);
    if (!devices.count) {
        if (invalid) *invalid = YES;
        return nil;
    }
    if (stale) *stale = cb_record_stale(difftime(time(NULL), st.st_mtime));  // the original time, before any rewrite
    if (legacy || cleaned) {
        if (cb_marker_write(path, devices, YES) && migrated) *migrated = YES;
    }
    return devices;
}

#endif

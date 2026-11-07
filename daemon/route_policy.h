// Decisions about giving the AirPlay route back, kept free of MediaRemote and Foundation so that
// they can be tested on a Mac (scripts/test-daemon.sh). connectbridged.m gathers the facts and
// carries out what is decided here.
//
// Rules:
//  - Only the device we put the route on (its uid and name when it was selected) is ever released,
//    not whatever the settings say now.
//  - The route is only touched while the current output is that device; if the user moved it
//    elsewhere, it is left alone and the record is dropped.
//  - The record (the "holding" marker) is dropped when the release succeeded or when it is clear
//    that the device does not hold the route. A failure keeps it, so that it is retried.

#ifndef CB_ROUTE_POLICY_H
#define CB_ROUTE_POLICY_H

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

typedef enum {
    CB_MATCH_NO,         // the current output is clearly another device
    CB_MATCH_UNKNOWN,    // the system reports no output at all: nothing can be said
    CB_MATCH_AMBIGUOUS,  // same name, but it cannot be told apart from another device of that name
    CB_MATCH_YES,        // the current output is the device we hold
} cb_match;
// The order is the strength of the evidence for "release": cb_match_merge() takes the larger one.

typedef enum {
    CB_ACTION_CLEAR,    // nothing (more) to release: drop the record
    CB_ACTION_RELEASE,  // select the built-in output now
    CB_ACTION_RETRY,    // cannot decide / do it yet: keep the record, try again later
} cb_action;

typedef enum {
    CB_AFTER_CLEAR,    // released: drop the record
    CB_AFTER_RETRY,    // failed: try again after cb_retry_delay()
    CB_AFTER_GIVE_UP,  // failed too often: keep the record for the next start, stop retrying
} cb_after;

enum { CB_MAX_RELEASE_ATTEMPTS = 8 };

// A record older than this is not trusted any more (the daemon has been gone for too long).
#define CB_RECORD_MAX_AGE_SECONDS (12 * 3600)

static inline bool cb_record_stale(double age_seconds) { return age_seconds > CB_RECORD_MAX_AGE_SECONDS; }

// Is what discovery says about a device name settled? Discovery fills up over time: a second
// device of the same name may simply not have been found yet. Settled means that discovery has been
// running for a while and that the devices of that name did not change over several snapshots in a
// row (a fixed wait alone does not tell that).
enum { CB_DISCOVERY_MIN_SNAPSHOTS = 6, CB_DISCOVERY_MIN_UNCHANGED_SECONDS = 3, CB_DISCOVERY_MIN_AGE_SECONDS = 5 };

static inline bool cb_discovery_stable(int unchanged_snapshots, double unchanged_seconds, double discovery_age_seconds) {
    return unchanged_snapshots >= CB_DISCOVERY_MIN_SNAPSHOTS
        && unchanged_seconds >= CB_DISCOVERY_MIN_UNCHANGED_SECONDS
        && discovery_age_seconds >= CB_DISCOVERY_MIN_AGE_SECONDS;
}

// Does one of the outputs the system reports (uids and names) belong to the held device?
// The system reports the selected device with a different uid than discovery does, so a uid match
// is certain when there is one (whatever discovery looks like). A name alone is only a match when
// discovery has settled (discovery_stable), knows the held device (discovery_has_owner) and no
// other device has that name; a name that more than one discovered device has is never enough.
// A different name is a clear "no", settled or not.
static inline cb_match cb_owner_match(const char *owner_uid, const char *owner_name,
                                      const char *const *uids, const char *const *names, size_t count,
                                      bool discovery_has_owner, bool discovery_stable, size_t same_name_in_discovery) {
    if (count == 0) return CB_MATCH_UNKNOWN;  // not "moved elsewhere": there is just nothing to look at
    bool name_hit = false;
    for (size_t i = 0; i < count; i++) {
        if (owner_uid && owner_uid[0] && uids[i] && strcmp(owner_uid, uids[i]) == 0) return CB_MATCH_YES;
        if (owner_name && owner_name[0] && names[i] && strcmp(owner_name, names[i]) == 0) name_hit = true;
    }
    if (!name_hit) return CB_MATCH_NO;
    if (same_name_in_discovery > 1) return CB_MATCH_AMBIGUOUS;
    return (discovery_stable && discovery_has_owner) ? CB_MATCH_YES : CB_MATCH_AMBIGUOUS;
}

// Is the current output the device we want to put the route on (the target)? The same question as
// above, asked before the route is held: only CB_MATCH_YES may be reported as "ready" (and start the
// volume sync). The target comes from discovery, so discovery knows it. Anything else (NO, UNKNOWN,
// AMBIGUOUS) keeps the route "pending"; selecting the target again stays throttled by the caller.
static inline cb_match cb_current_match(const char *target_uid, const char *target_name,
                                        const char *const *uids, const char *const *names, size_t count,
                                        bool discovery_stable, size_t same_name_in_discovery) {
    return cb_owner_match(target_uid, target_name, uids, names, count, true, discovery_stable, same_name_in_discovery);
}

// Several devices can be on record (see connectbridged.m: the previous owner is kept until the new
// one is confirmed as the output): the strongest evidence of any of them counts.
static inline cb_match cb_match_merge(cb_match a, cb_match b) { return a > b ? a : b; }

static inline cb_action cb_release_decide(bool api_available, bool record_stale, cb_match match, bool builtin_known) {
    if (!api_available) return CB_ACTION_CLEAR;  // the route was never managed on this iOS
    if (record_stale) return CB_ACTION_CLEAR;
    if (match == CB_MATCH_NO) return CB_ACTION_CLEAR;  // clearly somewhere else: not ours to touch
    if (match != CB_MATCH_YES) return CB_ACTION_RETRY;  // unknown / ambiguous: keep the record, look again
    return builtin_known ? CB_ACTION_RELEASE : CB_ACTION_RETRY;  // discovery has not found the built-in output yet
}

static inline cb_after cb_after_release(bool succeeded, int attempts_so_far) {
    if (succeeded) return CB_AFTER_CLEAR;
    return attempts_so_far >= CB_MAX_RELEASE_ATTEMPTS ? CB_AFTER_GIVE_UP : CB_AFTER_RETRY;
}

// 5, 10, 20, 40 and then 60 seconds: no hammering of MediaRemote and no log flood.
static inline double cb_retry_delay(int attempts_so_far) {
    double delay = 5;
    for (int i = 1; i < attempts_so_far && delay < 60; i++) delay *= 2;
    return delay > 60 ? 60 : delay;
}

#endif

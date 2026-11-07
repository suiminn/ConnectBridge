// Run with scripts/test-daemon.sh
#include <stdio.h>
#include "../route_policy.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL line %d: %s\n", __LINE__, #cond); failures++; } } while (0)

// One reported output (u, n), or none when both are NULL.
// `stable`: discovery has settled. Most checks below assume that; the unsettled ones say so.
static cb_match match_with(const char *uid, const char *name, const char *u, const char *n, bool in_discovery, bool stable, size_t same) {
    const char *uids[1] = {u}, *names[1] = {n};
    return cb_owner_match(uid, name, uids, names, (u || n) ? 1 : 0, in_discovery, stable, same);
}
static cb_match match(const char *uid, const char *name, const char *u, const char *n, bool in_discovery, size_t same) {
    return match_with(uid, name, u, n, in_discovery, true, same);
}

int main(void) {
    // A is held, the settings now say B: the record (A) is what is released.
    CHECK(match("uid-A", "HomePod A", "ctx-1", "HomePod A", true, 1) == CB_MATCH_YES);
    CHECK(cb_release_decide(true, false, CB_MATCH_YES, true) == CB_ACTION_RELEASE);

    // Moving to B: while the selection is open both are on record. B failed to select: the output
    // is still A. B succeeded: the output is B. Either way the strongest evidence decides.
    cb_match for_a = match("uid-A", "HomePod A", "ctx-1", "HomePod A", true, 1);
    cb_match for_b = match("uid-B", "Sonos B", "ctx-1", "HomePod A", true, 1);
    CHECK(for_a == CB_MATCH_YES && for_b == CB_MATCH_NO);
    CHECK(cb_release_decide(true, false, cb_match_merge(for_a, for_b), true) == CB_ACTION_RELEASE);  // B failed
    for_a = match("uid-A", "HomePod A", "ctx-2", "Sonos B", true, 1);
    for_b = match("uid-B", "Sonos B", "ctx-2", "Sonos B", true, 1);
    CHECK(for_a == CB_MATCH_NO && for_b == CB_MATCH_YES);
    CHECK(cb_release_decide(true, false, cb_match_merge(for_a, for_b), true) == CB_ACTION_RELEASE);  // B succeeded
    CHECK(cb_release_decide(true, false, cb_match_merge(CB_MATCH_NO, CB_MATCH_NO), true) == CB_ACTION_CLEAR);

    // The user moved the output elsewhere (built-in speaker, another AirPlay device): hands off,
    // and the record is dropped.
    CHECK(match("uid-A", "HomePod A", "ctx-2", "Speaker", true, 1) == CB_MATCH_NO);
    CHECK(match("uid-A", "HomePod A", "ctx-3", "Sonos Era 100", true, 1) == CB_MATCH_NO);
    CHECK(cb_release_decide(true, false, CB_MATCH_NO, true) == CB_ACTION_CLEAR);
    CHECK(cb_release_decide(true, false, CB_MATCH_NO, false) == CB_ACTION_CLEAR);  // even if discovery is not ready

    // The system reports no output at all: that does not say the route moved. Keep the record.
    CHECK(cb_owner_match("uid-A", "HomePod A", NULL, NULL, 0, true, true, 1) == CB_MATCH_UNKNOWN);
    CHECK(cb_release_decide(true, false, CB_MATCH_UNKNOWN, true) == CB_ACTION_RETRY);
    CHECK(cb_match_merge(CB_MATCH_UNKNOWN, CB_MATCH_NO) == CB_MATCH_UNKNOWN);  // one unknown keeps the record

    // Discovery is not ready when the release is due: keep the record and retry, then release.
    CHECK(cb_release_decide(true, false, CB_MATCH_YES, false) == CB_ACTION_RETRY);   // built-in output not found yet
    CHECK(cb_release_decide(true, false, CB_MATCH_YES, true) == CB_ACTION_RELEASE);
    CHECK(cb_release_decide(true, false, CB_MATCH_AMBIGUOUS, true) == CB_ACTION_RETRY);

    // uid match is certain, settled discovery or not.
    CHECK(match_with("uid-A", "HomePod", "uid-A", "HomePod", true, false, 1) == CB_MATCH_YES);
    CHECK(match_with("uid-A", "HomePod", "uid-A", "HomePod", false, false, 0) == CB_MATCH_YES);
    CHECK(match_with("uid-A", "HomePod", "uid-A", "HomePod", true, true, 2) == CB_MATCH_YES);
    // Name only, discovery not settled: a twin may not have been found yet.
    CHECK(match_with("uid-A", "HomePod", "ctx-9", "HomePod", true, false, 1) == CB_MATCH_AMBIGUOUS);
    CHECK(match_with("uid-A", "HomePod", "ctx-9", "HomePod", false, false, 0) == CB_MATCH_AMBIGUOUS);
    // Name only, settled and unique: a match. Settled but several of that name: never.
    CHECK(match_with("uid-A", "HomePod", "ctx-9", "HomePod", true, true, 1) == CB_MATCH_YES);
    CHECK(match_with("uid-A", "HomePod", "ctx-9", "HomePod", true, true, 2) == CB_MATCH_AMBIGUOUS);
    CHECK(match_with("uid-A", "HomePod", "ctx-9", "HomePod", true, false, 2) == CB_MATCH_AMBIGUOUS);
    // Settled, but the held device is not in discovery any more: not sure.
    CHECK(match_with("uid-A", "HomePod", "ctx-9", "HomePod", false, true, 1) == CB_MATCH_AMBIGUOUS);
    CHECK(match_with("", "HomePod", "ctx-9", "HomePod", true, true, 1) == CB_MATCH_YES);   // no uid recorded: name only
    CHECK(match_with(NULL, NULL, "ctx-9", "HomePod", true, true, 1) == CB_MATCH_NO);       // nothing recorded: no match
    // Another name is a clear no whatever discovery looks like.
    CHECK(match_with("uid-A", "HomePod", "ctx-9", "Sonos", false, false, 0) == CB_MATCH_NO);
    CHECK(match_with("uid-A", "HomePod", "ctx-9", "Speaker", true, false, 2) == CB_MATCH_NO);

    // The current output against the device we want (cb_current_match): ready only on a sure match.
    {
        const char *u[] = {"ctx-9"}, *n[] = {"HomePod"}, *uu[] = {"uid-A"};
        CHECK(cb_current_match("uid-A", "HomePod", uu, n, 1, false, 2) == CB_MATCH_YES);       // uid: sure, unsettled or not
        CHECK(cb_current_match("uid-A", "HomePod", u, n, 1, false, 1) == CB_MATCH_AMBIGUOUS);   // name only, unsettled
        CHECK(cb_current_match("uid-A", "HomePod", u, n, 1, true, 1) == CB_MATCH_YES);          // name only, settled, unique
        CHECK(cb_current_match("uid-A", "HomePod", u, n, 1, true, 2) == CB_MATCH_AMBIGUOUS);    // same name twice
        CHECK(cb_current_match("uid-A", "Sonos", u, n, 1, true, 1) == CB_MATCH_NO);
        CHECK(cb_current_match("uid-A", "HomePod", u, n, 0, true, 1) == CB_MATCH_UNKNOWN);      // no current output
        // Another device of the same name is the output (uid differs): never ready while two exist...
        CHECK(cb_current_match("uid-A", "HomePod", u, n, 1, true, 2) != CB_MATCH_YES);
        // ...and once the wanted one itself is the output (its uid shows up), ready.
        CHECK(cb_current_match("uid-A", "HomePod", uu, n, 1, true, 2) == CB_MATCH_YES);
    }

    // Several records, one of them unsure: the safe side wins (nothing is released or dropped).
    CHECK(cb_release_decide(true, false, cb_match_merge(CB_MATCH_NO, CB_MATCH_AMBIGUOUS), true) == CB_ACTION_RETRY);
    CHECK(cb_release_decide(true, false, cb_match_merge(CB_MATCH_AMBIGUOUS, CB_MATCH_UNKNOWN), true) == CB_ACTION_RETRY);
    CHECK(cb_release_decide(true, false, cb_match_merge(CB_MATCH_NO, CB_MATCH_NO), true) == CB_ACTION_CLEAR);

    // Discovery settles after enough identical snapshots over enough time, once it has run a while.
    CHECK(!cb_discovery_stable(5, 10, 60));   // too few snapshots
    CHECK(!cb_discovery_stable(6, 2.9, 60));  // changed a moment ago
    CHECK(!cb_discovery_stable(20, 10, 4));   // discovery just started
    CHECK(cb_discovery_stable(6, 3, 5));
    CHECK(cb_discovery_stable(100, 60, 600));

    // The release API fails or times out: the record stays, retried 5, 10, 20, 40, 60, 60... seconds.
    CHECK(cb_after_release(false, 1) == CB_AFTER_RETRY);
    CHECK(cb_retry_delay(1) == 5 && cb_retry_delay(2) == 10 && cb_retry_delay(3) == 20);
    CHECK(cb_retry_delay(4) == 40 && cb_retry_delay(5) == 60 && cb_retry_delay(50) == 60);
    CHECK(cb_after_release(false, CB_MAX_RELEASE_ATTEMPTS - 1) == CB_AFTER_RETRY);
    CHECK(cb_after_release(false, CB_MAX_RELEASE_ATTEMPTS) == CB_AFTER_GIVE_UP);  // kept for the next start

    // Normal SIGTERM / SIGUSR1 / ReleaseDelay release that works: the record is dropped.
    CHECK(cb_after_release(true, 1) == CB_AFTER_CLEAR);

    // A record left by a crashed daemon is used after the restart, unless it is too old.
    CHECK(cb_release_decide(true, true, CB_MATCH_YES, true) == CB_ACTION_CLEAR);

    // MediaRemote is not available (other iOS): the route was never managed, nothing to keep.
    CHECK(cb_release_decide(false, false, CB_MATCH_YES, true) == CB_ACTION_CLEAR);

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("route_policy: all checks passed\n");
    return 0;
}

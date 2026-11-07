// Run with scripts/test-daemon.sh
#import "../marker.h"

static int failures = 0;
#define CHECK(cond) do { if (!(cond)) { printf("FAIL line %d: %s\n", __LINE__, #cond); failures++; } } while (0)

static NSString *gDir;

static NSString *writePlist(NSString *name, id content) {
    NSString *path = [gDir stringByAppendingPathComponent:name];
    if ([content isKindOfClass:[NSString class]] || [content isKindOfClass:[NSData class]]) {
        NSData *data = [content isKindOfClass:[NSString class]] ? [content dataUsingEncoding:NSUTF8StringEncoding] : content;
        [data writeToFile:path atomically:YES];
    } else {
        [content writeToFile:path atomically:YES];
    }
    return path;
}

static void setAge(NSString *path, int hours) {
    time_t t = time(NULL) - hours * 3600;
    struct timeval times[2] = { { .tv_sec = t }, { .tv_sec = t } };
    utimes(path.fileSystemRepresentation, times);
}

int main(void) {
    @autoreleasepool {
        gDir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"cb-marker-%d", getpid()]];
        [[NSFileManager defaultManager] createDirectoryAtPath:gDir withIntermediateDirectories:YES attributes:nil error:nil];
        BOOL stale, migrated, invalid;

        // Current format: read as it is, not rewritten.
        NSString *p = writePlist(@"new", @{ @"devices": @[ @{ @"uid": @"u1", @"name": @"HomePod" }, @{ @"uid": @"u2", @"name": @"Sonos" } ] });
        NSArray *d = cb_marker_load(p, &stale, &migrated, &invalid);
        CHECK(d.count == 2 && [d[0][@"uid"] isEqual:@"u1"] && [d[1][@"name"] isEqual:@"Sonos"]);
        CHECK(!stale && !migrated && !invalid);

        // Old format: one device, read as a list of one and rewritten in the current format.
        p = writePlist(@"legacy", @{ @"uid": @"u1", @"name": @"HomePod mini" });
        d = cb_marker_load(p, &stale, &migrated, &invalid);
        CHECK(d.count == 1 && [d[0][@"uid"] isEqual:@"u1"] && [d[0][@"name"] isEqual:@"HomePod mini"]);
        CHECK(migrated && !stale && !invalid);
        NSDictionary *rewritten = [NSDictionary dictionaryWithContentsOfFile:p];
        CHECK([rewritten[@"devices"] isKindOfClass:[NSArray class]] && [rewritten[@"devices"] count] == 1 && !rewritten[@"name"]);
        d = cb_marker_load(p, &stale, &migrated, &invalid);  // second read: the new format, nothing to migrate
        CHECK(d.count == 1 && !migrated);

        // Old format without a uid, or with a uid that is not a string: the uid is "".
        p = writePlist(@"legacy-nouid", @{ @"name": @"HomePod" });
        d = cb_marker_load(p, &stale, &migrated, &invalid);
        CHECK(d.count == 1 && [d[0][@"uid"] isEqual:@""] && migrated);
        p = writePlist(@"legacy-baduid", @{ @"uid": @42, @"name": @"HomePod" });
        d = cb_marker_load(p, &stale, &migrated, &invalid);
        CHECK(d.count == 1 && [d[0][@"uid"] isEqual:@""]);

        // Without a name, with an empty one or one that is not a string: nothing usable.
        NSArray *bad = @[ @{ @"uid": @"u1" }, @{ @"uid": @"u1", @"name": @"" }, @{ @"uid": @"u1", @"name": @7 },
                          @{ @"devices": @[] }, @{ @"devices": @"x" }, @{ @"devices": @[ @1, @"s", @{ @"uid": @"u" } ] }, @{} ];
        for (NSUInteger i = 0; i < bad.count; i++) {
            p = writePlist([NSString stringWithFormat:@"bad%lu", (unsigned long)i], bad[i]);
            d = cb_marker_load(p, &stale, &migrated, &invalid);
            CHECK(d == nil && invalid && !migrated);
        }

        // Empty file, garbage, a plist that is an array, a missing file: no crash, nothing usable.
        p = writePlist(@"empty", @"");
        CHECK(cb_marker_load(p, &stale, &migrated, &invalid) == nil && invalid);
        p = writePlist(@"garbage", [NSData dataWithBytes:"\xff\x00\x01not a plist" length:16]);
        CHECK(cb_marker_load(p, &stale, &migrated, &invalid) == nil && invalid);
        p = writePlist(@"array", @[ @"a", @"b" ]);
        CHECK(cb_marker_load(p, &stale, &migrated, &invalid) == nil && invalid);
        CHECK(cb_marker_load([gDir stringByAppendingPathComponent:@"missing"], &stale, &migrated, &invalid) == nil && !invalid);

        // Valid and invalid elements mixed: the valid ones are kept and the file is cleaned.
        p = writePlist(@"mixed", @{ @"devices": @[ @1, @{ @"uid": @"u1", @"name": @"HomePod" }, @{ @"name": @"" }, @{ @"name": @"Sonos" } ] });
        d = cb_marker_load(p, &stale, &migrated, &invalid);
        CHECK(d.count == 2 && [d[0][@"name"] isEqual:@"HomePod"] && [d[1][@"uid"] isEqual:@""] && migrated);
        CHECK([[NSDictionary dictionaryWithContentsOfFile:p][@"devices"] count] == 2);

        // A stale old-format marker is migrated and stays stale: the rewrite keeps its time.
        p = writePlist(@"legacy-stale", @{ @"uid": @"u1", @"name": @"HomePod" });
        setAge(p, 13);
        d = cb_marker_load(p, &stale, &migrated, &invalid);
        CHECK(d.count == 1 && migrated && stale);
        struct stat st;
        stat(p.fileSystemRepresentation, &st);
        CHECK(difftime(time(NULL), st.st_mtime) > 12 * 3600);
        d = cb_marker_load(p, &stale, &migrated, &invalid);
        CHECK(d.count == 1 && !migrated && stale);  // still stale on the next read
        p = writePlist(@"new-stale", @{ @"devices": @[ @{ @"uid": @"u1", @"name": @"HomePod" } ] });
        setAge(p, 11);
        cb_marker_load(p, &stale, &migrated, &invalid);
        CHECK(!stale);
        setAge(p, 13);
        cb_marker_load(p, &stale, &migrated, &invalid);
        CHECK(stale);

        [[NSFileManager defaultManager] removeItemAtPath:gDir error:nil];
    }
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("marker: all checks passed\n");
    return 0;
}

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// usage: dumpclass [lib:<path>] [sym:<name>] [<ClassName>] ...
// env FILTER=a,b : only print methods whose name contains one of the substrings (case-insensitive)
static BOOL matches(NSString *name, NSArray *filters) {
    if (!filters.count) return YES;
    for (NSString *f in filters)
        if ([name rangeOfString:f options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    return NO;
}

static void dumpMethods(Class cls, BOOL meta, NSArray *filters) {
    unsigned n = 0;
    Method *ms = class_copyMethodList(meta ? object_getClass(cls) : cls, &n);
    for (unsigned i = 0; i < n; i++) {
        NSString *name = NSStringFromSelector(method_getName(ms[i]));
        if (matches(name, filters))
            printf("  %c %s  [%s]\n", meta ? '+' : '-', name.UTF8String, method_getTypeEncoding(ms[i]));
    }
    free(ms);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *fenv = getenv("FILTER");
        NSArray *filters = fenv ? [[NSString stringWithUTF8String:fenv] componentsSeparatedByString:@","] : @[];
        for (int i = 1; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if ([a hasPrefix:@"lib:"]) {
                void *h = dlopen([a substringFromIndex:4].UTF8String, RTLD_NOW);
                printf("dlopen %s: %s\n", [a substringFromIndex:4].UTF8String, h ? "ok" : dlerror());
            } else if ([a hasPrefix:@"classes:"]) {
                NSString *sub = [a substringFromIndex:8];
                unsigned cn = 0; Class *all = objc_copyClassList(&cn);
                for (unsigned k = 0; k < cn; k++) {
                    NSString *nm = NSStringFromClass(all[k]);
                    if ([nm rangeOfString:sub options:NSCaseInsensitiveSearch].location != NSNotFound) printf("%s\n", nm.UTF8String);
                }
                free(all);
            } else if ([a hasPrefix:@"sym:"]) {
                void *p = dlsym(RTLD_DEFAULT, [a substringFromIndex:4].UTF8String);
                printf("sym %s: %s\n", [a substringFromIndex:4].UTF8String, p ? "found" : "missing");
            } else {
                Class c = NSClassFromString(a);
                if (!c) { printf("class %s: missing\n", a.UTF8String); continue; }
                printf("class %s (super %s)\n", a.UTF8String, class_getSuperclass(c) ? class_getName(class_getSuperclass(c)) : "-");
                dumpMethods(c, YES, filters);
                dumpMethods(c, NO, filters);
            }
        }
    }
    return 0;
}

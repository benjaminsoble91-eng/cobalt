// Splice substrate shim - bundled into modded apps as Frameworks/CydiaSubstrate.framework.
// Tweaks that were built for a jailbreak link CydiaSubstrate / ElleKit / libhooker / libroot.
// Splice points those links here, so the tweak runs inside a normal (non-jailbroken) app:
//   * Objective-C hooks (MSHookMessageEx, LBHookMessage) use the ObjC runtime - fully supported.
//   * C function hooks (MSHookFunction, LHHookFunctions) can't patch code without a jailbreak, so
//     they rebind the function's symbol pointers in every loaded image (fishhook-style). Calls that
//     go through a library import are hooked; calls inside the library that owns the function aren't.
//   * MSFindSymbol / MSGetImageByName look things up with dyld.
//   * libroot paths resolve to "" (no jailbreak root), and tweak resource bundles that Splice copied
//     into the app are found when the tweak asks for them by their jailbreak path.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <string.h>
#import <stdlib.h>
#import <pthread.h>

#define EXPORT __attribute__((visibility("default")))
#define SPLOG(fmt, ...) NSLog(@"[Splice] " fmt, ##__VA_ARGS__)

typedef const void *MSImageRef;

#pragma mark - Objective-C hooks

static IMP HookMessage(Class cls, SEL sel, IMP repl) {
    if (!cls || !sel || !repl) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        SPLOG(@"can't hook %s %s: no such method", class_getName(cls), sel_getName(sel));
        return NULL;
    }
    // Does the class define the method itself, or only inherit it?
    BOOL own = NO;
    unsigned int n = 0;
    Method *list = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) if (list[i] == m) { own = YES; break; }
    free(list);
    if (own) return method_setImplementation(m, repl);
    IMP inherited = method_getImplementation(m);
    if (!class_addMethod(cls, sel, repl, method_getTypeEncoding(m)))
        return method_setImplementation(class_getInstanceMethod(cls, sel), repl);
    return inherited;
}

EXPORT void MSHookMessageEx(Class cls, SEL sel, IMP repl, IMP *result) {
    IMP old = HookMessage(cls, sel, repl);
    if (result) *result = old;
}

EXPORT void MSHookMessage(Class cls, SEL sel, IMP repl, const char *prefix) {
    (void)prefix;
    HookMessage(cls, sel, repl);
}

EXPORT int LBHookMessage(Class cls, SEL sel, void *repl, void *oldPtr) {
    if (!cls) return 1;
    if (!class_getInstanceMethod(cls, sel)) return 2;
    IMP old = HookMessage(cls, sel, (IMP)repl);
    if (oldPtr) *(IMP *)oldPtr = old;
    return 0;
}

#pragma mark - C function hooks via symbol rebinding

typedef struct { char *name; void *repl; } Rebind;
static Rebind *gRebinds;
static size_t gRebindCount;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;

static void RebindSection(const struct section_64 *sect, intptr_t slide, const struct nlist_64 *symtab,
                          const char *strtab, const uint32_t *indirect, const Rebind *rb, size_t nrb) {
    uint32_t *idx = (uint32_t *)indirect + sect->reserved1;
    void **ptrs = (void **)((uintptr_t)slide + sect->addr);
    size_t count = sect->size / sizeof(void *);
    BOOL unlocked = NO;
    for (size_t i = 0; i < count; i++) {
        uint32_t si = idx[i];
        if (si == INDIRECT_SYMBOL_ABS || si == INDIRECT_SYMBOL_LOCAL || si == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        const char *name = strtab + symtab[si].n_un.n_strx;
        if (name[0] != '_') continue;
        for (size_t r = 0; r < nrb; r++) {
            if (strcmp(name + 1, rb[r].name) != 0) continue;
            if (ptrs[i] == rb[r].repl) break;
            if (!unlocked) {
                vm_address_t page = (vm_address_t)ptrs & ~(vm_address_t)(vm_page_size - 1);
                vm_size_t len = ((vm_address_t)(ptrs + count) - page + vm_page_size - 1) & ~(vm_size_t)(vm_page_size - 1);
                if (vm_protect(mach_task_self(), page, len, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) return;
                unlocked = YES;
            }
            ptrs[i] = rb[r].repl;
            break;
        }
    }
}

static void RebindImage(const struct mach_header_64 *mh, intptr_t slide, const Rebind *rb, size_t nrb) {
    if (!mh || mh->magic != MH_MAGIC_64 || !nrb) return;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *st = NULL;
    const struct dysymtab_command *dst = NULL;
    uintptr_t p = (uintptr_t)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)p;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT)) linkedit = (const void *)lc;
        else if (lc->cmd == LC_SYMTAB) st = (const void *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dst = (const void *)lc;
        p += lc->cmdsize;
    }
    if (!linkedit || !st || !dst || !dst->nindirectsyms) return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const void *)(base + st->symoff);
    const char *strtab = (const char *)(base + st->stroff);
    const uint32_t *indirect = (const void *)(base + dst->indirectsymoff);
    p = (uintptr_t)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)p;
        p += lc->cmdsize;
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        if (strncmp(seg->segname, "__DATA", 6) && strncmp(seg->segname, "__AUTH", 6)) continue;
        const struct section_64 *sects = (const void *)(seg + 1);
        for (uint32_t s = 0; s < seg->nsects; s++) {
            uint32_t type = sects[s].flags & SECTION_TYPE;
            if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS)
                RebindSection(&sects[s], slide, symtab, strtab, indirect, rb, nrb);
        }
    }
}

static void OnImageAdded(const struct mach_header *mh, intptr_t slide) {
    pthread_mutex_lock(&gLock);
    RebindImage((const struct mach_header_64 *)mh, slide, gRebinds, gRebindCount);
    pthread_mutex_unlock(&gLock);
}

static BOOL HookFunction(void *symbol, void *repl, void **result) {
    if (result) *result = symbol;   // calling "orig" always reaches the real function
    if (!symbol || !repl) return NO;
    Dl_info info;
    if (!dladdr(symbol, &info) || !info.dli_sname || info.dli_saddr != symbol) {
        SPLOG(@"can't hook function %p: it has no exported name (needs a jailbreak)", symbol);
        return NO;
    }
    static BOOL registered = NO;
    pthread_mutex_lock(&gLock);
    gRebinds = realloc(gRebinds, (gRebindCount + 1) * sizeof(Rebind));
    Rebind rb = { strdup(info.dli_sname), repl };
    gRebinds[gRebindCount++] = rb;
    BOOL first = !registered;
    registered = YES;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++)
        RebindImage((const struct mach_header_64 *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i), &rb, 1);
    pthread_mutex_unlock(&gLock);
    if (first) _dyld_register_func_for_add_image(OnImageAdded);   // also covers images loaded later
    return YES;
}

EXPORT void MSHookFunction(void *symbol, void *repl, void **result) {
    HookFunction(symbol, repl, result);
}

struct LHFunctionHook { void *function; void *replacement; void *oldptr; void *options; };
EXPORT int LHHookFunctions(const struct LHFunctionHook *hooks, int count) {
    int ok = 0;
    for (int i = 0; i < count; i++)
        if (HookFunction(hooks[i].function, hooks[i].replacement, (void **)hooks[i].oldptr)) ok++;
    return ok;
}

EXPORT const char *LHStrError(int err) { return err ? "hook failed (no jailbreak)" : "no error"; }

// Memory patching needs a jailbreak.
EXPORT int MSHookMemory(void *target, const void *data, size_t size) {
    (void)target; (void)data; (void)size;
    SPLOG(@"MSHookMemory isn't available without a jailbreak");
    return 1;
}
EXPORT void MSHookClassPair(Class target, Class hook, Class old) { (void)target; (void)hook; (void)old; }

#pragma mark - Images and symbols

EXPORT MSImageRef MSGetImageByName(const char *file) {
    if (!file) return NULL;
    const char *slash = strrchr(file, '/');
    const char *leaf = slash ? slash + 1 : file;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && !strcmp(name, file)) return _dyld_get_image_header(i);
    }
    // Jailbreak paths (/var/jb/..., /Library/MobileSubstrate/...) -> match by file name.
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        const char *s = name ? strrchr(name, '/') : NULL;
        if (s && !strcmp(s + 1, leaf)) return _dyld_get_image_header(i);
    }
    return NULL;
}

EXPORT void MSCloseImage(MSImageRef image) { (void)image; }

static void *SymtabLookup(const struct mach_header_64 *mh, intptr_t slide, const char *name) {
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *st = NULL;
    uintptr_t p = (uintptr_t)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)p;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT)) linkedit = (const void *)lc;
        else if (lc->cmd == LC_SYMTAB) st = (const void *)lc;
        p += lc->cmdsize;
    }
    if (!linkedit || !st) return NULL;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(base + st->symoff);
    const char *strtab = (const char *)(base + st->stroff);
    for (uint32_t i = 0; i < st->nsyms; i++) {
        if (syms[i].n_type & N_STAB) continue;
        if ((syms[i].n_type & N_TYPE) != N_SECT) continue;
        uint32_t sx = syms[i].n_un.n_strx;
        if (sx && sx < st->strsize && !strcmp(strtab + sx, name)) return (void *)(syms[i].n_value + slide);
    }
    return NULL;
}

EXPORT void *MSFindSymbol(MSImageRef image, const char *name) {
    if (!name) return NULL;
    const char *bare = name[0] == '_' ? name + 1 : name;
    if (!image) return dlsym(RTLD_DEFAULT, bare);
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        if (_dyld_get_image_header(i) != image) continue;
        void *h = dlopen(_dyld_get_image_name(i), RTLD_LAZY | RTLD_NOLOAD);
        void *r = h ? dlsym(h, bare) : NULL;
        if (h) dlclose(h);
        if (!r) r = SymtabLookup(image, _dyld_get_image_vmaddr_slide(i), name);
        return r;
    }
    return NULL;
}

// libhooker image API
EXPORT const void *LHOpenImage(const char *path) { return MSGetImageByName(path); }
EXPORT void LHCloseImage(const void *image) { (void)image; }
EXPORT int LHFindSymbols(const void *image, const char **names, void **out, size_t count) {
    int all = 1;
    for (size_t i = 0; i < count; i++) { out[i] = MSFindSymbol(image, names[i]); if (!out[i]) all = 0; }
    return all;
}

#pragma mark - libroot (rootless path helpers)

static NSString *BundledResource(NSString *path) {
    // "/var/jb/Library/Application Support/Foo.bundle/x.png" -> "<app>/Foo.bundle/x.png" when Splice copied it in.
    if (!path.length || [NSFileManager.defaultManager fileExistsAtPath:path]) return nil;
    NSArray *parts = path.pathComponents;
    for (NSUInteger i = 0; i < parts.count; i++) {
        NSString *c = parts[i];
        if (![c.pathExtension isEqualToString:@"bundle"]) continue;
        NSString *inApp = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:c];
        if (![NSFileManager.defaultManager fileExistsAtPath:inApp]) return nil;
        NSArray *rest = [parts subarrayWithRange:NSMakeRange(i + 1, parts.count - i - 1)];
        return rest.count ? [inApp stringByAppendingPathComponent:[NSString pathWithComponents:rest]] : inApp;
    }
    return nil;
}

EXPORT const char *libroot_dyn_get_root_prefix(void) { return ""; }
EXPORT const char *libroot_dyn_get_jbroot_prefix(void) { return ""; }
EXPORT const char *libroot_dyn_get_boot_uuid(void) { return ""; }
static char *CopyPath(const char *path, char *resolved) {
    if (!path) return NULL;
    const char *src = path;
    NSString *mapped = BundledResource(@(path));
    if (mapped) src = mapped.fileSystemRepresentation;
    if (!resolved) return strdup(src);
    strlcpy(resolved, src, PATH_MAX);
    return resolved;
}
EXPORT char *libroot_dyn_rootfspath(const char *path, char *resolved) { return CopyPath(path, resolved); }
EXPORT char *libroot_dyn_jbrootpath(const char *path, char *resolved) { return CopyPath(path, resolved); }

#pragma mark - Resource bundles

static id (*origBundleWithPath)(id, SEL, NSString *);
static id (*origInitWithPath)(id, SEL, NSString *);
static id RedirBundleWithPath(id self, SEL _cmd, NSString *path) {
    NSString *m = path ? BundledResource(path) : nil;
    return origBundleWithPath(self, _cmd, m ?: path);
}
static id RedirInitWithPath(id self, SEL _cmd, NSString *path) {
    NSString *m = path ? BundledResource(path) : nil;
    return origInitWithPath(self, _cmd, m ?: path);
}

__attribute__((constructor)) static void SpliceShimInit(void) {
    // Only redirect when the jailbreak path doesn't exist (always true on a stock device).
    MSHookMessageEx(object_getClass(NSBundle.class), @selector(bundleWithPath:), (IMP)RedirBundleWithPath, (IMP *)&origBundleWithPath);
    MSHookMessageEx(NSBundle.class, @selector(initWithPath:), (IMP)RedirInitWithPath, (IMP *)&origInitWithPath);
}

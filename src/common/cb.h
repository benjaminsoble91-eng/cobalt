// Shared helpers for Cobalt tweaks: pure Objective-C runtime hooks (no substrate link needed).
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

// Replace -[cls sel] with a block. Returns the previous implementation (the
// superclass's if cls only inherited it). Returns NULL if the method doesn't exist.
static inline IMP CBHook(Class cls, SEL sel, id block) {
    if (!cls) return NULL;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return NULL;
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(block);
    if (!class_addMethod(cls, sel, repl, method_getTypeEncoding(m)))
        method_setImplementation(m, repl);
    return orig;
}

static inline id CBSendID(id o, const char *name) {
    SEL s = sel_registerName(name);
    if (!o || ![o respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(o, s);
}
static inline BOOL CBSendBOOL(id o, const char *name) {
    SEL s = sel_registerName(name);
    if (!o || ![o respondsToSelector:s]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, s);
}
static inline id CBIvar(id o, const char *name) {
    if (!o) return nil;
    Ivar iv = class_getInstanceVariable(object_getClass(o), name);
    if (!iv) return nil;
    const char *t = ivar_getTypeEncoding(iv);
    if (!t || t[0] != '@') return nil;
    return object_getIvar(o, iv);
}
static inline BOOL CBPrefBool(CFStringRef domain, CFStringRef key, BOOL def) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, domain);
    BOOL r = def;
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) r = CFBooleanGetValue((CFBooleanRef)v);
        else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int i = def; CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &i); r = i != 0; }
        CFRelease(v);
    }
    return r;
}
static inline BOOL CBIsSpringBoard(void) {
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}

// panicbutton-helper: installed setuid root. Only does one thing: asks the kernel to panic.
//
// 1.0 tried to write to an unmapped kernel address through libjailbreak, but Dopamine
// never fills in gPrimitives.kwritebuf (it uses physical R/W instead), so the helper
// always stopped with "kwritebuf not available". It also touched kernel memory directly.
//
// 1.0.1 uses the kernel's own debug path instead: reboot(2) with RB_PANIC. XNU handles
// that by calling panic("userspace panic: <message>"), which writes a normal panic-full
// log. No kernel memory is written by us at all.
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

#ifndef RB_PANIC
#define RB_PANIC 0x800   /* from XNU bsd/sys/reboot.h */
#endif

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "panic") != 0) {
        fprintf(stderr, "usage: panicbutton-helper panic\n");
        return 2;
    }
    if (setgid(0) != 0 || setuid(0) != 0) {
        if (geteuid() != 0) { fprintf(stderr, "not running as root\n"); return 3; }
    }
    sync();   // flush filesystem buffers before the panic
    sync();
    fprintf(stderr, "requesting kernel panic...\n");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    long r = syscall(SYS_reboot, RB_PANIC, "PanicButton (Cobalt) manual panic");
#pragma clang diagnostic pop
    // Only reached if the kernel refused.
    int e = errno;
    fprintf(stderr, "reboot(RB_PANIC) returned %ld: %s\n", r, strerror(e));
    return e == EPERM ? 10 : 11;
}

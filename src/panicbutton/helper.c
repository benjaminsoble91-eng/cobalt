// panicbutton-helper: installed setuid root.
// Loads libjailbreak, acquires kernel R/W from Dopamine's jailbreak server,
// then writes to an unmapped kernel address to trigger a data-abort panic.
// Produces a panic-full log readable in Settings → Privacy → Analytics.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <stdint.h>

// These match Dopamine's libjailbreak exports
typedef void (^kernel_map_accessor)(void *ptr);
struct kernel_primitives {
    int (*kreadbuf)(uint64_t kaddr, void *output, size_t size);
    int (*kwritebuf)(uint64_t kaddr, const void *input, size_t size);
    int (*physreadbuf)(uint64_t physaddr, void *output, size_t size);
    int (*physwritebuf)(uint64_t physaddr, const void *input, size_t size);
    unsigned krwMinSafeReadSize;
    uint64_t (*kcall)(uint64_t func, int argc, const uint64_t *argv);
    void *kexec;
    int (*kalloc_global)(uint64_t *addr, uint64_t size);
    int (*kalloc_local)(uint64_t *addr, uint64_t size);
    int (*kfree_global)(uint64_t addr, uint64_t size);
    int (*kmap)(uint64_t pa, uint64_t size, void **uaddr);
    int (*physaccess_mapped)(uint64_t pa, uint64_t size, kernel_map_accessor accessorBlock);
    uint64_t (*vtophys)(uint64_t ttep, uint64_t va);
    uint64_t (*phystokv)(uint64_t pa);
};

int main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[1], "panic") != 0) {
        fprintf(stderr, "usage: panicbutton-helper panic\n");
        return 2;
    }

    // Escalate to root (we're installed setuid root)
    if (setgid(0) != 0 || setuid(0) != 0) {
        if (geteuid() != 0) {
            fprintf(stderr, "not running as root\n");
            return 3;
        }
    }

    // Load libjailbreak from Dopamine's basebin
    const char *paths[] = {
        "/var/jb/basebin/libjailbreak.dylib",
        "/basebin/libjailbreak.dylib",
        NULL
    };
    void *lib = NULL;
    for (int i = 0; paths[i]; i++) {
        lib = dlopen(paths[i], RTLD_NOW);
        if (lib) break;
    }
    if (!lib) {
        fprintf(stderr, "cannot load libjailbreak: %s\n", dlerror());
        return 4;
    }

    // Resolve jbclient_initialize_primitives
    int (*init_prims)(void) = dlsym(lib, "jbclient_initialize_primitives");
    if (!init_prims) {
        fprintf(stderr, "cannot find jbclient_initialize_primitives\n");
        return 5;
    }

    // Resolve gPrimitives
    struct kernel_primitives *prims = dlsym(lib, "gPrimitives");
    if (!prims) {
        fprintf(stderr, "cannot find gPrimitives\n");
        return 6;
    }

    // Acquire kernel R/W from the jailbreak server
    int ret = init_prims();
    if (ret != 0) {
        fprintf(stderr, "jbclient_initialize_primitives failed: %d\n", ret);
        return 7;
    }

    if (!prims->kwritebuf) {
        fprintf(stderr, "kwritebuf not available after init\n");
        return 8;
    }

    // Write to an unmapped kernel virtual address.
    // This triggers a synchronous data abort in the kernel, which XNU
    // handles as a panic. The full register state and backtrace are
    // saved to the panic log (readable in Settings → Privacy → Analytics).
    fprintf(stderr, "triggering kernel panic...\n");
    sync(); // flush filesystem buffers first

    uint64_t garbage = 0x4141414141414141ULL;
    // 0xFFFFFFF0DEAD0000 is well above any mapped kernel region on A9
    prims->kwritebuf(0xFFFFFFF0DEAD0000ULL, &garbage, sizeof(garbage));

    // Should never reach here — the kwrite panics the kernel synchronously
    fprintf(stderr, "kwrite returned without panicking (unexpected)\n");
    return 9;
}

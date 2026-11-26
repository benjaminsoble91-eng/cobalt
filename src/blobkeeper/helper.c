// blobkeeper-helper: runs as root (spawned with persona uid 0, and installed setuid as a fallback).
// One job: find this device's onboard ticket (the IM4M from the last restore/update), copy it to a
// place the BlobKeeper app can read, and report the boot-nonce generator from NVRAM if one is set.
//
//   blobkeeper-helper dump <outdir>
//
// Prints key=value lines on stdout:
//   ticket=<path of the copy>   source=<where it was found>   generator=0x...   (generator only if set)
// Exit: 0 ok, 3 not root, 4 no ticket found, 5 copy failed, 2 usage.
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>

// IOKit isn't in the public iOS headers; these are stable C exports.
typedef unsigned int io_object_t, io_registry_entry_t, mach_port_t_;
extern const mach_port_t_ kIOMasterPortDefault;
extern io_registry_entry_t IORegistryEntryFromPath(mach_port_t_ master, const char *path);
extern CFTypeRef IORegistryEntryCreateCFProperty(io_registry_entry_t e, CFStringRef key, CFAllocatorRef a, unsigned int opts);
extern int IOObjectRelease(io_object_t o);

static int file_ok(const char *p) {
    struct stat st;
    return stat(p, &st) == 0 && S_ISREG(st.st_mode) && st.st_size > 64;
}

// iOS 15+: /private/preboot/<active hash>/System/Library/Caches/apticket.der
// iOS 14 and older: /System/Library/Caches/apticket.der
static int find_ticket(char *out, size_t n) {
    char active[256] = {0};
    FILE *f = fopen("/private/preboot/active", "r");
    if (f) {
        size_t r = fread(active, 1, sizeof(active) - 1, f);
        fclose(f);
        active[r] = 0;
        active[strcspn(active, "\r\n ")] = 0;
        if (active[0]) {
            snprintf(out, n, "/private/preboot/%s/System/Library/Caches/apticket.der", active);
            if (file_ok(out)) return 1;
        }
    }
    DIR *d = opendir("/private/preboot");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] == '.' || strlen(e->d_name) < 32) continue;
            snprintf(out, n, "/private/preboot/%s/System/Library/Caches/apticket.der", e->d_name);
            if (file_ok(out)) { closedir(d); return 1; }
        }
        closedir(d);
    }
    const char *legacy[] = {"/System/Library/Caches/apticket.der", "/private/var/mobile/Library/Caches/apticket.der", NULL};
    for (int i = 0; legacy[i]; i++) {
        snprintf(out, n, "%s", legacy[i]);
        if (file_ok(out)) return 1;
    }
    return 0;
}

static int copy_file(const char *src, const char *dst) {
    int in = open(src, O_RDONLY);
    if (in < 0) return -1;
    int out = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) { close(in); return -1; }
    char buf[16384];
    ssize_t r;
    int rc = 0;
    while ((r = read(in, buf, sizeof(buf))) > 0)
        if (write(out, buf, r) != r) { rc = -1; break; }
    if (r < 0) rc = -1;
    close(in);
    close(out);
    return rc;
}

// Normalise whatever NVRAM holds into "0x" + 16 hex digits.
static int clean_generator(const char *in, char *out, size_t n) {
    const char *p = in;
    while (*p == ' ' || *p == '\t') p++;
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) p += 2;
    char hex[17] = {0};
    int k = 0;
    for (; *p && k < 16; p++) {
        char c = *p;
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) hex[k++] = (c >= 'A' && c <= 'F') ? c + 32 : c;
        else break;
    }
    if (k != 16) return 0;
    snprintf(out, n, "0x%s", hex);
    return 1;
}

static int read_generator(char *out, size_t n) {
    io_registry_entry_t opts = IORegistryEntryFromPath(kIOMasterPortDefault, "IODeviceTree:/options");
    if (opts) {
        CFTypeRef v = IORegistryEntryCreateCFProperty(opts, CFSTR("com.apple.System.boot-nonce"), kCFAllocatorDefault, 0);
        IOObjectRelease(opts);
        if (v) {
            char tmp[128] = {0};
            if (CFGetTypeID(v) == CFDataGetTypeID()) {
                CFIndex len = CFDataGetLength(v);
                if (len > (CFIndex)sizeof(tmp) - 1) len = sizeof(tmp) - 1;
                memcpy(tmp, CFDataGetBytePtr(v), len);
            } else if (CFGetTypeID(v) == CFStringGetTypeID()) {
                CFStringGetCString(v, tmp, sizeof(tmp), kCFStringEncodingUTF8);
            }
            CFRelease(v);
            if (clean_generator(tmp, out, n)) return 1;
        }
    }
    // Fallback: the jailbreak's nvram tool, if installed.
    const char *tools[] = {"/var/jb/usr/sbin/nvram", "/usr/sbin/nvram", NULL};
    for (int i = 0; tools[i]; i++) {
        if (access(tools[i], X_OK) != 0) continue;
        char cmd[256];
        snprintf(cmd, sizeof(cmd), "%s com.apple.System.boot-nonce 2>/dev/null", tools[i]);
        FILE *p = popen(cmd, "r");
        if (!p) continue;
        char line[256] = {0};
        char *got = fgets(line, sizeof(line), p);
        pclose(p);
        if (!got) continue;
        char *val = strpbrk(line, " \t");   // "com.apple.System.boot-nonce\t0x...."
        if (val && clean_generator(val, out, n)) return 1;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc != 3 || strcmp(argv[1], "dump") != 0) {
        fprintf(stderr, "usage: blobkeeper-helper dump <outdir>\n");
        return 2;
    }
    setgid(0);
    setuid(0);
    if (geteuid() != 0) { fprintf(stderr, "not running as root\n"); return 3; }

    const char *outdir = argv[2];
    mkdir(outdir, 0755);
    chown(outdir, 501, 501);

    char src[1024];
    if (!find_ticket(src, sizeof(src))) { fprintf(stderr, "no onboard ticket found\n"); return 4; }
    char dst[1200];
    snprintf(dst, sizeof(dst), "%s/apticket.der", outdir);
    if (copy_file(src, dst) != 0) { fprintf(stderr, "copy failed: %s\n", strerror(errno)); return 5; }
    chown(dst, 501, 501);
    chmod(dst, 0644);
    printf("ticket=%s\nsource=%s\n", dst, src);

    char gen[32];
    if (read_generator(gen, sizeof(gen))) printf("generator=%s\n", gen);
    fflush(stdout);
    return 0;
}

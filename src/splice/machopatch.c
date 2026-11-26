// machopatch.c - small Mach-O load-command editor used by Splice.
// Plain C with its own struct definitions so it also builds on Linux for testing.
//  * rewrites dylib dependency paths (e.g. CydiaSubstrate -> the bundled shim)
//  * sets a dylib's install name (LC_ID_DYLIB)
//  * adds LC_LOAD_DYLIB commands (injects tweaks into the app's main binary)
//  * reports FairPlay encryption
// Works on thin 64-bit binaries and fat (32/64-bit fat header) binaries; 32-bit slices are skipped.
// Load commands are rebuilt in the header padding, so nothing after the header moves.
#include "machopatch.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#define MH_MAGIC_64   0xfeedfacfu
#define MH_CIGAM_64   0xcffaedfeu
#define FAT_MAGIC     0xcafebabeu
#define FAT_MAGIC_64  0xcafebabfu
#define LC_REQ_DYLD   0x80000000u
#define LC_SEGMENT_64 0x19u
#define LC_LOAD_DYLIB 0x0cu
#define LC_ID_DYLIB   0x0du
#define LC_LOAD_WEAK_DYLIB   (0x18u | LC_REQ_DYLD)
#define LC_REEXPORT_DYLIB    (0x1fu | LC_REQ_DYLD)
#define LC_LAZY_LOAD_DYLIB   0x20u
#define LC_LOAD_UPWARD_DYLIB (0x23u | LC_REQ_DYLD)
#define LC_ENCRYPTION_INFO_64 0x2cu
#define MH_HEADER_64 32u

static uint32_t rd32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t rd64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static void wr32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint64_t be64(const uint8_t *p) { return ((uint64_t)be32(p) << 32) | be32(p + 4); }

static void seterr(char *err, size_t n, const char *fmt, ...) {
    if (!err || !n) return;
    va_list ap; va_start(ap, fmt); vsnprintf(err, n, fmt, ap); va_end(ap);
}

static int is_dylib_cmd(uint32_t c) {
    return c == LC_LOAD_DYLIB || c == LC_LOAD_WEAK_DYLIB || c == LC_REEXPORT_DYLIB ||
           c == LC_LAZY_LOAD_DYLIB || c == LC_LOAD_UPWARD_DYLIB;
}

// Collect the file offsets of the 64-bit slices. Returns count (0 = not a Mach-O we handle).
static int slices(const uint8_t *b, size_t len, size_t *offs, size_t *sizes, int max) {
    if (len < 8) return 0;
    uint32_t m = be32(b);
    if (m == FAT_MAGIC || m == FAT_MAGIC_64) {
        uint32_t n = be32(b + 4);
        size_t asz = m == FAT_MAGIC ? 20 : 32;
        int c = 0;
        for (uint32_t i = 0; i < n && c < max; i++) {
            const uint8_t *a = b + 8 + i * asz;
            if ((size_t)(a + asz - b) > len) break;
            uint64_t off = m == FAT_MAGIC ? be32(a + 8) : be64(a + 8);
            uint64_t sz  = m == FAT_MAGIC ? be32(a + 12) : be64(a + 16);
            if (off + MH_HEADER_64 > len || off + sz > len) continue;
            if (rd32(b + off) != MH_MAGIC_64) continue;   // skip 32-bit slices
            offs[c] = (size_t)off; sizes[c] = (size_t)sz; c++;
        }
        return c;
    }
    if (rd32(b) == MH_MAGIC_64) { offs[0] = 0; sizes[0] = len; return 1; }
    return 0;
}

int mp_is_macho(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    uint8_t h[4]; size_t r = fread(h, 1, 4, f); fclose(f);
    if (r < 4) return 0;
    uint32_t le = rd32(h), be = be32(h);
    return le == MH_MAGIC_64 || le == 0xfeedfaceu || be == FAT_MAGIC || be == FAT_MAGIC_64;
}

static uint8_t *readall(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    if (n <= 0) { fclose(f); return NULL; }
    uint8_t *b = malloc((size_t)n);
    if (b && fread(b, 1, (size_t)n, f) != (size_t)n) { free(b); b = NULL; }
    fclose(f);
    *len = (size_t)n;
    return b;
}

int mp_is_encrypted(const char *path) {
    size_t len = 0; uint8_t *b = readall(path, &len);
    if (!b) return 0;
    size_t offs[8], szs[8]; int n = slices(b, len, offs, szs, 8), enc = 0;
    for (int s = 0; s < n && !enc; s++) {
        const uint8_t *mh = b + offs[s];
        uint32_t ncmds = rd32(mh + 16);
        size_t p = offs[s] + MH_HEADER_64;
        for (uint32_t i = 0; i < ncmds && p + 8 <= len; i++) {
            uint32_t cmd = rd32(b + p), sz = rd32(b + p + 4);
            if (cmd == LC_ENCRYPTION_INFO_64 && p + 20 <= len && rd32(b + p + 16) != 0) enc = 1;
            if (sz < 8) break;
            p += sz;
        }
    }
    free(b);
    return enc;
}

int mp_list_deps(const char *path, mp_dep_cb cb, void *ctx) {
    size_t len = 0; uint8_t *b = readall(path, &len);
    if (!b) return -1;
    size_t offs[8], szs[8]; int n = slices(b, len, offs, szs, 8);
    if (n > 0) {   // first slice is enough: every slice links the same libraries
        const uint8_t *mh = b + offs[0];
        uint32_t ncmds = rd32(mh + 16);
        size_t p = offs[0] + MH_HEADER_64, end = p + rd32(mh + 20);
        for (uint32_t i = 0; i < ncmds && p + 8 <= len && p < end; i++) {
            uint32_t cmd = rd32(b + p), sz = rd32(b + p + 4);
            if (sz < 8 || p + sz > len) break;
            if (is_dylib_cmd(cmd) && sz > 24) {
                uint32_t no = rd32(b + p + 8);
                if (no < sz) {
                    char name[1024]; size_t m = sz - no; if (m >= sizeof name) m = sizeof name - 1;
                    memcpy(name, b + p + no, m); name[m] = 0;
                    cb(name, ctx);
                }
            }
            p += sz;
        }
    }
    free(b);
    return n > 0 ? 0 : -1;
}

typedef struct { uint8_t *data; size_t len; } Cmd;

static Cmd make_dylib_cmd(uint32_t cmd, const char *name, uint32_t ts, uint32_t cur, uint32_t compat) {
    size_t nl = strlen(name) + 1;
    size_t sz = (24 + nl + 7) & ~(size_t)7;
    Cmd c = { calloc(1, sz), sz };
    wr32(c.data, cmd); wr32(c.data + 4, (uint32_t)sz); wr32(c.data + 8, 24);
    wr32(c.data + 12, ts); wr32(c.data + 16, cur); wr32(c.data + 20, compat);
    memcpy(c.data + 24, name, nl);
    return c;
}

// Patch one slice in place. Returns 0 on success.
static int patch_slice(uint8_t *b, size_t soff, size_t ssize, const mp_opts *o, char *err, size_t errn, int *changed) {
    uint8_t *mh = b + soff;
    uint32_t ncmds = rd32(mh + 16), sizeofcmds = rd32(mh + 20);
    size_t start = MH_HEADER_64;
    if (start + sizeofcmds > ssize) { seterr(err, errn, "corrupt load commands"); return -1; }

    // Where the first real data starts = how much room the header has.
    uint64_t limit = ssize;
    Cmd *cmds = calloc(ncmds + (size_t)o->nadd + 1, sizeof(Cmd));
    size_t nc = 0, p = start;
    for (uint32_t i = 0; i < ncmds; i++) {
        if (p + 8 > start + sizeofcmds) { seterr(err, errn, "corrupt load command list"); goto fail; }
        uint32_t cmd = rd32(mh + p), sz = rd32(mh + p + 4);
        if (sz < 8 || p + sz > start + sizeofcmds) { seterr(err, errn, "corrupt load command"); goto fail; }
        if (cmd == LC_SEGMENT_64 && sz >= 72) {
            uint64_t fileoff = rd64(mh + p + 40), filesize = rd64(mh + p + 48);
            uint32_t nsects = rd32(mh + p + 64);
            if (fileoff > 0 && filesize > 0 && fileoff < limit) limit = fileoff;
            for (uint32_t s = 0; s < nsects && 72 + (size_t)(s + 1) * 80 <= sz; s++) {
                const uint8_t *sec = mh + p + 72 + s * 80;
                uint32_t off = rd32(sec + 48), type = rd32(sec + 64) & 0xff;
                uint64_t size = rd64(sec + 40);
                if (off > 0 && size > 0 && type != 1 && type != 0x0c && type != 0x12 && off < limit) limit = off;
            }
        }
        Cmd c = { NULL, sz };
        if ((is_dylib_cmd(cmd) || cmd == LC_ID_DYLIB) && sz > 24) {
            uint32_t no = rd32(mh + p + 8);
            char name[1024] = {0};
            if (no < sz) { size_t m = sz - no; if (m >= sizeof name) m = sizeof name - 1; memcpy(name, mh + p + no, m); }
            const char *repl = NULL;
            if (cmd == LC_ID_DYLIB) repl = o->new_id;
            else if (o->map) repl = o->map(name, o->ctx);
            if (repl && strcmp(repl, name) != 0) {
                c = make_dylib_cmd(cmd, repl, rd32(mh + p + 12), rd32(mh + p + 16), rd32(mh + p + 20));
                *changed = 1;
            }
        }
        if (!c.data) { c.data = malloc(sz); memcpy(c.data, mh + p, sz); }
        cmds[nc++] = c;
        p += sz;
    }
    // Inject new LC_LOAD_DYLIBs, skipping any already present.
    for (int a = 0; a < o->nadd; a++) {
        int dup = 0;
        for (size_t i = 0; i < nc && !dup; i++) {
            uint32_t cmd = rd32(cmds[i].data);
            if (is_dylib_cmd(cmd)) {
                uint32_t no = rd32(cmds[i].data + 8);
                if (no < cmds[i].len && strncmp((char *)cmds[i].data + no, o->add[a], cmds[i].len - no) == 0) dup = 1;
            }
        }
        if (dup) continue;
        cmds[nc++] = make_dylib_cmd(o->weak_add ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB, o->add[a], 2, 0x10000, 0x10000);
        *changed = 1;
    }
    size_t total = 0;
    for (size_t i = 0; i < nc; i++) total += cmds[i].len;
    if (start + total > limit) {
        seterr(err, errn, "not enough room in the Mach-O header (%zu bytes needed, %llu free)",
               total - sizeofcmds, (unsigned long long)(limit - start - sizeofcmds));
        goto fail;
    }
    if (*changed) {
        size_t oldEnd = start + sizeofcmds, q = start;
        for (size_t i = 0; i < nc; i++) { memcpy(mh + q, cmds[i].data, cmds[i].len); q += cmds[i].len; }
        if (q < oldEnd) memset(mh + q, 0, oldEnd - q);
        wr32(mh + 16, (uint32_t)nc);
        wr32(mh + 20, (uint32_t)total);
    }
    for (size_t i = 0; i < nc; i++) free(cmds[i].data);
    free(cmds);
    return 0;
fail:
    for (size_t i = 0; i < nc; i++) free(cmds[i].data);
    free(cmds);
    return -1;
}

int mp_patch(const char *path, const mp_opts *o, char *err, size_t errn) {
    size_t len = 0; uint8_t *b = readall(path, &len);
    if (!b) { seterr(err, errn, "can't read the file"); return -1; }
    size_t offs[8], szs[8]; int n = slices(b, len, offs, szs, 8);
    if (n == 0) { free(b); seterr(err, errn, "not a 64-bit Mach-O"); return -1; }
    int changed = 0;
    for (int s = 0; s < n; s++) {
        if (patch_slice(b, offs[s], szs[s], o, err, errn, &changed) != 0) { free(b); return -1; }
    }
    int rc = 0;
    if (changed) {
        FILE *f = fopen(path, "r+b");
        if (!f || fwrite(b, 1, len, f) != len) { seterr(err, errn, "can't write the file"); rc = -1; }
        if (f) fclose(f);
    }
    free(b);
    return rc;
}

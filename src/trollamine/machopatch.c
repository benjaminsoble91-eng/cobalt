// machopatch - prepares a copy of an app's main program so it loads one extra library.
// Portable C (own struct definitions) so the same code can be tested on Linux and shipped on iOS.
//
// What it does to a 64-bit arm64 Mach-O file:
//   1. copies out the entitlements stored in the existing code signature
//   2. removes the existing code signature (it would no longer match after editing)
//   3. adds a "load this library" command for dylib_path
// The file must then be signed again (ldid -S<entitlements>).
#include "machopatch.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TM_MH_MAGIC_64 0xfeedfacfu
#define TM_FAT_CIGAM 0xbebafecau /* fat magic as read on a little-endian machine */
#define TM_FAT_CIGAM_64 0xbfbafecau
#define TM_CPU_ARM64 0x0100000cu
#define TM_LC_SEGMENT_64 0x19u
#define TM_LC_LOAD_DYLIB 0xcu
#define TM_LC_CODE_SIGNATURE 0x1du
#define TM_CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0u
#define TM_CSMAGIC_ENTITLEMENTS 0xfade7171u

struct tm_mach_header_64 { uint32_t magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved; };
struct tm_load_command { uint32_t cmd, cmdsize; };
struct tm_segment_command_64 { uint32_t cmd, cmdsize; char segname[16]; uint64_t vmaddr, vmsize, fileoff, filesize; uint32_t maxprot, initprot, nsects, flags; };
struct tm_section_64 { char sectname[16]; char segname[16]; uint64_t addr, size; uint32_t offset, align, reloff, nreloc, flags, reserved1, reserved2, reserved3; };
struct tm_linkedit_data_command { uint32_t cmd, cmdsize, dataoff, datasize; };
struct tm_dylib_command { uint32_t cmd, cmdsize, name_offset, timestamp, current_version, compatibility_version; };

static uint32_t be32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }

static int fail(char *err, size_t errlen, const char *msg) {
    if (err && errlen) snprintf(err, errlen, "%s", msg);
    return -1;
}

int tm_patch_macho(const char *path, const char *dylib_path, char **entitlements_xml, char *err, size_t errlen) {
    if (entitlements_xml) *entitlements_xml = NULL;
    FILE *f = fopen(path, "rb");
    if (!f) return fail(err, errlen, "can't open the program file");
    fseek(f, 0, SEEK_END);
    long flen = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (flen < (long)sizeof(struct tm_mach_header_64)) { fclose(f); return fail(err, errlen, "program file is too small"); }
    uint8_t *file = malloc((size_t)flen);
    if (!file || fread(file, 1, (size_t)flen, f) != (size_t)flen) { fclose(f); free(file); return fail(err, errlen, "can't read the program file"); }
    fclose(f);

    // Pick the arm64 slice if this is a multi-architecture file.
    uint8_t *buf = file;
    size_t len = (size_t)flen;
    uint32_t magic;
    memcpy(&magic, buf, 4);
    if (magic == TM_FAT_CIGAM || magic == TM_FAT_CIGAM_64) {
        int is64 = (magic == TM_FAT_CIGAM_64);
        uint32_t n = be32(buf + 4);
        size_t entry = is64 ? 32 : 20;
        uint8_t *found = NULL;
        size_t found_len = 0;
        for (uint32_t i = 0; i < n && 8 + (size_t)(i + 1) * entry <= len; i++) {
            const uint8_t *a = buf + 8 + (size_t)i * entry;
            if (be32(a) != TM_CPU_ARM64) continue;
            uint64_t off = is64 ? (((uint64_t)be32(a + 8) << 32) | be32(a + 12)) : be32(a + 8);
            uint64_t size = is64 ? (((uint64_t)be32(a + 16) << 32) | be32(a + 20)) : be32(a + 12);
            if (off + size > len) continue;
            if (!found) { found = buf + off; found_len = (size_t)size; } // first arm64 slice (plain arm64 before arm64e)
        }
        if (!found) { free(file); return fail(err, errlen, "no arm64 code in the program file"); }
        buf = found;
        len = found_len;
        memcpy(&magic, buf, 4);
    }
    if (magic != TM_MH_MAGIC_64 || len < sizeof(struct tm_mach_header_64)) { free(file); return fail(err, errlen, "not a 64-bit program file"); }

    struct tm_mach_header_64 *mh = (struct tm_mach_header_64 *)buf;
    size_t cmds_start = sizeof(*mh);
    if (cmds_start + mh->sizeofcmds > len) { free(file); return fail(err, errlen, "corrupt load commands"); }

    struct tm_segment_command_64 *linkedit = NULL;
    struct tm_linkedit_data_command *codesig = NULL;
    uint64_t first_section_off = UINT64_MAX;
    int already = 0;
    size_t off = cmds_start;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        if (off + sizeof(struct tm_load_command) > cmds_start + mh->sizeofcmds) { free(file); return fail(err, errlen, "corrupt load commands"); }
        struct tm_load_command *lc = (struct tm_load_command *)(buf + off);
        if (lc->cmdsize < 8 || off + lc->cmdsize > cmds_start + mh->sizeofcmds) { free(file); return fail(err, errlen, "corrupt load command size"); }
        if (lc->cmd == TM_LC_SEGMENT_64 && lc->cmdsize >= sizeof(struct tm_segment_command_64)) {
            struct tm_segment_command_64 *seg = (struct tm_segment_command_64 *)lc;
            if (strncmp(seg->segname, "__LINKEDIT", 16) == 0) linkedit = seg;
            struct tm_section_64 *sect = (struct tm_section_64 *)(seg + 1);
            for (uint32_t s = 0; s < seg->nsects; s++) {
                if ((uint8_t *)(sect + s + 1) > buf + off + lc->cmdsize) break;
                if (sect[s].offset != 0 && sect[s].offset < first_section_off) first_section_off = sect[s].offset;
            }
        } else if (lc->cmd == TM_LC_CODE_SIGNATURE && lc->cmdsize >= sizeof(struct tm_linkedit_data_command)) {
            codesig = (struct tm_linkedit_data_command *)lc;
        } else if (lc->cmd == TM_LC_LOAD_DYLIB && lc->cmdsize >= sizeof(struct tm_dylib_command)) {
            struct tm_dylib_command *dc = (struct tm_dylib_command *)lc;
            if (dc->name_offset < lc->cmdsize && strncmp((const char *)lc + dc->name_offset, dylib_path, lc->cmdsize - dc->name_offset) == 0) already = 1;
        }
        off += lc->cmdsize;
    }
    if (first_section_off == UINT64_MAX) { free(file); return fail(err, errlen, "couldn't find where the code starts"); }

    // 1. Entitlements from the existing signature.
    if (codesig && entitlements_xml && (uint64_t)codesig->dataoff + codesig->datasize <= len && codesig->datasize >= 12) {
        const uint8_t *sig = buf + codesig->dataoff;
        if (be32(sig) == TM_CSMAGIC_EMBEDDED_SIGNATURE) {
            uint32_t count = be32(sig + 8);
            for (uint32_t i = 0; i < count && 12 + (uint64_t)(i + 1) * 8 <= codesig->datasize; i++) {
                uint32_t boff = be32(sig + 12 + i * 8 + 4);
                if ((uint64_t)boff + 8 > codesig->datasize) continue;
                if (be32(sig + boff) != TM_CSMAGIC_ENTITLEMENTS) continue;
                uint32_t blen = be32(sig + boff + 4);
                if (blen < 8 || (uint64_t)boff + blen > codesig->datasize) continue;
                char *xml = malloc(blen - 8 + 1);
                if (xml) { memcpy(xml, sig + boff + 8, blen - 8); xml[blen - 8] = 0; *entitlements_xml = xml; }
                break;
            }
        }
    }

    // 2. Remove the old signature (only when it is the last command and sits at the end of the file, the normal layout).
    if (codesig) {
        int is_last_cmd = ((uint8_t *)codesig + codesig->cmdsize == buf + cmds_start + mh->sizeofcmds);
        int at_end = ((uint64_t)codesig->dataoff + codesig->datasize + 16 >= len) && codesig->dataoff <= len;
        if (is_last_cmd && at_end && linkedit && codesig->dataoff >= linkedit->fileoff) {
            uint32_t dataoff = codesig->dataoff, cmdsize = codesig->cmdsize;
            linkedit->filesize = dataoff - linkedit->fileoff;
            linkedit->vmsize = (linkedit->filesize + 0x3fffu) & ~(uint64_t)0x3fffu;
            memset(codesig, 0, cmdsize);
            mh->ncmds -= 1;
            mh->sizeofcmds -= cmdsize;
            len = dataoff;
        }
    }

    // 3. Add the load command.
    if (!already) {
        size_t name_len = strlen(dylib_path) + 1;
        uint32_t need = (uint32_t)((sizeof(struct tm_dylib_command) + name_len + 7) & ~(size_t)7);
        size_t end = cmds_start + mh->sizeofcmds;
        if (end + need > first_section_off) { free(file); return fail(err, errlen, "no free space in the program header for the add-on"); }
        for (size_t i = 0; i < need; i++) {
            if (buf[end + i] != 0) { free(file); return fail(err, errlen, "program header space is already in use"); }
        }
        struct tm_dylib_command dc = { TM_LC_LOAD_DYLIB, need, (uint32_t)sizeof(struct tm_dylib_command), 2, 0x10000, 0x10000 };
        memcpy(buf + end, &dc, sizeof(dc));
        memcpy(buf + end + sizeof(dc), dylib_path, name_len);
        mh->ncmds += 1;
        mh->sizeofcmds += need;
    }

    // When patching a FAT binary, buf points into file at the arm64 slice offset.
    // The edits were made in-place, so write the entire original file buffer.
    uint8_t *write_buf = file;
    size_t write_len = (buf == file) ? len : (size_t)flen;
    f = fopen(path, "wb");
    if (!f) { free(file); return fail(err, errlen, "can't write the program file"); }
    size_t wrote = fwrite(write_buf, 1, write_len, f);
    int closed = fclose(f);
    free(file);
    if (wrote != write_len || closed != 0) return fail(err, errlen, "writing the program file failed");
    return 0;
}

// Read-only: returns the entitlements XML stored in a program file's signature (caller frees), or NULL.
char *tm_read_entitlements(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long flen = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (flen < (long)sizeof(struct tm_mach_header_64) || flen > 512L * 1024 * 1024) { fclose(f); return NULL; }
    uint8_t *file = malloc((size_t)flen);
    if (!file || fread(file, 1, (size_t)flen, f) != (size_t)flen) { fclose(f); free(file); return NULL; }
    fclose(f);
    uint8_t *buf = file;
    size_t len = (size_t)flen;
    uint32_t magic;
    memcpy(&magic, buf, 4);
    if (magic == TM_FAT_CIGAM || magic == TM_FAT_CIGAM_64) {
        int is64 = (magic == TM_FAT_CIGAM_64);
        uint32_t n = be32(buf + 4);
        size_t entry = is64 ? 32 : 20;
        uint8_t *found = NULL;
        size_t found_len = 0;
        for (uint32_t i = 0; i < n && 8 + (size_t)(i + 1) * entry <= len; i++) {
            const uint8_t *a = buf + 8 + (size_t)i * entry;
            if (be32(a) != TM_CPU_ARM64) continue;
            uint64_t off = is64 ? (((uint64_t)be32(a + 8) << 32) | be32(a + 12)) : be32(a + 8);
            uint64_t size = is64 ? (((uint64_t)be32(a + 16) << 32) | be32(a + 20)) : be32(a + 12);
            if (off + size > len) continue;
            if (!found) { found = buf + off; found_len = (size_t)size; }
        }
        if (!found) { free(file); return NULL; }
        buf = found; len = found_len;
        memcpy(&magic, buf, 4);
    }
    char *result = NULL;
    if (magic == TM_MH_MAGIC_64 && len >= sizeof(struct tm_mach_header_64)) {
        struct tm_mach_header_64 *mh = (struct tm_mach_header_64 *)buf;
        if (mh->sizeofcmds > len - sizeof(*mh)) { free(file); return NULL; }
        size_t off = sizeof(*mh), end = sizeof(*mh) + mh->sizeofcmds;
        for (uint32_t i = 0; i < mh->ncmds && end <= len; i++) {
            if (off + 8 > end) break;
            struct tm_load_command *lc = (struct tm_load_command *)(buf + off);
            if (lc->cmdsize < 8 || off + lc->cmdsize > end) break;
            if (lc->cmd == TM_LC_CODE_SIGNATURE && lc->cmdsize >= sizeof(struct tm_linkedit_data_command)) {
                struct tm_linkedit_data_command *cs = (struct tm_linkedit_data_command *)lc;
                if ((uint64_t)cs->dataoff + cs->datasize <= len && cs->datasize >= 12) {
                    const uint8_t *sig = buf + cs->dataoff;
                    if (be32(sig) == TM_CSMAGIC_EMBEDDED_SIGNATURE) {
                        uint32_t count = be32(sig + 8);
                        for (uint32_t j = 0; j < count && 12 + (uint64_t)(j + 1) * 8 <= cs->datasize; j++) {
                            uint32_t boff = be32(sig + 12 + j * 8 + 4);
                            if ((uint64_t)boff + 8 > cs->datasize || be32(sig + boff) != TM_CSMAGIC_ENTITLEMENTS) continue;
                            uint32_t blen = be32(sig + boff + 4);
                            if (blen < 8 || (uint64_t)boff + blen > cs->datasize) continue;
                            result = malloc(blen - 8 + 1);
                            if (result) { memcpy(result, sig + boff + 8, blen - 8); result[blen - 8] = 0; }
                            break;
                        }
                    }
                }
                break;
            }
            off += lc->cmdsize;
        }
    }
    free(file);
    return result;
}

#ifdef TM_PATCH_MAIN
int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "--read") == 0) { char *x = tm_read_entitlements(argv[2]); if (!x) return 1; fputs(x, stdout); return 0; }
    if (argc < 3) { fprintf(stderr, "usage: machopatch <file> <dylib path>\n"); return 2; }
    char err[256] = "";
    char *xml = NULL;
    int r = tm_patch_macho(argv[1], argv[2], &xml, err, sizeof(err));
    if (r != 0) { fprintf(stderr, "error: %s\n", err); return 1; }
    if (xml) fputs(xml, stdout);
    return 0;
}
#endif

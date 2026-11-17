// tmzip - minimal zip extractor (store + deflate), preserving unix permissions and symlinks.
// Used to unpack an IPA so each Mach-O inside can be signed before install.
// Portable C (zlib) so it can be tested on Linux and shipped on iOS.
#include "tmzip.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <zlib.h>

static uint16_t rd16(const uint8_t *p) { return (uint16_t)(p[0] | (p[1] << 8)); }
static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

static int fail(char *err, size_t errlen, const char *msg) {
    if (err && errlen) snprintf(err, errlen, "%s", msg);
    return -1;
}

// Rejects path components that would escape the destination directory.
static int safe_name(const char *name) {
    if (name[0] == '/' || name[0] == '\\') return 0;
    if (strstr(name, "..")) {
        // reject any ".." path component
        const char *p = name;
        while (p) {
            if ((p[0] == '.') && (p[1] == '.') && (p[2] == '/' || p[2] == '\\' || p[2] == 0) && (p == name || p[-1] == '/' || p[-1] == '\\')) return 0;
            p = strpbrk(p, "/\\");
            if (p) p++;
        }
    }
    return 1;
}

static int make_dirs(const char *path) {
    char tmp[PATH_MAX];
    size_t len = strlen(path);
    if (len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            if (mkdir(tmp, 0755) != 0 && errno != EEXIST) return -1;
            *p = '/';
        }
    }
    return 0;
}

int tm_extract_zip(const char *zip_path, const char *dest_dir, char *err, size_t errlen) {
    FILE *f = fopen(zip_path, "rb");
    if (!f) return fail(err, errlen, "can't open the archive");
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return fail(err, errlen, "can't read the archive"); }
    long flen = ftell(f);
    if (flen < 22) { fclose(f); return fail(err, errlen, "archive is too small"); }

    // Find the End Of Central Directory record (search backwards for its signature).
    long scan = flen - 22;
    long scan_min = (flen > 22 + 65535) ? flen - 22 - 65535 : 0;
    uint8_t sigbuf[4];
    long eocd = -1;
    for (; scan >= scan_min; scan--) {
        if (fseek(f, scan, SEEK_SET) != 0) break;
        if (fread(sigbuf, 1, 4, f) != 4) break;
        if (rd32(sigbuf) == 0x06054b50) { eocd = scan; break; }
    }
    if (eocd < 0) { fclose(f); return fail(err, errlen, "not a valid archive (no directory found)"); }

    uint8_t eo[22];
    fseek(f, eocd, SEEK_SET);
    if (fread(eo, 1, 22, f) != 22) { fclose(f); return fail(err, errlen, "corrupt archive directory"); }
    uint32_t total = rd16(eo + 10);
    uint32_t cd_size = rd32(eo + 12);
    uint32_t cd_off = rd32(eo + 16);
    if ((long)cd_off + cd_size > flen) { fclose(f); return fail(err, errlen, "corrupt archive directory"); }
    if (cd_size > 100UL * 1024 * 1024) { fclose(f); return fail(err, errlen, "central directory too large"); }

    uint8_t *cd = malloc(cd_size);
    if (!cd) { fclose(f); return fail(err, errlen, "out of memory"); }
    fseek(f, cd_off, SEEK_SET);
    if (fread(cd, 1, cd_size, f) != cd_size) { free(cd); fclose(f); return fail(err, errlen, "corrupt archive directory"); }

    size_t p = 0;
    int rc = 0;
    for (uint32_t i = 0; i < total && rc == 0; i++) {
        if (p + 46 > cd_size || rd32(cd + p) != 0x02014b50) { rc = fail(err, errlen, "corrupt archive entry"); break; }
        uint16_t method = rd16(cd + p + 10);
        uint32_t comp_size = rd32(cd + p + 20);
        uint32_t uncomp_size = rd32(cd + p + 24);
        uint16_t name_len = rd16(cd + p + 28);
        uint16_t extra_len = rd16(cd + p + 30);
        uint16_t comment_len = rd16(cd + p + 32);
        uint32_t ext_attrs = rd32(cd + p + 38);
        uint32_t local_off = rd32(cd + p + 42);
        if (p + 46 + name_len > cd_size) { rc = fail(err, errlen, "corrupt archive entry"); break; }
        char name[PATH_MAX];
        if (name_len >= sizeof(name)) { rc = fail(err, errlen, "a name in the archive is too long"); break; }
        memcpy(name, cd + p + 46, name_len);
        name[name_len] = 0;
        size_t cd_entry = p;
        p += 46 + name_len + extra_len + comment_len;

        if (name_len == 0) continue;
        if (!safe_name(name)) { rc = fail(err, errlen, "the archive contains an unsafe path"); break; }

        // Zip bomb protection: reject unreasonably large entries or suspicious ratios
        if (uncomp_size > 500UL * 1024 * 1024) { rc = fail(err, errlen, "a file in the archive is too large"); break; }
        if (uncomp_size > 0 && comp_size > 0 && uncomp_size / comp_size > 1000) { rc = fail(err, errlen, "suspicious compression ratio"); break; }

        uint32_t mode = ext_attrs >> 16;
        int is_dir = (name_len > 0 && (name[name_len - 1] == '/'));
        int is_link = ((mode & 0xF000) == 0xA000);

        char out[PATH_MAX];
        if ((size_t)snprintf(out, sizeof(out), "%s/%s", dest_dir, name) >= sizeof(out)) { rc = fail(err, errlen, "a path is too long"); break; }

        if (is_dir) { make_dirs(out); mkdir(out, 0755); continue; }
        if (make_dirs(out) != 0) { rc = fail(err, errlen, "couldn't create a folder"); break; }

        // Read the local header to find where the data starts (its name/extra lengths can differ).
        uint8_t lh[30];
        if (fseek(f, local_off, SEEK_SET) != 0 || fread(lh, 1, 30, f) != 30 || rd32(lh) != 0x04034b50) { rc = fail(err, errlen, "corrupt archive entry"); break; }
        long data_off = (long)local_off + 30 + rd16(lh + 26) + rd16(lh + 28);
        if (data_off + comp_size > (size_t)flen) { rc = fail(err, errlen, "corrupt archive entry"); break; }

        uint8_t *comp = malloc(comp_size ? comp_size : 1);
        uint8_t *raw = malloc(uncomp_size ? uncomp_size : 1);
        if (!comp || !raw) { free(comp); free(raw); rc = fail(err, errlen, "out of memory"); break; }
        fseek(f, data_off, SEEK_SET);
        if (fread(comp, 1, comp_size, f) != comp_size) { free(comp); free(raw); rc = fail(err, errlen, "couldn't read archive data"); break; }

        int ok = 0;
        if (method == 0) {
            if (comp_size == uncomp_size) { memcpy(raw, comp, uncomp_size); ok = 1; }
        } else if (method == 8) {
            z_stream zs = {0};
            if (inflateInit2(&zs, -15) == Z_OK) {
                zs.next_in = comp; zs.avail_in = comp_size;
                zs.next_out = raw; zs.avail_out = uncomp_size;
                int zr = inflate(&zs, Z_FINISH);
                inflateEnd(&zs);
                if ((zr == Z_STREAM_END || zr == Z_OK) && zs.total_out == uncomp_size) ok = 1;
            }
        }
        if (!ok) { free(comp); free(raw); rc = fail(err, errlen, "couldn't unpack a file (unsupported compression)"); break; }

        // CRC32 verification: compare against value from central directory (cd + cd_entry + 16)
        {
            uint32_t expected_crc = rd32(cd + cd_entry + 16);
            uint32_t actual_crc = (uint32_t)crc32(crc32(0L, Z_NULL, 0), raw, uncomp_size);
            if (actual_crc != expected_crc) { free(comp); free(raw); rc = fail(err, errlen, "CRC mismatch"); break; }
        }

        if (is_link) {
            char target[PATH_MAX];
            if (uncomp_size < sizeof(target)) {
                memcpy(target, raw, uncomp_size);
                target[uncomp_size] = 0;
                // Validate symlink target does not escape extraction directory
                if (target[0] == '/' || strstr(target, "..")) {
                    free(comp); free(raw);
                    continue;
                }
                unlink(out);
                if (symlink(target, out) != 0) rc = fail(err, errlen, "couldn't create a symlink");
            }
        } else {
            FILE *of = fopen(out, "wb");
            if (!of) { free(comp); free(raw); rc = fail(err, errlen, "couldn't write a file"); break; }
            size_t w = uncomp_size ? fwrite(raw, 1, uncomp_size, of) : 0;
            int cl = fclose(of);
            if (w != uncomp_size || cl != 0) rc = fail(err, errlen, "couldn't write a file");
            else {
                mode_t perm = (mode & 0777);
                if (perm == 0) perm = 0644;
                chmod(out, perm);
            }
        }
        free(comp);
        free(raw);
    }
    free(cd);
    fclose(f);
    return rc;
}

#ifdef TM_ZIP_MAIN
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: tmzip <zip> <destdir>\n"); return 2; }
    char err[256] = "";
    if (tm_extract_zip(argv[1], argv[2], err, sizeof(err)) != 0) { fprintf(stderr, "error: %s\n", err); return 1; }
    return 0;
}
#endif

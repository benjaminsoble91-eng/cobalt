// ticket.h: tiny IM4M (onboard ticket) reader for BlobKeeper. Plain C so it can be tested off-device.
// An IM4M is DER: SEQUENCE { IA5String "IM4M", INTEGER 0, SET { MANB { ... MANP { properties } } }, sig, certs }.
// Each manifest property is SEQUENCE { IA5String <4-char name>, value }. We only need a few of them,
// so instead of a full DER walk we look for "<IA5String name>" followed by the expected value type.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    int valid;               // looks like an IM4M
    int has_ecid;  uint64_t ecid;
    int has_bnch;  uint8_t bnch[64];  size_t bnch_len;   // ApNonce the ticket was signed for
    int has_chip;  uint64_t chip;
    int has_bord;  uint64_t bord;
} bk_ticket;

// Reads a DER length at p (p < end). Returns bytes used, 0 on error.
static size_t bk_der_len(const uint8_t *p, const uint8_t *end, size_t *len) {
    if (p >= end) return 0;
    if (!(p[0] & 0x80)) { *len = p[0]; return 1; }
    size_t n = p[0] & 0x7f;
    if (n == 0 || n > 4 || p + 1 + n > end) return 0;
    size_t v = 0;
    for (size_t i = 0; i < n; i++) v = (v << 8) | p[1 + i];
    *len = v;
    return 1 + n;
}

// Finds IA5String(name) followed by a value with the given DER tag. Returns value bytes or NULL.
static const uint8_t *bk_find_prop(const uint8_t *buf, size_t size, const char name[4], uint8_t tag, size_t *vlen) {
    const uint8_t *end = buf + size;
    for (const uint8_t *p = buf; p + 8 < end; p++) {
        if (p[0] != 0x16 || p[1] != 0x04 || memcmp(p + 2, name, 4) != 0) continue;
        const uint8_t *q = p + 6;
        if (q >= end || q[0] != tag) continue;
        size_t len = 0, used = bk_der_len(q + 1, end, &len);
        if (!used || q + 1 + used + len > end) continue;
        *vlen = len;
        return q + 1 + used;
    }
    return NULL;
}

static int bk_read_int(const uint8_t *buf, size_t size, const char name[4], uint64_t *out) {
    size_t len = 0;
    const uint8_t *v = bk_find_prop(buf, size, name, 0x02, &len);
    if (!v || len == 0 || len > 9) return 0;
    uint64_t x = 0;
    for (size_t i = 0; i < len; i++) x = (x << 8) | v[i];   // leading 0x00 pad byte is harmless
    *out = x;
    return 1;
}

static void bk_parse_ticket(const uint8_t *buf, size_t size, bk_ticket *t) {
    memset(t, 0, sizeof(*t));
    if (size < 16 || buf[0] != 0x30) return;
    // "IM4M" must be the first element of the outer SEQUENCE.
    size_t len = 0, used = bk_der_len(buf + 1, buf + size, &len);
    if (!used) return;
    const uint8_t *p = buf + 1 + used;
    if (p + 6 > buf + size || p[0] != 0x16 || p[1] != 0x04 || memcmp(p + 2, "IM4M", 4) != 0) return;
    t->valid = 1;
    t->has_ecid = bk_read_int(buf, size, "ECID", &t->ecid);
    t->has_chip = bk_read_int(buf, size, "CHIP", &t->chip);
    t->has_bord = bk_read_int(buf, size, "BORD", &t->bord);
    size_t blen = 0;
    const uint8_t *b = bk_find_prop(buf, size, "BNCH", 0x04, &blen);
    if (b && blen > 0 && blen <= sizeof(t->bnch)) {
        memcpy(t->bnch, b, blen);
        t->bnch_len = blen;
        t->has_bnch = 1;
    }
}

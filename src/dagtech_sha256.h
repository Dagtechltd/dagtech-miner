/*
 * DagTech SHA-256 Implementation
 * Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
 *
 * Standalone SHA-256 implementation for portability.
 * Used when OpenSSL is not available on the build system.
 * When building with -DUSE_OPENSSL, the OpenSSL library is used instead.
 */

#ifndef DAGTECH_SHA256_H
#define DAGTECH_SHA256_H

#include <stdint.h>
#include <string.h>

typedef struct {
    uint32_t state[8];
    uint64_t count;
    uint8_t  buffer[64];
} DAGTECH_SHA256_CTX;

static const uint32_t dagtech_sha256_k[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

#define DAGTECH_ROR32(x, n) (((x) >> (n)) | ((x) << (32 - (n))))
#define DAGTECH_CH(x, y, z)  (((x) & (y)) ^ (~(x) & (z)))
#define DAGTECH_MAJ(x, y, z) (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))
#define DAGTECH_EP0(x)  (DAGTECH_ROR32(x, 2) ^ DAGTECH_ROR32(x, 13) ^ DAGTECH_ROR32(x, 22))
#define DAGTECH_EP1(x)  (DAGTECH_ROR32(x, 6) ^ DAGTECH_ROR32(x, 11) ^ DAGTECH_ROR32(x, 25))
#define DAGTECH_SIG0(x) (DAGTECH_ROR32(x, 7) ^ DAGTECH_ROR32(x, 18) ^ ((x) >> 3))
#define DAGTECH_SIG1(x) (DAGTECH_ROR32(x, 17) ^ DAGTECH_ROR32(x, 19) ^ ((x) >> 10))

static inline void dagtech_sha256_transform(uint32_t state[8], const uint8_t data[64]) {
    uint32_t a, b, c, d, e, f, g, h, t1, t2, w[64];
    int i;

    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)data[i*4] << 24) | ((uint32_t)data[i*4+1] << 16) |
               ((uint32_t)data[i*4+2] << 8) | data[i*4+3];
    for (i = 16; i < 64; i++)
        w[i] = DAGTECH_SIG1(w[i-2]) + w[i-7] + DAGTECH_SIG0(w[i-15]) + w[i-16];

    a = state[0]; b = state[1]; c = state[2]; d = state[3];
    e = state[4]; f = state[5]; g = state[6]; h = state[7];

    for (i = 0; i < 64; i++) {
        t1 = h + DAGTECH_EP1(e) + DAGTECH_CH(e, f, g) + dagtech_sha256_k[i] + w[i];
        t2 = DAGTECH_EP0(a) + DAGTECH_MAJ(a, b, c);
        h = g; g = f; f = e; e = d + t1;
        d = c; c = b; b = a; a = t1 + t2;
    }

    state[0] += a; state[1] += b; state[2] += c; state[3] += d;
    state[4] += e; state[5] += f; state[6] += g; state[7] += h;
}

static inline void dagtech_sha256_init(DAGTECH_SHA256_CTX *ctx) {
    ctx->state[0] = 0x6a09e667; ctx->state[1] = 0xbb67ae85;
    ctx->state[2] = 0x3c6ef372; ctx->state[3] = 0xa54ff53a;
    ctx->state[4] = 0x510e527f; ctx->state[5] = 0x9b05688c;
    ctx->state[6] = 0x1f83d9ab; ctx->state[7] = 0x5be0cd19;
    ctx->count = 0;
}

static inline void dagtech_sha256_update(DAGTECH_SHA256_CTX *ctx, const uint8_t *data, size_t len) {
    size_t i, idx;
    idx = (size_t)(ctx->count & 63);
    ctx->count += len;

    for (i = 0; i < len; i++) {
        ctx->buffer[idx++] = data[i];
        if (idx == 64) {
            dagtech_sha256_transform(ctx->state, ctx->buffer);
            idx = 0;
        }
    }
}

static inline void dagtech_sha256_final(DAGTECH_SHA256_CTX *ctx, uint8_t hash[32]) {
    size_t idx = (size_t)(ctx->count & 63);
    uint64_t bits = ctx->count * 8;

    ctx->buffer[idx++] = 0x80;
    if (idx > 56) {
        memset(ctx->buffer + idx, 0, 64 - idx);
        dagtech_sha256_transform(ctx->state, ctx->buffer);
        idx = 0;
    }
    memset(ctx->buffer + idx, 0, 56 - idx);

    ctx->buffer[56] = (uint8_t)(bits >> 56);
    ctx->buffer[57] = (uint8_t)(bits >> 48);
    ctx->buffer[58] = (uint8_t)(bits >> 40);
    ctx->buffer[59] = (uint8_t)(bits >> 32);
    ctx->buffer[60] = (uint8_t)(bits >> 24);
    ctx->buffer[61] = (uint8_t)(bits >> 16);
    ctx->buffer[62] = (uint8_t)(bits >> 8);
    ctx->buffer[63] = (uint8_t)(bits);
    dagtech_sha256_transform(ctx->state, ctx->buffer);

    for (int i = 0; i < 8; i++) {
        hash[i*4]   = (uint8_t)(ctx->state[i] >> 24);
        hash[i*4+1] = (uint8_t)(ctx->state[i] >> 16);
        hash[i*4+2] = (uint8_t)(ctx->state[i] >> 8);
        hash[i*4+3] = (uint8_t)(ctx->state[i]);
    }
}

/* Convenience: one-shot SHA-256 */
static inline void dagtech_sha256(const uint8_t *data, size_t len, uint8_t hash[32]) {
    DAGTECH_SHA256_CTX ctx;
    dagtech_sha256_init(&ctx);
    dagtech_sha256_update(&ctx, data, len);
    dagtech_sha256_final(&ctx, hash);
}

#endif /* DAGTECH_SHA256_H */

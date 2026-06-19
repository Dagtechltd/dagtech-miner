// bdag_metal_scrypt.metal
// scrypt(N=1024, r=1, p=1) + BlockDAG post-ROMix tweak — Metal Shading Language
// Ported from bdag_scrypt_lib.c (CPU reference) + scrypt_cores.cu (CUDA)
// Copyright (c) 2026 DagTech Ltd. CONFIDENTIAL.
#include <metal_stdlib>
using namespace metal;

constant uint32_t SHA256_H[8] = {
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
};
constant uint32_t SHA256_K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

inline uint32_t swab32(uint32_t x) {
    return ((x & 0x000000ffu) << 24) | ((x & 0x0000ff00u) << 8) |
           ((x & 0x00ff0000u) >> 8)  | ((x & 0xff000000u) >> 24);
}
inline uint32_t rotr(uint32_t x, uint n) { return (x >> n) | (x << (32u - n)); }

static void sha256_init(thread uint32_t state[8]) {
    for (int i = 0; i < 8; ++i) state[i] = SHA256_H[i];
}

// SHA256 block compression on a 64-byte block already loaded as 16 big-endian uint32 words.
static void sha256_block(thread uint32_t state[8], thread const uint32_t W_in[16]) {
    uint32_t W[64];
    for (int i = 0; i < 16; ++i) W[i] = W_in[i];
    for (int i = 16; i < 64; ++i) {
        uint32_t s0 = rotr(W[i-15], 7) ^ rotr(W[i-15], 18) ^ (W[i-15] >> 3);
        uint32_t s1 = rotr(W[i-2], 17) ^ rotr(W[i-2], 19) ^ (W[i-2] >> 10);
        W[i] = s1 + W[i-7] + s0 + W[i-16];
    }
    uint32_t a=state[0], b=state[1], c=state[2], d=state[3];
    uint32_t e=state[4], f=state[5], g=state[6], h=state[7];
    for (int i = 0; i < 64; ++i) {
        uint32_t S1 = rotr(e,6) ^ rotr(e,11) ^ rotr(e,25);
        uint32_t ch = (e & f) ^ (~e & g);
        uint32_t t0 = h + S1 + ch + SHA256_K[i] + W[i];
        uint32_t S0 = rotr(a,2) ^ rotr(a,13) ^ rotr(a,22);
        uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
        uint32_t t1 = S0 + mj;
        h=g; g=f; f=e; e=d+t0; d=c; c=b; b=a; a=t0+t1;
    }
    state[0]+=a; state[1]+=b; state[2]+=c; state[3]+=d;
    state[4]+=e; state[5]+=f; state[6]+=g; state[7]+=h;
}

// Pack 64 bytes into 16 BE uint32 words.
static void pack_block(thread const uint8_t bytes[64], thread uint32_t W[16]) {
    for (int i = 0; i < 16; ++i) {
        W[i] = (uint32_t(bytes[i*4])<<24) | (uint32_t(bytes[i*4+1])<<16) |
               (uint32_t(bytes[i*4+2])<<8) | uint32_t(bytes[i*4+3]);
    }
}
// Unpack 8 uint32 state -> 32 bytes BE.
static void unpack_state(thread const uint32_t state[8], thread uint8_t out[32]) {
    for (int i = 0; i < 8; ++i) {
        out[i*4]   = (state[i]>>24)&0xff;
        out[i*4+1] = (state[i]>>16)&0xff;
        out[i*4+2] = (state[i]>>8)&0xff;
        out[i*4+3] = state[i]&0xff;
    }
}

// SHA256 on an arbitrary-length byte buffer (small, all in thread mem).
static void sha256_full(thread const uint8_t *data, uint len, thread uint8_t out[32]) {
    uint32_t state[8]; sha256_init(state);
    uint pos = 0;
    uint32_t W[16];
    while (pos + 64 <= len) {
        uint8_t tmp[64];
        for (int i = 0; i < 64; ++i) tmp[i] = data[pos+i];
        pack_block(tmp, W);
        sha256_block(state, W);
        pos += 64;
    }
    uint8_t tail[128] = {0};
    uint rem = len - pos;
    for (uint i = 0; i < rem; ++i) tail[i] = data[pos+i];
    tail[rem] = 0x80;
    uint64_t bits = (uint64_t)len * 8u;
    if (rem + 1 + 8 <= 64) {
        tail[56] = (bits>>56)&0xff; tail[57] = (bits>>48)&0xff;
        tail[58] = (bits>>40)&0xff; tail[59] = (bits>>32)&0xff;
        tail[60] = (bits>>24)&0xff; tail[61] = (bits>>16)&0xff;
        tail[62] = (bits>>8)&0xff;  tail[63] = bits&0xff;
        uint8_t blk[64]; for (int i=0;i<64;++i) blk[i] = tail[i];
        pack_block(blk, W); sha256_block(state, W);
    } else {
        uint8_t blk1[64]; for (int i=0;i<64;++i) blk1[i] = tail[i];
        pack_block(blk1, W); sha256_block(state, W);
        tail[120] = (bits>>56)&0xff; tail[121] = (bits>>48)&0xff;
        tail[122] = (bits>>40)&0xff; tail[123] = (bits>>32)&0xff;
        tail[124] = (bits>>24)&0xff; tail[125] = (bits>>16)&0xff;
        tail[126] = (bits>>8)&0xff;  tail[127] = bits&0xff;
        uint8_t blk2[64]; for (int i=0;i<64;++i) blk2[i] = tail[64+i];
        pack_block(blk2, W); sha256_block(state, W);
    }
    unpack_state(state, out);
}
// HMAC-SHA256 for arbitrary key/data lengths (key <=80, data <=132 for our use case).
static void hmac_sha256_msg(thread const uint8_t *key, uint keylen,
                            thread const uint8_t *data, uint datalen,
                            thread uint8_t out[32]) {
    uint8_t k[64] = {0};
    if (keylen > 64) {
        uint8_t kh[32];
        sha256_full(key, keylen, kh);
        for (int i = 0; i < 32; ++i) k[i] = kh[i];
    } else {
        for (uint i = 0; i < keylen; ++i) k[i] = key[i];
    }
    uint8_t ipad[64], opad[64];
    for (int i = 0; i < 64; ++i) { ipad[i] = 0x36 ^ k[i]; opad[i] = 0x5c ^ k[i]; }
    // inner: SHA256(ipad || data)
    uint8_t inner_buf[256]; // up to 64 + 132 = 196
    for (int i = 0; i < 64; ++i) inner_buf[i] = ipad[i];
    for (uint i = 0; i < datalen; ++i) inner_buf[64+i] = data[i];
    uint8_t inner_hash[32];
    sha256_full(inner_buf, 64 + datalen, inner_hash);
    // outer: SHA256(opad || inner_hash)
    uint8_t outer_buf[96];
    for (int i = 0; i < 64; ++i) outer_buf[i] = opad[i];
    for (int i = 0; i < 32; ++i) outer_buf[64+i] = inner_hash[i];
    sha256_full(outer_buf, 96, out);
}

// PBKDF2-HMAC-SHA256 with key=password, salt=salt, blocks*32 bytes output.
// We only ever need 128 bytes (4 blocks) or 32 bytes (1 block).
static void pbkdf2_sha256(thread const uint8_t *pw, uint pwlen,
                          thread const uint8_t *salt, uint saltlen,
                          thread uint8_t *out, uint outlen) {
    uint blocks = (outlen + 31) / 32;
    for (uint b = 1; b <= blocks; ++b) {
        uint8_t buf[256];
        for (uint i = 0; i < saltlen; ++i) buf[i] = salt[i];
        buf[saltlen]   = (b >> 24) & 0xff;
        buf[saltlen+1] = (b >> 16) & 0xff;
        buf[saltlen+2] = (b >> 8) & 0xff;
        buf[saltlen+3] = b & 0xff;
        uint8_t U[32];
        hmac_sha256_msg(pw, pwlen, buf, saltlen + 4, U);
        // c=1 — single iteration, T = U[0]
        uint copylen = (b == blocks) ? (outlen - (b-1)*32) : 32;
        for (uint i = 0; i < copylen; ++i) out[(b-1)*32 + i] = U[i];
    }
}

// Salsa20/8 — 8 rounds (4 pairs of column+row mix).
// B and Bx are 16 uint32 each (64 bytes); B = (B ^ Bx) then run Salsa, B += working.
static void salsa20_8(thread uint32_t B[16], thread const uint32_t Bx[16]) {
    uint32_t x[16];
    for (int i = 0; i < 16; ++i) { B[i] ^= Bx[i]; x[i] = B[i]; }
    for (int r = 0; r < 4; ++r) {
        // column round
        x[4]  ^= rotr(x[0]+x[12], 32-7);  x[9]  ^= rotr(x[5]+x[1],  32-7);
        x[14] ^= rotr(x[10]+x[6], 32-7);  x[3]  ^= rotr(x[15]+x[11],32-7);
        x[8]  ^= rotr(x[4]+x[0],  32-9);  x[13] ^= rotr(x[9]+x[5],  32-9);
        x[2]  ^= rotr(x[14]+x[10],32-9);  x[7]  ^= rotr(x[3]+x[15], 32-9);
        x[12] ^= rotr(x[8]+x[4],  32-13); x[1]  ^= rotr(x[13]+x[9], 32-13);
        x[6]  ^= rotr(x[2]+x[14], 32-13); x[11] ^= rotr(x[7]+x[3],  32-13);
        x[0]  ^= rotr(x[12]+x[8], 32-18); x[5]  ^= rotr(x[1]+x[13], 32-18);
        x[10] ^= rotr(x[6]+x[2],  32-18); x[15] ^= rotr(x[11]+x[7], 32-18);
        // row round
        x[1]  ^= rotr(x[0]+x[3],  32-7);  x[6]  ^= rotr(x[5]+x[4],  32-7);
        x[11] ^= rotr(x[10]+x[9], 32-7);  x[12] ^= rotr(x[15]+x[14],32-7);
        x[2]  ^= rotr(x[1]+x[0],  32-9);  x[7]  ^= rotr(x[6]+x[5],  32-9);
        x[8]  ^= rotr(x[11]+x[10],32-9);  x[13] ^= rotr(x[12]+x[15],32-9);
        x[3]  ^= rotr(x[2]+x[1],  32-13); x[4]  ^= rotr(x[7]+x[6],  32-13);
        x[9]  ^= rotr(x[8]+x[11], 32-13); x[14] ^= rotr(x[13]+x[12],32-13);
        x[0]  ^= rotr(x[3]+x[2],  32-18); x[5]  ^= rotr(x[4]+x[7],  32-18);
        x[10] ^= rotr(x[9]+x[8],  32-18); x[15] ^= rotr(x[14]+x[13],32-18);
    }
    for (int i = 0; i < 16; ++i) B[i] += x[i];
}
// scrypt ROMix: V is in device memory (128 KB per thread = 1024 * 32 uint32).
// X is the 32-uint32 working state in thread memory.
static void scrypt_romix_device(thread uint32_t X[32], device uint32_t *V) {
    uint32_t Bcopy[16];
    // Fill phase
    for (int i = 0; i < 1024; ++i) {
        for (int k = 0; k < 32; ++k) V[i*32 + k] = X[k];
        for (int k = 0; k < 16; ++k) Bcopy[k] = X[16+k];
        salsa20_8(*(thread uint32_t (*)[16])(X+0),  *(thread const uint32_t (*)[16])(X+16));
        for (int k = 0; k < 16; ++k) Bcopy[k] = X[k];
        salsa20_8(*(thread uint32_t (*)[16])(X+16), *(thread const uint32_t (*)[16])(X+0));
    }
    // Mix phase
    for (int i = 0; i < 1024; ++i) {
        uint32_t j = X[16] & 1023u;
        for (int k = 0; k < 32; ++k) X[k] ^= V[j*32 + k];
        salsa20_8(*(thread uint32_t (*)[16])(X+0),  *(thread const uint32_t (*)[16])(X+16));
        salsa20_8(*(thread uint32_t (*)[16])(X+16), *(thread const uint32_t (*)[16])(X+0));
    }
}

// BlockDAG post-ROMix tweak (the unique BDAG bit).
static void bdag_post_romix_tweak(thread uint32_t X[32]) {
    uint32_t x = swab32(X[0]);
    x = (x & 0xffff8000u) | ((x + 0xe0u) & 0x7fffu);
    X[0] = swab32(x);
}

// === MAIN KERNEL ===
// One thread per nonce. Computes full BDAG-scrypt hash for nonce_start+tid,
// writes 32-byte hash to out_hashes[tid * 32 .. tid*32+31].
//
// Buffers:
//   [0] hdr_in:      80-byte template header (last 4 bytes overwritten by nonce per thread)
//   [1] nonce_start: uint32_t starting nonce
//   [2] V_global:    device memory pool, 128KB * num_threads (32 MB for 256 threads)
//   [3] out_hashes:  num_threads * 32 bytes output
kernel void bdag_scrypt_kernel(
    constant uint8_t  *hdr_in       [[buffer(0)]],
    constant uint32_t &nonce_start  [[buffer(1)]],
    device   uint8_t  *V_global     [[buffer(2)]],
    device   uint8_t  *out_hashes   [[buffer(3)]],
    uint     tid                    [[thread_position_in_grid]])
{
    // 1. Build 80-byte header for this thread's nonce.
    uint8_t hdr80[80];
    for (int i = 0; i < 76; ++i) hdr80[i] = hdr_in[i];
    uint32_t nonce = nonce_start + tid;
    // Nonce written little-endian to bytes 76..79 of header (this is the stratum-side nonce
    // position; the byte-swap loop below converts it to BE words for hashing).
    hdr80[76] = nonce & 0xff;
    hdr80[77] = (nonce >> 8) & 0xff;
    hdr80[78] = (nonce >> 16) & 0xff;
    hdr80[79] = (nonce >> 24) & 0xff;

    // 2. Byte-swap each uint32 (BDAG header word-endian convention from bdag_scrypt_lib.c).
    uint8_t swapped[80];
    for (int i = 0; i < 80; i += 4) {
        swapped[i]   = hdr80[i+3];
        swapped[i+1] = hdr80[i+2];
        swapped[i+2] = hdr80[i+1];
        swapped[i+3] = hdr80[i+0];
    }

    // 3. PBKDF2-HMAC-SHA256(pw=swapped, salt=swapped, dklen=128) -> X[0..31] as 32 BE uint32.
    uint8_t X_bytes[128];
    pbkdf2_sha256(swapped, 80, swapped, 80, X_bytes, 128);
    uint32_t X[32];
    for (int i = 0; i < 32; ++i) {
        X[i] = uint32_t(X_bytes[i*4]) | (uint32_t(X_bytes[i*4+1])<<8) |
               (uint32_t(X_bytes[i*4+2])<<16) | (uint32_t(X_bytes[i*4+3])<<24);
    }

    // 4. scrypt ROMix with N=1024, using device-memory V slice for this thread.
    device uint32_t *V = (device uint32_t *)(V_global + uint64_t(tid) * 128u * 1024u);
    scrypt_romix_device(X, V);

    // 5. BDAG post-ROMix tweak.
    bdag_post_romix_tweak(X);

    // 6. Final PBKDF2-HMAC-SHA256(pw=swapped, salt=X_bytes, dklen=32) -> 32-byte hash.
    for (int i = 0; i < 32; ++i) {
        X_bytes[i*4]   = X[i]       & 0xff;
        X_bytes[i*4+1] = (X[i]>>8)  & 0xff;
        X_bytes[i*4+2] = (X[i]>>16) & 0xff;
        X_bytes[i*4+3] = (X[i]>>24) & 0xff;
    }
    uint8_t out32[32];
    pbkdf2_sha256(swapped, 80, X_bytes, 128, out32, 32);

    // 7. Write result.
    for (int i = 0; i < 32; ++i) out_hashes[tid * 32 + i] = out32[i];
}
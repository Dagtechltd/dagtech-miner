/*
 * DagTech Miner - High Performance CPU Mining Engine
 * Copyright (c) 2024-2026 DagTech Ltd / Dawie Nel
 * https://dagtech.network
 *
 * Licensed under the MIT License.
 * Custom implementation of Modified Scrypt (N=1024, r=1, p=1)
 * with proprietary post-ROMix transformation.
 *
 * Stratum protocol compatible with standard mining pools.
 *
 * Author:  Dawie Nel <dawie@dagtech.network>
 * Project: DagTech Mining Suite
 * Version: 1.0.0
 */

#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #ifdef _MSC_VER
    #pragma comment(lib, "ws2_32.lib")
    typedef int ssize_t;
  #endif
  #define close closesocket
  #define usleep(x) Sleep((x)/1000)
  #define sleep(x) Sleep((x)*1000)
#else
  #include <arpa/inet.h>
  #include <netdb.h>
  #include <netinet/in.h>
  #include <sys/socket.h>
  #include <unistd.h>
  #ifdef __APPLE__
    #include <sys/sysctl.h>
  #endif
#endif

#ifdef USE_OPENSSL
  #include <openssl/sha.h>
  #define DT_SHA256(data, len, out)       SHA256(data, len, out)
  #define DT_SHA256_CTX                   SHA256_CTX
  #define DT_SHA256_Init(ctx)             SHA256_Init(ctx)
  #define DT_SHA256_Update(ctx, d, l)     SHA256_Update(ctx, d, l)
  #define DT_SHA256_Final(out, ctx)       SHA256_Final(out, ctx)
#else
  #include "dagtech_sha256.h"
  #define DT_SHA256(data, len, out)       dagtech_sha256(data, len, out)
  #define DT_SHA256_CTX                   DAGTECH_SHA256_CTX
  #define DT_SHA256_Init(ctx)             dagtech_sha256_init(ctx)
  #define DT_SHA256_Update(ctx, d, l)     dagtech_sha256_update(ctx, d, l)
  #define DT_SHA256_Final(out, ctx)       dagtech_sha256_final(ctx, out)
#endif

#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>
#include <math.h>

/* =========================================================================
 * DagTech Miner Configuration
 * ========================================================================= */
#define DAGTECH_VERSION       "1.0.0"
#define DAGTECH_BANNER        "DagTech Miner v" DAGTECH_VERSION " - dagtech.network"
#define DAGTECH_AUTHOR        "Dawie Nel / DagTech Ltd"
#define DAGTECH_DEFAULT_POOL  "excalibur.dagtech.network"
#define DAGTECH_DEFAULT_PORT  3334

/* Scrypt parameters - fixed for this algorithm */
#define SCRYPT_N  1024
#define SCRYPT_R  1
#define SCRYPT_P  1

/* =========================================================================
 * Runtime State
 * ========================================================================= */
static char pool_host[256] = DAGTECH_DEFAULT_POOL;
static int  pool_port      = DAGTECH_DEFAULT_PORT;
static char wallet[128]    = "";
static char worker_name[64]= "dagtech";
static char password[32]   = "x";
static int  num_threads    = 0;  /* 0 = auto-detect */
static int  cpu_priority   = 0;  /* 0=normal, 1=low */
static volatile int running = 1;
static int  metrics_port   = 8880;  /* built-in metrics endpoint */

/* Stratum connection */
static int sockfd = -1;
static pthread_mutex_t sock_mtx  = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t job_mtx   = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t stats_mtx = PTHREAD_MUTEX_INITIALIZER;

/* Mining statistics */
static uint64_t total_hashes    = 0;
static uint64_t total_submitted = 0;
static uint64_t total_accepted  = 0;
static uint64_t total_rejected  = 0;
static double   current_hashrate = 0.0;
static time_t   start_time;

typedef struct {
    int      valid;
    uint64_t seq;
    char     job_id[128];
    char     prevhash[256];
    char     version[16];
    char     bits[16];
    char     ntime[16];
    char     extranonce1[16];
    double   difficulty;
} DagTechJob;

static DagTechJob current_job = {0};
static char extranonce1_global[16] = "";
static double current_difficulty = 0.01;

/* =========================================================================
 * Utility Functions - DagTech Implementation
 * ========================================================================= */
static inline uint32_t dagtech_swab32(uint32_t x) {
    return ((x & 0x000000ffUL) << 24) |
           ((x & 0x0000ff00UL) << 8)  |
           ((x & 0x00ff0000UL) >> 8)  |
           ((x & 0xff000000UL) >> 24);
}

static void hex_to_bytes(const char *hex, uint8_t *out, int len) {
    for (int i = 0; i < len; i++)
        sscanf(hex + 2 * i, "%2hhx", &out[i]);
}

static void bytes_to_hex(const uint8_t *data, int len, char *out) {
    for (int i = 0; i < len; i++)
        sprintf(out + 2 * i, "%02x", data[i]);
    out[2 * len] = 0;
}

static void sha256d(const uint8_t *data, int len, uint8_t *out) {
    uint8_t h1[32];
    DT_SHA256(data, len, h1);
    DT_SHA256(h1, 32, out);
}

/* =========================================================================
 * DagTech Scrypt Engine (N=1024, r=1, p=1)
 * Proprietary implementation by DagTech Ltd
 * ========================================================================= */
static inline void dagtech_xor_salsa8(uint32_t B[16], const uint32_t Bx[16]) {
    uint32_t x00=B[0]^Bx[0],  x01=B[1]^Bx[1],  x02=B[2]^Bx[2],  x03=B[3]^Bx[3];
    uint32_t x04=B[4]^Bx[4],  x05=B[5]^Bx[5],  x06=B[6]^Bx[6],  x07=B[7]^Bx[7];
    uint32_t x08=B[8]^Bx[8],  x09=B[9]^Bx[9],  x10=B[10]^Bx[10], x11=B[11]^Bx[11];
    uint32_t x12=B[12]^Bx[12], x13=B[13]^Bx[13], x14=B[14]^Bx[14], x15=B[15]^Bx[15];

    #define ROTL(a,c) (((a)<<(c)) | ((a)>>(32-(c))))
    for (int i = 0; i < 8; i += 2) {
        x04^=ROTL(x00+x12,7);  x09^=ROTL(x05+x01,7);
        x14^=ROTL(x10+x06,7);  x03^=ROTL(x15+x11,7);
        x08^=ROTL(x04+x00,9);  x13^=ROTL(x09+x05,9);
        x02^=ROTL(x14+x10,9);  x07^=ROTL(x03+x15,9);
        x12^=ROTL(x08+x04,13); x01^=ROTL(x13+x09,13);
        x06^=ROTL(x02+x14,13); x11^=ROTL(x07+x03,13);
        x00^=ROTL(x12+x08,18); x05^=ROTL(x01+x13,18);
        x10^=ROTL(x06+x02,18); x15^=ROTL(x11+x07,18);
        x01^=ROTL(x00+x03,7);  x06^=ROTL(x05+x04,7);
        x11^=ROTL(x10+x09,7);  x12^=ROTL(x15+x14,7);
        x02^=ROTL(x01+x00,9);  x07^=ROTL(x06+x05,9);
        x08^=ROTL(x11+x10,9);  x13^=ROTL(x12+x15,9);
        x03^=ROTL(x02+x01,13); x04^=ROTL(x07+x06,13);
        x09^=ROTL(x08+x11,13); x14^=ROTL(x13+x12,13);
        x00^=ROTL(x03+x02,18); x05^=ROTL(x04+x07,18);
        x10^=ROTL(x09+x08,18); x15^=ROTL(x14+x13,18);
    }
    #undef ROTL

    B[0]+=x00;  B[1]+=x01;  B[2]+=x02;  B[3]+=x03;
    B[4]+=x04;  B[5]+=x05;  B[6]+=x06;  B[7]+=x07;
    B[8]+=x08;  B[9]+=x09;  B[10]+=x10; B[11]+=x11;
    B[12]+=x12; B[13]+=x13; B[14]+=x14; B[15]+=x15;
}

static void dagtech_scrypt_romix(uint32_t *X, uint32_t *V, int N) {
    for (int i = 0; i < N; i++) {
        memcpy(&V[i * 32], X, 128);
        dagtech_xor_salsa8(&X[0], &X[16]);
        dagtech_xor_salsa8(&X[16], &X[0]);
    }
    for (int i = 0; i < N; i++) {
        int j = X[16] & (N - 1);
        for (int k = 0; k < 32; k++)
            X[k] ^= V[j * 32 + k];
        dagtech_xor_salsa8(&X[0], &X[16]);
        dagtech_xor_salsa8(&X[16], &X[0]);
    }
}

/*
 * DagTech Post-ROMix Transformation
 * Proprietary algorithm modification by DagTech Ltd
 * Applied after standard scrypt ROMix to produce the final hash
 */
static inline void dagtech_post_romix_transform(uint32_t *X) {
    uint32_t x = dagtech_swab32(X[0]);
    x = (x & 0xffff8000u) | ((x + 0xe0u) & 0x7fffu);
    X[0] = dagtech_swab32(x);
}

/* HMAC-SHA256 for PBKDF2 */
static void dagtech_hmac_sha256(const uint8_t *key, int klen,
                                 const uint8_t *data, int dlen,
                                 uint8_t *out) {
    uint8_t ipad[64], opad[64], kbuf[32];
    if (klen > 64) { DT_SHA256(key, klen, kbuf); key = kbuf; klen = 32; }
    memset(ipad, 0x36, 64);
    memset(opad, 0x5c, 64);
    for (int i = 0; i < klen; i++) { ipad[i] ^= key[i]; opad[i] ^= key[i]; }

    DT_SHA256_CTX ctx;
    uint8_t tmp[32];
    DT_SHA256_Init(&ctx);
    DT_SHA256_Update(&ctx, ipad, 64);
    DT_SHA256_Update(&ctx, data, dlen);
    DT_SHA256_Final(tmp, &ctx);
    DT_SHA256_Init(&ctx);
    DT_SHA256_Update(&ctx, opad, 64);
    DT_SHA256_Update(&ctx, tmp, 32);
    DT_SHA256_Final(out, &ctx);
}

/* PBKDF2-SHA256 key derivation */
static void dagtech_pbkdf2_sha256(const uint8_t *pass, int plen,
                                    const uint8_t *salt, int slen,
                                    uint8_t *out, int dklen) {
    uint8_t buf[256], U[32], T[32];
    int blocks = (dklen + 31) / 32;
    for (int block = 1; block <= blocks; block++) {
        memcpy(buf, salt, slen);
        buf[slen]   = (block >> 24) & 0xff;
        buf[slen+1] = (block >> 16) & 0xff;
        buf[slen+2] = (block >> 8)  & 0xff;
        buf[slen+3] = block & 0xff;
        dagtech_hmac_sha256(pass, plen, buf, slen + 4, U);
        memcpy(T, U, 32);
        int copylen = (block == blocks && dklen % 32) ? dklen % 32 : 32;
        memcpy(out + (block - 1) * 32, T, copylen);
    }
}

/*
 * DagTech Full Hash Function
 * Scrypt(N=1024, r=1, p=1) + DagTech Post-ROMix Transform
 */
static void dagtech_hash(const uint8_t *input, uint8_t *output) {
    uint32_t X[32];
    uint32_t *V = (uint32_t *)malloc(SCRYPT_N * 128);
    if (!V) {
        fprintf(stderr, "[DagTech] FATAL: Out of memory for scrypt buffer\n");
        exit(1);
    }

    dagtech_pbkdf2_sha256(input, 80, input, 80, (uint8_t *)X, 128);
    dagtech_scrypt_romix(X, V, SCRYPT_N);
    dagtech_post_romix_transform(X);
    dagtech_pbkdf2_sha256(input, 80, (uint8_t *)X, 128, output, 32);

    free(V);
}

/* =========================================================================
 * Stratum Protocol - DagTech Network Communication
 * ========================================================================= */
static int dagtech_connect_pool(void) {
    #ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2,2), &wsa);
    #endif

    struct addrinfo hints, *res, *rp;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    char port_str[16];
    snprintf(port_str, sizeof(port_str), "%d", pool_port);

    int rc = getaddrinfo(pool_host, port_str, &hints, &res);
    if (rc != 0) {
        fprintf(stderr, "[DagTech] DNS resolution failed for %s: %s\n",
                pool_host, gai_strerror(rc));
        return -1;
    }

    for (rp = res; rp != NULL; rp = rp->ai_next) {
        sockfd = socket(rp->ai_family, rp->ai_socktype, rp->ai_protocol);
        if (sockfd < 0) continue;
        if (connect(sockfd, rp->ai_addr, (int)rp->ai_addrlen) == 0) break;
        close(sockfd);
        sockfd = -1;
    }
    freeaddrinfo(res);

    if (sockfd < 0) {
        fprintf(stderr, "[DagTech] Failed to connect to %s:%d\n", pool_host, pool_port);
        return -1;
    }
    return 0;
}

static void dagtech_send(const char *line) {
    pthread_mutex_lock(&sock_mtx);
    char buf[2048];
    snprintf(buf, sizeof(buf), "%s\n", line);
    send(sockfd, buf, (int)strlen(buf), 0);
    pthread_mutex_unlock(&sock_mtx);
}

static void dagtech_subscribe_authorize(void) {
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[\"DagTech/" DAGTECH_VERSION "\"]}");
    dagtech_send(buf);

    /* Pool requires a clean EVM address as username.
       Worker name goes in the password field for identification. */
    char pass_field[128];
    if (worker_name[0] && strcmp(worker_name, "dagtech") != 0)
        snprintf(pass_field, sizeof(pass_field), "%s", worker_name);
    else
        snprintf(pass_field, sizeof(pass_field), "%s", password);

    snprintf(buf, sizeof(buf),
        "{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"%s\",\"%s\"]}",
        wallet, pass_field);
    dagtech_send(buf);
}

static int extract_quoted(const char *line, char out[][256], int max) {
    int count = 0;
    const char *p = line;
    while (count < max && (p = strchr(p, '"')) != NULL) {
        p++;
        const char *end = strchr(p, '"');
        if (!end) break;
        int len = (int)(end - p);
        if (len > 255) len = 255;
        memcpy(out[count], p, len);
        out[count][len] = 0;
        count++;
        p = end + 1;
    }
    return count;
}

static void dagtech_parse_stratum(const char *line) {
    /* Subscribe response - extract extranonce1 */
    if (strstr(line, "mining.subscribe") == NULL &&
        strstr(line, "\"result\"") && strstr(line, "\"id\":1")) {
        char strings[20][256];
        int n = extract_quoted(line, strings, 20);
        for (int i = 0; i < n; i++) {
            if (strlen(strings[i]) == 8 &&
                strspn(strings[i], "0123456789abcdef") == 8) {
                strncpy(extranonce1_global, strings[i],
                        sizeof(extranonce1_global) - 1);
                printf("[DagTech] Subscribed - extranonce1=%s\n", extranonce1_global);
                break;
            }
        }
    }
    /* Difficulty update — apply immediately to the live job so workers
       stop submitting stale low-diff shares between set_difficulty and
       the next mining.notify. */
    else if (strstr(line, "mining.set_difficulty")) {
        const char *p = strstr(line, "params");
        if (p) {
            p = strchr(p, '[');
            if (p) {
                double new_diff = atof(p + 1);
                current_difficulty = new_diff;
                /* Hot-patch the live job so worker threads see it now */
                pthread_mutex_lock(&job_mtx);
                if (current_job.valid)
                    current_job.difficulty = new_diff;
                pthread_mutex_unlock(&job_mtx);
                printf("[DagTech] Difficulty: %.8f\n", current_difficulty);
            }
        }
    }
    /* New job notification */
    else if (strstr(line, "mining.notify")) {
        char strings[20][256];
        int n = extract_quoted(line, strings, 20);
        int offset = 0;
        for (int i = 0; i < n; i++) {
            if (strcmp(strings[i], "mining.notify") == 0) {
                offset = i + 1;
                break;
            }
        }
        if (offset < n && strcmp(strings[offset], "params") == 0)
            offset++;
        if (n - offset >= 5) {
            pthread_mutex_lock(&job_mtx);
            current_job.valid = 1;
            current_job.seq++;
            current_job.difficulty = current_difficulty;
            strncpy(current_job.job_id,     strings[offset],   sizeof(current_job.job_id) - 1);
            strncpy(current_job.prevhash,   strings[offset+1], sizeof(current_job.prevhash) - 1);
            strncpy(current_job.version,    strings[offset+2], sizeof(current_job.version) - 1);
            strncpy(current_job.bits,       strings[offset+3], sizeof(current_job.bits) - 1);
            strncpy(current_job.ntime,      strings[offset+4], sizeof(current_job.ntime) - 1);
            strncpy(current_job.extranonce1, extranonce1_global, sizeof(current_job.extranonce1) - 1);
            pthread_mutex_unlock(&job_mtx);
            printf("[DagTech] New job: %s (diff %.8f)\n",
                   current_job.job_id, current_job.difficulty);
        }
    }
    /* Share accepted */
    else if (strstr(line, "\"result\"") && strstr(line, "true")) {
        pthread_mutex_lock(&stats_mtx);
        total_accepted++;
        pthread_mutex_unlock(&stats_mtx);
        printf("[DagTech] Share ACCEPTED (%lu total)\n", (unsigned long)total_accepted);
    }
    /* Share rejected or error */
    else if (strstr(line, "\"error\"") && !strstr(line, "null")) {
        pthread_mutex_lock(&stats_mtx);
        total_rejected++;
        pthread_mutex_unlock(&stats_mtx);
        printf("[DagTech] Share REJECTED: %s\n", line);
    }
}

static void *dagtech_recv_thread(void *arg) {
    (void)arg;
    char buf[8192];
    char linebuf[16384] = {0};
    int linelen = 0;

    while (running) {
        ssize_t n = recv(sockfd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) {
            if (running) printf("[DagTech] Pool connection lost\n");
            running = 0;
            break;
        }
        buf[n] = 0;
        for (int i = 0; i < n; i++) {
            if (buf[i] == '\n') {
                linebuf[linelen] = 0;
                if (linelen > 0) dagtech_parse_stratum(linebuf);
                linelen = 0;
            } else if (linelen < (int)sizeof(linebuf) - 1) {
                linebuf[linelen++] = buf[i];
            }
        }
    }
    return NULL;
}

/* =========================================================================
 * Block Header Construction
 * ========================================================================= */
static int dagtech_make_header(const DagTechJob *j, uint32_t nonce, uint8_t header[80]) {
    if (strlen(j->version) != 8 || strlen(j->prevhash) < 64 ||
        strlen(j->ntime) != 8 || strlen(j->bits) != 8 ||
        strlen(j->extranonce1) != 8) return -1;

    uint8_t version[4], prevhash[32], ntime_b[4], bits_b[4];
    uint8_t en1[4], en2[4], en_combined[8], merkle[32];

    hex_to_bytes(j->version,    version,  4);
    hex_to_bytes(j->prevhash,   prevhash, 32);
    hex_to_bytes(j->ntime,      ntime_b,  4);
    hex_to_bytes(j->bits,       bits_b,   4);
    hex_to_bytes(j->extranonce1, en1,     4);
    memset(en2, 0, 4);

    memcpy(en_combined, en1, 4);
    memcpy(en_combined + 4, en2, 4);
    sha256d(en_combined, 8, merkle);

    memcpy(header,      version,  4);
    memcpy(header + 4,  prevhash, 32);
    memcpy(header + 36, merkle,   32);
    memcpy(header + 68, ntime_b,  4);
    memcpy(header + 72, bits_b,   4);
    header[76] = nonce & 0xff;
    header[77] = (nonce >> 8) & 0xff;
    header[78] = (nonce >> 16) & 0xff;
    header[79] = (nonce >> 24) & 0xff;

    return 0;
}

/* Rate limiter: max ~5 share submissions per second to prevent
   pool flood-disconnect during vardiff ramp-up. */
static struct timespec last_submit_time = {0, 0};
static pthread_mutex_t submit_rate_mtx = PTHREAD_MUTEX_INITIALIZER;
#define SUBMIT_MIN_INTERVAL_MS 200  /* 1000ms / 5 shares = 200ms */

static void dagtech_submit_share(const DagTechJob *j, uint32_t nonce) {
    /* Throttle: skip if we submitted too recently */
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    pthread_mutex_lock(&submit_rate_mtx);
    long elapsed_ms = (now.tv_sec - last_submit_time.tv_sec) * 1000 +
                      (now.tv_nsec - last_submit_time.tv_nsec) / 1000000;
    if (elapsed_ms < SUBMIT_MIN_INTERVAL_MS) {
        pthread_mutex_unlock(&submit_rate_mtx);
        return;  /* Drop this share to avoid flood */
    }
    last_submit_time = now;
    pthread_mutex_unlock(&submit_rate_mtx);

    char nonce_hex[16];
    uint8_t nb[4];
    nb[0] = nonce & 0xff;
    nb[1] = (nonce >> 8) & 0xff;
    nb[2] = (nonce >> 16) & 0xff;
    nb[3] = (nonce >> 24) & 0xff;
    bytes_to_hex(nb, 4, nonce_hex);

    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"id\":%lu,\"method\":\"mining.submit\",\"params\":[\"%s\",\"%s\",\"00000000\",\"%s\",\"%s\"]}",
        (unsigned long)(1000 + total_submitted), wallet, j->job_id, j->ntime, nonce_hex);
    dagtech_send(buf);

    pthread_mutex_lock(&stats_mtx);
    total_submitted++;
    pthread_mutex_unlock(&stats_mtx);
}

static int dagtech_check_target(const uint8_t *hash, double difficulty) {
    double threshold = 65535.0 / difficulty;
    uint32_t target_top = (uint32_t)(threshold > 4294967295.0 ? 4294967295u : threshold);
    uint32_t hash_top = ((uint32_t)hash[31] << 24) | ((uint32_t)hash[30] << 16) |
                        ((uint32_t)hash[29] << 8)  | hash[28];
    return hash_top <= target_top;
}

/* =========================================================================
 * Mining Thread - DagTech Worker
 * ========================================================================= */
static void *dagtech_mine_thread(void *arg) {
    int tid = *(int *)arg;
    uint32_t nonce = (uint32_t)tid * (0xFFFFFFFFu / num_threads);
    uint64_t local_hashes = 0;

    printf("[DagTech] Worker %d started (nonce range 0x%08x)\n", tid, nonce);

    while (running) {
        DagTechJob j;
        pthread_mutex_lock(&job_mtx);
        j = current_job;
        pthread_mutex_unlock(&job_mtx);

        if (!j.valid) { usleep(100000); continue; }

        uint64_t job_seq = j.seq;

        for (int batch = 0; batch < 64 && running; batch++) {
            uint8_t header[80];
            if (dagtech_make_header(&j, nonce, header) < 0) break;

            uint8_t hash[32];
            dagtech_hash(header, hash);
            local_hashes++;

            if (dagtech_check_target(hash, j.difficulty)) {
                printf("[DagTech] ** SHARE FOUND ** Worker %d, nonce=0x%08x\n", tid, nonce);
                dagtech_submit_share(&j, nonce);
            }

            nonce++;

            /* Check for new job */
            pthread_mutex_lock(&job_mtx);
            if (current_job.seq != job_seq) {
                pthread_mutex_unlock(&job_mtx);
                break;
            }
            pthread_mutex_unlock(&job_mtx);
        }

        pthread_mutex_lock(&stats_mtx);
        total_hashes += local_hashes;
        pthread_mutex_unlock(&stats_mtx);
        local_hashes = 0;
    }
    return NULL;
}

/* =========================================================================
 * Built-in Metrics Server (for Dashboard)
 * Serves JSON stats on /metrics for the DagTech Dashboard
 * ========================================================================= */
static void *dagtech_metrics_thread(void *arg) {
    (void)arg;

    #ifdef _WIN32
    SOCKET srv = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    #else
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    #endif
    if (srv < 0) {
        fprintf(stderr, "[DagTech] Metrics server failed to create socket\n");
        return NULL;
    }

    int opt = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, (char *)&opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(metrics_port);

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        fprintf(stderr, "[DagTech] Metrics bind failed on port %d\n", metrics_port);
        close(srv);
        return NULL;
    }
    listen(srv, 5);
    printf("[DagTech] Metrics server on http://127.0.0.1:%d/metrics\n", metrics_port);

    while (running) {
        struct sockaddr_in client;
        #ifdef _WIN32
        int clen = sizeof(client);
        SOCKET cfd = accept(srv, (struct sockaddr *)&client, &clen);
        #else
        socklen_t clen = sizeof(client);
        int cfd = accept(srv, (struct sockaddr *)&client, &clen);
        #endif
        if (cfd < 0) continue;

        /* Read request (we don't really parse it) */
        char reqbuf[1024];
        recv(cfd, reqbuf, sizeof(reqbuf) - 1, 0);

        /* Build JSON response */
        pthread_mutex_lock(&stats_mtx);
        time_t uptime = time(NULL) - start_time;
        char json[2048];
        snprintf(json, sizeof(json),
            "{"
            "\"version\":\"%s\","
            "\"pool\":\"%s:%d\","
            "\"wallet\":\"%.10s...%s\","
            "\"threads\":%d,"
            "\"hashrate\":%.2f,"
            "\"total_hashes\":%llu,"
            "\"submitted\":%llu,"
            "\"accepted\":%llu,"
            "\"rejected\":%llu,"
            "\"difficulty\":%.8f,"
            "\"uptime\":%ld,"
            "\"job_id\":\"%s\""
            "}",
            DAGTECH_VERSION, pool_host, pool_port,
            wallet, wallet + strlen(wallet) - 4,
            num_threads, current_hashrate,
            (unsigned long long)total_hashes,
            (unsigned long long)total_submitted,
            (unsigned long long)total_accepted,
            (unsigned long long)total_rejected,
            current_difficulty, (long)uptime,
            current_job.job_id);
        pthread_mutex_unlock(&stats_mtx);

        char response[4096];
        snprintf(response, sizeof(response),
            "HTTP/1.1 200 OK\r\n"
            "Content-Type: application/json\r\n"
            "Access-Control-Allow-Origin: *\r\n"
            "Connection: close\r\n"
            "Content-Length: %d\r\n"
            "\r\n%s",
            (int)strlen(json), json);

        send(cfd, response, (int)strlen(response), 0);
        close(cfd);
    }

    close(srv);
    return NULL;
}

/* =========================================================================
 * Signal Handler
 * ========================================================================= */
static void dagtech_signal(int sig) {
    (void)sig;
    printf("\n[DagTech] Shutting down...\n");
    running = 0;
}

/* =========================================================================
 * Usage / Help
 * ========================================================================= */
static void dagtech_usage(void) {
    printf("\n");
    printf("  %s\n", DAGTECH_BANNER);
    printf("  %s\n\n", DAGTECH_AUTHOR);
    printf("  Usage: dagtech-miner [options]\n\n");
    printf("  Options:\n");
    printf("    --wallet <addr>    Your wallet address (REQUIRED)\n");
    printf("    --pool <host>      Pool hostname (default: %s)\n", DAGTECH_DEFAULT_POOL);
    printf("    --port <n>         Pool port (default: %d)\n", DAGTECH_DEFAULT_PORT);
    printf("    --threads <n>      Number of mining threads (default: auto)\n");
    printf("    --worker <name>    Worker name (default: dagtech)\n");
    printf("    --low-priority     Run at lowest CPU priority\n");
    printf("    --metrics-port <n> Metrics HTTP port (default: %d)\n", metrics_port);
    printf("    --help             Show this help\n");
    printf("\n");
    printf("  Example:\n");
    printf("    dagtech-miner --wallet 0xYOUR_WALLET_ADDRESS\n\n");
}

/* =========================================================================
 * Auto-detect CPU thread count
 * ========================================================================= */
static int dagtech_detect_threads(void) {
    int cores = 1;
    #ifdef _WIN32
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    cores = si.dwNumberOfProcessors;
    #elif defined(__linux__)
    cores = sysconf(_SC_NPROCESSORS_ONLN);
    #elif defined(__APPLE__)
    size_t len = sizeof(cores);
    sysctlbyname("hw.logicalcpu", &cores, &len, NULL, 0);
    #endif
    /* Use half the cores by default to leave room for system */
    int threads = cores / 2;
    if (threads < 1) threads = 1;
    return threads;
}

/* =========================================================================
 * Main Entry Point - DagTech Miner
 * ========================================================================= */
int main(int argc, char **argv) {
    signal(SIGINT, dagtech_signal);
    signal(SIGTERM, dagtech_signal);

    /* Parse command line arguments */
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--wallet") == 0 && i + 1 < argc)
            strncpy(wallet, argv[++i], sizeof(wallet) - 1);
        else if (strcmp(argv[i], "--pool") == 0 && i + 1 < argc)
            strncpy(pool_host, argv[++i], sizeof(pool_host) - 1);
        else if (strcmp(argv[i], "--port") == 0 && i + 1 < argc)
            pool_port = atoi(argv[++i]);
        else if (strcmp(argv[i], "--threads") == 0 && i + 1 < argc)
            num_threads = atoi(argv[++i]);
        else if (strcmp(argv[i], "--worker") == 0 && i + 1 < argc)
            strncpy(worker_name, argv[++i], sizeof(worker_name) - 1);
        else if (strcmp(argv[i], "--password") == 0 && i + 1 < argc)
            strncpy(password, argv[++i], sizeof(password) - 1);
        else if (strcmp(argv[i], "--low-priority") == 0)
            cpu_priority = 1;
        else if (strcmp(argv[i], "--metrics-port") == 0 && i + 1 < argc)
            metrics_port = atoi(argv[++i]);
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            dagtech_usage();
            return 0;
        }
    }

    /* Banner */
    printf("\n");
    printf("  ============================================\n");
    printf("  %s\n", DAGTECH_BANNER);
    printf("  %s\n", DAGTECH_AUTHOR);
    printf("  ============================================\n\n");

    /* Validate wallet */
    if (wallet[0] == 0) {
        fprintf(stderr, "[DagTech] ERROR: Wallet address is required!\n");
        dagtech_usage();
        return 1;
    }
    if (strncmp(wallet, "0x", 2) != 0 || strlen(wallet) != 42) {
        fprintf(stderr, "[DagTech] WARNING: Wallet format looks unusual (expected 0x + 40 hex chars)\n");
    }

    /* Auto-detect threads if not specified */
    if (num_threads <= 0)
        num_threads = dagtech_detect_threads();

    /* Set low priority if requested */
    if (cpu_priority) {
        #ifdef _WIN32
        SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS);
        #else
        nice(19);
        #endif
        printf("[DagTech] Running at LOW CPU priority\n");
    }

    printf("[DagTech] Wallet:  %s\n", wallet);
    printf("[DagTech] Pool:    %s:%d\n", pool_host, pool_port);
    printf("[DagTech] Threads: %d\n", num_threads);
    printf("[DagTech] Worker:  %s\n", worker_name);
    printf("\n");

    /* Connect to pool */
    printf("[DagTech] Connecting to pool...\n");
    if (dagtech_connect_pool() < 0) {
        fprintf(stderr, "[DagTech] FATAL: Cannot connect to pool %s:%d\n", pool_host, pool_port);
        return 1;
    }
    printf("[DagTech] Connected!\n");

    start_time = time(NULL);
    dagtech_subscribe_authorize();

    /* Start receiver thread */
    pthread_t recv_tid;
    pthread_create(&recv_tid, NULL, dagtech_recv_thread, NULL);

    /* Start metrics server thread */
    pthread_t metrics_tid;
    pthread_create(&metrics_tid, NULL, dagtech_metrics_thread, NULL);

    /* Wait for first job */
    printf("[DagTech] Waiting for work from pool...\n");
    for (int i = 0; i < 100 && running && !current_job.valid; i++)
        usleep(100000);
    if (!current_job.valid) {
        fprintf(stderr, "[DagTech] FATAL: No job received from pool\n");
        running = 0;
        return 1;
    }

    /* Start mining threads */
    pthread_t *threads = malloc(num_threads * sizeof(pthread_t));
    int *tids = malloc(num_threads * sizeof(int));
    for (int i = 0; i < num_threads; i++) {
        tids[i] = i;
        pthread_create(&threads[i], NULL, dagtech_mine_thread, &tids[i]);
    }

    printf("[DagTech] Mining started with %d workers!\n\n", num_threads);

    /* Statistics reporting loop */
    time_t last_report = time(NULL);
    uint64_t last_hashes = 0;
    while (running) {
        sleep(10);
        time_t now = time(NULL);
        double elapsed = difftime(now, last_report);
        if (elapsed >= 10) {
            pthread_mutex_lock(&stats_mtx);
            uint64_t h = total_hashes;
            current_hashrate = (h - last_hashes) / elapsed;
            pthread_mutex_unlock(&stats_mtx);

            time_t uptime = now - start_time;
            int up_h = (int)(uptime / 3600);
            int up_m = (int)((uptime % 3600) / 60);

            printf("[DagTech] %.1f H/s | Shares: %lu/%lu/%lu (sub/acc/rej) | Uptime: %dh%dm\n",
                   current_hashrate,
                   (unsigned long)total_submitted,
                   (unsigned long)total_accepted,
                   (unsigned long)total_rejected,
                   up_h, up_m);
            last_hashes = h;
            last_report = now;
        }
    }

    /* Cleanup */
    for (int i = 0; i < num_threads; i++)
        pthread_join(threads[i], NULL);
    pthread_join(recv_tid, NULL);

    free(threads);
    free(tids);
    close(sockfd);

    #ifdef _WIN32
    WSACleanup();
    #endif

    printf("[DagTech] Shutdown complete. Total hashes: %llu\n",
           (unsigned long long)total_hashes);
    return 0;
}

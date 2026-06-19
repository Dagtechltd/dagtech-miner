/* bdag_cpu_miner.c - BlockDAG CPU Stratum Miner
 * Uses standard scrypt(N=1024,r=1,p=1) + BDAG post-ROMix tweak
 * Connects to pool via stratum (same protocol as GPU miner)
 * Designed to run at lowest CPU priority (nice 19, limited threads)
 */

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <openssl/sha.h>
#include <sys/socket.h>
#include <unistd.h>
#include <pthread.h>
#include <signal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <errno.h>

/* ---- Config ---- */
/* === GPU MODE additions === */
#ifdef __cplusplus
extern "C" {
#endif
int  bdag_gpu_init(char *err_buf, int err_buflen);
int  bdag_gpu_scrypt_batch(const uint8_t hdr[80], uint32_t nonce_start, uint32_t batch_size, uint8_t *out_hashes);
const char *bdag_gpu_device_name(void);
void bdag_gpu_shutdown(void);
#ifdef __cplusplus
}
#endif
static int  MINER_MODE = 0;     /* 0 = cpu, 1 = gpu, 2 = both */
static int  GPU_BATCH  = 1024;
static char POOL_HOST[256] = "127.0.0.1";
static int POOL_PORT = 3334;
static char WALLET[64] = "0x6387C32ccDD60BfBa00EC70A67715Dcd52E8083f";
static char PASSWORD[32] = "x";
static int NUM_THREADS = 8;
static volatile int running = 1;

/* ---- Stratum state ---- */
static int sockfd = -1;
static pthread_mutex_t sock_mtx = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t job_mtx = PTHREAD_MUTEX_INITIALIZER;

static uint64_t total_hashes = 0;
static uint64_t total_submitted = 0;
static uint64_t total_accepted = 0;
static pthread_mutex_t stats_mtx = PTHREAD_MUTEX_INITIALIZER;

typedef struct {
    int valid;
    uint64_t seq;
    char job_id[128];
    char prevhash[256];
    char version[16];
    char bits[16];
    char ntime[16];
    char extranonce1[16];
    double difficulty;
} Job;

static Job current_job = {0};
static char extranonce1_global[16] = "";
static double current_difficulty = 0.01;

/* ---- Utility ---- */
static inline uint32_t swab32(uint32_t x) {
    return ((x & 0x000000ffUL) << 24) |
           ((x & 0x0000ff00UL) << 8)  |
           ((x & 0x00ff0000UL) >> 8)  |
           ((x & 0xff000000UL) >> 24);
}

static void hex_to_bytes(const char *hex, uint8_t *out, int len) {
    for (int i = 0; i < len; i++) {
        sscanf(hex + 2*i, "%2hhx", &out[i]);
    }
}

static void bytes_to_hex(const uint8_t *data, int len, char *out) {
    for (int i = 0; i < len; i++) {
        sprintf(out + 2*i, "%02x", data[i]);
    }
    out[2*len] = 0;
}

static void sha256d(const uint8_t *data, int len, uint8_t *out) {
    uint8_t h1[32];
    SHA256(data, len, h1);
    SHA256(h1, 32, out);
}

/* ---- Scrypt implementation (N=1024, r=1, p=1) ---- */
static inline void xor_salsa8(uint32_t B[16], const uint32_t Bx[16]) {
    uint32_t x00,x01,x02,x03,x04,x05,x06,x07,x08,x09,x10,x11,x12,x13,x14,x15;
    /* Pre-XOR B with Bx IN PLACE (standard scrypt pattern) */
    x00=(B[0]^=Bx[0]); x01=(B[1]^=Bx[1]); x02=(B[2]^=Bx[2]); x03=(B[3]^=Bx[3]);
    x04=(B[4]^=Bx[4]); x05=(B[5]^=Bx[5]); x06=(B[6]^=Bx[6]); x07=(B[7]^=Bx[7]);
    x08=(B[8]^=Bx[8]); x09=(B[9]^=Bx[9]); x10=(B[10]^=Bx[10]); x11=(B[11]^=Bx[11]);
    x12=(B[12]^=Bx[12]); x13=(B[13]^=Bx[13]); x14=(B[14]^=Bx[14]); x15=(B[15]^=Bx[15]);

    #define R(a,c) (((a)<<(c)) | ((a)>>(32-(c))))
    for (int i = 0; i < 8; i += 2) {
        /* Column round */
        x04^=R(x00+x12,7); x09^=R(x05+x01,7); x14^=R(x10+x06,7); x03^=R(x15+x11,7);
        x08^=R(x04+x00,9); x13^=R(x09+x05,9); x02^=R(x14+x10,9); x07^=R(x03+x15,9);
        x12^=R(x08+x04,13); x01^=R(x13+x09,13); x06^=R(x02+x14,13); x11^=R(x07+x03,13);
        x00^=R(x12+x08,18); x05^=R(x01+x13,18); x10^=R(x06+x02,18); x15^=R(x11+x07,18);
        /* Row round - STANDARD (x08, not x04) */
        x01^=R(x00+x03,7); x06^=R(x05+x04,7); x11^=R(x10+x09,7); x12^=R(x15+x14,7);
        x02^=R(x01+x00,9); x07^=R(x06+x05,9); x08^=R(x11+x10,9); x13^=R(x12+x15,9);
        x03^=R(x02+x01,13); x04^=R(x07+x06,13); x09^=R(x08+x11,13); x14^=R(x13+x12,13);
        x00^=R(x03+x02,18); x05^=R(x04+x07,18); x10^=R(x09+x08,18); x15^=R(x14+x13,18);
    }
    #undef R

    B[0]+=x00; B[1]+=x01; B[2]+=x02; B[3]+=x03;
    B[4]+=x04; B[5]+=x05; B[6]+=x06; B[7]+=x07;
    B[8]+=x08; B[9]+=x09; B[10]+=x10; B[11]+=x11;
    B[12]+=x12; B[13]+=x13; B[14]+=x14; B[15]+=x15;
}

static void scrypt_romix(uint32_t *X, uint32_t *V, int N) {
    for (int i = 0; i < N; i++) {
        memcpy(&V[i * 32], X, 128);
        xor_salsa8(&X[0], &X[16]);
        xor_salsa8(&X[16], &X[0]);
    }
    for (int i = 0; i < N; i++) {
        int j = X[16] & (N - 1);
        for (int k = 0; k < 32; k++) X[k] ^= V[j * 32 + k];
        xor_salsa8(&X[0], &X[16]);
        xor_salsa8(&X[16], &X[0]);
    }
}

/* BDAG post-ROMix tweak */
static inline void bdag_post_romix_tweak(uint32_t *X) {
    uint32_t x = swab32(X[0]);
    x = (x & 0xffff8000u) | ((x + 0xe0u) & 0x7fffu);
    X[0] = swab32(x);
}

static void hmac_sha256(const uint8_t *key, int klen, const uint8_t *data, int dlen, uint8_t *out) {
    uint8_t ipad[64], opad[64], kbuf[32];
    if (klen > 64) { SHA256(key, klen, kbuf); key = kbuf; klen = 32; }
    memset(ipad, 0x36, 64); memset(opad, 0x5c, 64);
    for (int i = 0; i < klen; i++) { ipad[i] ^= key[i]; opad[i] ^= key[i]; }

    SHA256_CTX ctx;
    uint8_t tmp[32];
    SHA256_Init(&ctx); SHA256_Update(&ctx, ipad, 64); SHA256_Update(&ctx, data, dlen); SHA256_Final(tmp, &ctx);
    SHA256_Init(&ctx); SHA256_Update(&ctx, opad, 64); SHA256_Update(&ctx, tmp, 32); SHA256_Final(out, &ctx);
}

static void pbkdf2_sha256(const uint8_t *pass, int plen, const uint8_t *salt, int slen, uint8_t *out, int dklen) {
    uint8_t buf[256], U[32], T[32];
    int blocks = (dklen + 31) / 32;
    for (int block = 1; block <= blocks; block++) {
        memcpy(buf, salt, slen);
        buf[slen] = (block >> 24) & 0xff;
        buf[slen+1] = (block >> 16) & 0xff;
        buf[slen+2] = (block >> 8) & 0xff;
        buf[slen+3] = block & 0xff;
        hmac_sha256(pass, plen, buf, slen + 4, U);
        memcpy(T, U, 32);
        int copylen = (block == blocks && dklen % 32) ? dklen % 32 : 32;
        memcpy(out + (block-1)*32, T, copylen);
    }
}

/* Full scrypt hash with BDAG tweak */
static void bdag_scrypt_hash(const uint8_t *input, uint8_t *output) {
    uint32_t X[32];
    uint32_t *V = (uint32_t *)malloc(1024 * 128);
    if (!V) { fprintf(stderr, "OOM\n"); exit(1); }

    /* Byte-swap each uint32 in header (pool expects big-endian words) */
    uint8_t hdr[80];
    for (int i = 0; i < 80; i += 4) {
        hdr[i+0] = input[i+3];
        hdr[i+1] = input[i+2];
        hdr[i+2] = input[i+1];
        hdr[i+3] = input[i+0];
    }

    pbkdf2_sha256(hdr, 80, hdr, 80, (uint8_t*)X, 128);
    scrypt_romix(X, V, 1024);
    bdag_post_romix_tweak(X);
    pbkdf2_sha256(hdr, 80, (uint8_t*)X, 128, output, 32);

    free(V);
}

/* ---- Networking / Stratum ---- */
static int connect_pool(void) {
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) return -1;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(POOL_PORT);

    if (inet_pton(AF_INET, POOL_HOST, &addr.sin_addr) <= 0) {
        struct hostent *he = gethostbyname(POOL_HOST);
        if (!he) return -1;
        memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);
    }

    if (connect(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) return -1;
    return 0;
}

static void send_line(const char *line) {
    pthread_mutex_lock(&sock_mtx);
    char buf[2048];
    snprintf(buf, sizeof(buf), "%s\n", line);
    send(sockfd, buf, strlen(buf), 0);
    pthread_mutex_unlock(&sock_mtx);
}

static void subscribe_authorize(void) {
    char buf[512];
    snprintf(buf, sizeof(buf), "{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[]}");
    send_line(buf);
    snprintf(buf, sizeof(buf), "{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"%s\",\"%s\"]}", WALLET, PASSWORD);
    send_line(buf);
}

static int extract_quoted_strings(const char *line, char out[][256], int max) {
    int count = 0;
    const char *p = line;
    while (count < max && (p = strchr(p, '"')) != NULL) {
        p++;
        const char *end = strchr(p, '"');
        if (!end) break;
        int len = end - p;
        if (len > 255) len = 255;
        memcpy(out[count], p, len);
        out[count][len] = 0;
        count++;
        p = end + 1;
    }
    return count;
}

static void parse_line(const char *line) {
    if (strstr(line, "mining.subscribe") == NULL && strstr(line, "\"result\"") && strstr(line, "\"id\":1")) {
        char strings[20][256];
        int n = extract_quoted_strings(line, strings, 20);
        for (int i = 0; i < n; i++) {
            if (strlen(strings[i]) == 8 && strspn(strings[i], "0123456789abcdef") == 8) {
                strncpy(extranonce1_global, strings[i], sizeof(extranonce1_global)-1);
                printf("[SUBSCRIBE] extranonce1=%s\n", extranonce1_global);
                break;
            }
        }
    }
    else if (strstr(line, "mining.set_difficulty")) {
        const char *p = strstr(line, "params");
        if (p) { p = strchr(p, '['); if (p) { current_difficulty = atof(p+1); printf("[DIFFICULTY] %.8f\n", current_difficulty); } }
    }
    else if (strstr(line, "mining.notify")) {
        char strings[20][256];
        int n = extract_quoted_strings(line, strings, 20);
        int offset = 0;
        for (int i = 0; i < n; i++) { if (strcmp(strings[i], "mining.notify") == 0) { offset = i + 1; break; } }
        if (offset < n && strcmp(strings[offset], "params") == 0) offset++;
        if (n - offset >= 5) {
            pthread_mutex_lock(&job_mtx);
            current_job.valid = 1;
            current_job.seq++;
            current_job.difficulty = current_difficulty;
            strncpy(current_job.job_id, strings[offset], sizeof(current_job.job_id)-1);
            strncpy(current_job.prevhash, strings[offset+1], sizeof(current_job.prevhash)-1);
            strncpy(current_job.version, strings[offset+2], sizeof(current_job.version)-1);
            strncpy(current_job.bits, strings[offset+3], sizeof(current_job.bits)-1);
            strncpy(current_job.ntime, strings[offset+4], sizeof(current_job.ntime)-1);
            strncpy(current_job.extranonce1, extranonce1_global, sizeof(current_job.extranonce1)-1);
            pthread_mutex_unlock(&job_mtx);
            printf("[NEW JOB] id=%s diff=%.8f\n", current_job.job_id, current_job.difficulty);
        }
    }
    else if (strstr(line, "\"result\"") && strstr(line, "true")) {
        pthread_mutex_lock(&stats_mtx);
        total_accepted++;
        pthread_mutex_unlock(&stats_mtx);
        printf("[ACCEPTED] total=%lu\n", (unsigned long)total_accepted);
    }
    else if (strstr(line, "\"error\"") && !strstr(line, "null")) {
        printf("[POOL ERROR] %s\n", line);
    }
}

static void *recv_thread(void *arg) {
    (void)arg;
    char buf[8192];
    char linebuf[16384] = {0};
    int linelen = 0;

    while (running) {
        ssize_t n = recv(sockfd, buf, sizeof(buf)-1, 0);
        if (n <= 0) { running = 0; break; }
        buf[n] = 0;
        fprintf(stderr, "[RAW] %s", buf);
        for (int i = 0; i < n; i++) {
            if (buf[i] == '\n') {
                linebuf[linelen] = 0;
                if (linelen > 0) parse_line(linebuf);
                linelen = 0;
            } else if (linelen < (int)sizeof(linebuf)-1) {
                linebuf[linelen++] = buf[i];
            }
        }
    }
    return NULL;
}

static int make_header(const Job *j, uint32_t nonce, uint8_t header[80]) {
    if (strlen(j->version) != 8 || strlen(j->prevhash) < 64 ||
        strlen(j->ntime) != 8 || strlen(j->bits) != 8 ||
        strlen(j->extranonce1) != 8) return -1;

    uint8_t version[4], prevhash[32], ntime_b[4], bits_b[4];
    uint8_t en1[4], en2[4], en_combined[8], merkle[32];

    hex_to_bytes(j->version, version, 4);
    hex_to_bytes(j->prevhash, prevhash, 32);
    hex_to_bytes(j->ntime, ntime_b, 4);
    hex_to_bytes(j->bits, bits_b, 4);
    hex_to_bytes(j->extranonce1, en1, 4);
    memset(en2, 0, 4);

    memcpy(en_combined, en1, 4);
    memcpy(en_combined + 4, en2, 4);
    sha256d(en_combined, 8, merkle);

    memcpy(header, version, 4);
    memcpy(header + 4, prevhash, 32);
    memcpy(header + 36, merkle, 32);
    memcpy(header + 68, ntime_b, 4);
    memcpy(header + 72, bits_b, 4);
    header[76] = nonce & 0xff;
    header[77] = (nonce >> 8) & 0xff;
    header[78] = (nonce >> 16) & 0xff;
    header[79] = (nonce >> 24) & 0xff;

    return 0;
}

static void submit_nonce(const Job *j, uint32_t nonce) {
    char nonce_hex[16];
    uint8_t nb[4];
    nb[0]=nonce&0xff; nb[1]=(nonce>>8)&0xff; nb[2]=(nonce>>16)&0xff; nb[3]=(nonce>>24)&0xff;
    bytes_to_hex(nb, 4, nonce_hex);

    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"id\":%lu,\"method\":\"mining.submit\",\"params\":[\"%s\",\"%s\",\"00000000\",\"%s\",\"%s\"]}",
        (unsigned long)(1000 + total_submitted), WALLET, j->job_id, j->ntime, nonce_hex);
    send_line(buf);

    pthread_mutex_lock(&stats_mtx);
    total_submitted++;
    pthread_mutex_unlock(&stats_mtx);
}

static int check_target(const uint8_t *hash, double difficulty) {
    double threshold = 65535.0 / difficulty;
    uint32_t target_top = (uint32_t)(threshold > 4294967295.0 ? 4294967295u : threshold);
    uint32_t hash_top = ((uint32_t)hash[31]<<24) | ((uint32_t)hash[30]<<16) |
                        ((uint32_t)hash[29]<<8) | hash[28];
    return hash_top <= target_top;
}

static void *gpu_mine_thread(void *arg) {
    (void)arg;
    uint32_t nonce = 0;
    uint64_t local_hashes = 0;
    static uint8_t *gpu_hashes = NULL;
    if (!gpu_hashes) {
        gpu_hashes = (uint8_t *)malloc((size_t)GPU_BATCH * 32);
        if (!gpu_hashes) { fprintf(stderr, "[GPU] OOM allocating hash buffer\n"); return NULL; }
    }
    printf("[GPU] worker started, batch=%d device=%s\n", GPU_BATCH, bdag_gpu_device_name());
    while (running) {
        Job j;
        pthread_mutex_lock(&job_mtx);
        j = current_job;
        pthread_mutex_unlock(&job_mtx);
        if (!j.valid) { usleep(100000); continue; }
        uint64_t job_seq = j.seq;
        uint8_t header[80];
        if (make_header(&j, 0, header) < 0) { usleep(100000); continue; }
        int got = bdag_gpu_scrypt_batch(header, nonce, GPU_BATCH, gpu_hashes);
        if (got <= 0) {
            fprintf(stderr, "[GPU] batch failed rc=%d\n", got);
            usleep(500000);
            continue;
        }
        for (int i = 0; i < got; ++i) {
            if (check_target(gpu_hashes + i * 32, j.difficulty)) {
                uint32_t found = nonce + (uint32_t)i;
                printf("[GPU] SHARE FOUND! nonce=0x%08x\n", found);
                submit_nonce(&j, found);
            }
        }
        nonce += (uint32_t)got;
        local_hashes += (uint64_t)got;
        pthread_mutex_lock(&job_mtx);
        if (current_job.seq != job_seq) {
            pthread_mutex_unlock(&job_mtx);
            // job changed; flush stats and loop
        } else {
            pthread_mutex_unlock(&job_mtx);
        }
        pthread_mutex_lock(&stats_mtx);
        total_hashes += local_hashes;
        pthread_mutex_unlock(&stats_mtx);
        local_hashes = 0;
    }
    return NULL;
}

static void *mine_thread(void *arg) {
    int tid = *(int*)arg;
    uint32_t nonce = (uint32_t)tid * (0xFFFFFFFFu / NUM_THREADS);
    uint64_t local_hashes = 0;

    printf("[THREAD %d] starting at nonce 0x%08x\n", tid, nonce);

    while (running) {
        Job j;
        pthread_mutex_lock(&job_mtx);
        j = current_job;
        pthread_mutex_unlock(&job_mtx);

        if (!j.valid) { usleep(100000); continue; }

        uint64_t job_seq = j.seq;

        for (int batch = 0; batch < 32 && running; batch++) {
            uint8_t header[80];
            if (make_header(&j, nonce, header) < 0) break;

            uint8_t hash[32];
            bdag_scrypt_hash(header, hash);
            local_hashes++;

            if (check_target(hash, j.difficulty)) {
                printf("[THREAD %d] SHARE FOUND! nonce=0x%08x\n", tid, nonce);
                submit_nonce(&j, nonce);
            }

            nonce++;

            pthread_mutex_lock(&job_mtx);
            if (current_job.seq != job_seq) { pthread_mutex_unlock(&job_mtx); break; }
            pthread_mutex_unlock(&job_mtx);
        }

        pthread_mutex_lock(&stats_mtx);
        total_hashes += local_hashes;
        pthread_mutex_unlock(&stats_mtx);
        local_hashes = 0;
    }
    return NULL;
}

static void sighandler(int sig) { (void)sig; running = 0; }

int main(int argc, char **argv) {
    signal(SIGINT, sighandler);
    signal(SIGTERM, sighandler);
    setvbuf(stdout, NULL, _IOLBF, 0);  /* line-buffer for launchd log capture */

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--host") == 0 && i+1 < argc) strncpy(POOL_HOST, argv[++i], sizeof(POOL_HOST)-1);
        else if (strcmp(argv[i], "--port") == 0 && i+1 < argc) POOL_PORT = atoi(argv[++i]);
        else if (strcmp(argv[i], "--wallet") == 0 && i+1 < argc) strncpy(WALLET, argv[++i], sizeof(WALLET)-1);
        else if (strcmp(argv[i], "--threads") == 0 && i+1 < argc) NUM_THREADS = atoi(argv[++i]);
        else if (strcmp(argv[i], "--password") == 0 && i+1 < argc) strncpy(PASSWORD, argv[++i], sizeof(PASSWORD)-1);
        else if (strcmp(argv[i], "--mode") == 0 && i+1 < argc) {
            const char *m = argv[++i];
            if (!strcmp(m, "cpu")) MINER_MODE = 0;
            else if (!strcmp(m, "gpu")) MINER_MODE = 1;
            else if (!strcmp(m, "both")) MINER_MODE = 2;
            else { fprintf(stderr, "Unknown --mode: %s (use cpu|gpu|both)\n", m); return 2; }
        }
        else if (strcmp(argv[i], "--batch") == 0 && i+1 < argc) GPU_BATCH = atoi(argv[++i]);
    }

    printf("BDAG CPU Miner - %d threads\n", NUM_THREADS);
    printf("Pool: %s:%d  Wallet: %.10s...%s\n", POOL_HOST, POOL_PORT, WALLET, WALLET+36);

    if (connect_pool() < 0) { fprintf(stderr, "Failed to connect to pool\n"); return 1; }
    printf("Connected to pool\n");

    subscribe_authorize();

    pthread_t recv_tid;
    pthread_create(&recv_tid, NULL, recv_thread, NULL);

    printf("Waiting for job...\n");
    for (int i = 0; i < 100 && running && !current_job.valid; i++) usleep(100000);
    if (!current_job.valid) { fprintf(stderr, "No job received\n"); running = 0; return 1; }

    pthread_t gpu_tid;
    int gpu_started = 0;
    if (MINER_MODE == 1 || MINER_MODE == 2) {
        char gpu_err[256] = {0};
        int rc = bdag_gpu_init(gpu_err, sizeof(gpu_err));
        if (rc != 0) {
            fprintf(stderr, "[GPU] init failed: %s (rc=%d) — falling back to CPU\n", gpu_err, rc);
            if (MINER_MODE == 1) MINER_MODE = 0;
        } else {
            printf("[GPU] Metal initialized on %s\n", bdag_gpu_device_name());
            pthread_create(&gpu_tid, NULL, gpu_mine_thread, NULL);
            gpu_started = 1;
        }
    }
    int cpu_thread_count = (MINER_MODE == 1) ? 0 : NUM_THREADS;
    pthread_t *threads = malloc(cpu_thread_count > 0 ? cpu_thread_count * sizeof(pthread_t) : 1);
    int *tids = malloc(cpu_thread_count > 0 ? cpu_thread_count * sizeof(int) : 1);
    for (int i = 0; i < cpu_thread_count; i++) {
        tids[i] = i;
        pthread_create(&threads[i], NULL, mine_thread, &tids[i]);
    }

    time_t last_report = time(NULL);
    uint64_t last_hashes = 0;
    while (running) {
        sleep(10);
        time_t now = time(NULL);
        double elapsed = difftime(now, last_report);
        if (elapsed >= 10) {
            pthread_mutex_lock(&stats_mtx);
            uint64_t h = total_hashes;
            pthread_mutex_unlock(&stats_mtx);
            double rate = (h - last_hashes) / elapsed;
            printf("[STATS] %.1f H/s | total=%lu submitted=%lu accepted=%lu\n",
                   rate, (unsigned long)h, (unsigned long)total_submitted, (unsigned long)total_accepted);
            last_hashes = h;
            last_report = now;
        }
    }

    for (int i = 0; i < NUM_THREADS; i++) pthread_join(threads[i], NULL);
    pthread_join(recv_tid, NULL);

    free(threads); free(tids);
    close(sockfd);
    printf("Shutdown complete\n");
    return 0;
}

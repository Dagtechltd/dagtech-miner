#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <openssl/sha.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <random>
#include <regex>
#include <cstdlib>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "hasher.h"

// ========================
// Stage 18A config defaults
// ========================

static std::string POOL_HOST = "62.171.161.32";
static int POOL_PORT = 3334;
static std::string WALLET = "0xc12ee9dC15c3Fc7FCe8Ae2Ef8eD84e92c0B72310";
static std::string PASSWORD = "x";

static int RUNTIME_SECONDS = 60;
static long double SUBMIT_MARGIN = 1.02L;
static long double MIN_SUBMIT_THRESHOLD = 0.25L;
static std::string EXTRANONCE2_HEX = "00000000";

static int sockfd = -1;
static std::atomic<bool> running(false);

static std::atomic<uint64_t> total_checked(0);
static std::atomic<uint64_t> total_submitted(0);
static std::atomic<uint64_t> total_accepted(0);
static std::atomic<uint64_t> total_errors(0);
static std::atomic<uint64_t> total_lowdiff(0);
static std::atomic<uint64_t> total_stale_errors(0);
static std::atomic<uint64_t> total_stale_skipped(0);
static std::atomic<uint64_t> total_nohit_batches(0);
static std::atomic<uint64_t> total_hit_batches(0);

static std::atomic<int> rpc_id_counter(1000);

struct Job {
    bool valid = false;
    uint64_t seq = 0;

    std::string job_id;
    std::string prevhash;
    std::string version;
    std::string bits;
    std::string ntime;
    std::string extranonce1;

    long double difficulty = 0.01L;
};

static std::mutex job_mtx;
static Job current_job;
static std::string extranonce1_global;
static long double current_difficulty = 0.01L;

static std::vector<uint8_t> hex_to_bytes(const std::string &hex) {
    std::vector<uint8_t> out;
    out.reserve(hex.size() / 2);

    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        out.push_back((uint8_t)strtoul(hex.substr(i, 2).c_str(), nullptr, 16));
    }

    return out;
}

static std::string bytes_to_hex(const uint8_t *data, size_t len) {
    std::ostringstream oss;
    oss << std::hex << std::setfill('0');

    for (size_t i = 0; i < len; i++) {
        oss << std::setw(2) << (int)data[i];
    }

    return oss.str();
}

static std::vector<uint8_t> sha256d(const std::vector<uint8_t> &data) {
    uint8_t h1[SHA256_DIGEST_LENGTH];
    uint8_t h2[SHA256_DIGEST_LENGTH];

    SHA256(data.data(), data.size(), h1);
    SHA256(h1, SHA256_DIGEST_LENGTH, h2);

    return std::vector<uint8_t>(h2, h2 + SHA256_DIGEST_LENGTH);
}

static bool connect_tcp(const std::string &host, int port) {
    sockfd = socket(AF_INET, SOCK_STREAM, 0);

    if (sockfd < 0) {
        perror("socket");
        return false;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));

    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);

    if (inet_pton(AF_INET, host.c_str(), &addr.sin_addr) <= 0) {
        struct hostent *he = gethostbyname(host.c_str());
        if (!he) {
            std::cerr << "[STAGE18A] DNS failed for " << host << "\n";
            return false;
        }
        memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);
    }

    if (connect(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        return false;
    }

    return true;
}

static void send_line(const std::string &s) {
    std::string line = s + "\n";
    send(sockfd, line.c_str(), line.size(), 0);
}

static void subscribe_authorize() {
    send_line("{\"id\":1,\"method\":\"mining.subscribe\",\"params\":[]}");
    send_line("{\"id\":2,\"method\":\"mining.authorize\",\"params\":[\"" + WALLET + "\",\"" + PASSWORD + "\"]}");
}

static std::vector<std::string> quoted_strings_after_params(const std::string &line) {
    std::vector<std::string> out;

    size_t p = line.find("\"params\"");
    if (p == std::string::npos) return out;

    std::string tail = line.substr(p);

    std::regex r("\"([^\"]*)\"");
    auto begin = std::sregex_iterator(tail.begin(), tail.end(), r);
    auto end = std::sregex_iterator();

    for (auto it = begin; it != end; ++it) {
        std::string v = (*it)[1].str();

        if (v == "params") continue;
        out.push_back(v);
    }

    return out;
}

static void parse_set_difficulty(const std::string &line) {
    std::regex r("\"mining\\.set_difficulty\".*?\\[([0-9\\.eE+-]+)\\]");
    std::smatch m;

    if (std::regex_search(line, m, r)) {
        long double d = strtold(m[1].str().c_str(), nullptr);

        {
            std::lock_guard<std::mutex> lk(job_mtx);
            current_difficulty = d;
            if (current_job.valid) {
                current_job.difficulty = d;
            }
        }

        std::cout << "[DIFF18A] " << std::fixed << std::setprecision(8) << (double)d << "\n";
    }
}

static void parse_subscribe_response(const std::string &line) {
    if (line.find("\"id\":1") == std::string::npos && line.find("\"id\": 1") == std::string::npos) {
        return;
    }

    std::regex r("\"([0-9a-fA-F]{8})\"\\s*,\\s*4");
    std::smatch m;

    if (std::regex_search(line, m, r)) {
        extranonce1_global = m[1].str();
        std::cout << "[SUBSCRIBE18A] extranonce1=" << extranonce1_global << "\n";
    }
}

static void parse_notify(const std::string &line) {
    if (line.find("mining.notify") == std::string::npos) return;

    std::vector<std::string> q = quoted_strings_after_params(line);

    // Expected strings:
    // q[0]=mining.notify may appear depending regex tail shape; remove it if present.
    std::vector<std::string> v;
    for (auto &s : q) {
        if (s == "mining.notify") continue;
        v.push_back(s);
    }

    if (v.size() < 5) {
        std::cerr << "[NOTIFY18A] could not parse notify line: " << line << "\n";
        return;
    }

    Job j;
    j.valid = true;

    {
        std::lock_guard<std::mutex> lk(job_mtx);
        j.seq = current_job.seq + 1;
        j.difficulty = current_difficulty;
    }

    j.job_id = v[0];
    j.prevhash = v[1];
    j.version = v[2];
    j.bits = v[3];
    j.ntime = v[4];
    j.extranonce1 = extranonce1_global;

    {
        std::lock_guard<std::mutex> lk(job_mtx);
        current_job = j;
    }

    std::cout << "\n[NEW JOB18A] id=" << j.job_id
              << " valid=true"
              << " diff=" << std::fixed << std::setprecision(8) << (double)j.difficulty
              << " prevhash=" << j.prevhash.substr(0, 16) << "..."
              << " version=" << j.version
              << " bits=" << j.bits
              << " ntime=" << j.ntime
              << " en1=" << j.extranonce1
              << "\n";
}

static void parse_pool_response(const std::string &line) {
    if (line.find("\"result\"") != std::string::npos && line.find("true") != std::string::npos) {
        total_accepted++;
        return;
    }

    if (line.find("\"error\"") != std::string::npos) {
        total_errors++;

        if (line.find("low difficulty") != std::string::npos) total_lowdiff++;
        if (line.find("stale") != std::string::npos) total_stale_errors++;

        std::cout << "[POOL ERROR18A] " << line << "\n";
    }
}

static void recv_loop() {
    char buf[8192];
    std::string buffer;

    while (running.load()) {
        ssize_t n = recv(sockfd, buf, sizeof(buf) - 1, 0);

        if (n <= 0) {
            if (running.load()) {
                std::cerr << "[RECV18A] disconnected or recv error\n";
                running = false;
            }
            break;
        }

        buf[n] = 0;
        buffer += buf;

        size_t pos;

        while ((pos = buffer.find('\n')) != std::string::npos) {
            std::string line = buffer.substr(0, pos);
            buffer.erase(0, pos + 1);

            if (line.empty()) continue;

            parse_subscribe_response(line);
            parse_set_difficulty(line);
            parse_notify(line);
            parse_pool_response(line);
        }
    }
}

static bool make_payload80_from_job(const Job &j, uint8_t payload[80]) {
    if (j.version.size() != 8 || j.prevhash.size() < 64 || j.ntime.size() != 8 || j.bits.size() != 8) {
        return false;
    }

    if (j.extranonce1.size() != 8 || EXTRANONCE2_HEX.size() != 8) {
        return false;
    }

    auto version = hex_to_bytes(j.version);
    auto prevhash = hex_to_bytes(j.prevhash.substr(0, 64));
    auto ntime = hex_to_bytes(j.ntime);
    auto bits = hex_to_bytes(j.bits);

    auto en1 = hex_to_bytes(j.extranonce1);
    auto en2 = hex_to_bytes(EXTRANONCE2_HEX);

    std::vector<uint8_t> en;
    en.insert(en.end(), en1.begin(), en1.end());
    en.insert(en.end(), en2.begin(), en2.end());

    auto merkle_like = sha256d(en);

    memcpy(payload + 0, version.data(), 4);
    memcpy(payload + 4, prevhash.data(), 32);
    memcpy(payload + 36, merkle_like.data(), 32);
    memcpy(payload + 68, ntime.data(), 4);
    memcpy(payload + 72, bits.data(), 4);

    // Nonce bytes filled later by pdata[19].
    payload[76] = 0;
    payload[77] = 0;
    payload[78] = 0;
    payload[79] = 0;

    return true;
}

static void make_kepler_target_from_threshold(long double threshold, uint32_t target[8]) {
    for (int i = 0; i < 8; i++) target[i] = 0;

    if (threshold < 0.000001L) threshold = 0.000001L;

    // Matches the working Stage 14/15 threshold family:
    // threshold 1.0  -> top chunk approx 0000ffff
    // threshold 0.25 -> top chunk approx 0003fffc
    long double coeff_ld = 65535.0L / threshold;

    if (coeff_ld < 1.0L) coeff_ld = 1.0L;
    if (coeff_ld > 4294967295.0L) coeff_ld = 4294967295.0L;

    uint32_t coeff = (uint32_t)coeff_ld;

    // Keplerminer compares j=7 down to 0, so the leading target chunk goes into target[7].
    target[7] = coeff;
}

static std::string nonce_word_to_submit_hex(uint32_t nonce_word) {
    uint8_t b[4];
    memcpy(b, &nonce_word, 4);
    return bytes_to_hex(b, 4);
}

static void submit_nonce(const Job &j, uint32_t nonce_word) {
    std::string nonce_hex = nonce_word_to_submit_hex(nonce_word);
    int id = rpc_id_counter++;

    std::ostringstream oss;
    oss << "{\"id\":" << id
        << ",\"method\":\"mining.submit\",\"params\":[\""
        << WALLET << "\",\""
        << j.job_id << "\",\""
        << EXTRANONCE2_HEX << "\",\""
        << j.ntime << "\",\""
        << nonce_hex << "\"]}";

    send_line(oss.str());
    total_submitted++;
}

static void print_usage(const char *prog) {
    std::cout << "Usage: " << prog << " [options]\n"
              << "  --host <host>              Pool host or IP address\n"
              << "  --port <port>              Pool port\n"
              << "  --wallet <0x...>           EVM-style payout wallet address\n"
              << "  --password <password>      Stratum password, usually x\n"
              << "  --runtime <seconds>        Runtime before exit\n"
              << "  --margin <number>          Submission margin, e.g. 1.02\n"
              << "  --min-threshold <number>   Minimum submission threshold\n"
              << "  --extranonce2 <hex>        Extranonce2 value, usually 00000000\n"
              << "  --help                     Show this help message\n";
}

static bool valid_wallet(const std::string &wallet) {
    static const std::regex wallet_re("^0x[0-9a-fA-F]{40}$");
    return std::regex_match(wallet, wallet_re)
        && wallet != "0x0000000000000000000000000000000000000000";
}

static void parse_args(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];

        if (a == "--help" || a == "-h") {
            print_usage(argv[0]);
            std::exit(0);
        }
        else if (a == "--host" && i + 1 < argc) POOL_HOST = argv[++i];
        else if (a == "--port" && i + 1 < argc) POOL_PORT = atoi(argv[++i]);
        else if (a == "--wallet" && i + 1 < argc) WALLET = argv[++i];
        else if (a == "--password" && i + 1 < argc) PASSWORD = argv[++i];
        else if (a == "--runtime" && i + 1 < argc) RUNTIME_SECONDS = atoi(argv[++i]);
        else if (a == "--margin" && i + 1 < argc) SUBMIT_MARGIN = strtold(argv[++i], nullptr);
        else if (a == "--min-threshold" && i + 1 < argc) MIN_SUBMIT_THRESHOLD = strtold(argv[++i], nullptr);
        else if (a == "--extranonce2" && i + 1 < argc) EXTRANONCE2_HEX = argv[++i];
        else {
            std::cerr << "Unknown or incomplete argument: " << a << "\n";
            print_usage(argv[0]);
            std::exit(1);
        }
    }
}

int main(int argc, char **argv) {
    parse_args(argc, argv);

    if (!valid_wallet(WALLET)) {
        std::cerr << "[FINAL18A] FAIL invalid wallet. Use a non-placeholder 42-character EVM address beginning with 0x.\n";
        return 1;
    }

    std::cout << "[STAGE18A] Keplerminer BDAG live miner\n";
    std::cout << "[STAGE18A] pool=" << POOL_HOST << ":" << POOL_PORT << "\n";
    std::cout << "[STAGE18A] wallet=" << WALLET << "\n";
    std::cout << "[STAGE18A] runtime=" << RUNTIME_SECONDS << "s\n";
    std::cout << "[STAGE18A] margin=" << std::fixed << std::setprecision(4) << (double)SUBMIT_MARGIN << "\n";
    std::cout << "[STAGE18A] min_threshold=" << std::fixed << std::setprecision(4) << (double)MIN_SUBMIT_THRESHOLD << "\n";

    CudaHasher *hasher = new CudaHasher();

    if (hasher->Initialize() != 0) {
        std::cerr << "[FINAL18A] FAIL Keplerminer CudaHasher initialisation failed\n";
        delete hasher;
        return 1;
    }

    int batchsize = hasher->GetBatchSize();
    std::cout << "[STAGE18A] kepler_batchsize=" << batchsize << "\n";

    if (!connect_tcp(POOL_HOST, POOL_PORT)) {
        std::cerr << "[FINAL18A] FAIL pool connect failed\n";
        delete hasher;
        return 1;
    }

    running = true;

    subscribe_authorize();

    std::thread rx(recv_loop);

    std::mt19937 rng((uint32_t)time(nullptr));
    uint32_t start_nonce_word = rng();

    auto start_time = std::chrono::steady_clock::now();
    auto last_print = start_time;

    uint64_t batches = 0;

    while (running.load()) {
        auto now = std::chrono::steady_clock::now();
        double elapsed_total = std::chrono::duration<double>(now - start_time).count();

        if (elapsed_total >= RUNTIME_SECONDS) {
            running = false;
            break;
        }

        Job j;

        {
            std::lock_guard<std::mutex> lk(job_mtx);
            j = current_job;
        }

        if (!j.valid) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }

        uint8_t payload[80];

        if (!make_payload80_from_job(j, payload)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            continue;
        }

        uint32_t pdata[20];
        memcpy(pdata, payload, 80);

        pdata[19] = start_nonce_word;

        long double threshold = j.difficulty * SUBMIT_MARGIN;
        if (threshold < MIN_SUBMIT_THRESHOLD) threshold = MIN_SUBMIT_THRESHOLD;

        uint32_t target[8];
        make_kepler_target_from_threshold(threshold, target);

        int stop = 0;
        unsigned long hashes_done = 0;

        int rc = hasher->ScanNCoins(pdata, target, batchsize, &stop, &hashes_done);

        total_checked += batchsize;
        batches++;

        Job latest;
        {
            std::lock_guard<std::mutex> lk(job_mtx);
            latest = current_job;
        }

        if (rc >= 0) {
            uint32_t found_nonce_word = start_nonce_word + (uint32_t)rc;
            total_hit_batches++;

            bool stale_batch = (!latest.valid || latest.seq != j.seq || latest.job_id != j.job_id);

            if (stale_batch) {
                total_stale_skipped++;
            } else {
                submit_nonce(j, found_nonce_word);
            }
        } else {
            total_nohit_batches++;
        }

        start_nonce_word += (uint32_t)batchsize;

        auto now2 = std::chrono::steady_clock::now();
        double since_print = std::chrono::duration<double>(now2 - last_print).count();

        if (since_print >= 10.0) {
            double elapsed = std::chrono::duration<double>(now2 - start_time).count();
            double hps = (double)total_checked.load() / elapsed;

            std::cout << "[LIVE18A] checked=" << total_checked.load()
                      << " avg=" << std::fixed << std::setprecision(1) << hps << " H/s"
                      << " batches=" << batches
                      << " hit_batches=" << total_hit_batches.load()
                      << " nohit_batches=" << total_nohit_batches.load()
                      << " submitted=" << total_submitted.load()
                      << " accepted=" << total_accepted.load()
                      << " errors=" << total_errors.load()
                      << " low=" << total_lowdiff.load()
                      << " stale_err=" << total_stale_errors.load()
                      << " stale_skipped=" << total_stale_skipped.load()
                      << " current_diff=" << std::setprecision(8) << (double)j.difficulty
                      << " threshold=" << std::setprecision(8) << (double)threshold
                      << "\n";

            last_print = now2;
        }
    }

    running = false;

    if (sockfd >= 0) {
        shutdown(sockfd, SHUT_RDWR);
        close(sockfd);
        sockfd = -1;
    }

    if (rx.joinable()) rx.join();

    auto end_time = std::chrono::steady_clock::now();
    double elapsed = std::chrono::duration<double>(end_time - start_time).count();
    double hps = elapsed > 0 ? (double)total_checked.load() / elapsed : 0.0;

    std::cout << "[FINAL18A] checked=" << total_checked.load()
              << " elapsed=" << std::fixed << std::setprecision(1) << elapsed << "s"
              << " avg=" << std::setprecision(1) << hps << " H/s"
              << " batches=" << batches
              << " hit_batches=" << total_hit_batches.load()
              << " nohit_batches=" << total_nohit_batches.load()
              << " submitted=" << total_submitted.load()
              << " accepted=" << total_accepted.load()
              << " errors=" << total_errors.load()
              << " low=" << total_lowdiff.load()
              << " stale_err=" << total_stale_errors.load()
              << " stale_skipped=" << total_stale_skipped.load()
              << "\n";

    delete hasher;

    std::cout << "[FINAL18A] Done\n";
    return 0;
}

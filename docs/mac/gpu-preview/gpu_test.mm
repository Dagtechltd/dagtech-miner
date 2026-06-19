// gpu_test.mm
// Hash-equivalence test: runs ONE BDAG-scrypt on a fixed 80-byte header
// through both the Metal GPU kernel AND the CPU reference (bdag_scrypt_lib.c).
// Prints both 32-byte hashes, asserts byte-identical.
// Build: xcrun clang++ -ObjC++ -fobjc-arc -O3 -std=c++17 \
//   -framework Metal -framework Foundation \
//   gpu_test.mm bdag_scrypt_lib.c -lcrypto -o gpu_test
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

extern "C" void scrypt_hash_data(uint8_t *out, const uint8_t *in);

static NSString *load_metal_source(const char *path) {
    NSError *err = nil;
    NSString *src = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:path]
                                              encoding:NSUTF8StringEncoding error:&err];
    if (!src) { NSLog(@"load .metal failed: %@", err); exit(2); }
    return src;
}

static void print_hex(const char *label, const uint8_t *b, size_t n) {
    printf("%s ", label);
    for (size_t i = 0; i < n; ++i) printf("%02x", b[i]);
    printf("\n");
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        // Fixed 80-byte test header (deterministic, easy to reason about)
        uint8_t hdr[80] = {0};
        for (int i = 0; i < 76; ++i) hdr[i] = i ^ 0x42;
        uint32_t test_nonce = 0xdeadbeef;
        hdr[76] = test_nonce & 0xff;
        hdr[77] = (test_nonce >> 8) & 0xff;
        hdr[78] = (test_nonce >> 16) & 0xff;
        hdr[79] = (test_nonce >> 24) & 0xff;

        // --- CPU reference ---
        uint8_t cpu_out[32];
        scrypt_hash_data(cpu_out, hdr);
        print_hex("CPU:", cpu_out, 32);

        // --- GPU path ---
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) { printf("no Metal device\n"); return 3; }
        NSLog(@"GPU: %@", device.name);

        NSString *src = load_metal_source("bdag_metal_scrypt.metal");
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:opts error:&err];
        if (!lib) { NSLog(@"newLibrary failed: %@", err); return 4; }

        id<MTLFunction> fn = [lib newFunctionWithName:@"bdag_scrypt_kernel"];
        if (!fn) { printf("kernel not found\n"); return 5; }

        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&err];
        if (!pso) { NSLog(@"pipeline failed: %@", err); return 6; }

        // We test ONE thread (one nonce). Header passed as-is (without nonce — kernel inserts).
        uint8_t hdr_template[80];
        memcpy(hdr_template, hdr, 76);
        // bytes 76..79 in hdr_in are don't-cares; kernel overrides with nonce_start+tid

        id<MTLBuffer> hdr_buf = [device newBufferWithBytes:hdr_template length:80 options:MTLResourceStorageModeShared];
        uint32_t nonce_start = test_nonce;
        id<MTLBuffer> nonce_buf = [device newBufferWithBytes:&nonce_start length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> v_buf = [device newBufferWithLength:(128*1024) options:MTLResourceStorageModePrivate]; // one thread = 128 KB V
        id<MTLBuffer> out_buf = [device newBufferWithLength:32 options:MTLResourceStorageModeShared];

        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:hdr_buf   offset:0 atIndex:0];
        [enc setBuffer:nonce_buf offset:0 atIndex:1];
        [enc setBuffer:v_buf     offset:0 atIndex:2];
        [enc setBuffer:out_buf   offset:0 atIndex:3];
        MTLSize grid = MTLSizeMake(1, 1, 1);
        MTLSize tg   = MTLSizeMake(1, 1, 1);
        [enc dispatchThreads:grid threadsPerThreadgroup:tg];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        if (cb.error) { NSLog(@"dispatch error: %@", cb.error); return 7; }

        uint8_t gpu_out[32];
        memcpy(gpu_out, out_buf.contents, 32);
        print_hex("GPU:", gpu_out, 32);

        bool match = memcmp(cpu_out, gpu_out, 32) == 0;
        printf("%s\n", match ? "MATCH — byte-identical" : "MISMATCH");
        return match ? 0 : 1;
    }
}
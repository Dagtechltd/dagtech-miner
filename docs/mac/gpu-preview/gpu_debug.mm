// gpu_debug.mm — print intermediate X[0..7] from CPU and GPU
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>

static void print_u32_hex(const char *label, const uint32_t *X, int n) {
    printf("%s ", label);
    for (int i = 0; i < n; ++i) printf("%08x ", X[i]);
    printf("\n");
}

static void cpu_pbkdf2_first(const uint8_t *hdr_swapped, uint32_t *X_out) {
    // PBKDF2-HMAC-SHA256(pw=swapped, salt=swapped, c=1, dklen=128)
    uint8_t out[128];
    for (int blk = 1; blk <= 4; ++blk) {
        uint8_t buf[84];
        memcpy(buf, hdr_swapped, 80);
        buf[80] = (blk >> 24) & 0xff;
        buf[81] = (blk >> 16) & 0xff;
        buf[82] = (blk >> 8) & 0xff;
        buf[83] = blk & 0xff;
        uint8_t U[32];
        CCHmac(kCCHmacAlgSHA256, hdr_swapped, 80, buf, 84, U);
        memcpy(out + (blk-1)*32, U, 32);
    }
    for (int i = 0; i < 32; ++i) {
        X_out[i] = (uint32_t(out[i*4])<<24) | (uint32_t(out[i*4+1])<<16) |
                   (uint32_t(out[i*4+2])<<8) | uint32_t(out[i*4+3]);
    }
}

int main() {
    @autoreleasepool {
        uint8_t hdr[80] = {0};
        for (int i = 0; i < 76; ++i) hdr[i] = i ^ 0x42;
        uint32_t nonce = 0xdeadbeef;
        hdr[76] = nonce & 0xff;
        hdr[77] = (nonce >> 8) & 0xff;
        hdr[78] = (nonce >> 16) & 0xff;
        hdr[79] = (nonce >> 24) & 0xff;
        // Byte-swap each uint32
        uint8_t swapped[80];
        for (int i = 0; i < 80; i += 4) {
            swapped[i]   = hdr[i+3];
            swapped[i+1] = hdr[i+2];
            swapped[i+2] = hdr[i+1];
            swapped[i+3] = hdr[i+0];
        }
        // CPU PBKDF2
        uint32_t X_cpu[32];
        cpu_pbkdf2_first(swapped, X_cpu);
        print_u32_hex("CPU X[0..7] (after PBKDF2):", X_cpu, 8);

        // GPU: run a kernel that just does PBKDF2 + writes X[0..31] as uint32 BE
        NSString *src = [NSString stringWithContentsOfFile:@"bdag_metal_scrypt.metal"
                                                  encoding:NSUTF8StringEncoding error:nil];
        // Append a debug kernel that dumps X after PBKDF2
        NSString *debugKernel = @"\nkernel void debug_pbkdf2(\n"
            @"  constant uint8_t *hdr_in [[buffer(0)]],\n"
            @"  device uint32_t *X_out [[buffer(1)]],\n"
            @"  uint tid [[thread_position_in_grid]]) {\n"
            @"  uint8_t swapped[80];\n"
            @"  for (int i = 0; i < 80; ++i) swapped[i] = hdr_in[i];\n"
            @"  uint8_t X_bytes[128];\n"
            @"  pbkdf2_sha256(swapped, 80, swapped, 80, X_bytes, 128);\n"
            @"  uint32_t X[32];\n"
            @"  for (int i = 0; i < 32; ++i) {\n"
            @"    X[i] = (uint32_t(X_bytes[i*4])<<24) | (uint32_t(X_bytes[i*4+1])<<16) |\n"
            @"           (uint32_t(X_bytes[i*4+2])<<8) | uint32_t(X_bytes[i*4+3]);\n"
            @"  }\n"
            @"  for (int i = 0; i < 32; ++i) X_out[i] = X[i];\n"
            @"}\n";
        NSString *fullSrc = [src stringByAppendingString:debugKernel];

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        id<MTLLibrary> lib = [device newLibraryWithSource:fullSrc options:opts error:&err];
        if (!lib) { NSLog(@"compile: %@", err); return 4; }
        id<MTLFunction> fn = [lib newFunctionWithName:@"debug_pbkdf2"];
        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&err];
        if (!pso) { NSLog(@"pso: %@", err); return 5; }
        id<MTLBuffer> hdr_buf = [device newBufferWithBytes:swapped length:80 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out_buf = [device newBufferWithLength:128 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [device newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:hdr_buf offset:0 atIndex:0];
        [enc setBuffer:out_buf offset:0 atIndex:1];
        [enc dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
        [enc endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        if (cb.error) { NSLog(@"dispatch: %@", cb.error); return 7; }

        uint32_t *X_gpu = (uint32_t *)out_buf.contents;
        print_u32_hex("GPU X[0..7] (after PBKDF2):", X_gpu, 8);

        bool match = memcmp(X_cpu, X_gpu, 32*sizeof(uint32_t)) == 0;
        printf("PBKDF2 step: %s\n", match ? "MATCH" : "MISMATCH");
        return match ? 0 : 1;
    }
}
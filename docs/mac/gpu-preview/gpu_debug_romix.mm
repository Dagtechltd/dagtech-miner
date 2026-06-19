// gpu_debug_romix.mm — compare X after ROMix
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonHMAC.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static inline uint32_t swab32(uint32_t x) {
    return ((x & 0xffu) << 24) | ((x & 0xff00u) << 8) |
           ((x & 0xff0000u) >> 8) | ((x & 0xff000000u) >> 24);
}
static inline void xor_salsa8(uint32_t B[16], const uint32_t Bx[16]) {
    uint32_t x00,x01,x02,x03,x04,x05,x06,x07,x08,x09,x10,x11,x12,x13,x14,x15;
    x00=(B[0]^=Bx[0]); x01=(B[1]^=Bx[1]); x02=(B[2]^=Bx[2]); x03=(B[3]^=Bx[3]);
    x04=(B[4]^=Bx[4]); x05=(B[5]^=Bx[5]); x06=(B[6]^=Bx[6]); x07=(B[7]^=Bx[7]);
    x08=(B[8]^=Bx[8]); x09=(B[9]^=Bx[9]); x10=(B[10]^=Bx[10]); x11=(B[11]^=Bx[11]);
    x12=(B[12]^=Bx[12]); x13=(B[13]^=Bx[13]); x14=(B[14]^=Bx[14]); x15=(B[15]^=Bx[15]);
    #define R(a,c) (((a)<<(c)) | ((a)>>(32-(c))))
    for (int i = 0; i < 8; i += 2) {
        x04^=R(x00+x12,7); x09^=R(x05+x01,7); x14^=R(x10+x06,7); x03^=R(x15+x11,7);
        x08^=R(x04+x00,9); x13^=R(x09+x05,9); x02^=R(x14+x10,9); x07^=R(x03+x15,9);
        x12^=R(x08+x04,13); x01^=R(x13+x09,13); x06^=R(x02+x14,13); x11^=R(x07+x03,13);
        x00^=R(x12+x08,18); x05^=R(x01+x13,18); x10^=R(x06+x02,18); x15^=R(x11+x07,18);
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
static void cpu_scrypt_romix(uint32_t *X, uint32_t *V, int N) {
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

int main() {
    @autoreleasepool {
        // Known starting X[32]
        uint32_t X_in[32];
        for (int i = 0; i < 32; ++i) X_in[i] = 0xdeadbeef + i * 0x12345678;
        // CPU ROMix
        uint32_t X_cpu[32]; memcpy(X_cpu, X_in, 128);
        uint32_t *V = (uint32_t *)malloc(1024 * 128);
        cpu_scrypt_romix(X_cpu, V, 1024);
        free(V);
        printf("CPU X[0..7] after ROMix: "); for (int i = 0; i < 8; ++i) printf("%08x ", X_cpu[i]); printf("\n");

        // GPU ROMix
        NSString *src = [NSString stringWithContentsOfFile:@"bdag_metal_scrypt.metal"
                                                  encoding:NSUTF8StringEncoding error:nil];
        NSString *dbg = @"\nkernel void debug_romix(\n"
            @"  constant uint32_t *X_in [[buffer(0)]],\n"
            @"  device uint8_t *V_global [[buffer(1)]],\n"
            @"  device uint32_t *X_out [[buffer(2)]],\n"
            @"  uint tid [[thread_position_in_grid]]) {\n"
            @"  uint32_t X[32];\n"
            @"  for (int i = 0; i < 32; ++i) X[i] = X_in[i];\n"
            @"  device uint32_t *V = (device uint32_t *)(V_global + uint64_t(tid) * 128u * 1024u);\n"
            @"  scrypt_romix_device(X, V);\n"
            @"  for (int i = 0; i < 32; ++i) X_out[i] = X[i];\n"
            @"}\n";
        NSString *fullSrc = [src stringByAppendingString:dbg];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        NSError *err = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        id<MTLLibrary> lib = [device newLibraryWithSource:fullSrc options:opts error:&err];
        if (!lib) { NSLog(@"compile: %@", err); return 4; }
        id<MTLFunction> fn = [lib newFunctionWithName:@"debug_romix"];
        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&err];
        id<MTLBuffer> in_buf = [device newBufferWithBytes:X_in length:128 options:MTLResourceStorageModeShared];
        id<MTLBuffer> v_buf  = [device newBufferWithLength:128*1024 options:MTLResourceStorageModePrivate];
        id<MTLBuffer> out_buf = [device newBufferWithLength:128 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [device newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:in_buf offset:0 atIndex:0];
        [enc setBuffer:v_buf offset:0 atIndex:1];
        [enc setBuffer:out_buf offset:0 atIndex:2];
        [enc dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)];
        [enc endEncoding];
        [cb commit]; [cb waitUntilCompleted];
        if (cb.error) { NSLog(@"dispatch: %@", cb.error); return 7; }
        uint32_t *X_gpu = (uint32_t *)out_buf.contents;
        printf("GPU X[0..7] after ROMix: "); for (int i = 0; i < 8; ++i) printf("%08x ", X_gpu[i]); printf("\n");
        bool match = memcmp(X_cpu, X_gpu, 128) == 0;
        printf("ROMix: %s\n", match ? "MATCH" : "MISMATCH");
        // If mismatch, find first differing word
        if (!match) {
            for (int i = 0; i < 32; ++i) {
                if (X_cpu[i] != X_gpu[i]) {
                    printf("  first diff at X[%d]: cpu=%08x gpu=%08x\n", i, X_cpu[i], X_gpu[i]);
                    break;
                }
            }
        }
        return match ? 0 : 1;
    }
}
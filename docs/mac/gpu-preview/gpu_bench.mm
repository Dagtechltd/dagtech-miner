// gpu_bench.mm — measure GPU hashrate with N threads in one batch
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include <sys/time.h>

static double now_ms() {
    struct timeval t; gettimeofday(&t, NULL);
    return t.tv_sec * 1000.0 + t.tv_usec / 1000.0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        uint32_t batch = argc > 1 ? atoi(argv[1]) : 256;
        uint32_t iters = argc > 2 ? atoi(argv[2]) : 4;
        printf("batch=%u iters=%u total=%u hashes\n", batch, iters, batch * iters);

        uint8_t hdr[80] = {0};
        for (int i = 0; i < 76; ++i) hdr[i] = i ^ 0x42;

        NSString *src = [NSString stringWithContentsOfFile:@"bdag_metal_scrypt.metal"
                                                  encoding:NSUTF8StringEncoding error:nil];
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:opts error:&err];
        if (!lib) { NSLog(@"%@", err); return 4; }
        id<MTLFunction> fn = [lib newFunctionWithName:@"bdag_scrypt_kernel"];
        id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&err];
        if (!pso) { NSLog(@"%@", err); return 5; }

        size_t v_bytes = (size_t)batch * 128 * 1024;
        printf("V buffer: %.1f MB\n", v_bytes / (1024.0*1024.0));
        id<MTLBuffer> hdr_buf = [device newBufferWithBytes:hdr length:80 options:MTLResourceStorageModeShared];
        id<MTLBuffer> v_buf   = [device newBufferWithLength:v_bytes options:MTLResourceStorageModePrivate];
        id<MTLBuffer> out_buf = [device newBufferWithLength:32 * batch options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> q = [device newCommandQueue];

        // Warmup
        {
            uint32_t nonce_start = 0;
            id<MTLBuffer> nb = [device newBufferWithBytes:&nonce_start length:4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:hdr_buf offset:0 atIndex:0];
            [enc setBuffer:nb      offset:0 atIndex:1];
            [enc setBuffer:v_buf   offset:0 atIndex:2];
            [enc setBuffer:out_buf offset:0 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(batch,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(batch,32),1,1)];
            [enc endEncoding];
            [cb commit]; [cb waitUntilCompleted];
            if (cb.error) { NSLog(@"warmup error: %@", cb.error); return 7; }
        }

        double t0 = now_ms();
        for (uint32_t k = 0; k < iters; ++k) {
            uint32_t nonce_start = k * batch;
            id<MTLBuffer> nb = [device newBufferWithBytes:&nonce_start length:4 options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
            [enc setComputePipelineState:pso];
            [enc setBuffer:hdr_buf offset:0 atIndex:0];
            [enc setBuffer:nb      offset:0 atIndex:1];
            [enc setBuffer:v_buf   offset:0 atIndex:2];
            [enc setBuffer:out_buf offset:0 atIndex:3];
            [enc dispatchThreads:MTLSizeMake(batch,1,1) threadsPerThreadgroup:MTLSizeMake(MIN(batch,32),1,1)];
            [enc endEncoding];
            [cb commit]; [cb waitUntilCompleted];
            if (cb.error) { NSLog(@"iter %u error: %@", k, cb.error); return 8; }
        }
        double t1 = now_ms();
        double total_hashes = (double)batch * iters;
        double secs = (t1 - t0) / 1000.0;
        double hashrate = total_hashes / secs;
        printf("time: %.3fs  total: %.0f hashes  HASHRATE: %.1f H/s (%.2f KH/s)\n",
               secs, total_hashes, hashrate, hashrate / 1000.0);
        return 0;
    }
}
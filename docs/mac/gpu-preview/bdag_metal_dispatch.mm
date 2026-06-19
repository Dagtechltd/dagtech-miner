// bdag_metal_dispatch.mm
// Production Metal GPU dispatcher for BDAG-scrypt.
// C-ABI surface:
//   int  bdag_gpu_init(char *err_buf, int err_buflen);
//   int  bdag_gpu_scrypt_batch(const uint8_t hdr[80], uint32_t nonce_start,
//                              uint32_t batch_size, uint8_t *out_hashes);
//   void bdag_gpu_shutdown(void);
// Copyright (c) 2026 DagTech Ltd. CONFIDENTIAL.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "metal_source.h"

static id<MTLDevice> g_device = nil;
static id<MTLComputePipelineState> g_pso = nil;
static id<MTLCommandQueue> g_queue = nil;
static id<MTLBuffer> g_v_buffer = nil;
static uint32_t g_v_capacity = 0;

extern "C" int bdag_gpu_init(char *err_buf, int err_buflen) {
    @autoreleasepool {
        g_device = MTLCreateSystemDefaultDevice();
        if (!g_device) {
            if (err_buf && err_buflen > 0) snprintf(err_buf, err_buflen, "no Metal device");
            return -1;
        }
        NSError *err = nil;
        MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
        opts.languageVersion = MTLLanguageVersion2_4;
        NSString *src = [NSString stringWithUTF8String:kBdagMetalSource];
        id<MTLLibrary> lib = [g_device newLibraryWithSource:src options:opts error:&err];
        if (!lib) {
            if (err_buf && err_buflen > 0) snprintf(err_buf, err_buflen, "MSL compile: %s", err.localizedDescription.UTF8String);
            return -2;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:@"bdag_scrypt_kernel"];
        if (!fn) {
            if (err_buf && err_buflen > 0) snprintf(err_buf, err_buflen, "kernel not found");
            return -3;
        }
        g_pso = [g_device newComputePipelineStateWithFunction:fn error:&err];
        if (!g_pso) {
            if (err_buf && err_buflen > 0) snprintf(err_buf, err_buflen, "PSO: %s", err.localizedDescription.UTF8String);
            return -4;
        }
        g_queue = [g_device newCommandQueue];
        return 0;
    }
}

extern "C" int bdag_gpu_scrypt_batch(const uint8_t hdr[80], uint32_t nonce_start,
                                     uint32_t batch_size, uint8_t *out_hashes) {
    @autoreleasepool {
        if (!g_device || !g_pso || !g_queue) return -1;
        // Ensure V buffer is large enough; lazy resize.
        uint64_t needed = (uint64_t)batch_size * 128 * 1024;
        if (!g_v_buffer || g_v_capacity < batch_size) {
            g_v_buffer = [g_device newBufferWithLength:needed options:MTLResourceStorageModePrivate];
            g_v_capacity = batch_size;
        }
        id<MTLBuffer> hdr_buf = [g_device newBufferWithBytes:hdr length:80 options:MTLResourceStorageModeShared];
        id<MTLBuffer> nonce_buf = [g_device newBufferWithBytes:&nonce_start length:4 options:MTLResourceStorageModeShared];
        id<MTLBuffer> out_buf = [g_device newBufferWithLength:32 * batch_size options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:g_pso];
        [enc setBuffer:hdr_buf   offset:0 atIndex:0];
        [enc setBuffer:nonce_buf offset:0 atIndex:1];
        [enc setBuffer:g_v_buffer offset:0 atIndex:2];
        [enc setBuffer:out_buf   offset:0 atIndex:3];
        NSUInteger tg = MIN((NSUInteger)batch_size, g_pso.maxTotalThreadsPerThreadgroup);
        if (tg < 1) tg = 1;
        [enc dispatchThreads:MTLSizeMake(batch_size,1,1) threadsPerThreadgroup:MTLSizeMake(tg,1,1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) return -2;
        memcpy(out_hashes, out_buf.contents, 32 * batch_size);
        return (int)batch_size;
    }
}

extern "C" const char *bdag_gpu_device_name(void) {
    if (g_device) return g_device.name.UTF8String;
    return "(no device)";
}

extern "C" void bdag_gpu_shutdown(void) {
    g_v_buffer = nil; g_pso = nil; g_queue = nil; g_device = nil;
    g_v_capacity = 0;
}
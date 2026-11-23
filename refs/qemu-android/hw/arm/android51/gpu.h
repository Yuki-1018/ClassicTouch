/*
 * GPU bridge declarations between android51 devices and AOSP emugl (EAGL).
 */
#ifndef ANDROID51_GPU_H
#define ANDROID51_GPU_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int ae_gpu_init(unsigned w, unsigned h);
void ae_gpu_destroy(void);
void *ae_gpu_open(void);
void ae_gpu_close(void *s);
int ae_gpu_fd(void *s);
int ae_gpu_send(void *s, const void *p, size_t n);
int ae_gpu_receive(void *s, void *p, size_t n);
unsigned ae_gpu_poll(void *s);
void ae_gpu_invalidate_frame(void);
void ae_gpu_set_wake_callback(void (*cb)(void *), void *ctx);
int ae_gpu_frame_region(uint8_t *p, size_t n, unsigned *first, unsigned *rows);
const char *ae_gpu_last_error(void);

#ifdef __cplusplus
}
#endif

#endif

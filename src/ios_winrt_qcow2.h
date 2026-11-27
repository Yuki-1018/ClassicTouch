#ifndef IOS_WINRT_QCOW2_H
#define IOS_WINRT_QCOW2_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Create an empty QCOW2 v3 image (64 KiB clusters, 16-bit refcounts).
 * `virtual_size_bytes` must be a non-zero multiple of 512 KiB.
 * Returns 0 on success, or -errno on failure.
 */
int winrt_qcow2_create_blank(const char *path, uint64_t virtual_size_bytes);

/**
 * Convert a raw disk image (`src_raw_path`) into a compact QCOW2 v3 image
 * (`dst_qcow2_path`), omitting all-zero 64 KiB clusters (and skipping sparse
 * holes via SEEK_DATA when supported).
 * `progress_cb`, if non-NULL, is invoked periodically with `fraction` in [0, 1].
 * Returns 0 on success, or -errno on failure.
 */
typedef void (*winrt_qcow2_progress_cb)(double fraction, void *ctx);

int winrt_qcow2_convert_from_raw(const char *src_raw_path,
                                 const char *dst_qcow2_path,
                                 winrt_qcow2_progress_cb progress_cb,
                                 void *ctx);

/**
 * Read the virtual size (in bytes) of a QCOW2 image header.
 * Returns true on success and stores the virtual size in `*out_virtual_size`.
 */
bool winrt_qcow2_read_virtual_size(const char *path, uint64_t *out_virtual_size);

#ifdef __cplusplus
}
#endif

#endif /* IOS_WINRT_QCOW2_H */

#ifndef QEMU_WINRT_UI_H
#define QEMU_WINRT_UI_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*QemuWinRTFrameCallback)(void *opaque, int width, int height,
                                       int stride_bytes, const void *pixels);
typedef void (*QemuWinRTDirtyFrameCallback)(void *opaque, int width, int height,
                                            int dirty_x, int dirty_y,
                                            int dirty_w, int dirty_h,
                                            int stride_bytes, const void *pixels);

int qemu_winrt_main(int argc, char **argv);
int qemu_winrt_create_disk(const char *path, uint64_t size_bytes);
void qemu_winrt_ui_set_frame_callback(QemuWinRTFrameCallback cb, void *opaque);
void qemu_winrt_ui_set_dirty_frame_callback(QemuWinRTDirtyFrameCallback cb, void *opaque);
void qemu_winrt_ui_pointer_abs(int x_0_32767, int y_0_32767, int buttons_mask);
void qemu_winrt_ui_touch(int slot, int x_0_32767, int y_0_32767, int phase);
void qemu_winrt_ui_scroll(int wheel_delta);
void qemu_winrt_ui_key_qcode(int qcode, int down);
void qemu_winrt_ui_send_cad(void);
void qemu_winrt_ui_reset_usb_input(void);
int qemu_winrt_ui_audio_pull(int16_t *out_stereo_frames, int max_frames,
                             int *out_sample_rate, int *out_channels);
void qemu_winrt_ui_sync(void);
void qemu_winrt_ui_quit(void);

/* Internal lifecycle hooks between qemu-winrt-entry.c and qemu-winrt-ui.c */
void qemu_winrt_ui_attach(void);
void qemu_winrt_ui_detach(void);

#ifdef __cplusplus
}
#endif

#endif /* QEMU_WINRT_UI_H */

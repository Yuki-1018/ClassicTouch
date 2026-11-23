/*
 * Public C ABI exported by `libqemu-android.dylib` for ClassicTouch iOS app.
 */

#ifndef QEMU_ANDROID_UI_H
#define QEMU_ANDROID_UI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define QEMU_ANDROID_KEY_VOLUMEDOWN 114
#define QEMU_ANDROID_KEY_VOLUMEUP   115
#define QEMU_ANDROID_KEY_POWER      116
#define QEMU_ANDROID_KEY_HOME       102
#define QEMU_ANDROID_KEY_BACK       158
#define QEMU_ANDROID_KEY_MENU       139

typedef void (*QemuAndroidFrameCallback)(void *opaque, int width, int height,
                                         int stride_bytes, const void *rgba_pixels);
typedef void (*QemuAndroidDirtyFrameCallback)(void *opaque, int full_w, int full_h,
                                              int x, int y, int width, int height,
                                              int stride_bytes, const void *rgba_pixels);
typedef void (*QemuAndroidSerialLogCallback)(void *opaque, const char *text,
                                             size_t len);

int qemu_android_main(int argc, char **argv);
void qemu_android_ui_configure_images(const char *system_img,
                                      const char *userdata_img,
                                      const char *cache_img);
void qemu_android_ui_configure_display(int width, int height, int dpi);
void qemu_android_ui_add_boot_property(const char *name, const char *value);
void qemu_android_ui_set_frame_callback(QemuAndroidFrameCallback cb, void *opaque);
void qemu_android_ui_set_dirty_frame_callback(QemuAndroidDirtyFrameCallback cb, void *opaque);
void qemu_android_ui_set_serial_log_callback(QemuAndroidSerialLogCallback cb,
                                             void *opaque);

void qemu_android_ui_touch(int finger_id, int x, int y, int down);
void qemu_android_ui_button(int keycode, int down);
void qemu_android_ui_accel(float x, float y, float z);
void qemu_android_ui_battery(int ac_online, int status, int level);
int qemu_android_ui_audio_pull(int16_t *out_stereo_frames, int max_frames,
                               int *out_sample_rate, int *out_channels);

bool qemu_android_adb_connected(void);
void qemu_android_adb_disconnect(void);
size_t qemu_android_adb_read(uint8_t *out_buf, size_t max_bytes);
size_t qemu_android_adb_write(const uint8_t *data, size_t len);

bool qemu_android_ui_is_ready(void);
void qemu_android_ui_sync(void);
void qemu_android_ui_quit(void);

#ifdef __cplusplus
}
#endif

#endif /* QEMU_ANDROID_UI_H */

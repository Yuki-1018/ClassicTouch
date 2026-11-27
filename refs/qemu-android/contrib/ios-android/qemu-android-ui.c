/*
 * Host UI bridge for Classic Android (`libqemu-android.dylib`),
 * connecting ClassicTouch callbacks to Goldfish's `android51` host ABI.
 */

#include "qemu/osdep.h"
#include "qemu-android-ui.h"
#include "hw/arm/android51/adb.h"
#include "hw/arm/android51/android51_host.h"
#include "standard-headers/linux/input.h"
#include <pthread.h>
#include <stdatomic.h>

#ifndef BTN_TOUCH
#define BTN_TOUCH 0x14a
#endif
#ifndef ABS_MT_SLOT
#define ABS_MT_SLOT 0x2f
#define ABS_MT_POSITION_X 0x35
#define ABS_MT_POSITION_Y 0x36
#define ABS_MT_TRACKING_ID 0x39
#endif

#define INPUT_QUEUE_CAP 2048
#define MAX_TOUCH_SLOTS 10
#define PCM_RING_SAMPLES (44100 * 2)

static _Atomic bool g_vm_ready = false;
static QemuAndroidFrameCallback g_frame_cb;
static void *g_frame_opaque;
static QemuAndroidDirtyFrameCallback g_dirty_frame_cb;
static void *g_dirty_frame_opaque;
static QemuAndroidSerialLogCallback g_serial_cb;
static void *g_serial_opaque;
static int g_lcd_width = 640;
static int g_lcd_height = 1136;

/* Touch + Key queue drained safely under BQL by host_poll() */
static pthread_mutex_t g_input_lock = PTHREAD_MUTEX_INITIALIZER;
static Android51Event g_input_ring[INPUT_QUEUE_CAP];
static size_t g_input_head = 0;
static size_t g_input_count = 0;

typedef struct TouchSlotState {
    bool active;
    int32_t x;
    int32_t y;
} TouchSlotState;

static TouchSlotState g_slots[MAX_TOUCH_SLOTS];
static uint32_t g_next_tracking = 1;

/* PCM output ring fed by Goldfish audio_callback -> android51_host_pcm */
static int16_t g_pcm_ring[PCM_RING_SAMPLES];
static _Atomic uint32_t g_pcm_head = 0;
static _Atomic uint32_t g_pcm_tail = 0;

static void push_input_packet_locked(const Android51Event *evs, size_t n)
{
    if (n > INPUT_QUEUE_CAP - g_input_count) {
        return;
    }
    for (size_t i = 0; i < n; i++) {
        size_t idx = (g_input_head + g_input_count) % INPUT_QUEUE_CAP;
        g_input_ring[idx] = evs[i];
        g_input_count++;
    }
}

static void on_host_frame(void *opaque, const uint8_t *pixels, size_t stride,
                          uint32_t x, uint32_t y, uint32_t width, uint32_t height)
{
    (void)opaque;
    if (!pixels || width == 0 || height == 0) {
        return;
    }
    int full_w = g_lcd_width > 0 ? g_lcd_width : (int)(x + width);
    int full_h = g_lcd_height > 0 ? g_lcd_height : (int)(y + height);
    if ((int)(x + width) > full_w) {
        full_w = (int)(x + width);
    }
    if ((int)(y + height) > full_h) {
        full_h = (int)(y + height);
    }
    if (g_dirty_frame_cb) {
        g_dirty_frame_cb(g_dirty_frame_opaque, full_w, full_h,
                         (int)x, (int)y, (int)width, (int)height,
                         (int)stride, pixels);
    }
    if (g_frame_cb) {
        g_frame_cb(g_frame_opaque, full_w, full_h, (int)stride, pixels);
    }
}

static size_t on_host_input(void *opaque, Android51Event *events, size_t capacity)
{
    (void)opaque;
    if (!events || capacity == 0) {
        return 0;
    }
    pthread_mutex_lock(&g_input_lock);
    size_t take = g_input_count < capacity ? g_input_count : capacity;
    for (size_t i = 0; i < take; i++) {
        events[i] = g_input_ring[g_input_head];
        g_input_head = (g_input_head + 1) % INPUT_QUEUE_CAP;
    }
    g_input_count -= take;
    pthread_mutex_unlock(&g_input_lock);
    return take;
}

static void on_host_pcm(void *opaque, const uint8_t *data, size_t bytes)
{
    (void)opaque;
    if (!data || bytes < 2) {
        return;
    }
    const int16_t *pcm = (const int16_t *)data;
    uint32_t num_samples = (uint32_t)(bytes / sizeof(int16_t));
    uint32_t head = atomic_load_explicit(&g_pcm_head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&g_pcm_tail, memory_order_acquire);
    uint32_t avail = PCM_RING_SAMPLES - 1 - (head - tail);
    if (num_samples > avail) {
        num_samples = avail;
    }
    for (uint32_t i = 0; i < num_samples; i++) {
        g_pcm_ring[(head + i) % PCM_RING_SAMPLES] = pcm[i];
    }
    atomic_store_explicit(&g_pcm_head, head + num_samples, memory_order_release);
}

static void on_host_serial(void *opaque, const uint8_t *data, size_t bytes)
{
    (void)opaque;
    if (g_serial_cb && data && bytes > 0) {
        g_serial_cb(g_serial_opaque, (const char *)data, bytes);
    }
}

static void on_host_state(void *opaque, int state)
{
    (void)opaque;
    if (state == 4) {
        atomic_store_explicit(&g_vm_ready, false, memory_order_release);
    }
}

static const Android51Host g_host_callbacks = {
    .abi = ANDROID51_HOST_ABI,
    .size = sizeof(Android51Host),
    .opaque = NULL,
    .frame = on_host_frame,
    .input = on_host_input,
    .pcm = on_host_pcm,
    .serial = on_host_serial,
    .state = on_host_state,
};

const Android51Host *qemu_android_ui_host_callbacks(void)
{
    return &g_host_callbacks;
}

void qemu_android_ui_vm_started(void)
{
    atomic_store_explicit(&g_vm_ready, true, memory_order_release);
}

bool qemu_android_adb_connected(void)
{
    return android51_adb_connected();
}

void qemu_android_adb_disconnect(void)
{
    android51_adb_disconnect();
}

size_t qemu_android_adb_read(uint8_t *out_buf, size_t max_bytes)
{
    return android51_adb_read(out_buf, max_bytes);
}

size_t qemu_android_adb_write(const uint8_t *data, size_t len)
{
    return android51_adb_write(data, len);
}

void android51_host_gpu_frame(const uint8_t *pixels, size_t stride,
                              uint32_t x, uint32_t y, uint32_t width, uint32_t height)
{
    on_host_frame(NULL, pixels, stride, x, y, width, height);
}

bool qemu_android_ui_is_ready(void)
{
    return atomic_load_explicit(&g_vm_ready, memory_order_acquire);
}

void qemu_android_ui_configure_images(const char *system_img,
                                      const char *userdata_img,
                                      const char *cache_img)
{
    (void)system_img;
    (void)userdata_img;
    (void)cache_img;
}

void qemu_android_ui_configure_display(int width, int height, int dpi)
{
    if (width > 0) g_lcd_width = width;
    if (height > 0) g_lcd_height = height;
    if (dpi > 0) android51_set_lcd_density((uint32_t)dpi);
}

void qemu_android_ui_add_boot_property(const char *name, const char *value)
{
    android51_add_boot_property(name, value);
}

void qemu_android_ui_set_frame_callback(QemuAndroidFrameCallback cb, void *opaque)
{
    g_frame_cb = cb;
    g_frame_opaque = opaque;
}

void qemu_android_ui_set_dirty_frame_callback(QemuAndroidDirtyFrameCallback cb, void *opaque)
{
    g_dirty_frame_cb = cb;
    g_dirty_frame_opaque = opaque;
}

void qemu_android_ui_set_serial_log_callback(QemuAndroidSerialLogCallback cb,
                                             void *opaque)
{
    g_serial_cb = cb;
    g_serial_opaque = opaque;
}

void qemu_android_ui_touch(int finger_id, int x, int y, int down)
{
    if (finger_id < 0 || finger_id >= MAX_TOUCH_SLOTS) {
        return;
    }
    if (x < 0) x = 0;
    if (g_lcd_width > 0 && x >= g_lcd_width) x = g_lcd_width - 1;
    if (y < 0) y = 0;
    if (g_lcd_height > 0 && y >= g_lcd_height) y = g_lcd_height - 1;

    pthread_mutex_lock(&g_input_lock);
    size_t active_count = 0;
    for (int i = 0; i < MAX_TOUCH_SLOTS; i++) {
        if (g_slots[i].active) active_count++;
    }

    Android51Event pkt[7];
    size_t n = 0;
    bool was_active = g_slots[finger_id].active;

    if (down) {
        if (!was_active) {
            if (active_count == 0) {
                pkt[n++] = (Android51Event){ EV_KEY, BTN_TOUCH, 1 };
            }
            pkt[n++] = (Android51Event){ EV_ABS, ABS_MT_SLOT, (int32_t)finger_id };
            int32_t tid = (int32_t)(g_next_tracking++ & 0x7fffffffU);
            if (tid <= 0) tid = 1;
            pkt[n++] = (Android51Event){ EV_ABS, ABS_MT_TRACKING_ID, tid };
            pkt[n++] = (Android51Event){ EV_ABS, ABS_MT_POSITION_X, (int32_t)x };
            pkt[n++] = (Android51Event){ EV_ABS, ABS_MT_POSITION_Y, (int32_t)y };
            pkt[n++] = (Android51Event){ EV_SYN, SYN_REPORT, 0 };
            g_slots[finger_id].active = true;
            g_slots[finger_id].x = x;
            g_slots[finger_id].y = y;
        } else if (g_slots[finger_id].x != x || g_slots[finger_id].y != y) {
            pkt[n++] = (Android51Event){ EV_ABS, ABS_MT_SLOT, (int32_t)finger_id };
            pkt[n++] = (Android51Event){ EV_ABS, ABS_MT_POSITION_X, (int32_t)x };
            pkt[n++] = (Android51Event){ EV_ABS, ABS_MT_POSITION_Y, (int32_t)y };
            pkt[n++] = (Android51Event){ EV_SYN, SYN_REPORT, 0 };
            g_slots[finger_id].x = x;
            g_slots[finger_id].y = y;
        }
    } else if (was_active) {
        if (active_count == 1) {
            pkt[n++] = (Android51Event){ EV_KEY, BTN_TOUCH, 0 };
        }
        pkt[n++] = (Android51Event){ EV_ABS, ABS_MT_SLOT, (int32_t)finger_id };
        pkt[n++] = (Android51Event){ EV_ABS, ABS_MT_TRACKING_ID, -1 };
        pkt[n++] = (Android51Event){ EV_SYN, SYN_REPORT, 0 };
        g_slots[finger_id].active = false;
    }

    if (n > 0) {
        push_input_packet_locked(pkt, n);
    }
    pthread_mutex_unlock(&g_input_lock);
}

void qemu_android_ui_button(int keycode, int down)
{
    if (keycode <= 0) {
        return;
    }
    Android51Event pkt[2] = {
        { EV_KEY, (uint16_t)keycode, down ? 1 : 0 },
        { EV_SYN, SYN_REPORT, 0 },
    };
    pthread_mutex_lock(&g_input_lock);
    push_input_packet_locked(pkt, 2);
    pthread_mutex_unlock(&g_input_lock);
}

void qemu_android_ui_accel(float x, float y, float z)
{
    (void)x;
    (void)y;
    (void)z;
}

void qemu_android_ui_battery(int ac_online, int status, int level)
{
    (void)ac_online;
    (void)status;
    (void)level;
}

int qemu_android_ui_audio_pull(int16_t *out_stereo_frames, int max_frames,
                               int *out_sample_rate, int *out_channels)
{
    if (out_sample_rate) *out_sample_rate = 44100;
    if (out_channels) *out_channels = 2;
    if (!out_stereo_frames || max_frames <= 0) {
        return 0;
    }
    uint32_t tail = atomic_load_explicit(&g_pcm_tail, memory_order_relaxed);
    uint32_t head = atomic_load_explicit(&g_pcm_head, memory_order_acquire);
    uint32_t avail_frames = (head - tail) / 2;
    uint32_t nframes = (uint32_t)max_frames;
    if (nframes > avail_frames) {
        nframes = avail_frames;
    }
    uint32_t nsamples = nframes * 2;
    for (uint32_t i = 0; i < nsamples; i++) {
        out_stereo_frames[i] = g_pcm_ring[(tail + i) % PCM_RING_SAMPLES];
    }
    atomic_store_explicit(&g_pcm_tail, tail + nsamples, memory_order_release);
    return (int)nframes;
}

void qemu_android_ui_sync(void)
{
}

void qemu_android_ui_quit(void)
{
    atomic_store_explicit(&g_vm_ready, false, memory_order_release);
    android51_host_stop();
}

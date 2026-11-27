/*
 * Host UI & Audio/Input bridge for Windows RT (`libqemu-winrt.dylib`) on iOS.
 */

#include "qemu/osdep.h"
#include "qemu-winrt-ui.h"
#include "qemu/main-loop.h"
#include "qemu/timer.h"
#include "qapi/error.h"
#include "qapi/qapi-types-audio.h"
#include "system/runstate.h"
#include "block/block-global-state.h"
#include "hw/core/qdev.h"
#include "hw/usb/usb.h"
#include "ui/console.h"
#include "ui/input.h"
#include "ui/surface.h"
#include "ui/qemu-pixman.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

extern void qemu_noaudio_set_tap(void (*cb)(void *opaque, const void *buf,
                                            size_t len, int freq, int channels,
                                            int format),
                                 void *opaque);

#define WINRT_INPUT_QUEUE_CAP 512
#define WINRT_PCM_RING_SAMPLES (48000 * 4)

typedef enum WinRTInputType {
    WINRT_EV_POINTER = 1,
    WINRT_EV_SCROLL = 2,
    WINRT_EV_KEY = 3,
    WINRT_EV_CAD = 4,
    WINRT_EV_RESET_USB = 5,
    WINRT_EV_TOUCH = 6,
} WinRTInputType;

typedef struct WinRTInputEvent {
    WinRTInputType type;
    int a;
    int b;
    int c;
    int d;
} WinRTInputEvent;

static _Atomic bool g_ui_attached = false;

static QemuWinRTFrameCallback g_frame_cb = NULL;
static void *g_frame_opaque = NULL;
static QemuWinRTDirtyFrameCallback g_dirty_frame_cb = NULL;
static void *g_dirty_frame_opaque = NULL;

static QemuConsole *g_con = NULL;
static DisplaySurface *g_surface = NULL;
static DisplayChangeListener g_dcl;
static bool g_dcl_registered = false;
static pixman_image_t *g_conv_image = NULL;
static int g_conv_w = 0;
static int g_conv_h = 0;
static bool g_logged_first_switch = false;
static bool g_logged_first_nonblack = false;
static int g_last_switch_w = 0;
static int g_last_switch_h = 0;

static pthread_mutex_t g_input_lock = PTHREAD_MUTEX_INITIALIZER;
static WinRTInputEvent g_input_ring[WINRT_INPUT_QUEUE_CAP];
static size_t g_input_head = 0;
static size_t g_input_count = 0;
static int g_last_buttons = 0;
static int g_touch_tracking_id[INPUT_EVENT_SLOTS_MAX];
static int g_touch_active_count = 0;
static int g_touch_next_id = 1;

static QEMUBH *g_input_bh = NULL;
static QEMUBH *g_sync_bh = NULL;
static QEMUBH *g_quit_bh = NULL;
static QEMUTimer *g_usb_reattach_timer = NULL;

static int16_t g_pcm_ring[WINRT_PCM_RING_SAMPLES];
static _Atomic uint32_t g_pcm_head = 0;
static _Atomic uint32_t g_pcm_tail = 0;
static _Atomic int g_audio_rate = 44100;

static void deliver_surface_rect(DisplaySurface *ds, int x, int y, int w, int h)
{
    if (!ds || !ds->image || w <= 0 || h <= 0) {
        return;
    }
    if (!g_dirty_frame_cb && !g_frame_cb) {
        return;
    }

    int sw = surface_width(ds);
    int sh = surface_height(ds);
    if (sw <= 0 || sh <= 0) {
        return;
    }

    if (x < 0) {
        w += x;
        x = 0;
    }
    if (y < 0) {
        h += y;
        y = 0;
    }
    if (x >= sw || y >= sh) {
        return;
    }
    if (x + w > sw) {
        w = sw - x;
    }
    if (y + h > sh) {
        h = sh - y;
    }
    if (w <= 0 || h <= 0) {
        return;
    }

    pixman_format_code_t fmt = surface_format(ds);
    const void *pixels = NULL;
    int stride = 0;

    if (fmt == PIXMAN_x8r8g8b8 || fmt == PIXMAN_a8r8g8b8) {
        pixels = surface_data(ds);
        stride = surface_stride(ds);
    } else {
        if (!g_conv_image || g_conv_w != sw || g_conv_h != sh) {
            if (g_conv_image) {
                pixman_image_unref(g_conv_image);
                g_conv_image = NULL;
            }
            g_conv_image = pixman_image_create_bits(PIXMAN_x8r8g8b8, sw, sh,
                                                    NULL, sw * 4);
            g_conv_w = sw;
            g_conv_h = sh;
            if (!g_conv_image) {
                return;
            }
            pixman_image_composite32(PIXMAN_OP_SRC, ds->image, NULL,
                                     g_conv_image, 0, 0, 0, 0, 0, 0, sw, sh);
            x = 0;
            y = 0;
            w = sw;
            h = sh;
        } else {
            pixman_image_composite32(PIXMAN_OP_SRC, ds->image, NULL,
                                     g_conv_image, x, y, 0, 0, x, y, w, h);
        }
        pixels = pixman_image_get_data(g_conv_image);
        stride = pixman_image_get_stride(g_conv_image);
    }

    if (!pixels || stride <= 0) {
        return;
    }

    if (!g_logged_first_nonblack) {
        const uint8_t *base = (const uint8_t *)pixels;
        int step_x = sw > 8 ? sw / 8 : 1;
        int step_y = sh > 8 ? sh / 8 : 1;
        for (int py = 0; py < sh && !g_logged_first_nonblack; py += step_y) {
            const uint32_t *row = (const uint32_t *)(base + (size_t)py * (size_t)stride);
            for (int px_i = 0; px_i < sw; px_i += step_x) {
                if ((row[px_i] & 0x00ffffffU) != 0) {
                    g_logged_first_nonblack = true;
                    fprintf(stderr, "[winrt-ui] first non-black frame (%dx%d)\n", sw, sh);
                    break;
                }
            }
        }
    }

    if (g_dirty_frame_cb) {
        g_dirty_frame_cb(g_dirty_frame_opaque, sw, sh, x, y, w, h, stride, pixels);
    } else if (g_frame_cb) {
        g_frame_cb(g_frame_opaque, sw, sh, stride, pixels);
    }
}

static void winrt_dpy_refresh(DisplayChangeListener *dcl)
{
    if (dcl->con) {
        graphic_hw_update(dcl->con);
    }
}

static void winrt_dpy_gfx_update(DisplayChangeListener *dcl,
                                 int x, int y, int w, int h)
{
    (void)dcl;
    deliver_surface_rect(g_surface, x, y, w, h);
}

static void winrt_dpy_gfx_switch(DisplayChangeListener *dcl,
                                 DisplaySurface *new_surface)
{
    (void)dcl;
    g_surface = new_surface;
    if (new_surface) {
        int sw = surface_width(new_surface);
        int sh = surface_height(new_surface);
        if (!g_logged_first_switch || sw != g_last_switch_w || sh != g_last_switch_h) {
            g_logged_first_switch = true;
            g_last_switch_w = sw;
            g_last_switch_h = sh;
            fprintf(stderr, "[winrt-ui] gfx_switch %dx%d fmt=0x%x\n",
                    sw, sh, (unsigned)surface_format(new_surface));
        }
        deliver_surface_rect(new_surface, 0, 0, sw, sh);
    }
}

static const DisplayChangeListenerOps winrt_dcl_ops = {
    .dpy_name = "ios-winrt",
    .dpy_refresh = winrt_dpy_refresh,
    .dpy_gfx_update = winrt_dpy_gfx_update,
    .dpy_gfx_switch = winrt_dpy_gfx_switch,
};

static inline int16_t clamp_s16(int32_t v)
{
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

static int16_t sample_to_s16(const uint8_t *frame, int ch_idx, int format)
{
    switch ((AudioFormat)format) {
    case AUDIO_FORMAT_S16:
        return ((const int16_t *)frame)[ch_idx];
    case AUDIO_FORMAT_U16:
        return clamp_s16((int32_t)((const uint16_t *)frame)[ch_idx] - 32768);
    case AUDIO_FORMAT_S8:
        return (int16_t)(((const int8_t *)frame)[ch_idx] * 256);
    case AUDIO_FORMAT_U8:
        return (int16_t)(((int16_t)((const uint8_t *)frame)[ch_idx] - 128) * 256);
    case AUDIO_FORMAT_S32:
        return (int16_t)(((const int32_t *)frame)[ch_idx] >> 16);
    case AUDIO_FORMAT_U32:
        return clamp_s16((int32_t)(((const uint32_t *)frame)[ch_idx] >> 16) - 32768);
    case AUDIO_FORMAT_F32: {
        float f = ((const float *)frame)[ch_idx];
        if (f > 1.0f) f = 1.0f;
        if (f < -1.0f) f = -1.0f;
        return clamp_s16((int32_t)(f * 32767.0f));
    }
    default:
        return 0;
    }
}

static void winrt_noaudio_tap(void *opaque, const void *buf, size_t len,
                              int freq, int channels, int format)
{
    (void)opaque;
    if (!buf || len == 0 || freq <= 0 || channels <= 0) {
        return;
    }

    size_t bps = 2;
    switch ((AudioFormat)format) {
    case AUDIO_FORMAT_U8:
    case AUDIO_FORMAT_S8:
        bps = 1;
        break;
    case AUDIO_FORMAT_U16:
    case AUDIO_FORMAT_S16:
        bps = 2;
        break;
    case AUDIO_FORMAT_U32:
    case AUDIO_FORMAT_S32:
    case AUDIO_FORMAT_F32:
        bps = 4;
        break;
    default:
        return;
    }

    size_t frame_bytes = (size_t)channels * bps;
    size_t nframes = len / frame_bytes;
    if (nframes == 0) {
        return;
    }

    atomic_store_explicit(&g_audio_rate, freq, memory_order_relaxed);

    uint32_t head = atomic_load_explicit(&g_pcm_head, memory_order_relaxed);
    uint32_t tail = atomic_load_explicit(&g_pcm_tail, memory_order_acquire);
    uint32_t avail_frames = (WINRT_PCM_RING_SAMPLES - 2 - (head - tail)) / 2;
    if (nframes > avail_frames) {
        nframes = avail_frames;
    }

    const uint8_t *src = (const uint8_t *)buf;
    int ch1_idx = channels >= 2 ? 1 : 0;
    for (size_t i = 0; i < nframes; i++) {
        const uint8_t *frame = src + i * frame_bytes;
        int16_t l = sample_to_s16(frame, 0, format);
        int16_t r = sample_to_s16(frame, ch1_idx, format);
        uint32_t idx = head + (uint32_t)(i * 2);
        g_pcm_ring[idx % WINRT_PCM_RING_SAMPLES] = l;
        g_pcm_ring[(idx + 1) % WINRT_PCM_RING_SAMPLES] = r;
    }
    atomic_store_explicit(&g_pcm_head, head + (uint32_t)(nframes * 2),
                          memory_order_release);
}

static USBDevice *find_usb_device_by_id(const char *id)
{
    DeviceState *dev = qdev_find_recursive(sysbus_get_default(), id);
    if (!dev) {
        return NULL;
    }
    return (USBDevice *)object_dynamic_cast(OBJECT(dev), TYPE_USB_DEVICE);
}

static void winrt_usb_reattach_cb(void *opaque)
{
    (void)opaque;
    const char *ids[2] = { "kbd", "mice" };
    for (int i = 0; i < 2; i++) {
        USBDevice *udev = find_usb_device_by_id(ids[i]);
        if (udev && !udev->attached) {
            Error *local_err = NULL;
            usb_device_attach(udev, &local_err);
            if (local_err) {
                warn_report_err(local_err);
            }
        }
    }
}

static void send_key_sync(QKeyCode q, bool down)
{
    qemu_input_event_send_key_qcode(g_con, q, down);
    qemu_input_event_sync();
}

static void winrt_input_bh_cb(void *opaque)
{
    (void)opaque;
    WinRTInputEvent batch[64];

    for (;;) {
        size_t take = 0;
        pthread_mutex_lock(&g_input_lock);
        while (g_input_count > 0 && take < 64) {
            batch[take++] = g_input_ring[g_input_head];
            g_input_head = (g_input_head + 1) % WINRT_INPUT_QUEUE_CAP;
            g_input_count--;
        }
        pthread_mutex_unlock(&g_input_lock);

        if (take == 0) {
            break;
        }

        for (size_t i = 0; i < take; i++) {
            WinRTInputEvent ev = batch[i];
            switch (ev.type) {
            case WINRT_EV_POINTER: {
                int x = ev.a < 0 ? 0 : (ev.a > 0x7fff ? 0x7fff : ev.a);
                int y = ev.b < 0 ? 0 : (ev.b > 0x7fff ? 0x7fff : ev.b);
                int mask = ev.c;
                int changed = mask ^ g_last_buttons;
                qemu_input_queue_abs(g_con, INPUT_AXIS_X, x, 0, 0x7fff);
                qemu_input_queue_abs(g_con, INPUT_AXIS_Y, y, 0, 0x7fff);
                if (changed & 1) {
                    qemu_input_queue_btn(g_con, INPUT_BUTTON_LEFT, (mask & 1) != 0);
                }
                if (changed & 2) {
                    qemu_input_queue_btn(g_con, INPUT_BUTTON_RIGHT, (mask & 2) != 0);
                }
                if (changed & 4) {
                    qemu_input_queue_btn(g_con, INPUT_BUTTON_MIDDLE, (mask & 4) != 0);
                }
                g_last_buttons = mask;
                qemu_input_event_sync();
                break;
            }
            case WINRT_EV_SCROLL: {
                int steps = ev.a;
                InputButton btn = steps > 0 ? INPUT_BUTTON_WHEEL_UP : INPUT_BUTTON_WHEEL_DOWN;
                int n = steps < 0 ? -steps : steps;
                if (n > 5) n = 5;
                for (int s = 0; s < n; s++) {
                    qemu_input_queue_btn(g_con, btn, true);
                    qemu_input_event_sync();
                    qemu_input_queue_btn(g_con, btn, false);
                    qemu_input_event_sync();
                }
                break;
            }
            case WINRT_EV_KEY:
                if (ev.a > 0 && ev.a < Q_KEY_CODE__MAX) {
                    send_key_sync((QKeyCode)ev.a, ev.b != 0);
                }
                break;
            case WINRT_EV_CAD:
                send_key_sync(Q_KEY_CODE_CTRL, true);
                send_key_sync(Q_KEY_CODE_ALT, true);
                send_key_sync(Q_KEY_CODE_DELETE, true);
                send_key_sync(Q_KEY_CODE_DELETE, false);
                send_key_sync(Q_KEY_CODE_ALT, false);
                send_key_sync(Q_KEY_CODE_CTRL, false);
                break;
            case WINRT_EV_RESET_USB: {
                const char *ids[2] = { "kbd", "mice" };
                for (int j = 0; j < 2; j++) {
                    USBDevice *udev = find_usb_device_by_id(ids[j]);
                    if (udev && udev->attached) {
                        usb_device_detach(udev);
                    }
                }
                if (g_usb_reattach_timer) {
                    timer_mod(g_usb_reattach_timer,
                              qemu_clock_get_ms(QEMU_CLOCK_REALTIME) + 150);
                }
                break;
            }
            case WINRT_EV_TOUCH: {
                int slot = ev.a;
                int x = ev.b < 0 ? 0 : (ev.b > 0x7fff ? 0x7fff : ev.b);
                int y = ev.c < 0 ? 0 : (ev.c > 0x7fff ? 0x7fff : ev.c);
                int phase = ev.d;
                if (slot < 0 || slot >= INPUT_EVENT_SLOTS_MAX) {
                    break;
                }
                if (phase == 0 || (phase == 1 && g_touch_tracking_id[slot] < 0)) {
                    bool was_empty = (g_touch_active_count == 0);
                    int tid = g_touch_next_id++;
                    if (g_touch_next_id > 65535) {
                        g_touch_next_id = 1;
                    }
                    if (g_touch_tracking_id[slot] < 0) {
                        g_touch_active_count++;
                    }
                    g_touch_tracking_id[slot] = tid;
                    qemu_input_queue_mtt(g_con, INPUT_MULTI_TOUCH_TYPE_BEGIN, slot, tid);
                    qemu_input_queue_mtt_abs(g_con, INPUT_AXIS_X, x, 0, 0x7fff, slot, tid);
                    qemu_input_queue_mtt_abs(g_con, INPUT_AXIS_Y, y, 0, 0x7fff, slot, tid);
                    if (was_empty) {
                        qemu_input_queue_btn(g_con, INPUT_BUTTON_TOUCH, true);
                    }
                    qemu_input_event_sync();
                } else if (phase == 1) {
                    int tid = g_touch_tracking_id[slot];
                    qemu_input_queue_mtt(g_con, INPUT_MULTI_TOUCH_TYPE_UPDATE, slot, tid);
                    qemu_input_queue_mtt_abs(g_con, INPUT_AXIS_X, x, 0, 0x7fff, slot, tid);
                    qemu_input_queue_mtt_abs(g_con, INPUT_AXIS_Y, y, 0, 0x7fff, slot, tid);
                    qemu_input_event_sync();
                } else if (phase == 2 || phase == 3) {
                    if (g_touch_tracking_id[slot] >= 0) {
                        g_touch_tracking_id[slot] = -1;
                        if (g_touch_active_count > 0) {
                            g_touch_active_count--;
                        }
                        qemu_input_queue_mtt(g_con, INPUT_MULTI_TOUCH_TYPE_END, slot, -1);
                        if (g_touch_active_count == 0) {
                            qemu_input_queue_btn(g_con, INPUT_BUTTON_TOUCH, false);
                        }
                        qemu_input_event_sync();
                    }
                }
                break;
            }
            }
        }
    }
}

static void winrt_sync_bh_cb(void *opaque)
{
    (void)opaque;
    bdrv_flush_all();
}

static void winrt_quit_bh_cb(void *opaque)
{
    (void)opaque;
    qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_UI);
}

static void enqueue_input_event(WinRTInputEvent ev)
{
    if (!atomic_load_explicit(&g_ui_attached, memory_order_acquire)) {
        return;
    }
    pthread_mutex_lock(&g_input_lock);
    if (g_input_count > 0) {
        size_t last_idx = (g_input_head + g_input_count - 1) % WINRT_INPUT_QUEUE_CAP;
        if ((ev.type == WINRT_EV_POINTER &&
             g_input_ring[last_idx].type == WINRT_EV_POINTER &&
             g_input_ring[last_idx].c == ev.c) ||
            (ev.type == WINRT_EV_TOUCH && ev.d == 1 &&
             g_input_ring[last_idx].type == WINRT_EV_TOUCH &&
             g_input_ring[last_idx].d == 1 &&
             g_input_ring[last_idx].a == ev.a)) {
            g_input_ring[last_idx] = ev;
            pthread_mutex_unlock(&g_input_lock);
            if (g_input_bh) {
                qemu_bh_schedule(g_input_bh);
            }
            return;
        }
    }
    if (g_input_count < WINRT_INPUT_QUEUE_CAP) {
        size_t idx = (g_input_head + g_input_count) % WINRT_INPUT_QUEUE_CAP;
        g_input_ring[idx] = ev;
        g_input_count++;
    }
    pthread_mutex_unlock(&g_input_lock);

    if (g_input_bh) {
        qemu_bh_schedule(g_input_bh);
    }
}

void qemu_winrt_ui_attach(void)
{
    g_con = NULL;
    for (unsigned int idx = 0; ; idx++) {
        QemuConsole *con = qemu_console_lookup_by_index(idx);
        if (!con) {
            break;
        }
        if (qemu_console_is_graphic(con)) {
            g_con = con;
            break;
        }
    }
    if (!g_con) {
        g_con = qemu_console_lookup_default();
    }
    g_logged_first_switch = false;
    g_logged_first_nonblack = false;
    g_last_switch_w = 0;
    g_last_switch_h = 0;
    for (int i = 0; i < INPUT_EVENT_SLOTS_MAX; i++) {
        g_touch_tracking_id[i] = -1;
    }
    g_touch_active_count = 0;
    g_touch_next_id = 1;
    fprintf(stderr, "[winrt-ui] attached console=%p graphic=%d\n",
            (void *)g_con, g_con ? qemu_console_is_graphic(g_con) : 0);
    g_input_bh = qemu_bh_new(winrt_input_bh_cb, NULL);
    g_sync_bh = qemu_bh_new(winrt_sync_bh_cb, NULL);
    g_quit_bh = qemu_bh_new(winrt_quit_bh_cb, NULL);
    g_usb_reattach_timer = timer_new_ms(QEMU_CLOCK_REALTIME, winrt_usb_reattach_cb, NULL);

    memset(&g_dcl, 0, sizeof(g_dcl));
    g_dcl.ops = &winrt_dcl_ops;
    g_dcl.con = g_con;
    g_dcl.update_interval = 8;
    register_displaychangelistener(&g_dcl);
    g_dcl_registered = true;
    update_displaychangelistener(&g_dcl, 8);

    qemu_noaudio_set_tap(winrt_noaudio_tap, NULL);
    atomic_store_explicit(&g_ui_attached, true, memory_order_release);
}

void qemu_winrt_ui_detach(void)
{
    atomic_store_explicit(&g_ui_attached, false, memory_order_release);
    qemu_noaudio_set_tap(NULL, NULL);

    if (g_dcl_registered) {
        unregister_displaychangelistener(&g_dcl);
        g_dcl_registered = false;
        g_dcl.ds = NULL;
    }
    if (g_usb_reattach_timer) {
        timer_free(g_usb_reattach_timer);
        g_usb_reattach_timer = NULL;
    }
    if (g_input_bh) {
        qemu_bh_delete(g_input_bh);
        g_input_bh = NULL;
    }
    if (g_sync_bh) {
        qemu_bh_delete(g_sync_bh);
        g_sync_bh = NULL;
    }
    if (g_quit_bh) {
        qemu_bh_delete(g_quit_bh);
        g_quit_bh = NULL;
    }
    if (g_conv_image) {
        pixman_image_unref(g_conv_image);
        g_conv_image = NULL;
    }
    g_surface = NULL;
    g_con = NULL;
    g_logged_first_switch = false;
    g_logged_first_nonblack = false;
    g_last_switch_w = 0;
    g_last_switch_h = 0;
    for (int i = 0; i < INPUT_EVENT_SLOTS_MAX; i++) {
        g_touch_tracking_id[i] = -1;
    }
    g_touch_active_count = 0;
    g_touch_next_id = 1;
}

int qemu_winrt_create_disk(const char *path, uint64_t size_bytes)
{
    if (!path || !*path || size_bytes < (1ULL << 20)) {
        return -EINVAL;
    }
    int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0) {
        return -errno;
    }
    if (ftruncate(fd, (off_t)size_bytes) != 0) {
        int err = -errno;
        close(fd);
        unlink(path);
        return err;
    }
    close(fd);
    return 0;
}

void qemu_winrt_ui_set_frame_callback(QemuWinRTFrameCallback cb, void *opaque)
{
    g_frame_cb = cb;
    g_frame_opaque = opaque;
}

void qemu_winrt_ui_set_dirty_frame_callback(QemuWinRTDirtyFrameCallback cb, void *opaque)
{
    g_dirty_frame_cb = cb;
    g_dirty_frame_opaque = opaque;
}

void qemu_winrt_ui_pointer_abs(int x_0_32767, int y_0_32767, int buttons_mask)
{
    enqueue_input_event((WinRTInputEvent){
        WINRT_EV_POINTER, x_0_32767, y_0_32767, buttons_mask, 0
    });
}

void qemu_winrt_ui_touch(int slot, int x_0_32767, int y_0_32767, int phase)
{
    if (slot < 0 || slot >= INPUT_EVENT_SLOTS_MAX) {
        return;
    }
    enqueue_input_event((WinRTInputEvent){
        WINRT_EV_TOUCH, slot, x_0_32767, y_0_32767, phase
    });
}

void qemu_winrt_ui_scroll(int wheel_delta)
{
    if (wheel_delta == 0) {
        return;
    }
    enqueue_input_event((WinRTInputEvent){ WINRT_EV_SCROLL, wheel_delta, 0, 0, 0 });
}

void qemu_winrt_ui_key_qcode(int qcode, int down)
{
    enqueue_input_event((WinRTInputEvent){ WINRT_EV_KEY, qcode, down ? 1 : 0, 0, 0 });
}

void qemu_winrt_ui_send_cad(void)
{
    enqueue_input_event((WinRTInputEvent){ WINRT_EV_CAD, 0, 0, 0, 0 });
}

void qemu_winrt_ui_reset_usb_input(void)
{
    enqueue_input_event((WinRTInputEvent){ WINRT_EV_RESET_USB, 0, 0, 0, 0 });
}

int qemu_winrt_ui_audio_pull(int16_t *out_stereo_frames, int max_frames,
                             int *out_sample_rate, int *out_channels)
{
    if (out_sample_rate) {
        *out_sample_rate = atomic_load_explicit(&g_audio_rate, memory_order_relaxed);
    }
    if (out_channels) {
        *out_channels = 2;
    }
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
        out_stereo_frames[i] = g_pcm_ring[(tail + i) % WINRT_PCM_RING_SAMPLES];
    }
    atomic_store_explicit(&g_pcm_tail, tail + nsamples, memory_order_release);
    return (int)nframes;
}

void qemu_winrt_ui_sync(void)
{
    if (atomic_load_explicit(&g_ui_attached, memory_order_acquire) && g_sync_bh) {
        qemu_bh_schedule(g_sync_bh);
    }
}

void qemu_winrt_ui_quit(void)
{
    if (atomic_load_explicit(&g_ui_attached, memory_order_acquire) && g_quit_bh) {
        qemu_bh_schedule(g_quit_bh);
    }
}

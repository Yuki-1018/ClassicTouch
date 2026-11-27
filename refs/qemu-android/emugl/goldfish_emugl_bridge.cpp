/*
 * C <-> C++ bridge between Goldfish pipe/display (`gpu.h`)
 * and our fixed AOSP emugl (`FrameBuffer` / `RenderThread`) on host EAGL/EGL.
 */

#include "gpu.h"
#include "android51_host.h"
#include "DispatchTables.h"
#include "FrameBuffer.h"
#include "IOStream.h"
#include "RenderThread.h"
#include "OpenGLESDispatch/EGLDispatch.h"
#include "OpenGLESDispatch/GLESv1Dispatch.h"
#include "OpenGLESDispatch/GLESv2Dispatch.h"
#include "emugl/common/crash_reporter.h"
#include "emugl/common/feature_control.h"
#include "emugl/common/logging.h"
#include "emugl/common/mutex.h"

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <mutex>
#include <new>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>
#include <vector>

namespace {

static std::mutex s_frame_lock;
static emugl::Mutex s_render_lock;
static std::vector<uint8_t> s_frame;
static std::vector<uint8_t> s_prev_src;
static bool s_have_post = false;
static bool s_pending = false;
static bool s_initialized = false;
static bool s_attempted = false;
static char s_init_error[256] = "GPU initialization has not completed";
static unsigned s_width = 0;
static unsigned s_height = 0;
static unsigned s_dirty_first = 0;
static unsigned s_dirty_last = 0;
static std::atomic<void (*)(void *)> s_wake_cb{nullptr};
static std::atomic<void *> s_wake_ctx{nullptr};

static void emugl_logger_cb(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[emugl] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

static void emugl_crash_cb(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[emugl-fatal] ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

static bool emugl_feature_cb(android::featurecontrol::Feature f)
{
    (void)f;
    return false;
}

static void on_emugl_post(void *ctx, int w, int h, int direction,
                          int format, int type, unsigned char *pixels)
{
    (void)ctx;
    if (w != (int)s_width || h != (int)s_height || type != 0x1401 || !pixels) {
        return;
    }
    const bool is_bgra = (format == 0x80E1 /* GL_BGRA_EXT */);
    const bool is_rgba = (format == 0x1908 /* GL_RGBA */);
    if (!is_bgra && !is_rgba) {
        return;
    }

    static std::atomic<uint32_t> s_post_count{0};
    uint32_t frame_no = s_post_count.fetch_add(1, std::memory_order_relaxed) + 1;
    if (frame_no <= 3 || frame_no == 30 || frame_no == 120 || (frame_no % 300 == 0)) {
        size_t total = (size_t)s_width * (size_t)s_height * 4U;
        size_t non_black = 0;
        for (size_t i = 0; i + 3 < total; i += 64) {
            if (pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0) {
                non_black++;
            }
        }
        fprintf(stderr, "[emugl] post frame #%u (%dx%d fmt=0x%x dir=%d non_black=%zu)\n",
                frame_no, w, h, format, direction, non_black);
    }

    const size_t row_bytes = (size_t)s_width * 4U;
    bool notify = false;
    unsigned dirty_first = 0, dirty_rows = 0, frame_w = 0;
    size_t frame_stride = 0;
    const uint8_t *frame_ptr = nullptr;
    std::vector<uint8_t> direct_copy;
    {
        std::lock_guard<std::mutex> lock(s_frame_lock);
        if (s_frame.size() != row_bytes * s_height || s_prev_src.size() != row_bytes * s_height) {
            return;
        }

        for (unsigned y = 0; y < s_height; ++y) {
            unsigned src_y = (direction < 0) ? (s_height - 1U - y) : y;
            const uint8_t *src = pixels + (size_t)src_y * row_bytes;
            uint8_t *previous = s_prev_src.data() + (size_t)y * row_bytes;
            if (s_have_post && memcmp(previous, src, row_bytes) == 0) {
                continue;
            }
            memcpy(previous, src, row_bytes);
            uint8_t *dst = s_frame.data() + (size_t)y * row_bytes;
            if (is_bgra) {
                memcpy(dst, src, row_bytes);
            } else {
                for (unsigned x = 0; x < s_width; ++x) {
                    dst[x * 4 + 0] = src[x * 4 + 2];
                    dst[x * 4 + 1] = src[x * 4 + 1];
                    dst[x * 4 + 2] = src[x * 4 + 0];
                    dst[x * 4 + 3] = 255;
                }
            }
            if (!s_pending) {
                s_dirty_first = s_dirty_last = y;
                s_pending = true;
            } else {
                s_dirty_first = std::min(s_dirty_first, y);
                s_dirty_last = std::max(s_dirty_last, y);
            }
            notify = true;
        }
        s_have_post = true;
        if (notify) {
            dirty_first = s_dirty_first;
            dirty_rows = s_dirty_last - s_dirty_first + 1;
            frame_w = s_width;
            frame_stride = row_bytes;
            /* Present directly to Metal FrameMailbox off QEMU BQL while keeping
             * the full surface pointer layout FrameMailbox expects. */
            frame_ptr = s_frame.data();
            s_pending = false;
            android51_host_gpu_frame(frame_ptr, frame_stride, 0, dirty_first, frame_w, dirty_rows);
            static std::atomic<bool> s_logged_direct{false};
            if (!s_logged_direct.exchange(true, std::memory_order_relaxed)) {
                fprintf(stderr, "[emugl] first gpu frame presented directly (%ux%u)\n", s_width, s_height);
            }
        }
    }
}

class SocketStream final : public IOStream {
    int m_fd;
    bool m_handshake = false;
    std::vector<unsigned char> m_storage;
public:
    explicit SocketStream(int socket_fd) : IOStream(4096), m_fd(socket_fd) {}
    ~SocketStream() override {
        if (m_fd >= 0) {
            close(m_fd);
            m_fd = -1;
        }
    }
    void forceStop() override {
        if (m_fd >= 0) {
            shutdown(m_fd, SHUT_RDWR);
        }
    }
    void *allocBuffer(size_t size) override {
        if (size > 64u * 1024 * 1024) {
            return nullptr;
        }
        m_storage.resize(size);
        return m_storage.data();
    }
    int commitBuffer(size_t size) override {
        int result = writeFully(m_storage.data(), size);
        if (m_storage.capacity() > 1024 * 1024) {
            std::vector<unsigned char>().swap(m_storage);
        }
        return result;
    }
    int writeFully(const void *data, size_t size) override {
        auto p = static_cast<const unsigned char *>(data);
        while (size) {
#ifdef MSG_NOSIGNAL
            ssize_t n = send(m_fd, p, size, MSG_NOSIGNAL);
#else
            ssize_t n = send(m_fd, p, size, 0);
#endif
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return -1;
            p += n;
            size -= (size_t)n;
        }
        return 0;
    }
    const unsigned char *readFully(void *data, size_t size) override {
        auto p = static_cast<unsigned char *>(data);
        while (size) {
            ssize_t n = recv(m_fd, p, size, 0);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) return nullptr;
            p += n;
            size -= (size_t)n;
        }
        return static_cast<unsigned char *>(data);
    }
    const unsigned char *read(void *data, size_t *size) override {
        if (!m_handshake) {
            uint32_t flags = 0;
            if (!readFully(&flags, sizeof(flags)) || flags != 0) {
                return nullptr;
            }
            m_handshake = true;
        }
        ssize_t n;
        do {
            n = recv(m_fd, data, *size, 0);
        } while (n < 0 && errno == EINTR);
        if (n <= 0) {
            return nullptr;
        }
        *size = (size_t)n;
        return static_cast<unsigned char *>(data);
    }
};

struct SocketConnection {
    int fd;
    RenderThread *thread;
};

static int socket_transfer(void *opaque, void *data, size_t size, bool sending)
{
    if (!opaque || size > 8192) {
        return -4;
    }
    int fd = static_cast<SocketConnection *>(opaque)->fd;
    ssize_t n;
    do {
#ifdef MSG_NOSIGNAL
        n = sending ? send(fd, data, size, MSG_NOSIGNAL) : recv(fd, data, size, 0);
#else
        n = sending ? send(fd, data, size, 0) : recv(fd, data, size, 0);
#endif
    } while (n < 0 && errno == EINTR);
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
        return -2;
    }
    return (n <= 0 && size) ? -4 : (int)n;
}

} // namespace

extern "C" {

const char *ae_gpu_last_error(void)
{
    return s_init_error;
}

int ae_gpu_init(unsigned w, unsigned h)
{
    if (s_attempted) {
        return s_initialized ? 1 : 0;
    }
    s_attempted = true;
    if (!w || !h || w > 2048 || h > 2048) {
        std::snprintf(s_init_error, sizeof(s_init_error), "Invalid GPU framebuffer dimensions");
        return 0;
    }

    set_emugl_logger(emugl_logger_cb);
    set_emugl_cxt_logger(emugl_logger_cb);
    set_emugl_crash_reporter(emugl_crash_cb);
    set_emugl_feature_is_enabled(emugl_feature_cb);

    if (!init_egl_dispatch()) {
        std::snprintf(s_init_error, sizeof(s_init_error), "init_egl_dispatch failed");
        return 0;
    }
    if (!gles1_dispatch_init(&s_gles1)) {
        std::snprintf(s_init_error, sizeof(s_init_error), "gles1_dispatch_init failed");
        return 0;
    }
    if (!gles2_dispatch_init(&s_gles2)) {
        std::snprintf(s_init_error, sizeof(s_init_error), "gles2_dispatch_init failed");
        return 0;
    }

    try {
        s_width = w;
        s_height = h;
        s_frame.assign((size_t)w * h * 4U, 0);
        s_prev_src.assign(s_frame.size(), 0xff);
        for (size_t i = 3; i < s_frame.size(); i += 4) {
            s_frame[i] = 255;
        }
        s_have_post = false;
        s_pending = true;
        s_dirty_first = 0;
        s_dirty_last = h - 1;

        if (!FrameBuffer::initialize((int)w, (int)h, false /* useSubWindow */)) {
            std::snprintf(s_init_error, sizeof(s_init_error), "FrameBuffer::initialize failed (%ux%u)", w, h);
            return 0;
        }
        FrameBuffer::getFB()->setPostCallback(on_emugl_post, nullptr);
        s_initialized = true;
        s_init_error[0] = '\0';
        return 1;
    } catch (const std::bad_alloc &) {
        std::snprintf(s_init_error, sizeof(s_init_error), "Insufficient memory while initializing GPU");
        return 0;
    }
}

void ae_gpu_destroy(void)
{
    if (s_initialized) {
        if (FrameBuffer *fb = FrameBuffer::getFB()) {
            fb->finalize();
            delete fb;
        }
        s_initialized = false;
    }
    s_attempted = false;
    s_width = 0;
    s_height = 0;
    s_have_post = false;
    s_pending = false;
}

void *ae_gpu_open(void)
{
    if (!s_initialized || !FrameBuffer::getFB()) {
        return nullptr;
    }
    int sockets[2] = { -1, -1 };
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sockets) != 0) {
        return nullptr;
    }
    int bufferBytes = 64 * 1024;
    for (int fd : sockets) {
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferBytes, sizeof(bufferBytes));
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferBytes, sizeof(bufferBytes));
        fcntl(fd, F_SETFD, FD_CLOEXEC);
#ifdef SO_NOSIGPIPE
        int yes = 1;
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
    }
    fcntl(sockets[0], F_SETFL, O_NONBLOCK);

    SocketStream *stream = new SocketStream(sockets[1]);
    RenderThread *thread = RenderThread::create(stream, &s_render_lock);
    if (!thread || !thread->start()) {
        if (thread) {
            delete thread;
        } else {
            delete stream;
        }
        close(sockets[0]);
        return nullptr;
    }
    return new SocketConnection{ sockets[0], thread };
}

void ae_gpu_close(void *opaque)
{
    auto *c = static_cast<SocketConnection *>(opaque);
    if (!c) {
        return;
    }
    if (c->fd >= 0) {
        shutdown(c->fd, SHUT_RDWR);
        close(c->fd);
        c->fd = -1;
    }
    if (c->thread) {
        c->thread->forceStop();
        c->thread->wait(nullptr);
        delete c->thread;
        c->thread = nullptr;
    }
    delete c;
}

int ae_gpu_fd(void *stream)
{
    return stream ? static_cast<SocketConnection *>(stream)->fd : -1;
}

int ae_gpu_send(void *s, const void *p, size_t n)
{
    return socket_transfer(s, const_cast<void *>(p), n, true);
}

int ae_gpu_receive(void *s, void *p, size_t n)
{
    return socket_transfer(s, p, n, false);
}

unsigned ae_gpu_poll(void *opaque)
{
    if (!opaque) {
        return 4;
    }
    pollfd p = { static_cast<SocketConnection *>(opaque)->fd, POLLIN | POLLOUT, 0 };
    if (poll(&p, 1, 0) < 0) {
        return (errno == EINTR) ? 0 : 4;
    }
    return ((p.revents & POLLIN) ? 1U : 0U) |
           ((p.revents & POLLOUT) ? 2U : 0U) |
           ((p.revents & (POLLHUP | POLLERR | POLLNVAL)) ? 4U : 0U);
}

void ae_gpu_invalidate_frame(void)
{
    std::lock_guard<std::mutex> lock(s_frame_lock);
    if (s_have_post && s_height > 0) {
        s_pending = true;
        s_dirty_first = 0;
        s_dirty_last = s_height - 1;
    }
}

void ae_gpu_set_wake_callback(void (*cb)(void *), void *ctx)
{
    s_wake_ctx.store(ctx, std::memory_order_relaxed);
    s_wake_cb.store(cb, std::memory_order_release);
}

int ae_gpu_frame_region(uint8_t *pixels, size_t size, unsigned *first, unsigned *rows)
{
    std::lock_guard<std::mutex> lock(s_frame_lock);
    if (!s_have_post || !s_pending || size != s_frame.size() || !pixels || !first || !rows) {
        return 0;
    }
    *first = s_dirty_first;
    *rows = s_dirty_last - s_dirty_first + 1;
    size_t offset = (size_t)s_dirty_first * s_width * 4U;
    memcpy(pixels + offset, s_frame.data() + offset, (size_t)(*rows) * s_width * 4U);
    s_pending = false;
    return 1;
}

} // extern "C"

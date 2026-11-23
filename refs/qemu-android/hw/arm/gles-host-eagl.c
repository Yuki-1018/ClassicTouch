/*
 * OpenGL ES 1.1 high-level emulation -- the iOS half of the host context.
 *
 * gles-host.c is the renderer and it is platform-neutral; this file is the one
 * thing it cannot do for itself, which is ask iOS for a context. On macOS the
 * same two functions are a dozen lines of CGL inside gles-host.c.
 *
 * WHY THIS IS ALLOWED TO BE SO SMALL. The guest is an iPod touch running iOS
 * 3.1.3, so the API the guest issues -- fixed-function GLES 1.1, glMatrixMode
 * and glOrthof and glLightfv -- is still exactly the API OpenGLES.framework
 * exports today (verified against the iPhoneOS 26.5 SDK: 457 entry points, all
 * of the guest's among them). There is no shader translation anywhere in this
 * port. Nor does anything here have to emulate a drawable: the "swap" in this
 * design is a copy into the guest's own CoreAnimation surface (see
 * gles_present_to_surface), so the host context never needs a CAEAGLLayer, a
 * window or presentRenderbuffer. An offscreen FBO in a bare EAGLContext is the
 * entire requirement -- with, since the present has to be cheap on a tiler, an
 * IOSurface for its color attachment rather than plain texture storage. That
 * second half is the rest of this file.
 *
 * WHY C AND objc_msgSend RATHER THAN AN .m FILE. This is three message sends,
 * and writing them in Objective-C costs more than it looks. meson picks a
 * target's linker driver from the languages of its sources -- and of anything
 * it links -- so a single .m anywhere in qemu-system-arm switches the link from
 * c_LINKER to objc_LINKER. meson then applies objc_link_args, which configure
 * never writes (it writes c_link_args and cpp_link_args only), so every
 * --extra-ldflags the iOS cross build depends on -- the sysroot's -L, its
 * libcrypto.a -- silently disappears and the link dies on the first library it
 * can no longer find. Both ways out of that were tried and neither works from
 * inside hw/arm/meson.build: a separate static_library propagates its language
 * to whatever links it, and so does handing over its extracted objects.
 *
 * The proper fix is one line in configure, teaching it to emit objc_link_args
 * beside c_link_args; with that this file could be an .m and read a little
 * better. It would not do anything different. What it does now is the same
 * three messages the compiler would have emitted, and it is a leaf: nothing
 * else in the tree calls it, so the cost of the idiom is contained here.
 *
 * THREADING. EAGL's current context is thread-local, exactly like CGL's. Every
 * QC_GLES request arrives on the one vCPU thread that traps out of the guest,
 * so the context is created on that thread and stays current on it; no other
 * thread in the process touches GL. gles_eagl_make_current is the same cheap
 * thread-local comparison the CGL path does rather than an unconditional call
 * into the GL stack.
 *
 * Copyright (c) 2026 the qemu-ios contributors.
 */

#include "qemu/osdep.h"

#include <objc/message.h>
#include <objc/runtime.h>

#include <CoreFoundation/CoreFoundation.h>
#include <IOSurface/IOSurfaceRef.h>
#include <os/lock.h>

typedef struct GLESEAGLContext {
    id ctx;
    unsigned api;
    unsigned host_api;
    IOSurfaceRef surf;
    uint32_t surf_w;
    uint32_t surf_h;
    int refs;
} *GLESEAGLContextObj;

bool gles_eagl_create(GLESEAGLContextObj share, unsigned api,
                      GLESEAGLContextObj *out);
int gles_eagl_set_current(GLESEAGLContextObj c);
GLESEAGLContextObj gles_eagl_get_current(void);
GLESEAGLContextObj gles_eagl_retain(GLESEAGLContextObj c);
void gles_eagl_release(GLESEAGLContextObj c);
unsigned gles_eagl_current_api(void);
unsigned gles_eagl_host_api(void);
bool gles_eagl_iosurface_bind(uint32_t width, uint32_t height,
                              unsigned long target,
                              unsigned long internal_format,
                              unsigned long format, unsigned long type);
void *gles_eagl_iosurface_lock(size_t *stride);
void gles_eagl_iosurface_unlock(void);
void *gles_eagl_current_iosurface(void);
void *gles_eagl_context_iosurface(GLESEAGLContextObj c);
void *gles_eagl_surface_retain(void *surf);
void gles_eagl_surface_release(void *surf);
size_t gles_eagl_surface_stride(void *surf);
void *gles_eagl_surface_lock_ro(void *surf, size_t *stride);
void gles_eagl_surface_unlock_ro(void *surf);
void *gles_eagl_surface_lock_rw(void *surf, size_t *stride);
void gles_eagl_surface_unlock_rw(void *surf);
void *gles_eagl_surface_create_bind(uint32_t width, uint32_t height,
                                    unsigned long target);
bool gles_eagl_surface_write_rows(void *surf, const uint8_t *pixels,
                                  uint32_t width, uint32_t height);

/* EAGLRenderingAPI, from <OpenGLES/EAGL.h>: ES 1.1, ES 2.0, ES 3.0. */
#define EAGL_RENDERING_API_GLES1 1
#define EAGL_RENDERING_API_GLES2 2
#define EAGL_RENDERING_API_GLES3 3

/* objc_msgSend has no callable prototype on arm64 -- it must be cast to the
 * exact signature of the method being sent, because the ABI for the call is
 * the method's, not a variadic one. */
typedef id (*msg_id_t)(id, SEL);
typedef id (*msg_id_ul_t)(id, SEL, unsigned long);
typedef id (*msg_id_ul_id_t)(id, SEL, unsigned long, id);
typedef BOOL (*msg_bool_id_t)(id, SEL, id);
typedef void (*msg_void_t)(id, SEL);
typedef BOOL (*msg_bool_sel_t)(id, SEL, SEL);

/*
 * -[EAGLContext texImageIOSurface:target:internalFormat:width:height:
 *               format:type:plane:]
 *
 * Ten arguments including self and _cmd, so the last two land on the stack --
 * which is precisely why the prototype has to match the method's declared types
 * exactly rather than approximately. NSUInteger is unsigned long, the width,
 * height and plane arguments are genuinely uint32_t, and getting either wrong
 * would put `plane` somewhere the callee does not look.
 */
typedef BOOL (*msg_teximage_t)(id, SEL, IOSurfaceRef, unsigned long,
                               unsigned long, uint32_t, uint32_t,
                               unsigned long, unsigned long, uint32_t);

static Class gles_eagl_class;
static SEL sel_currentContext;
static SEL sel_setCurrentContext;
static SEL sel_alloc;
static SEL sel_initWithAPI;
static SEL sel_initWithAPI_sharegroup;
static SEL sel_sharegroup;
static SEL sel_release;
static SEL sel_respondsToSelector;
static SEL sel_texImageIOSurface;
static int gles_eagl_has_teximage = -1;
static __thread GLESEAGLContextObj gles_eagl_current;

static void gles_eagl_init_selectors(void)
{
    if (sel_currentContext) {
        return;
    }
    sel_currentContext = sel_registerName("currentContext");
    sel_setCurrentContext = sel_registerName("setCurrentContext:");
    sel_alloc = sel_registerName("alloc");
    sel_initWithAPI = sel_registerName("initWithAPI:");
    sel_initWithAPI_sharegroup = sel_registerName("initWithAPI:sharegroup:");
    sel_sharegroup = sel_registerName("sharegroup");
    sel_release = sel_registerName("release");
    sel_respondsToSelector = sel_registerName("respondsToSelector:");
    sel_texImageIOSurface = sel_registerName(
        "texImageIOSurface:target:internalFormat:width:height:format:type:plane:");
}

int gles_eagl_set_current(GLESEAGLContextObj c)
{
    id target = c ? c->ctx : NULL;
    id cur;

    if (c && c == gles_eagl_current) {
        return 0;
    }
    if (!gles_eagl_class) {
        gles_eagl_current = NULL;
        return c ? -1 : 0;
    }
    gles_eagl_init_selectors();
    cur = ((msg_id_t)objc_msgSend)((id)gles_eagl_class, sel_currentContext);
    if (cur != target) {
        if (!((msg_bool_id_t)objc_msgSend)((id)gles_eagl_class,
                                           sel_setCurrentContext,
                                           target)) {
            fprintf(stderr, "[gles] EAGL setCurrentContext failed\n");
            return -1;
        }
    }
    gles_eagl_current = c;
    return 0;
}

GLESEAGLContextObj gles_eagl_get_current(void)
{
    return gles_eagl_current;
}

GLESEAGLContextObj gles_eagl_retain(GLESEAGLContextObj c)
{
    if (c) {
        c->refs++;
    }
    return c;
}

void gles_eagl_release(GLESEAGLContextObj c)
{
    if (!c || --c->refs > 0) {
        return;
    }
    if (gles_eagl_current == c) {
        gles_eagl_set_current(NULL);
    }
    if (c->surf) {
        CFRelease(c->surf);
        c->surf = NULL;
    }
    if (c->ctx) {
        gles_eagl_init_selectors();
        ((msg_void_t)objc_msgSend)(c->ctx, sel_release);
        c->ctx = NULL;
    }
    free(c);
}

unsigned gles_eagl_current_api(void)
{
    return gles_eagl_current ? gles_eagl_current->api : EAGL_RENDERING_API_GLES1;
}

unsigned gles_eagl_host_api(void)
{
    return gles_eagl_current ? gles_eagl_current->host_api : EAGL_RENDERING_API_GLES1;
}

static id gles_eagl_alloc_ctx(id sg, unsigned api)
{
    gles_eagl_init_selectors();
    id fresh = ((msg_id_t)objc_msgSend)((id)gles_eagl_class, sel_alloc);
    if (!fresh) {
        return NULL;
    }
    if (sg) {
        return ((msg_id_ul_id_t)objc_msgSend)(
            fresh, sel_initWithAPI_sharegroup, api, sg);
    }
    return ((msg_id_ul_t)objc_msgSend)(
        fresh, sel_initWithAPI, api);
}

bool gles_eagl_create(GLESEAGLContextObj share, unsigned api,
                      GLESEAGLContextObj *out)
{
    unsigned logical_api = api == 2 ? EAGL_RENDERING_API_GLES2
                                    : EAGL_RENDERING_API_GLES1;
    unsigned target_api = logical_api;
    id eagl_ctx = NULL, sg = NULL;
    GLESEAGLContextObj c;

    if (!out) {
        return false;
    }
    *out = NULL;

    /* Not dlopen'd or weak-linked: the machine is linked against
     * OpenGLES.framework, so if the class is missing the process would not
     * have started. The check is for the day Apple withdraws it. */
    if (!gles_eagl_class) {
        gles_eagl_class = objc_getClass("EAGLContext");
    }
    if (!gles_eagl_class) {
        fprintf(stderr, "[gles] no EAGLContext class; the guest will fall "
                "back to software GL\n");
        return false;
    }

    if (share && share->ctx) {
        sg = ((msg_id_t)objc_msgSend)(share->ctx,
                                      sel_registerName("sharegroup"));
    }

    /* Prefer ES 3.0 for ES 2.0 guest contexts so core ES3 features such as
     * GL_UNPACK_ROW_LENGTH, glBlitFramebuffer, and GLsync fences are native. */
    if (logical_api == EAGL_RENDERING_API_GLES2) {
        if (share && share->host_api >= EAGL_RENDERING_API_GLES2) {
            target_api = share->host_api;
            eagl_ctx = gles_eagl_alloc_ctx(sg, target_api);
        } else {
            eagl_ctx = gles_eagl_alloc_ctx(sg, EAGL_RENDERING_API_GLES3);
            if (eagl_ctx) {
                target_api = EAGL_RENDERING_API_GLES3;
            } else {
                eagl_ctx = gles_eagl_alloc_ctx(sg, EAGL_RENDERING_API_GLES2);
                target_api = EAGL_RENDERING_API_GLES2;
            }
        }
    } else {
        eagl_ctx = gles_eagl_alloc_ctx(sg, target_api);
    }
    if (!eagl_ctx) {
        fprintf(stderr, "[gles] EAGL ES %u.0 context unavailable on this OS "
                "(share=%p); the guest will fall back to software GL\n",
                target_api, (void *)sg);
        return false;
    }

    c = calloc(1, sizeof(*c));
    if (!c) {
        ((msg_void_t)objc_msgSend)(eagl_ctx, sel_registerName("release"));
        return false;
    }
    c->ctx = eagl_ctx;
    c->api = logical_api;
    c->host_api = target_api;
    c->refs = 1;

    if (gles_eagl_set_current(c) != 0) {
        gles_eagl_release(c);
        return false;
    }

    *out = c;
    return true;
}

/* ---------------------------------------------------------------- IOSurface */

/*
 * The render target the CPU can read without asking GL for it.
 *
 * The frame has to reach guest memory every present -- the guest's
 * CoreAnimation owns the destination and the request is synchronous -- so the
 * pixels cross the CPU/GPU line either way. What is negotiable is HOW. A
 * glReadPixels out of an ordinary texture attachment is the worst available
 * answer on a tile-based GPU: it forces the tiler to resolve on demand, into
 * driver-owned staging the CPU then copies again, with a full pipeline drain in
 * front of it. An IOSurface attachment is the same render target with system
 * memory as its backing store, so once the GPU is done the pixels are simply
 * THERE and the present is a memcpy out of a mapped page.
 *
 * ORDERING. IOSurfaceLock without kIOSurfaceLockAvoidSync is the synchronizing
 * read: that flag exists to let a caller BAIL OUT of "a potentially expensive
 * paging operation (such as readback from a GPU to system memory)", which is
 * Apple documenting that the default lock performs exactly that wait. So the
 * lock is the guarantee, and it is a better one than glFinish -- it waits for
 * the work that touches THIS surface rather than draining every queue in the
 * context. The caller still owes it a glFlush first, because a lock can only
 * wait for commands the driver has actually been given.
 */
static void gles_dict_set_int(CFMutableDictionaryRef d, CFStringRef key, int v)
{
    CFNumberRef n = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &v);

    if (n) {
        CFDictionarySetValue(d, key, n);
        CFRelease(n);
    }
}

bool gles_eagl_iosurface_bind(uint32_t width, uint32_t height,
                              unsigned long target,
                              unsigned long internal_format,
                              unsigned long format, unsigned long type)
{
    GLESEAGLContextObj c = gles_eagl_current;
    CFMutableDictionaryRef props;
    SEL sel = sel_registerName("texImageIOSurface:target:internalFormat:"
                               "width:height:format:type:plane:");

    if (!c || !c->ctx) {
        return false;
    }

    /*
     * texImageIOSurface: has been deprecated since iOS 12 and the whole
     * framework is on borrowed time, so ask before sending rather than trap on
     * the day it goes. gles-host.c keeps the glReadPixels path for exactly this
     * case: slow pixels beat no pixels.
     */
    if (!((msg_bool_sel_t)objc_msgSend)(c->ctx,
                                        sel_registerName("respondsToSelector:"),
                                        sel)) {
        fprintf(stderr, "[gles] EAGL has no texImageIOSurface:; presenting by "
                "readback\n");
        return false;
    }

    if (c->surf && (c->surf_w != width || c->surf_h != height)) {
        CFRelease(c->surf);
        c->surf = NULL;
        c->surf_w = 0;
        c->surf_h = 0;
    }

    if (!c->surf) {
        props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                          &kCFTypeDictionaryKeyCallBacks,
                                          &kCFTypeDictionaryValueCallBacks);
        if (!props) {
            return false;
        }
        gles_dict_set_int(props, kIOSurfaceWidth, (int)width);
        gles_dict_set_int(props, kIOSurfaceHeight, (int)height);
        gles_dict_set_int(props, kIOSurfaceBytesPerElement, 4);
        /* 'BGRA' -- the byte order CoreAnimation uses in the guest, so the present
         * is a copy and never a swizzle. Deliberately no kIOSurfaceBytesPerRow:
         * IOSurface picks the alignment the GPU wants and the caller reads the
         * result back out of IOSurfaceGetBytesPerRow. */
        gles_dict_set_int(props, kIOSurfacePixelFormat, 0x42475241);

        c->surf = IOSurfaceCreate(props);
        CFRelease(props);
        if (!c->surf) {
            fprintf(stderr, "[gles] IOSurfaceCreate failed; presenting by "
                    "readback\n");
            return false;
        }
        c->surf_w = width;
        c->surf_h = height;
    }

    /* Binds to whichever texture the caller left bound on `target`, exactly as
     * glTexImage2D would -- this REPLACES that call, it does not accompany it. */
    if (!((msg_teximage_t)objc_msgSend)(c->ctx, sel, c->surf, target,
                                        internal_format, width, height,
                                        format, type, 0)) {
        fprintf(stderr, "[gles] texImageIOSurface rejected the surface; "
                "presenting by readback\n");
        CFRelease(c->surf);
        c->surf = NULL;
        c->surf_w = 0;
        c->surf_h = 0;
        return false;
    }

    return true;
}

/*
 * Returns the frame's first byte, or NULL if the surface cannot be read -- in
 * which case the caller must fall back for this frame rather than present
 * whatever was there before. Rows run bottom-up, GL's way round.
 */
void *gles_eagl_iosurface_lock(size_t *stride)
{
    GLESEAGLContextObj c = gles_eagl_current;
    void *base;

    if (!c || !c->surf) {
        return NULL;
    }
    if (IOSurfaceLock(c->surf, kIOSurfaceLockReadOnly, NULL) != 0) {
        return NULL;
    }
    base = IOSurfaceGetBaseAddress(c->surf);
    if (!base) {
        IOSurfaceUnlock(c->surf, kIOSurfaceLockReadOnly, NULL);
        return NULL;
    }
    *stride = IOSurfaceGetBytesPerRow(c->surf);
    return base;
}

void gles_eagl_iosurface_unlock(void)
{
    GLESEAGLContextObj c = gles_eagl_current;

    if (c && c->surf) {
        /* Symmetrical with the lock's flags; the header calls anything else
         * undefined behavior. */
        IOSurfaceUnlock(c->surf, kIOSurfaceLockReadOnly, NULL);
    }
}

void *gles_eagl_current_iosurface(void)
{
    return gles_eagl_current ? (void *)gles_eagl_current->surf : NULL;
}

void *gles_eagl_context_iosurface(GLESEAGLContextObj c)
{
    return c ? (void *)c->surf : NULL;
}

void *gles_eagl_surface_retain(void *surf)
{
    return surf ? (void *)CFRetain((IOSurfaceRef)surf) : NULL;
}

void gles_eagl_surface_release(void *surf)
{
    if (surf) {
        CFRelease((IOSurfaceRef)surf);
    }
}

size_t gles_eagl_surface_stride(void *surf)
{
    return surf ? IOSurfaceGetBytesPerRow((IOSurfaceRef)surf) : 0;
}

void *gles_eagl_surface_lock_ro(void *surf, size_t *stride)
{
    void *base;

    if (!surf) {
        return NULL;
    }
    if (IOSurfaceLock((IOSurfaceRef)surf, kIOSurfaceLockReadOnly, NULL) != 0) {
        return NULL;
    }
    base = IOSurfaceGetBaseAddress((IOSurfaceRef)surf);
    if (!base) {
        IOSurfaceUnlock((IOSurfaceRef)surf, kIOSurfaceLockReadOnly, NULL);
        return NULL;
    }
    *stride = IOSurfaceGetBytesPerRow((IOSurfaceRef)surf);
    return base;
}

void gles_eagl_surface_unlock_ro(void *surf)
{
    if (surf) {
        IOSurfaceUnlock((IOSurfaceRef)surf, kIOSurfaceLockReadOnly, NULL);
    }
}

void *gles_eagl_surface_lock_rw(void *surf, size_t *stride)
{
    void *base;

    if (!surf) {
        return NULL;
    }
    if (IOSurfaceLock((IOSurfaceRef)surf, 0, NULL) != 0) {
        return NULL;
    }
    base = IOSurfaceGetBaseAddress((IOSurfaceRef)surf);
    if (!base) {
        IOSurfaceUnlock((IOSurfaceRef)surf, 0, NULL);
        return NULL;
    }
    *stride = IOSurfaceGetBytesPerRow((IOSurfaceRef)surf);
    return base;
}

void gles_eagl_surface_unlock_rw(void *surf)
{
    if (surf) {
        IOSurfaceUnlock((IOSurfaceRef)surf, 0, NULL);
    }
}

void *gles_eagl_surface_create_bind(uint32_t width, uint32_t height,
                                    unsigned long target)
{
    GLESEAGLContextObj c = gles_eagl_current;
    CFMutableDictionaryRef props;
    IOSurfaceRef surf;

    if (!c || !c->ctx || !width || !height) {
        return NULL;
    }
    gles_eagl_init_selectors();
    if (gles_eagl_has_teximage < 0) {
        gles_eagl_has_teximage = ((msg_bool_sel_t)objc_msgSend)(
            c->ctx, sel_respondsToSelector, sel_texImageIOSurface) ? 1 : 0;
    }
    if (!gles_eagl_has_teximage) {
        return NULL;
    }
    props = CFDictionaryCreateMutable(kCFAllocatorDefault, 0,
                                      &kCFTypeDictionaryKeyCallBacks,
                                      &kCFTypeDictionaryValueCallBacks);
    if (!props) {
        return NULL;
    }
    gles_dict_set_int(props, kIOSurfaceWidth, (int)width);
    gles_dict_set_int(props, kIOSurfaceHeight, (int)height);
    gles_dict_set_int(props, kIOSurfaceBytesPerElement, 4);
    gles_dict_set_int(props, kIOSurfacePixelFormat, 0x42475241); /* 'BGRA' */

    surf = IOSurfaceCreate(props);
    CFRelease(props);
    if (!surf) {
        return NULL;
    }
    /* GL_RGBA=0x1908, GL_BGRA=0x80E1, GL_UNSIGNED_BYTE=0x1401 */
    if (!((msg_teximage_t)objc_msgSend)(c->ctx, sel_texImageIOSurface, surf,
                                        target, 0x1908, width, height,
                                        0x80E1, 0x1401, 0)) {
        CFRelease(surf);
        return NULL;
    }
    return (void *)surf;
}

bool gles_eagl_surface_write_rows(void *surf, const uint8_t *pixels,
                                  uint32_t width, uint32_t height)
{
    uint8_t *dst;
    size_t dst_stride, row_bytes = (size_t)width * 4;

    if (!surf || !pixels) {
        return false;
    }
    if (IOSurfaceLock((IOSurfaceRef)surf, 0, NULL) != 0) {
        return false;
    }
    dst = (uint8_t *)IOSurfaceGetBaseAddress((IOSurfaceRef)surf);
    if (!dst) {
        IOSurfaceUnlock((IOSurfaceRef)surf, 0, NULL);
        return false;
    }
    dst_stride = IOSurfaceGetBytesPerRow((IOSurfaceRef)surf);
    if (dst_stride == row_bytes) {
        memcpy(dst, pixels, row_bytes * height);
    } else {
        for (uint32_t y = 0; y < height; y++) {
            memcpy(dst + (size_t)y * dst_stride, pixels + (size_t)y * row_bytes,
                   row_bytes);
        }
    }
    IOSurfaceUnlock((IOSurfaceRef)surf, 0, NULL);
    return true;
}

/* ---- Zero-copy GPU IOSurface -> Host Metal Direct Display ---- */
typedef void (*gles_direct_present_cb_t)(void *opaque, void *iosurface_ref, int w, int h);

#define GLES_DIRECT_SLOTS 16
#define GLES_SCANOUT_SLOTS 8

typedef struct {
    uint64_t pa0;
    IOSurfaceRef surf;
    uint32_t w, h;
    uint64_t stamp;
} GLESDirectSlot;

static os_unfair_lock gles_direct_lock = OS_UNFAIR_LOCK_INIT;
static gles_direct_present_cb_t gles_direct_cb;
static void *gles_direct_opaque;
static GLESDirectSlot gles_direct_slots[GLES_DIRECT_SLOTS];
static uint64_t gles_direct_stamp;
static uint64_t gles_scanout_pa0[GLES_SCANOUT_SLOTS];
static unsigned gles_scanout_idx;

void qemu_ios_set_direct_iosurface_callback(gles_direct_present_cb_t cb, void *opaque);
void qemu_ios_set_direct_iosurface_callback(gles_direct_present_cb_t cb, void *opaque)
{
    os_unfair_lock_lock(&gles_direct_lock);
    gles_direct_cb = cb;
    gles_direct_opaque = opaque;
    if (!cb) {
        for (int i = 0; i < GLES_DIRECT_SLOTS; i++) {
            if (gles_direct_slots[i].surf) {
                CFRelease(gles_direct_slots[i].surf);
                gles_direct_slots[i].surf = NULL;
                gles_direct_slots[i].pa0 = 0;
            }
        }
        memset(gles_scanout_pa0, 0, sizeof(gles_scanout_pa0));
    }
    os_unfair_lock_unlock(&gles_direct_lock);
}

void gles_eagl_direct_register(uint64_t pa0, void *surf, uint32_t w, uint32_t h);
void gles_eagl_direct_register(uint64_t pa0, void *surf, uint32_t w, uint32_t h)
{
    if (!pa0 || !surf || !w || !h) {
        return;
    }
    os_unfair_lock_lock(&gles_direct_lock);
    if (!gles_direct_cb) {
        os_unfair_lock_unlock(&gles_direct_lock);
        return;
    }
    int best = 0;
    uint64_t oldest = UINT64_MAX;
    for (int i = 0; i < GLES_DIRECT_SLOTS; i++) {
        if (gles_direct_slots[i].pa0 == pa0) {
            best = i;
            break;
        }
        if (!gles_direct_slots[i].surf) {
            best = i;
            oldest = 0;
        } else if (gles_direct_slots[i].stamp < oldest) {
            oldest = gles_direct_slots[i].stamp;
            best = i;
        }
    }
    IOSurfaceRef old = gles_direct_slots[best].surf;
    if (old != (IOSurfaceRef)surf) {
        CFRetain((IOSurfaceRef)surf);
        gles_direct_slots[best].surf = (IOSurfaceRef)surf;
    } else {
        old = NULL;
    }
    gles_direct_slots[best].pa0 = pa0;
    gles_direct_slots[best].w = w;
    gles_direct_slots[best].h = h;
    gles_direct_slots[best].stamp = ++gles_direct_stamp;
    os_unfair_lock_unlock(&gles_direct_lock);
    if (old) {
        CFRelease(old);
    }
}

void gles_eagl_direct_unregister(const void *surf);
void gles_eagl_direct_unregister(const void *surf)
{
    if (!surf) {
        return;
    }
    IOSurfaceRef to_release[GLES_DIRECT_SLOTS];
    int nrel = 0;
    os_unfair_lock_lock(&gles_direct_lock);
    for (int i = 0; i < GLES_DIRECT_SLOTS; i++) {
        if (gles_direct_slots[i].surf == (IOSurfaceRef)surf) {
            to_release[nrel++] = gles_direct_slots[i].surf;
            gles_direct_slots[i].surf = NULL;
            gles_direct_slots[i].pa0 = 0;
        }
    }
    os_unfair_lock_unlock(&gles_direct_lock);
    for (int i = 0; i < nrel; i++) {
        CFRelease(to_release[i]);
    }
}

void gles_eagl_direct_note_scanout(uint64_t pa0);
void gles_eagl_direct_note_scanout(uint64_t pa0)
{
    if (!pa0) {
        return;
    }
    os_unfair_lock_lock(&gles_direct_lock);
    for (int i = 0; i < GLES_SCANOUT_SLOTS; i++) {
        if (gles_scanout_pa0[i] == pa0) {
            os_unfair_lock_unlock(&gles_direct_lock);
            return;
        }
    }
    gles_scanout_pa0[gles_scanout_idx++ % GLES_SCANOUT_SLOTS] = pa0;
    os_unfair_lock_unlock(&gles_direct_lock);
}

bool gles_eagl_direct_is_scanout(uint64_t pa0);
bool gles_eagl_direct_is_scanout(uint64_t pa0)
{
    if (!pa0) {
        return false;
    }
    bool found = false;
    os_unfair_lock_lock(&gles_direct_lock);
    if (gles_direct_cb) {
        for (int i = 0; i < GLES_SCANOUT_SLOTS; i++) {
            if (gles_scanout_pa0[i] == pa0) {
                found = true;
                break;
            }
        }
    }
    os_unfair_lock_unlock(&gles_direct_lock);
    return found;
}

bool gles_eagl_direct_try_present(uint64_t pa0, uint32_t w, uint32_t h);
bool gles_eagl_direct_try_present(uint64_t pa0, uint32_t w, uint32_t h)
{
    if (!pa0 || !w || !h) {
        return false;
    }
    gles_direct_present_cb_t cb = NULL;
    void *opaque = NULL;
    IOSurfaceRef surf = NULL;

    os_unfair_lock_lock(&gles_direct_lock);
    if (gles_direct_cb) {
        for (int i = 0; i < GLES_DIRECT_SLOTS; i++) {
            if (gles_direct_slots[i].pa0 == pa0 &&
                gles_direct_slots[i].surf &&
                gles_direct_slots[i].w == w &&
                gles_direct_slots[i].h == h) {
                surf = gles_direct_slots[i].surf;
                CFRetain(surf);
                cb = gles_direct_cb;
                opaque = gles_direct_opaque;
                break;
            }
        }
    }
    os_unfair_lock_unlock(&gles_direct_lock);
    if (!surf || !cb) {
        return false;
    }
    cb(opaque, (void *)surf, (int)w, (int)h);
    CFRelease(surf);
    return true;
}

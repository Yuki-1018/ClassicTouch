/*
 * Host EGL + OpenGL ES 1/2/3 backend implemented directly on top of iOS
 * OpenGLES.framework (EAGLContext + EAGLSharegroup) for Classic Android emugl.
 *
 * Pure C++ with objc_msgSend so meson/clang++ links without ObjC driver issues.
 */

#include <EGL/egl.h>
#define EGL_EGLEXT_PROTOTYPES
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include <atomic>
#include <dlfcn.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unordered_map>
#include <mutex>
#include <string>

#ifndef GL_OES_EGL_image
#define GL_OES_EGL_image 1
#endif
#ifndef GL_FRAMEBUFFER_BINDING
#define GL_FRAMEBUFFER_BINDING 0x8CA6
#endif
#ifndef GL_READ_FRAMEBUFFER_EXT
#define GL_READ_FRAMEBUFFER_EXT 0x8CA8
#endif
#ifndef GL_DRAW_FRAMEBUFFER_EXT
#define GL_DRAW_FRAMEBUFFER_EXT 0x8CA9
#endif
#ifndef GL_DEPTH24_STENCIL8_OES
#define GL_DEPTH24_STENCIL8_OES 0x88F0
#endif

namespace {

constexpr unsigned long kEaglApiGles1 = 1;
constexpr unsigned long kEaglApiGles2 = 2;
constexpr unsigned long kEaglApiGles3 = 3;

typedef id (*MsgId)(id, SEL);
typedef id (*MsgIdUl)(id, SEL, unsigned long);
typedef id (*MsgIdUlId)(id, SEL, unsigned long, id);
typedef BOOL (*MsgBoolId)(id, SEL, id);
typedef void (*MsgVoid)(id, SEL);

static Class cls_EAGLContext = nullptr;
static SEL sel_currentContext = nullptr;
static SEL sel_setCurrentContext = nullptr;
static SEL sel_alloc = nullptr;
static SEL sel_initWithAPI = nullptr;
static SEL sel_initWithAPI_sharegroup = nullptr;
static SEL sel_sharegroup = nullptr;
static SEL sel_release = nullptr;

static void *s_gles_fw = nullptr;
static id s_root_sharegroup = nullptr;
static id s_gles1_sharegroup = nullptr;
static pthread_mutex_t s_global_lock = PTHREAD_MUTEX_INITIALIZER;

/* Texture & Renderbuffer aliasing for EGLImageKHR across EAGLSharegroup */
static std::mutex s_alias_lock;
static std::unordered_map<GLuint, GLuint> s_tex_alias;
static std::unordered_map<GLuint, GLuint> s_rbo_alias;

/* Raw ES2 function pointers from OpenGLES.framework */
static void (*raw_glBindTexture)(GLenum, GLuint) = nullptr;
static void (*raw_glDeleteTextures)(GLsizei, const GLuint*) = nullptr;
static void (*raw_glActiveTexture)(GLenum) = nullptr;
static void (*raw_glTexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void*) = nullptr;
static void (*raw_glTexSubImage2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void*) = nullptr;
static void (*raw_glCompressedTexImage2D)(GLenum, GLint, GLenum, GLsizei, GLsizei, GLint, GLsizei, const void*) = nullptr;
static void (*raw_glCompressedTexSubImage2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLsizei, const void*) = nullptr;
static void (*raw_glCopyTexImage2D)(GLenum, GLint, GLenum, GLint, GLint, GLsizei, GLsizei, GLint) = nullptr;
static void (*raw_glCopyTexSubImage2D)(GLenum, GLint, GLint, GLint, GLint, GLint, GLsizei, GLsizei) = nullptr;
static void (*raw_glTexParameteri)(GLenum, GLenum, GLint) = nullptr;
static void (*raw_glTexParameterf)(GLenum, GLenum, GLfloat) = nullptr;
static void (*raw_glTexParameteriv)(GLenum, GLenum, const GLint*) = nullptr;
static void (*raw_glTexParameterfv)(GLenum, GLenum, const GLfloat*) = nullptr;
static void (*raw_glGetTexParameteriv)(GLenum, GLenum, GLint*) = nullptr;
static void (*raw_glGetTexParameterfv)(GLenum, GLenum, GLfloat*) = nullptr;
static void (*raw_glGenerateMipmap)(GLenum) = nullptr;
static void (*raw_glShaderSource)(GLuint, GLsizei, const GLchar* const*, const GLint*) = nullptr;
static void (*raw_glEnable)(GLenum) = nullptr;
static void (*raw_glDisable)(GLenum) = nullptr;
static void (*raw_glBindFramebuffer)(GLenum, GLuint) = nullptr;
static void (*raw_glDeleteFramebuffers)(GLsizei, const GLuint*) = nullptr;
static void (*raw_glGenFramebuffers)(GLsizei, GLuint*) = nullptr;
static void (*raw_glFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint) = nullptr;
static void (*raw_glFramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint) = nullptr;
static GLenum (*raw_glCheckFramebufferStatus)(GLenum) = nullptr;
static void (*raw_glGenRenderbuffers)(GLsizei, GLuint*) = nullptr;
static void (*raw_glDeleteRenderbuffers)(GLsizei, const GLuint*) = nullptr;
static void (*raw_glBindRenderbuffer)(GLenum, GLuint) = nullptr;
static void (*raw_glRenderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei) = nullptr;
static void (*raw_glGetIntegerv)(GLenum, GLint*) = nullptr;
static const GLubyte* (*raw_glGetString)(GLenum) = nullptr;
static void (*raw_glFlush)(void) = nullptr;
static void (*raw_glFinish)(void) = nullptr;

static void (*raw_glBindFramebufferOES)(GLenum, GLuint) = nullptr;
static void (*raw_glGenFramebuffersOES)(GLsizei, GLuint*) = nullptr;
static void (*raw_glDeleteFramebuffersOES)(GLsizei, const GLuint*) = nullptr;
static void (*raw_glFramebufferTexture2DOES)(GLenum, GLenum, GLenum, GLuint, GLint) = nullptr;
static void (*raw_glFramebufferRenderbufferOES)(GLenum, GLenum, GLenum, GLuint) = nullptr;
static void (*raw_glBindRenderbufferOES)(GLenum, GLuint) = nullptr;
static void (*raw_glGenRenderbuffersOES)(GLsizei, GLuint*) = nullptr;
static void (*raw_glDeleteRenderbuffersOES)(GLsizei, const GLuint*) = nullptr;
static void (*raw_glRenderbufferStorageOES)(GLenum, GLenum, GLsizei, GLsizei) = nullptr;
static GLenum (*raw_glCheckFramebufferStatusOES)(GLenum) = nullptr;

struct EaglConfig {
    EGLint id;
    EGLint r, g, b, a;
    EGLint depth, stencil;
    EGLint renderable_type;
    EGLint surface_type;
};

static const EaglConfig s_configs[] = {
    { 1, 8, 8, 8, 8, 24, 8, EGL_OPENGL_ES_BIT | EGL_OPENGL_ES2_BIT, EGL_WINDOW_BIT | EGL_PBUFFER_BIT },
    { 2, 8, 8, 8, 8, 16, 0, EGL_OPENGL_ES_BIT | EGL_OPENGL_ES2_BIT, EGL_WINDOW_BIT | EGL_PBUFFER_BIT },
    { 3, 8, 8, 8, 8, 0,  0, EGL_OPENGL_ES_BIT | EGL_OPENGL_ES2_BIT, EGL_WINDOW_BIT | EGL_PBUFFER_BIT },
    { 4, 8, 8, 8, 0, 24, 8, EGL_OPENGL_ES_BIT | EGL_OPENGL_ES2_BIT, EGL_WINDOW_BIT | EGL_PBUFFER_BIT },
    { 5, 5, 6, 5, 0, 16, 0, EGL_OPENGL_ES_BIT | EGL_OPENGL_ES2_BIT, EGL_WINDOW_BIT | EGL_PBUFFER_BIT },
    { 6, 5, 6, 5, 0, 0,  0, EGL_OPENGL_ES_BIT | EGL_OPENGL_ES2_BIT, EGL_WINDOW_BIT | EGL_PBUFFER_BIT },
};

struct EaglContextObj {
    id eagl_ctx;
    int client_version; /* 1 or 2 */
    GLuint active_tex_unit = 0;
    GLuint bound_tex_2d[32] = { 0 };
    GLuint bound_tex_ext[32] = { 0 };
    GLenum last_bound_target[32] = { 0 };
    GLuint bound_rbo = 0;
    GLuint bound_fbo = 0;
    /* Lazily cached FBOs keyed by monotonic EaglSurfaceObj::id (FBO names are per-EAGLContext!) */
    std::unordered_map<uint64_t, GLuint> surface_fbos;
};

struct EaglSurfaceObj {
    uint64_t id;
    int width;
    int height;
    bool has_depth;
    bool has_stencil;
    GLuint color_rbo;
    GLuint depth_rbo;
    GLuint color_rbo_es1;
    GLuint depth_rbo_es1;
};

static std::atomic<uint64_t> s_next_surface_id{1};

static std::mutex s_image_lock;
static std::unordered_map<uint32_t, GLuint> s_images;
static std::atomic<uint32_t> s_next_image_id{1};

static __thread EGLint t_last_error = EGL_SUCCESS;
static __thread EGLenum t_bound_api = EGL_OPENGL_ES_API;
static __thread EaglContextObj *t_cur_ctx = nullptr;
static __thread EaglSurfaceObj *t_cur_draw = nullptr;
static __thread EaglSurfaceObj *t_cur_read = nullptr;
static __thread GLuint t_cur_draw_fbo = 0;

static void ensure_eagl_init()
{
    pthread_mutex_lock(&s_global_lock);
    if (!s_gles_fw) {
        s_gles_fw = dlopen("/System/Library/Frameworks/OpenGLES.framework/OpenGLES", RTLD_NOW);
        cls_EAGLContext = objc_getClass("EAGLContext");
        sel_currentContext = sel_registerName("currentContext");
        sel_setCurrentContext = sel_registerName("setCurrentContext:");
        sel_alloc = sel_registerName("alloc");
        sel_initWithAPI = sel_registerName("initWithAPI:");
        sel_initWithAPI_sharegroup = sel_registerName("initWithAPI:sharegroup:");
        sel_sharegroup = sel_registerName("sharegroup");
        sel_release = sel_registerName("release");

        raw_glBindTexture = (decltype(raw_glBindTexture))dlsym(s_gles_fw, "glBindTexture");
        raw_glDeleteTextures = (decltype(raw_glDeleteTextures))dlsym(s_gles_fw, "glDeleteTextures");
        raw_glActiveTexture = (decltype(raw_glActiveTexture))dlsym(s_gles_fw, "glActiveTexture");
        raw_glTexImage2D = (decltype(raw_glTexImage2D))dlsym(s_gles_fw, "glTexImage2D");
        raw_glTexSubImage2D = (decltype(raw_glTexSubImage2D))dlsym(s_gles_fw, "glTexSubImage2D");
        raw_glCompressedTexImage2D = (decltype(raw_glCompressedTexImage2D))dlsym(s_gles_fw, "glCompressedTexImage2D");
        raw_glCompressedTexSubImage2D = (decltype(raw_glCompressedTexSubImage2D))dlsym(s_gles_fw, "glCompressedTexSubImage2D");
        raw_glCopyTexImage2D = (decltype(raw_glCopyTexImage2D))dlsym(s_gles_fw, "glCopyTexImage2D");
        raw_glCopyTexSubImage2D = (decltype(raw_glCopyTexSubImage2D))dlsym(s_gles_fw, "glCopyTexSubImage2D");
        raw_glTexParameteri = (decltype(raw_glTexParameteri))dlsym(s_gles_fw, "glTexParameteri");
        raw_glTexParameterf = (decltype(raw_glTexParameterf))dlsym(s_gles_fw, "glTexParameterf");
        raw_glTexParameteriv = (decltype(raw_glTexParameteriv))dlsym(s_gles_fw, "glTexParameteriv");
        raw_glTexParameterfv = (decltype(raw_glTexParameterfv))dlsym(s_gles_fw, "glTexParameterfv");
        raw_glGetTexParameteriv = (decltype(raw_glGetTexParameteriv))dlsym(s_gles_fw, "glGetTexParameteriv");
        raw_glGetTexParameterfv = (decltype(raw_glGetTexParameterfv))dlsym(s_gles_fw, "glGetTexParameterfv");
        raw_glGenerateMipmap = (decltype(raw_glGenerateMipmap))dlsym(s_gles_fw, "glGenerateMipmap");
        raw_glShaderSource = (decltype(raw_glShaderSource))dlsym(s_gles_fw, "glShaderSource");
        raw_glEnable = (decltype(raw_glEnable))dlsym(s_gles_fw, "glEnable");
        raw_glDisable = (decltype(raw_glDisable))dlsym(s_gles_fw, "glDisable");
        raw_glBindFramebuffer = (decltype(raw_glBindFramebuffer))dlsym(s_gles_fw, "glBindFramebuffer");
        raw_glDeleteFramebuffers = (decltype(raw_glDeleteFramebuffers))dlsym(s_gles_fw, "glDeleteFramebuffers");
        raw_glGenFramebuffers = (decltype(raw_glGenFramebuffers))dlsym(s_gles_fw, "glGenFramebuffers");
        raw_glFramebufferTexture2D = (decltype(raw_glFramebufferTexture2D))dlsym(s_gles_fw, "glFramebufferTexture2D");
        raw_glFramebufferRenderbuffer = (decltype(raw_glFramebufferRenderbuffer))dlsym(s_gles_fw, "glFramebufferRenderbuffer");
        raw_glCheckFramebufferStatus = (decltype(raw_glCheckFramebufferStatus))dlsym(s_gles_fw, "glCheckFramebufferStatus");
        raw_glGenRenderbuffers = (decltype(raw_glGenRenderbuffers))dlsym(s_gles_fw, "glGenRenderbuffers");
        raw_glDeleteRenderbuffers = (decltype(raw_glDeleteRenderbuffers))dlsym(s_gles_fw, "glDeleteRenderbuffers");
        raw_glBindRenderbuffer = (decltype(raw_glBindRenderbuffer))dlsym(s_gles_fw, "glBindRenderbuffer");
        raw_glRenderbufferStorage = (decltype(raw_glRenderbufferStorage))dlsym(s_gles_fw, "glRenderbufferStorage");
        raw_glGetIntegerv = (decltype(raw_glGetIntegerv))dlsym(s_gles_fw, "glGetIntegerv");
        raw_glGetString = (decltype(raw_glGetString))dlsym(s_gles_fw, "glGetString");
        raw_glFlush = (decltype(raw_glFlush))dlsym(s_gles_fw, "glFlush");
        raw_glFinish = (decltype(raw_glFinish))dlsym(s_gles_fw, "glFinish");

        raw_glBindFramebufferOES = (decltype(raw_glBindFramebufferOES))dlsym(s_gles_fw, "glBindFramebufferOES");
        raw_glGenFramebuffersOES = (decltype(raw_glGenFramebuffersOES))dlsym(s_gles_fw, "glGenFramebuffersOES");
        raw_glDeleteFramebuffersOES = (decltype(raw_glDeleteFramebuffersOES))dlsym(s_gles_fw, "glDeleteFramebuffersOES");
        raw_glFramebufferTexture2DOES = (decltype(raw_glFramebufferTexture2DOES))dlsym(s_gles_fw, "glFramebufferTexture2DOES");
        raw_glFramebufferRenderbufferOES = (decltype(raw_glFramebufferRenderbufferOES))dlsym(s_gles_fw, "glFramebufferRenderbufferOES");
        raw_glBindRenderbufferOES = (decltype(raw_glBindRenderbufferOES))dlsym(s_gles_fw, "glBindRenderbufferOES");
        raw_glGenRenderbuffersOES = (decltype(raw_glGenRenderbuffersOES))dlsym(s_gles_fw, "glGenRenderbuffersOES");
        raw_glDeleteRenderbuffersOES = (decltype(raw_glDeleteRenderbuffersOES))dlsym(s_gles_fw, "glDeleteRenderbuffersOES");
        raw_glRenderbufferStorageOES = (decltype(raw_glRenderbufferStorageOES))dlsym(s_gles_fw, "glRenderbufferStorageOES");
        raw_glCheckFramebufferStatusOES = (decltype(raw_glCheckFramebufferStatusOES))dlsym(s_gles_fw, "glCheckFramebufferStatusOES");

        /* Create a root ES2/ES3 sharegroup shared across every EAGLContext */
        id root = ((MsgIdUl)objc_msgSend)(((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_alloc),
                                          sel_initWithAPI, kEaglApiGles2);
        if (root) {
            s_root_sharegroup = ((MsgId)objc_msgSend)(root, sel_sharegroup);
        }
        id root1 = ((MsgIdUl)objc_msgSend)(((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_alloc),
                                           sel_initWithAPI, kEaglApiGles1);
        if (root1) {
            s_gles1_sharegroup = ((MsgId)objc_msgSend)(root1, sel_sharegroup);
        }
    }
    pthread_mutex_unlock(&s_global_lock);
}

static void eagl_set_current_raw(id ctx)
{
    ((MsgBoolId)objc_msgSend)((id)cls_EAGLContext, sel_setCurrentContext, ctx);
}

static GLuint get_or_create_fbo_for_surface(EaglContextObj *ctx, EaglSurfaceObj *surf)
{
    if (!ctx || !surf) {
        return 0;
    }
    auto it = ctx->surface_fbos.find(surf->id);
    if (it != ctx->surface_fbos.end()) {
        return it->second;
    }

    GLuint fbo = 0;
    if (ctx->client_version == 1) {
        if (!surf->color_rbo_es1) {
            GLint prev_rbo = 0;
            raw_glGetIntegerv(0x8CA7 /* GL_RENDERBUFFER_BINDING_OES */, &prev_rbo);
            raw_glGenRenderbuffersOES(1, &surf->color_rbo_es1);
            raw_glBindRenderbufferOES(0x8D41 /* GL_RENDERBUFFER_OES */, surf->color_rbo_es1);
            raw_glRenderbufferStorageOES(0x8D41, GL_RGBA8_OES, surf->width, surf->height);
            if (surf->has_depth || surf->has_stencil) {
                raw_glGenRenderbuffersOES(1, &surf->depth_rbo_es1);
                raw_glBindRenderbufferOES(0x8D41, surf->depth_rbo_es1);
                raw_glRenderbufferStorageOES(0x8D41, GL_DEPTH24_STENCIL8_OES, surf->width, surf->height);
            }
            raw_glBindRenderbufferOES(0x8D41, (GLuint)prev_rbo);
        }
        raw_glGenFramebuffersOES(1, &fbo);
        raw_glBindFramebufferOES(GL_FRAMEBUFFER, fbo);
        raw_glFramebufferRenderbufferOES(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                         0x8D41 /* GL_RENDERBUFFER_OES */, surf->color_rbo_es1);
        if (surf->depth_rbo_es1) {
            raw_glFramebufferRenderbufferOES(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                             0x8D41, surf->depth_rbo_es1);
            if (surf->has_stencil) {
                raw_glFramebufferRenderbufferOES(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
                                                 0x8D41, surf->depth_rbo_es1);
            }
            if (raw_glCheckFramebufferStatusOES &&
                raw_glCheckFramebufferStatusOES(GL_FRAMEBUFFER) != 0x8CD5 /* GL_FRAMEBUFFER_COMPLETE_OES */) {
                raw_glFramebufferRenderbufferOES(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
                                                 0x8D41, 0);
                raw_glFramebufferRenderbufferOES(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                                 0x8D41, 0);
                raw_glDeleteRenderbuffersOES(1, &surf->depth_rbo_es1);
                surf->depth_rbo_es1 = 0;
                surf->has_depth = false;
                surf->has_stencil = false;
            }
        }
        if (raw_glCheckFramebufferStatusOES &&
            raw_glCheckFramebufferStatusOES(GL_FRAMEBUFFER) != 0x8CD5 /* GL_FRAMEBUFFER_COMPLETE_OES */) {
            raw_glBindRenderbufferOES(0x8D41, surf->color_rbo_es1);
            raw_glRenderbufferStorageOES(0x8D41, 0x8056 /* GL_RGBA4_OES */, surf->width, surf->height);
            raw_glFramebufferRenderbufferOES(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                             0x8D41, surf->color_rbo_es1);
        }
    } else {
        raw_glGenFramebuffers(1, &fbo);
        raw_glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        raw_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                      GL_RENDERBUFFER, surf->color_rbo);
        if (surf->depth_rbo) {
            raw_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                                          GL_RENDERBUFFER, surf->depth_rbo);
            if (surf->has_stencil) {
                raw_glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT,
                                              GL_RENDERBUFFER, surf->depth_rbo);
            }
        }
    }
    ctx->surface_fbos[surf->id] = fbo;
    return fbo;
}

/* ---- EGL Implementation ---- */
static EGLint eagl_eglGetError(void) { return t_last_error; }

static EGLDisplay eagl_eglGetDisplay(EGLNativeDisplayType dpy)
{
    (void)dpy;
    ensure_eagl_init();
    return (EGLDisplay)(uintptr_t)1;
}

static EGLBoolean eagl_eglInitialize(EGLDisplay dpy, EGLint *major, EGLint *minor)
{
    (void)dpy;
    ensure_eagl_init();
    if (major) *major = 1;
    if (minor) *minor = 4;
    t_last_error = EGL_SUCCESS;
    return EGL_TRUE;
}

static EGLBoolean eagl_eglTerminate(EGLDisplay dpy) { (void)dpy; return EGL_TRUE; }

static const char *eagl_eglQueryString(EGLDisplay dpy, EGLint name)
{
    (void)dpy;
    switch (name) {
    case EGL_VENDOR: return "ClassicTouch EAGL";
    case EGL_VERSION: return "1.4 EAGL";
    case EGL_EXTENSIONS:
        return "EGL_KHR_image_base EGL_KHR_gl_texture_2D_image "
               "EGL_KHR_gl_renderbuffer_image ";
    case EGL_CLIENT_APIS: return "OpenGL_ES";
    default: return "";
    }
}

static EGLBoolean eagl_eglGetConfigs(EGLDisplay dpy, EGLConfig *configs,
                                     EGLint config_size, EGLint *num_config)
{
    (void)dpy;
    int total = (int)(sizeof(s_configs) / sizeof(s_configs[0]));
    if (!num_config) return EGL_FALSE;
    if (!configs) {
        *num_config = total;
        return EGL_TRUE;
    }
    int n = config_size < total ? config_size : total;
    for (int i = 0; i < n; i++) {
        configs[i] = (EGLConfig)&s_configs[i];
    }
    *num_config = n;
    return EGL_TRUE;
}

static EGLBoolean eagl_eglChooseConfig(EGLDisplay dpy, const EGLint *attrib_list,
                                       EGLConfig *configs, EGLint config_size,
                                       EGLint *num_config)
{
    (void)dpy;
    if (!num_config) return EGL_FALSE;

    EGLint want_r = 0, want_g = 0, want_b = 0, want_a = 0;
    EGLint want_depth = 0, want_stencil = 0;
    EGLint want_renderable = 0, want_surface = 0;

    if (attrib_list) {
        for (const EGLint *p = attrib_list; *p != EGL_NONE; p += 2) {
            switch (p[0]) {
            case EGL_RED_SIZE: want_r = p[1]; break;
            case EGL_GREEN_SIZE: want_g = p[1]; break;
            case EGL_BLUE_SIZE: want_b = p[1]; break;
            case EGL_ALPHA_SIZE: want_a = p[1]; break;
            case EGL_DEPTH_SIZE: want_depth = p[1]; break;
            case EGL_STENCIL_SIZE: want_stencil = p[1]; break;
            case EGL_RENDERABLE_TYPE: want_renderable = p[1]; break;
            case EGL_SURFACE_TYPE: want_surface = p[1]; break;
            default: break;
            }
        }
    }

    int total = (int)(sizeof(s_configs) / sizeof(s_configs[0]));
    int matched = 0;
    for (int i = 0; i < total; i++) {
        const EaglConfig *c = &s_configs[i];
        if (want_r > c->r || want_g > c->g || want_b > c->b || want_a > c->a) continue;
        if (want_depth > c->depth || want_stencil > c->stencil) continue;
        if (want_renderable && ((c->renderable_type & want_renderable) != want_renderable)) continue;
        if (want_surface && ((c->surface_type & want_surface) != want_surface)) continue;
        if (configs && matched < config_size) {
            configs[matched] = (EGLConfig)c;
        }
        matched++;
    }
    if (configs && matched > config_size) matched = config_size;
    *num_config = matched;
    return EGL_TRUE;
}

static EGLBoolean eagl_eglGetConfigAttrib(EGLDisplay dpy, EGLConfig config,
                                          EGLint attribute, EGLint *value)
{
    (void)dpy;
    const EaglConfig *c = (const EaglConfig *)config;
    if (!c || !value) return EGL_FALSE;
    switch (attribute) {
    case EGL_CONFIG_ID: *value = c->id; break;
    case EGL_BUFFER_SIZE: *value = c->r + c->g + c->b + c->a; break;
    case EGL_RED_SIZE: *value = c->r; break;
    case EGL_GREEN_SIZE: *value = c->g; break;
    case EGL_BLUE_SIZE: *value = c->b; break;
    case EGL_ALPHA_SIZE: *value = c->a; break;
    case EGL_DEPTH_SIZE: *value = c->depth; break;
    case EGL_STENCIL_SIZE: *value = c->stencil; break;
    case EGL_RENDERABLE_TYPE: *value = c->renderable_type; break;
    case EGL_CONFORMANT: *value = c->renderable_type; break;
    case EGL_SURFACE_TYPE: *value = c->surface_type; break;
    case EGL_CONFIG_CAVEAT: *value = EGL_NONE; break;
    case EGL_COLOR_BUFFER_TYPE: *value = EGL_RGB_BUFFER; break;
    case EGL_NATIVE_RENDERABLE: *value = EGL_TRUE; break;
    case EGL_MAX_PBUFFER_WIDTH: *value = 4096; break;
    case EGL_MAX_PBUFFER_HEIGHT: *value = 4096; break;
    case EGL_MAX_PBUFFER_PIXELS: *value = 4096 * 4096; break;
    case EGL_MIN_SWAP_INTERVAL: *value = 1; break;
    case EGL_MAX_SWAP_INTERVAL: *value = 1; break;
    case EGL_TRANSPARENT_TYPE: *value = EGL_NONE; break;
    case EGL_BIND_TO_TEXTURE_RGB: *value = EGL_TRUE; break;
    case EGL_BIND_TO_TEXTURE_RGBA: *value = EGL_TRUE; break;
    case 0x3142 /* EGL_RECORDABLE_ANDROID */: *value = EGL_TRUE; break;
    default: *value = 0; break;
    }
    return EGL_TRUE;
}

static EGLSurface eagl_eglCreatePbufferSurface(EGLDisplay dpy, EGLConfig config,
                                               const EGLint *attrib_list)
{
    (void)dpy;
    const EaglConfig *c = (const EaglConfig *)config;
    int width = 1, height = 1;
    if (attrib_list) {
        for (const EGLint *p = attrib_list; *p != EGL_NONE; p += 2) {
            if (p[0] == EGL_WIDTH) width = p[1];
            else if (p[0] == EGL_HEIGHT) height = p[1];
        }
    }
    if (width < 1) width = 1;
    if (height < 1) height = 1;

    EaglSurfaceObj *surf = new EaglSurfaceObj();
    surf->id = s_next_surface_id.fetch_add(1, std::memory_order_relaxed);
    surf->width = width;
    surf->height = height;
    surf->has_depth = c ? (c->depth > 0) : false;
    surf->has_stencil = c ? (c->stencil > 0) : false;
    surf->color_rbo = 0;
    surf->depth_rbo = 0;
    surf->color_rbo_es1 = 0;
    surf->depth_rbo_es1 = 0;

    /* Temporarily borrow an ES2 context in the root sharegroup to allocate ES2 RBO storage */
    id prev_raw = ((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_currentContext);
    id temp_ctx = nullptr;
    if (!prev_raw || (t_cur_ctx && t_cur_ctx->client_version != 2)) {
        temp_ctx = ((MsgIdUlId)objc_msgSend)(((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_alloc),
                                             sel_initWithAPI_sharegroup, kEaglApiGles2, s_root_sharegroup);
        eagl_set_current_raw(temp_ctx);
    }

    GLint prev_rbo = 0;
    raw_glGetIntegerv(GL_RENDERBUFFER_BINDING, &prev_rbo);

    raw_glGenRenderbuffers(1, &surf->color_rbo);
    raw_glBindRenderbuffer(GL_RENDERBUFFER, surf->color_rbo);
    raw_glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8_OES, width, height);

    if (surf->has_depth || surf->has_stencil) {
        raw_glGenRenderbuffers(1, &surf->depth_rbo);
        raw_glBindRenderbuffer(GL_RENDERBUFFER, surf->depth_rbo);
        raw_glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8_OES, width, height);
        surf->has_stencil = true;
    }

    raw_glBindRenderbuffer(GL_RENDERBUFFER, (GLuint)prev_rbo);
    if (raw_glFlush) {
        raw_glFlush();
    }

    if (temp_ctx) {
        eagl_set_current_raw(prev_raw);
        ((MsgVoid)objc_msgSend)(temp_ctx, sel_release);
    }

    return (EGLSurface)surf;
}

static EGLSurface eagl_eglCreateWindowSurface(EGLDisplay dpy, EGLConfig config,
                                              EGLNativeWindowType win,
                                              const EGLint *attrib_list)
{
    (void)win;
    return eagl_eglCreatePbufferSurface(dpy, config, attrib_list);
}

static EGLBoolean eagl_eglDestroySurface(EGLDisplay dpy, EGLSurface surface)
{
    (void)dpy;
    EaglSurfaceObj *surf = (EaglSurfaceObj *)surface;
    if (!surf) return EGL_FALSE;
    id prev_raw = ((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_currentContext);
    if (surf->color_rbo || surf->depth_rbo) {
        id temp_ctx = nullptr;
        if (!prev_raw || (t_cur_ctx && t_cur_ctx->client_version != 2)) {
            temp_ctx = ((MsgIdUlId)objc_msgSend)(((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_alloc),
                                                 sel_initWithAPI_sharegroup, kEaglApiGles2, s_root_sharegroup);
            eagl_set_current_raw(temp_ctx);
        }
        if (surf->color_rbo) raw_glDeleteRenderbuffers(1, &surf->color_rbo);
        if (surf->depth_rbo) raw_glDeleteRenderbuffers(1, &surf->depth_rbo);
        if (temp_ctx) {
            eagl_set_current_raw(prev_raw);
            ((MsgVoid)objc_msgSend)(temp_ctx, sel_release);
        }
    }
    if (surf->color_rbo_es1 || surf->depth_rbo_es1) {
        id temp_ctx1 = nullptr;
        if (!prev_raw || (t_cur_ctx && t_cur_ctx->client_version != 1)) {
            temp_ctx1 = ((MsgIdUlId)objc_msgSend)(((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_alloc),
                                                  sel_initWithAPI_sharegroup, kEaglApiGles1, s_gles1_sharegroup);
            eagl_set_current_raw(temp_ctx1);
        }
        if (surf->color_rbo_es1 && raw_glDeleteRenderbuffersOES) {
            raw_glDeleteRenderbuffersOES(1, &surf->color_rbo_es1);
        }
        if (surf->depth_rbo_es1 && raw_glDeleteRenderbuffersOES) {
            raw_glDeleteRenderbuffersOES(1, &surf->depth_rbo_es1);
        }
        if (temp_ctx1) {
            eagl_set_current_raw(prev_raw);
            ((MsgVoid)objc_msgSend)(temp_ctx1, sel_release);
        }
    }
    delete surf;
    return EGL_TRUE;
}

static EGLBoolean eagl_eglBindAPI(EGLenum api) { t_bound_api = api; return EGL_TRUE; }
static EGLenum eagl_eglQueryAPI(void) { return t_bound_api; }

static EGLBoolean eagl_eglReleaseThread(void)
{
    t_cur_ctx = nullptr;
    t_cur_draw = nullptr;
    t_cur_read = nullptr;
    t_cur_draw_fbo = 0;
    eagl_set_current_raw(nil);
    return EGL_TRUE;
}

static EGLContext eagl_eglCreateContext(EGLDisplay dpy, EGLConfig config,
                                        EGLContext share_context,
                                        const EGLint *attrib_list)
{
    (void)dpy;
    (void)config;
    (void)share_context;
    ensure_eagl_init();

    int ver = 1;
    if (attrib_list) {
        for (const EGLint *p = attrib_list; *p != EGL_NONE; p += 2) {
            if (p[0] == EGL_CONTEXT_CLIENT_VERSION) {
                ver = p[1];
            }
        }
    }
    unsigned long api = (ver >= 2) ? kEaglApiGles2 : kEaglApiGles1;
    id sharegroup = (ver >= 2) ? s_root_sharegroup : s_gles1_sharegroup;
    id raw = ((MsgIdUlId)objc_msgSend)(((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_alloc),
                                       sel_initWithAPI_sharegroup, api, sharegroup);
    if (!raw && sharegroup) {
        raw = ((MsgIdUl)objc_msgSend)(((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_alloc),
                                      sel_initWithAPI, api);
    }
    if (!raw && ver >= 3) {
        raw = ((MsgIdUlId)objc_msgSend)(((MsgId)objc_msgSend)((id)cls_EAGLContext, sel_alloc),
                                        sel_initWithAPI_sharegroup, kEaglApiGles2, s_root_sharegroup);
    }
    if (!raw) {
        t_last_error = EGL_BAD_ALLOC;
        return EGL_NO_CONTEXT;
    }

    EaglContextObj *ctx = new EaglContextObj();
    ctx->eagl_ctx = raw;
    ctx->client_version = (ver >= 2) ? 2 : 1;
    return (EGLContext)ctx;
}

static EGLBoolean eagl_eglDestroyContext(EGLDisplay dpy, EGLContext context)
{
    (void)dpy;
    EaglContextObj *ctx = (EaglContextObj *)context;
    if (!ctx) return EGL_FALSE;
    if (t_cur_ctx == ctx) {
        eagl_eglReleaseThread();
    }
    if (ctx->eagl_ctx) {
        ((MsgVoid)objc_msgSend)(ctx->eagl_ctx, sel_release);
    }
    delete ctx;
    return EGL_TRUE;
}

static EGLBoolean eagl_eglMakeCurrent(EGLDisplay dpy, EGLSurface draw,
                                      EGLSurface read, EGLContext context)
{
    (void)dpy;
    EaglContextObj *ctx = (EaglContextObj *)context;
    EaglSurfaceObj *dsurf = (EaglSurfaceObj *)draw;
    EaglSurfaceObj *rsurf = (EaglSurfaceObj *)read;

    if (t_cur_ctx && t_cur_ctx != ctx && raw_glFlush) {
        raw_glFlush();
    }

    if (!ctx) {
        t_cur_ctx = nullptr;
        t_cur_draw = nullptr;
        t_cur_read = nullptr;
        t_cur_draw_fbo = 0;
        eagl_set_current_raw(nil);
        return EGL_TRUE;
    }

    eagl_set_current_raw(ctx->eagl_ctx);
    t_cur_ctx = ctx;
    t_cur_draw = dsurf;
    t_cur_read = rsurf;
    t_cur_draw_fbo = dsurf ? get_or_create_fbo_for_surface(ctx, dsurf) : 0;

    GLuint target_fbo = (ctx->bound_fbo != 0) ? ctx->bound_fbo : t_cur_draw_fbo;
    if (ctx->client_version == 1) {
        raw_glBindFramebufferOES(GL_FRAMEBUFFER, target_fbo);
    } else {
        raw_glBindFramebuffer(GL_FRAMEBUFFER, target_fbo);
    }
    return EGL_TRUE;
}

static EGLContext eagl_eglGetCurrentContext(void) { return (EGLContext)t_cur_ctx; }

static EGLSurface eagl_eglGetCurrentSurface(EGLint readdraw)
{
    return (EGLSurface)(readdraw == EGL_READ ? t_cur_read : t_cur_draw);
}

static EGLBoolean eagl_eglSwapBuffers(EGLDisplay dpy, EGLSurface surface)
{
    (void)dpy;
    (void)surface;
    if (raw_glFlush) raw_glFlush();
    return EGL_TRUE;
}

static EGLImageKHR eagl_eglCreateImageKHR(EGLDisplay dpy, EGLContext ctx,
                                          EGLenum target, EGLClientBuffer buf,
                                          const EGLint *attrib_list)
{
    (void)dpy;
    (void)ctx;
    (void)attrib_list;
    if (target != EGL_GL_TEXTURE_2D_KHR) {
        return EGL_NO_IMAGE_KHR;
    }
    uint32_t id = s_next_image_id.fetch_add(1, std::memory_order_relaxed);
    if (id == 0) {
        id = s_next_image_id.fetch_add(1, std::memory_order_relaxed);
    }
    {
        std::lock_guard<std::mutex> lk(s_image_lock);
        s_images[id] = (GLuint)(uintptr_t)buf;
    }
    return (EGLImageKHR)(uintptr_t)id;
}

static EGLBoolean eagl_eglDestroyImageKHR(EGLDisplay dpy, EGLImageKHR image)
{
    (void)dpy;
    uint32_t id = (uint32_t)(uintptr_t)image;
    std::lock_guard<std::mutex> lk(s_image_lock);
    return (s_images.erase(id) > 0) ? EGL_TRUE : EGL_FALSE;
}

/* ---- GLES Wrappers (FBO 0 redirection + EGLImage zero-copy aliasing) ---- */
#ifndef GL_TEXTURE_EXTERNAL_OES
#define GL_TEXTURE_EXTERNAL_OES 0x8D65
#endif
#ifndef GL_TEXTURE_BINDING_EXTERNAL_OES
#define GL_TEXTURE_BINDING_EXTERNAL_OES 0x8D67
#endif

static inline GLenum normalize_tex_target(GLenum t)
{
    return (t == GL_TEXTURE_EXTERNAL_OES) ? GL_TEXTURE_2D : t;
}

static inline bool is_glsl_ident_char(char c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

static inline bool is_es1_current()
{
    return t_cur_ctx && t_cur_ctx->client_version == 1;
}

static GLuint resolve_tex_alias(GLuint texture)
{
    if (texture == 0 || is_es1_current()) {
        return texture;
    }
    std::lock_guard<std::mutex> lk(s_alias_lock);
    auto it = s_tex_alias.find(texture);
    return (it != s_tex_alias.end()) ? it->second : texture;
}

static GLuint resolve_rbo_tex_alias(GLuint renderbuffer)
{
    if (renderbuffer == 0 || is_es1_current()) {
        return 0;
    }
    std::lock_guard<std::mutex> lk(s_alias_lock);
    auto it = s_rbo_alias.find(renderbuffer);
    return (it != s_rbo_alias.end()) ? it->second : 0;
}

static void erase_rbo_aliases(GLsizei n, const GLuint *renderbuffers)
{
    if (n > 0 && renderbuffers && !is_es1_current()) {
        std::lock_guard<std::mutex> lk(s_alias_lock);
        for (GLsizei i = 0; i < n; i++) {
            s_rbo_alias.erase(renderbuffers[i]);
        }
    }
}

static void wrap_glActiveTexture(GLenum texture)
{
    if (t_cur_ctx && texture >= GL_TEXTURE0 && texture < GL_TEXTURE0 + 32) {
        t_cur_ctx->active_tex_unit = (GLuint)(texture - GL_TEXTURE0);
    }
    raw_glActiveTexture(texture);
}

static void wrap_glBindTexture(GLenum target, GLuint texture)
{
    if (target == GL_TEXTURE_2D || target == GL_TEXTURE_EXTERNAL_OES) {
        if (t_cur_ctx) {
            GLuint unit = t_cur_ctx->active_tex_unit;
            t_cur_ctx->last_bound_target[unit] = target;
            if (target == GL_TEXTURE_EXTERNAL_OES) {
                t_cur_ctx->bound_tex_ext[unit] = texture;
            } else {
                t_cur_ctx->bound_tex_2d[unit] = texture;
            }
            if (texture == 0) {
                /* Since GL_TEXTURE_EXTERNAL_OES and GL_TEXTURE_2D share host
                 * GL_TEXTURE_2D on EAGL, unbinding one target must re-bind the
                 * other target if it is still logically bound on this unit! */
                GLuint fallback = (target == GL_TEXTURE_EXTERNAL_OES)
                    ? t_cur_ctx->bound_tex_2d[unit]
                    : t_cur_ctx->bound_tex_ext[unit];
                if (fallback != 0) {
                    t_cur_ctx->last_bound_target[unit] =
                        (target == GL_TEXTURE_EXTERNAL_OES) ? GL_TEXTURE_2D : GL_TEXTURE_EXTERNAL_OES;
                    raw_glBindTexture(GL_TEXTURE_2D, resolve_tex_alias(fallback));
                    return;
                }
            }
        }
        GLuint real_tex = (texture != 0) ? resolve_tex_alias(texture) : 0;
        raw_glBindTexture(GL_TEXTURE_2D, real_tex);
        return;
    }
    raw_glBindTexture(target, texture);
}

static void wrap_glDeleteTextures(GLsizei n, const GLuint *textures)
{
    if (n > 0 && textures && !is_es1_current()) {
        std::lock_guard<std::mutex> lk(s_alias_lock);
        for (GLsizei i = 0; i < n; i++) {
            GLuint tex = textures[i];
            s_tex_alias.erase(tex);
            for (auto it = s_tex_alias.begin(); it != s_tex_alias.end(); ) {
                if (it->second == tex) {
                    it = s_tex_alias.erase(it);
                } else {
                    ++it;
                }
            }
            for (auto it = s_rbo_alias.begin(); it != s_rbo_alias.end(); ) {
                if (it->second == tex) {
                    it = s_rbo_alias.erase(it);
                } else {
                    ++it;
                }
            }
        }
    }
    raw_glDeleteTextures(n, textures);
}

static void detach_alias_if_target_redefined(GLenum target)
{
    if (!t_cur_ctx || is_es1_current() ||
        (target != GL_TEXTURE_2D && target != GL_TEXTURE_EXTERNAL_OES)) {
        return;
    }
    GLuint unit = t_cur_ctx->active_tex_unit;
    GLuint logical_tex = (target == GL_TEXTURE_EXTERNAL_OES)
        ? t_cur_ctx->bound_tex_ext[unit]
        : t_cur_ctx->bound_tex_2d[unit];
    if (logical_tex == 0) {
        return;
    }
    bool removed = false;
    {
        std::lock_guard<std::mutex> lk(s_alias_lock);
        removed = (s_tex_alias.erase(logical_tex) > 0);
    }
    if (removed) {
        raw_glBindTexture(GL_TEXTURE_2D, logical_tex);
    }
}

static void wrap_glTexImage2D(GLenum target, GLint level, GLint internalformat,
                              GLsizei width, GLsizei height, GLint border,
                              GLenum format, GLenum type, const void *pixels)
{
    detach_alias_if_target_redefined(target);
    raw_glTexImage2D(normalize_tex_target(target), level, internalformat,
                     width, height, border, format, type, pixels);
}

static void wrap_glTexSubImage2D(GLenum target, GLint level, GLint xoffset,
                                 GLint yoffset, GLsizei width, GLsizei height,
                                 GLenum format, GLenum type, const void *pixels)
{
    raw_glTexSubImage2D(normalize_tex_target(target), level, xoffset, yoffset,
                        width, height, format, type, pixels);
}

static void wrap_glCompressedTexImage2D(GLenum target, GLint level,
                                        GLenum internalformat, GLsizei width,
                                        GLsizei height, GLint border,
                                        GLsizei imageSize, const void *data)
{
    detach_alias_if_target_redefined(target);
    raw_glCompressedTexImage2D(normalize_tex_target(target), level,
                               internalformat, width, height, border,
                               imageSize, data);
}

static void wrap_glCompressedTexSubImage2D(GLenum target, GLint level,
                                           GLint xoffset, GLint yoffset,
                                           GLsizei width, GLsizei height,
                                           GLenum format, GLsizei imageSize,
                                           const void *data)
{
    raw_glCompressedTexSubImage2D(normalize_tex_target(target), level, xoffset,
                                  yoffset, width, height, format, imageSize, data);
}

static void wrap_glCopyTexImage2D(GLenum target, GLint level,
                                  GLenum internalformat, GLint x, GLint y,
                                  GLsizei width, GLsizei height, GLint border)
{
    detach_alias_if_target_redefined(target);
    raw_glCopyTexImage2D(normalize_tex_target(target), level, internalformat,
                         x, y, width, height, border);
}

static void wrap_glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset,
                                     GLint yoffset, GLint x, GLint y,
                                     GLsizei width, GLsizei height)
{
    raw_glCopyTexSubImage2D(normalize_tex_target(target), level, xoffset,
                            yoffset, x, y, width, height);
}

static void wrap_glTexParameteri(GLenum target, GLenum pname, GLint param)
{
    raw_glTexParameteri(normalize_tex_target(target), pname, param);
}

static void wrap_glTexParameterf(GLenum target, GLenum pname, GLfloat param)
{
    raw_glTexParameterf(normalize_tex_target(target), pname, param);
}

static void wrap_glTexParameteriv(GLenum target, GLenum pname, const GLint *params)
{
    raw_glTexParameteriv(normalize_tex_target(target), pname, params);
}

static void wrap_glTexParameterfv(GLenum target, GLenum pname, const GLfloat *params)
{
    raw_glTexParameterfv(normalize_tex_target(target), pname, params);
}

static void wrap_glGetTexParameteriv(GLenum target, GLenum pname, GLint *params)
{
    raw_glGetTexParameteriv(normalize_tex_target(target), pname, params);
}

static void wrap_glGetTexParameterfv(GLenum target, GLenum pname, GLfloat *params)
{
    raw_glGetTexParameterfv(normalize_tex_target(target), pname, params);
}

static void wrap_glGenerateMipmap(GLenum target)
{
    raw_glGenerateMipmap(normalize_tex_target(target));
}

static void wrap_glEnable(GLenum cap)
{
    raw_glEnable(normalize_tex_target(cap));
}

static void wrap_glDisable(GLenum cap)
{
    raw_glDisable(normalize_tex_target(cap));
}

static void wrap_glShaderSource(GLuint shader, GLsizei count,
                                const GLchar *const *string, const GLint *length)
{
    if (!string || count <= 0) {
        raw_glShaderSource(shader, count, string, length);
        return;
    }

    std::string full;
    for (GLsizei i = 0; i < count; i++) {
        if (!string[i]) {
            continue;
        }
        if (length && length[i] >= 0) {
            full.append(string[i], (size_t)length[i]);
        } else {
            full.append(string[i]);
        }
    }

    if (full.find("GL_OES_EGL_image_external") == std::string::npos &&
        full.find("samplerExternalOES") == std::string::npos) {
        raw_glShaderSource(shader, count, string, length);
        return;
    }

    std::string rewritten;
    rewritten.reserve(full.size());
    size_t pos = 0;
    while (pos < full.size()) {
        size_t nl = full.find('\n', pos);
        bool has_nl = (nl != std::string::npos);
        size_t line_end = has_nl ? nl : full.size();
        size_t trimmed_end = line_end;
        if (trimmed_end > pos && full[trimmed_end - 1] == '\r') {
            --trimmed_end;
        }
        size_t ws = pos;
        while (ws < trimmed_end && (full[ws] == ' ' || full[ws] == '\t')) {
            ++ws;
        }
        std::string line = full.substr(pos, line_end - pos);
        if (ws < trimmed_end && full[ws] == '#' &&
            line.find("extension") != std::string::npos &&
            line.find("GL_OES_EGL_image_external") != std::string::npos) {
            rewritten += "// stripped external ext";
            if (has_nl) {
                rewritten.push_back('\n');
            }
        } else {
            rewritten += line;
            if (has_nl) {
                rewritten.push_back('\n');
            }
        }
        pos = has_nl ? (nl + 1) : full.size();
    }

    static const char kExtSampler[] = "samplerExternalOES";
    constexpr size_t kExtLen = sizeof(kExtSampler) - 1;
    std::string final_src;
    final_src.reserve(rewritten.size());
    size_t scan = 0;
    while (scan < rewritten.size()) {
        size_t hit = rewritten.find(kExtSampler, scan);
        if (hit == std::string::npos) {
            final_src.append(rewritten, scan, rewritten.size() - scan);
            break;
        }
        bool left_ok = (hit == 0) || !is_glsl_ident_char(rewritten[hit - 1]);
        size_t after = hit + kExtLen;
        bool right_ok = (after >= rewritten.size()) || !is_glsl_ident_char(rewritten[after]);
        if (left_ok && right_ok) {
            final_src.append(rewritten, scan, hit - scan);
            final_src.append("sampler2D");
        } else {
            final_src.append(rewritten, scan, after - scan);
        }
        scan = after;
    }

    const GLchar *src_ptr = final_src.c_str();
    GLint src_len = (GLint)final_src.size();
    raw_glShaderSource(shader, 1, &src_ptr, &src_len);
}

static void wrap_glBindFramebuffer(GLenum target, GLuint fb)
{
    if (t_cur_ctx && (target == GL_FRAMEBUFFER || target == GL_DRAW_FRAMEBUFFER_EXT)) {
        t_cur_ctx->bound_fbo = fb;
    }
    if (fb == 0 && t_cur_draw_fbo != 0) {
        fb = t_cur_draw_fbo;
    }
    raw_glBindFramebuffer(target, fb);
}

static void wrap_glBindFramebufferOES(GLenum target, GLuint fb)
{
    if (t_cur_ctx && (target == GL_FRAMEBUFFER || target == GL_DRAW_FRAMEBUFFER_EXT)) {
        t_cur_ctx->bound_fbo = fb;
    }
    if (fb == 0 && t_cur_draw_fbo != 0) {
        fb = t_cur_draw_fbo;
    }
    raw_glBindFramebufferOES(target, fb);
}

static void wrap_glDeleteFramebuffers(GLsizei n, const GLuint *framebuffers)
{
    bool deleted_bound = false;
    if (n > 0 && framebuffers && t_cur_ctx && t_cur_ctx->bound_fbo != 0) {
        for (GLsizei i = 0; i < n; i++) {
            if (framebuffers[i] == t_cur_ctx->bound_fbo) {
                deleted_bound = true;
                break;
            }
        }
    }
    raw_glDeleteFramebuffers(n, framebuffers);
    if (deleted_bound && t_cur_ctx) {
        t_cur_ctx->bound_fbo = 0;
        raw_glBindFramebuffer(GL_FRAMEBUFFER, t_cur_draw_fbo);
    }
}

static void wrap_glDeleteFramebuffersOES(GLsizei n, const GLuint *framebuffers)
{
    bool deleted_bound = false;
    if (n > 0 && framebuffers && t_cur_ctx && t_cur_ctx->bound_fbo != 0) {
        for (GLsizei i = 0; i < n; i++) {
            if (framebuffers[i] == t_cur_ctx->bound_fbo) {
                deleted_bound = true;
                break;
            }
        }
    }
    raw_glDeleteFramebuffersOES(n, framebuffers);
    if (deleted_bound && t_cur_ctx) {
        t_cur_ctx->bound_fbo = 0;
        raw_glBindFramebufferOES(GL_FRAMEBUFFER, t_cur_draw_fbo);
    }
}

static void wrap_glFramebufferTexture2D(GLenum target, GLenum attachment,
                                        GLenum textarget, GLuint texture, GLint level)
{
    if (textarget == GL_TEXTURE_2D || textarget == GL_TEXTURE_EXTERNAL_OES) {
        texture = resolve_tex_alias(texture);
        textarget = GL_TEXTURE_2D;
    }
    raw_glFramebufferTexture2D(target, attachment, textarget, texture, level);
}

static void wrap_glFramebufferTexture2DOES(GLenum target, GLenum attachment,
                                           GLenum textarget, GLuint texture, GLint level)
{
    if (textarget == GL_TEXTURE_2D || textarget == GL_TEXTURE_EXTERNAL_OES) {
        texture = resolve_tex_alias(texture);
        textarget = GL_TEXTURE_2D;
    }
    raw_glFramebufferTexture2DOES(target, attachment, textarget, texture, level);
}

static void wrap_glBindRenderbuffer(GLenum target, GLuint renderbuffer)
{
    if (t_cur_ctx) {
        t_cur_ctx->bound_rbo = renderbuffer;
    }
    raw_glBindRenderbuffer(target, renderbuffer);
}

static void wrap_glBindRenderbufferOES(GLenum target, GLuint renderbuffer)
{
    if (t_cur_ctx) {
        t_cur_ctx->bound_rbo = renderbuffer;
    }
    raw_glBindRenderbufferOES(target, renderbuffer);
}

static void wrap_glRenderbufferStorage(GLenum target, GLenum internalformat,
                                       GLsizei width, GLsizei height)
{
    if (internalformat == GL_RGBA || internalformat == GL_RGB) {
        internalformat = GL_RGBA8_OES;
    }
    raw_glRenderbufferStorage(target, internalformat, width, height);
}

static void wrap_glRenderbufferStorageOES(GLenum target, GLenum internalformat,
                                          GLsizei width, GLsizei height)
{
    if (internalformat == GL_RGBA || internalformat == GL_RGB) {
        internalformat = GL_RGBA8_OES;
    }
    raw_glRenderbufferStorageOES(target, internalformat, width, height);
}

static void wrap_glDeleteRenderbuffers(GLsizei n, const GLuint *renderbuffers)
{
    erase_rbo_aliases(n, renderbuffers);
    raw_glDeleteRenderbuffers(n, renderbuffers);
}

static void wrap_glDeleteRenderbuffersOES(GLsizei n, const GLuint *renderbuffers)
{
    erase_rbo_aliases(n, renderbuffers);
    raw_glDeleteRenderbuffersOES(n, renderbuffers);
}

static void wrap_glFramebufferRenderbuffer(GLenum target, GLenum attachment,
                                           GLenum renderbuffertarget, GLuint renderbuffer)
{
    GLuint tex = resolve_rbo_tex_alias(renderbuffer);
    if (tex != 0) {
        raw_glFramebufferTexture2D(target, attachment, GL_TEXTURE_2D, tex, 0);
        return;
    }
    raw_glFramebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer);
}

static void wrap_glFramebufferRenderbufferOES(GLenum target, GLenum attachment,
                                              GLenum renderbuffertarget, GLuint renderbuffer)
{
    GLuint tex = resolve_rbo_tex_alias(renderbuffer);
    if (tex != 0) {
        raw_glFramebufferTexture2DOES(target, attachment, GL_TEXTURE_2D, tex, 0);
        return;
    }
    raw_glFramebufferRenderbufferOES(target, attachment, renderbuffertarget, renderbuffer);
}

static void wrap_glGetIntegerv(GLenum pname, GLint *params)
{
    if (pname == GL_TEXTURE_BINDING_EXTERNAL_OES) {
        if (params) {
            *params = (GLint)(t_cur_ctx ? t_cur_ctx->bound_tex_ext[t_cur_ctx->active_tex_unit] : 0);
        }
        return;
    }
    raw_glGetIntegerv(pname, params);
    if (pname == GL_FRAMEBUFFER_BINDING && params && t_cur_draw_fbo != 0 &&
        (GLuint)*params == t_cur_draw_fbo) {
        *params = 0;
    } else if (pname == GL_TEXTURE_BINDING_2D && params && t_cur_ctx) {
        *params = (GLint)t_cur_ctx->bound_tex_2d[t_cur_ctx->active_tex_unit];
    }
}

static bool has_ext_token(const std::string &hay, const char *tok)
{
    size_t tlen = strlen(tok);
    size_t pos = 0;
    while ((pos = hay.find(tok, pos)) != std::string::npos) {
        bool left_ok = (pos == 0 || hay[pos - 1] == ' ');
        bool right_ok = (pos + tlen == hay.size() || hay[pos + tlen] == ' ');
        if (left_ok && right_ok) {
            return true;
        }
        pos += tlen;
    }
    return false;
}

static const GLubyte *wrap_glGetString(GLenum name)
{
    static thread_local std::string t_ext_cache;
    const GLubyte *orig = raw_glGetString(name);
    if (name == GL_VERSION) {
        return reinterpret_cast<const GLubyte *>(
            is_es1_current() ? "OpenGL ES-CM 1.1 ClassicTouch"
                             : "OpenGL ES 2.0 ClassicTouch");
    }
    if (name == GL_SHADING_LANGUAGE_VERSION && !is_es1_current()) {
        return reinterpret_cast<const GLubyte *>("OpenGL ES GLSL ES 1.00");
    }
    if (name == GL_EXTENSIONS && orig) {
        std::string host(reinterpret_cast<const char *>(orig));
        std::string filtered;
        if (is_es1_current()) {
            filtered = "GL_OES_EGL_image GL_OES_EGL_image_external "
                       "GL_OES_framebuffer_object GL_OES_rgb8_rgba8 "
                       "GL_OES_depth24 GL_OES_packed_depth_stencil";
            static const char *const kEs1Allow[] = {
                "GL_OES_blend_equation_separate",
                "GL_OES_blend_func_separate",
                "GL_OES_blend_subtract",
                "GL_OES_byte_coordinates",
                "GL_OES_compressed_paletted_texture",
                "GL_OES_draw_texture",
                "GL_OES_extended_matrix_palette",
                "GL_OES_fixed_point",
                "GL_OES_matrix_get",
                "GL_OES_matrix_palette",
                "GL_OES_point_size_array",
                "GL_OES_point_sprite",
                "GL_OES_query_matrix",
                "GL_OES_read_format",
                "GL_OES_single_precision",
                "GL_OES_stencil_wrap",
                "GL_OES_texture_cube_map",
                "GL_OES_texture_env_crossbar",
                "GL_OES_texture_mirrored_repeat",
                "GL_OES_texture_npot",
            };
            for (const char *ext : kEs1Allow) {
                if (has_ext_token(host, ext)) {
                    filtered.push_back(' ');
                    filtered.append(ext);
                }
            }
        } else {
            filtered = "GL_OES_EGL_image GL_OES_EGL_image_external "
                       "GL_OES_depth24 GL_OES_packed_depth_stencil "
                       "GL_OES_rgb8_rgba8";
            static const char *const kEs2Allow[] = {
                "GL_OES_compressed_ETC1_RGB8_texture",
                "GL_OES_depth32",
                "GL_OES_depth_texture",
                "GL_OES_element_index_uint",
                "GL_OES_fbo_render_mipmap",
                "GL_OES_mapbuffer",
                "GL_OES_required_internalformat",
                "GL_OES_standard_derivatives",
                "GL_OES_texture_float",
                "GL_OES_texture_float_linear",
                "GL_OES_texture_half_float",
                "GL_OES_texture_half_float_linear",
                "GL_OES_texture_npot",
                "GL_OES_vertex_array_object",
                "GL_OES_vertex_half_float",
                "GL_EXT_blend_minmax",
                "GL_EXT_color_buffer_half_float",
                "GL_EXT_discard_framebuffer",
                "GL_EXT_shader_texture_lod",
                "GL_EXT_shadow_samplers",
                "GL_EXT_sRGB",
                "GL_EXT_texture_compression_s3tc",
                "GL_EXT_texture_filter_anisotropic",
                "GL_EXT_texture_rg",
                "GL_EXT_texture_storage",
            };
            for (const char *ext : kEs2Allow) {
                if (has_ext_token(host, ext)) {
                    filtered.push_back(' ');
                    filtered.append(ext);
                }
            }
            if (has_ext_token(host, "GL_EXT_texture_format_BGRA8888") ||
                has_ext_token(host, "GL_APPLE_texture_format_BGRA8888")) {
                filtered.append(" GL_EXT_texture_format_BGRA8888");
            }
            if (has_ext_token(host, "GL_EXT_read_format_bgra") ||
                has_ext_token(host, "GL_IMG_read_format")) {
                filtered.append(" GL_EXT_read_format_bgra");
            }
        }
        if (!filtered.empty() && filtered.back() != ' ') {
            filtered.push_back(' ');
        }
        t_ext_cache = filtered;
        return reinterpret_cast<const GLubyte *>(t_ext_cache.c_str());
    }
    return orig;
}

static GLuint lookup_egl_image_tex(void *image)
{
    uint32_t id = (uint32_t)(uintptr_t)image;
    if (id == 0) return 0;
    std::lock_guard<std::mutex> lk(s_image_lock);
    auto it = s_images.find(id);
    return (it != s_images.end()) ? it->second : 0;
}

static void wrap_glEGLImageTargetTexture2DOES(GLenum target, void *image)
{
    if (is_es1_current()) {
        return;
    }
    GLuint img_tex = lookup_egl_image_tex(image);
    if (!img_tex || (target != GL_TEXTURE_2D && target != GL_TEXTURE_EXTERNAL_OES)) {
        return;
    }
    GLuint logical_tex = 0;
    if (t_cur_ctx) {
        GLuint unit = t_cur_ctx->active_tex_unit;
        if (target == GL_TEXTURE_EXTERNAL_OES) {
            logical_tex = t_cur_ctx->bound_tex_ext[unit];
            if (logical_tex == 0) {
                logical_tex = t_cur_ctx->bound_tex_2d[unit];
            }
        } else {
            if (t_cur_ctx->last_bound_target[unit] == GL_TEXTURE_EXTERNAL_OES &&
                t_cur_ctx->bound_tex_ext[unit] != 0) {
                logical_tex = t_cur_ctx->bound_tex_ext[unit];
            } else {
                logical_tex = t_cur_ctx->bound_tex_2d[unit];
                if (logical_tex == 0) {
                    logical_tex = t_cur_ctx->bound_tex_ext[unit];
                }
            }
        }
    } else {
        GLint bound = 0;
        raw_glGetIntegerv(GL_TEXTURE_BINDING_2D, &bound);
        logical_tex = (GLuint)bound;
    }
    if (logical_tex != 0 && logical_tex != img_tex) {
        std::lock_guard<std::mutex> lk(s_alias_lock);
        s_tex_alias[logical_tex] = img_tex;
    }
    raw_glBindTexture(GL_TEXTURE_2D, img_tex);
}

static void wrap_glEGLImageTargetRenderbufferStorageOES(GLenum target, void *image)
{
    if (is_es1_current()) {
        return;
    }
    (void)target;
    GLuint img_tex = lookup_egl_image_tex(image);
    if (img_tex && t_cur_ctx && t_cur_ctx->bound_rbo != 0) {
        std::lock_guard<std::mutex> lk(s_alias_lock);
        s_rbo_alias[t_cur_ctx->bound_rbo] = img_tex;
    }
}

static void *eagl_eglGetProcAddress(const char *name);

static const struct {
    const char *name;
    void *fn;
} s_egl_procs[] = {
    { "eglGetError", (void *)eagl_eglGetError },
    { "eglGetDisplay", (void *)eagl_eglGetDisplay },
    { "eglInitialize", (void *)eagl_eglInitialize },
    { "eglTerminate", (void *)eagl_eglTerminate },
    { "eglQueryString", (void *)eagl_eglQueryString },
    { "eglGetConfigs", (void *)eagl_eglGetConfigs },
    { "eglChooseConfig", (void *)eagl_eglChooseConfig },
    { "eglGetConfigAttrib", (void *)eagl_eglGetConfigAttrib },
    { "eglCreateWindowSurface", (void *)eagl_eglCreateWindowSurface },
    { "eglCreatePbufferSurface", (void *)eagl_eglCreatePbufferSurface },
    { "eglDestroySurface", (void *)eagl_eglDestroySurface },
    { "eglBindAPI", (void *)eagl_eglBindAPI },
    { "eglQueryAPI", (void *)eagl_eglQueryAPI },
    { "eglReleaseThread", (void *)eagl_eglReleaseThread },
    { "eglCreateContext", (void *)eagl_eglCreateContext },
    { "eglDestroyContext", (void *)eagl_eglDestroyContext },
    { "eglMakeCurrent", (void *)eagl_eglMakeCurrent },
    { "eglGetCurrentContext", (void *)eagl_eglGetCurrentContext },
    { "eglGetCurrentSurface", (void *)eagl_eglGetCurrentSurface },
    { "eglSwapBuffers", (void *)eagl_eglSwapBuffers },
    { "eglGetProcAddress", (void *)eagl_eglGetProcAddress },
    { "eglCreateImageKHR", (void *)eagl_eglCreateImageKHR },
    { "eglDestroyImageKHR", (void *)eagl_eglDestroyImageKHR },
};

static void *eagl_eglGetProcAddress(const char *name)
{
    if (!name) return nullptr;
    for (const auto &e : s_egl_procs) {
        if (strcmp(e.name, name) == 0) return e.fn;
    }
    return nullptr;
}

} // namespace

extern "C" {

void *eagl_ios_find_egl_symbol(const char *name)
{
    ensure_eagl_init();
    return eagl_eglGetProcAddress(name);
}

void *eagl_ios_find_gles2_symbol(const char *name)
{
    ensure_eagl_init();
    if (!name) return nullptr;
    if (strcmp(name, "glActiveTexture") == 0) return (void *)wrap_glActiveTexture;
    if (strcmp(name, "glBindFramebuffer") == 0) return (void *)wrap_glBindFramebuffer;
    if (strcmp(name, "glDeleteFramebuffers") == 0) return (void *)wrap_glDeleteFramebuffers;
    if (strcmp(name, "glFramebufferTexture2D") == 0) return (void *)wrap_glFramebufferTexture2D;
    if (strcmp(name, "glBindRenderbuffer") == 0) return (void *)wrap_glBindRenderbuffer;
    if (strcmp(name, "glRenderbufferStorage") == 0) return (void *)wrap_glRenderbufferStorage;
    if (strcmp(name, "glDeleteRenderbuffers") == 0) return (void *)wrap_glDeleteRenderbuffers;
    if (strcmp(name, "glFramebufferRenderbuffer") == 0) return (void *)wrap_glFramebufferRenderbuffer;
    if (strcmp(name, "glBindTexture") == 0) return (void *)wrap_glBindTexture;
    if (strcmp(name, "glDeleteTextures") == 0) return (void *)wrap_glDeleteTextures;
    if (strcmp(name, "glTexImage2D") == 0) return (void *)wrap_glTexImage2D;
    if (strcmp(name, "glTexSubImage2D") == 0) return (void *)wrap_glTexSubImage2D;
    if (strcmp(name, "glCompressedTexImage2D") == 0) return (void *)wrap_glCompressedTexImage2D;
    if (strcmp(name, "glCompressedTexSubImage2D") == 0) return (void *)wrap_glCompressedTexSubImage2D;
    if (strcmp(name, "glCopyTexImage2D") == 0) return (void *)wrap_glCopyTexImage2D;
    if (strcmp(name, "glCopyTexSubImage2D") == 0) return (void *)wrap_glCopyTexSubImage2D;
    if (strcmp(name, "glTexParameteri") == 0) return (void *)wrap_glTexParameteri;
    if (strcmp(name, "glTexParameterf") == 0) return (void *)wrap_glTexParameterf;
    if (strcmp(name, "glTexParameteriv") == 0) return (void *)wrap_glTexParameteriv;
    if (strcmp(name, "glTexParameterfv") == 0) return (void *)wrap_glTexParameterfv;
    if (strcmp(name, "glGetTexParameteriv") == 0) return (void *)wrap_glGetTexParameteriv;
    if (strcmp(name, "glGetTexParameterfv") == 0) return (void *)wrap_glGetTexParameterfv;
    if (strcmp(name, "glGenerateMipmap") == 0) return (void *)wrap_glGenerateMipmap;
    if (strcmp(name, "glShaderSource") == 0) return (void *)wrap_glShaderSource;
    if (strcmp(name, "glGetIntegerv") == 0) return (void *)wrap_glGetIntegerv;
    if (strcmp(name, "glGetString") == 0) return (void *)wrap_glGetString;
    if (strcmp(name, "glEGLImageTargetTexture2DOES") == 0) return (void *)wrap_glEGLImageTargetTexture2DOES;
    if (strcmp(name, "glEGLImageTargetRenderbufferStorageOES") == 0) return (void *)wrap_glEGLImageTargetRenderbufferStorageOES;
    return dlsym(s_gles_fw, name);
}

void *eagl_ios_find_gles1_symbol(const char *name)
{
    ensure_eagl_init();
    if (!name) return nullptr;
    if (strcmp(name, "glActiveTexture") == 0) return (void *)wrap_glActiveTexture;
    if (strcmp(name, "glBindFramebufferOES") == 0 ||
        strcmp(name, "glBindFramebufferEXT") == 0) return (void *)wrap_glBindFramebufferOES;
    if (strcmp(name, "glDeleteFramebuffersOES") == 0 ||
        strcmp(name, "glDeleteFramebuffersEXT") == 0) return (void *)wrap_glDeleteFramebuffersOES;
    if (strcmp(name, "glFramebufferTexture2DOES") == 0 ||
        strcmp(name, "glFramebufferTexture2DEXT") == 0) return (void *)wrap_glFramebufferTexture2DOES;
    if (strcmp(name, "glBindRenderbufferOES") == 0 ||
        strcmp(name, "glBindRenderbufferEXT") == 0) return (void *)wrap_glBindRenderbufferOES;
    if (strcmp(name, "glRenderbufferStorageOES") == 0 ||
        strcmp(name, "glRenderbufferStorageEXT") == 0) return (void *)wrap_glRenderbufferStorageOES;
    if (strcmp(name, "glDeleteRenderbuffersOES") == 0 ||
        strcmp(name, "glDeleteRenderbuffersEXT") == 0) return (void *)wrap_glDeleteRenderbuffersOES;
    if (strcmp(name, "glFramebufferRenderbufferOES") == 0 ||
        strcmp(name, "glFramebufferRenderbufferEXT") == 0) return (void *)wrap_glFramebufferRenderbufferOES;
    if (strcmp(name, "glBindTexture") == 0) return (void *)wrap_glBindTexture;
    if (strcmp(name, "glDeleteTextures") == 0) return (void *)wrap_glDeleteTextures;
    if (strcmp(name, "glTexImage2D") == 0) return (void *)wrap_glTexImage2D;
    if (strcmp(name, "glTexSubImage2D") == 0) return (void *)wrap_glTexSubImage2D;
    if (strcmp(name, "glCompressedTexImage2D") == 0) return (void *)wrap_glCompressedTexImage2D;
    if (strcmp(name, "glCompressedTexSubImage2D") == 0) return (void *)wrap_glCompressedTexSubImage2D;
    if (strcmp(name, "glCopyTexImage2D") == 0) return (void *)wrap_glCopyTexImage2D;
    if (strcmp(name, "glCopyTexSubImage2D") == 0) return (void *)wrap_glCopyTexSubImage2D;
    if (strcmp(name, "glTexParameteri") == 0) return (void *)wrap_glTexParameteri;
    if (strcmp(name, "glTexParameterf") == 0) return (void *)wrap_glTexParameterf;
    if (strcmp(name, "glTexParameteriv") == 0) return (void *)wrap_glTexParameteriv;
    if (strcmp(name, "glTexParameterfv") == 0) return (void *)wrap_glTexParameterfv;
    if (strcmp(name, "glGetTexParameteriv") == 0) return (void *)wrap_glGetTexParameteriv;
    if (strcmp(name, "glGetTexParameterfv") == 0) return (void *)wrap_glGetTexParameterfv;
    if (strcmp(name, "glEnable") == 0) return (void *)wrap_glEnable;
    if (strcmp(name, "glDisable") == 0) return (void *)wrap_glDisable;
    if (strcmp(name, "glGetIntegerv") == 0) return (void *)wrap_glGetIntegerv;
    if (strcmp(name, "glGetString") == 0) return (void *)wrap_glGetString;
    if (strcmp(name, "glEGLImageTargetTexture2DOES") == 0) return (void *)wrap_glEGLImageTargetTexture2DOES;
    if (strcmp(name, "glEGLImageTargetRenderbufferStorageOES") == 0) return (void *)wrap_glEGLImageTargetRenderbufferStorageOES;
    return dlsym(s_gles_fw, name);
}

} // extern "C"

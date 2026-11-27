/*
* Copyright (C) 2011 The Android Open Source Project
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/
#include "ColorBuffer.h"

#include "DispatchTables.h"
#include "GLcommon/GLutils.h"
#include "RenderThreadInfo.h"
#include "TextureDraw.h"
#include "TextureResize.h"

#include "OpenGLESDispatch/EGLDispatch.h"

#include <atomic>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef GL_BGRA_EXT
#define GL_BGRA_EXT 0x80E1
#endif
#ifndef GL_FRAMEBUFFER_BINDING
#define GL_FRAMEBUFFER_BINDING 0x8CA6
#endif

static std::atomic<int> s_readback_bgra_state{0};

extern "C" GLenum emugl_colorbuffer_readback_format(void) {
    return (s_readback_bgra_state.load(std::memory_order_acquire) >= 0) ? GL_BGRA_EXT : GL_RGBA;
}

namespace {

// Lazily create and bind a framebuffer object to the current host context.
// |fbo| is the address of the framebuffer object name.
// |tex| is the name of a texture that is attached to the framebuffer object
// on creation only. I.e. all rendering operations will target it.
// returns true in case of success, false on failure.
bool bindFbo(GLuint* fbo, GLuint tex) {
    if (*fbo) {
        // fbo already exist - just bind
        s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
        return true;
    }

    s_gles2.glGenFramebuffers(1, fbo);
    s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, *fbo);
    s_gles2.glFramebufferTexture2D(GL_FRAMEBUFFER,
                                   GL_COLOR_ATTACHMENT0_OES,
                                   GL_TEXTURE_2D, tex, 0);
    GLenum status = s_gles2.glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE_OES) {
        ERR("ColorBuffer::bindFbo: FBO not complete: %#x\n", status);
        s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        s_gles2.glDeleteFramebuffers(1, fbo);
        *fbo = 0;
        return false;
    }
    return true;
}

void unbindFbo() {
    s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

// Helper class to use a ColorBuffer::Helper context.
// Usage is pretty simple:
//
//     {
//        ScopedHelperContext context(m_helper);
//        if (!context.isOk()) {
//            return false;   // something bad happened.
//        }
//        .... do something ....
//     }   // automatically calls m_helper->teardownContext();
//
class ScopedHelperContext {
public:
    ScopedHelperContext(ColorBuffer::Helper* helper) : mHelper(helper) {
        if (!helper->setupContext()) {
            mHelper = NULL;
        }
    }

    bool isOk() const { return mHelper != NULL; }

    ~ScopedHelperContext() {
        release();
    }

    void release() {
        if (mHelper) {
            mHelper->teardownContext();
            mHelper = NULL;
        }
    }
private:
    ColorBuffer::Helper* mHelper;
};

}  // namespace

// static
ColorBuffer* ColorBuffer::create(EGLDisplay p_display,
                                 int p_width,
                                 int p_height,
                                 GLenum p_internalFormat,
                                 bool has_eglimage_texture_2d,
                                 Helper* helper) {
    GLenum texInternalFormat = 0;

    switch (p_internalFormat) {
        case GL_RGB:
        case GL_RGB565_OES:
            /* Apple EAGL / PowerVR FBOs reject 24-bit GL_RGB color attachments. */
            texInternalFormat = GL_RGBA;
            break;

        case GL_RGBA:
        case GL_RGB5_A1_OES:
        case GL_RGBA4_OES:
        case 0x8058: /* GL_RGBA8_OES */
        case GL_BGRA_EXT:
            texInternalFormat = GL_RGBA;
            break;

        default:
            return NULL;
            break;
    }

    ScopedHelperContext context(helper);
    if (!context.isOk()) {
        return NULL;
    }

    ColorBuffer *cb = new ColorBuffer(p_display, helper);

    s_gles2.glGenTextures(1, &cb->m_tex);
    s_gles2.glBindTexture(GL_TEXTURE_2D, cb->m_tex);

    s_gles2.glTexImage2D(GL_TEXTURE_2D,
                         0,
                         texInternalFormat,
                         p_width,
                         p_height,
                         0,
                         texInternalFormat,
                         GL_UNSIGNED_BYTE,
                         NULL);

    s_gles2.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    s_gles2.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    s_gles2.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    s_gles2.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    //
    // create another texture for that colorbuffer for blit
    //
    s_gles2.glGenTextures(1, &cb->m_blitTex);
    s_gles2.glBindTexture(GL_TEXTURE_2D, cb->m_blitTex);
    s_gles2.glTexImage2D(GL_TEXTURE_2D,
                         0,
                         texInternalFormat,
                         p_width,
                         p_height,
                         0,
                         texInternalFormat,
                         GL_UNSIGNED_BYTE,
                         NULL);

    s_gles2.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    s_gles2.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    s_gles2.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    s_gles2.glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    cb->m_width = p_width;
    cb->m_height = p_height;
    cb->m_internalFormat = texInternalFormat;

    if (has_eglimage_texture_2d) {
        cb->m_eglImage = s_egl.eglCreateImageKHR(
                p_display,
                s_egl.eglGetCurrentContext(),
                EGL_GL_TEXTURE_2D_KHR,
                (EGLClientBuffer)SafePointerFromUInt(cb->m_tex),
                NULL);

        cb->m_blitEGLImage = s_egl.eglCreateImageKHR(
                p_display,
                s_egl.eglGetCurrentContext(),
                EGL_GL_TEXTURE_2D_KHR,
                (EGLClientBuffer)SafePointerFromUInt(cb->m_blitTex),
                NULL);
    }

    cb->m_resizer = new TextureResize(p_width, p_height);
    s_gles2.glFinish();

    return cb;
}

ColorBuffer::ColorBuffer(EGLDisplay display, Helper* helper) :
        m_display(display),
        m_helper(helper) {}

ColorBuffer::~ColorBuffer() {
    ScopedHelperContext context(m_helper);

    if (m_blitEGLImage) {
        s_egl.eglDestroyImageKHR(m_display, m_blitEGLImage);
    }
    if (m_eglImage) {
        s_egl.eglDestroyImageKHR(m_display, m_eglImage);
    }

    if (m_fbo) {
        s_gles2.glDeleteFramebuffers(1, &m_fbo);
    }

    GLuint tex[2] = {m_tex, m_blitTex};
    s_gles2.glDeleteTextures(2, tex);

    delete m_resizer;
}

void ColorBuffer::readPixels(int x,
                             int y,
                             int width,
                             int height,
                             GLenum p_format,
                             GLenum p_type,
                             void* pixels) {
    ScopedHelperContext context(m_helper);
    if (!context.isOk()) {
        return;
    }

    if (bindFbo(&m_fbo, m_tex)) {
        s_gles2.glReadPixels(x, y, width, height, p_format, p_type, pixels);
        unbindFbo();
    }
}

void ColorBuffer::subUpdate(int x,
                            int y,
                            int width,
                            int height,
                            GLenum p_format,
                            GLenum p_type,
                            void* pixels) {
    ScopedHelperContext context(m_helper);
    if (!context.isOk()) {
        return;
    }

    s_gles2.glBindTexture(GL_TEXTURE_2D, m_tex);
    s_gles2.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    if (p_format == GL_RGB && m_internalFormat == GL_RGBA) {
        uint8_t* rgba = static_cast<uint8_t*>(::malloc((size_t)width * height * 4));
        if (rgba) {
            if (p_type == GL_UNSIGNED_SHORT_5_6_5) {
                const uint16_t* src = static_cast<const uint16_t*>(pixels);
                for (int i = 0; i < width * height; ++i) {
                    uint16_t c = src[i];
                    uint8_t r = (c >> 11) & 0x1f;
                    uint8_t g = (c >> 5) & 0x3f;
                    uint8_t b = c & 0x1f;
                    rgba[i * 4 + 0] = (r << 3) | (r >> 2);
                    rgba[i * 4 + 1] = (g << 2) | (g >> 4);
                    rgba[i * 4 + 2] = (b << 3) | (b >> 2);
                    rgba[i * 4 + 3] = 0xff;
                }
            } else {
                const uint8_t* src = static_cast<const uint8_t*>(pixels);
                for (int i = 0; i < width * height; ++i) {
                    rgba[i * 4 + 0] = src[i * 3 + 0];
                    rgba[i * 4 + 1] = src[i * 3 + 1];
                    rgba[i * 4 + 2] = src[i * 3 + 2];
                    rgba[i * 4 + 3] = 0xff;
                }
            }
            s_gles2.glTexSubImage2D(
                    GL_TEXTURE_2D, 0, x, y, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
            ::free(rgba);
            s_gles2.glFinish();
            return;
        }
    }
    s_gles2.glTexSubImage2D(
            GL_TEXTURE_2D, 0, x, y, width, height, p_format, p_type, pixels);
    s_gles2.glFinish();
}

bool ColorBuffer::blitFromCurrentReadBuffer()
{
    RenderThreadInfo *tInfo = RenderThreadInfo::get();
    if (!tInfo->currContext.get()) {
        // no Current context
        return false;
    }

    // Copy the content of the current read surface into m_blitEGLImage.
    // This is done by creating a temporary texture, bind it to the EGLImage
    // then call glCopyTexSubImage2D().
    GLuint tmpTex;
    GLint currTexBind;
    if (tInfo->currContext->isGL2()) {
        GLint prevFbo = 0;
        s_gles2.glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
        if (prevFbo != 0) {
            s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, 0);
        }
        s_gles2.glGetIntegerv(GL_TEXTURE_BINDING_2D, &currTexBind);
        s_gles2.glGenTextures(1,&tmpTex);
        s_gles2.glBindTexture(GL_TEXTURE_2D, tmpTex);
        s_gles2.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, m_blitEGLImage);
        s_gles2.glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0,
                                  m_width, m_height);
        s_gles2.glDeleteTextures(1, &tmpTex);
        s_gles2.glBindTexture(GL_TEXTURE_2D, currTexBind);
        if (prevFbo != 0) {
            s_gles2.glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)prevFbo);
        }
        s_gles2.glFinish();
        static std::atomic<uint32_t> s_gl2_blits{0};
        uint32_t bn = s_gl2_blits.fetch_add(1, std::memory_order_relaxed) + 1;
        if (bn <= 3) {
            fprintf(stderr, "[emugl] blitFromCurrentReadBuffer GL2 #%u (%ux%u)\n",
                    bn, m_width, m_height);
        }
    }
    else {
        const size_t rowBytes = (size_t)m_width * 4;
        uint8_t* pixels = static_cast<uint8_t*>(::malloc(rowBytes * (m_height + 1)));
        if (!pixels) {
            return false;
        }
        uint8_t* tmpRow = pixels + rowBytes * m_height;
        GLint prevFbo = 0;
        s_gles1.glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
        if (prevFbo != 0) {
            s_gles1.glBindFramebufferEXT(0x8D40 /* GL_FRAMEBUFFER_OES */, 0);
        }
        s_gles1.glFinish();
        s_gles1.glPixelStorei(GL_PACK_ALIGNMENT, 1);
        s_gles1.glReadPixels(0, 0, m_width, m_height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        if (prevFbo != 0) {
            s_gles1.glBindFramebufferEXT(0x8D40 /* GL_FRAMEBUFFER_OES */, (GLuint)prevFbo);
        }
        static std::atomic<uint32_t> s_gl1_blits{0};
        uint32_t bn = s_gl1_blits.fetch_add(1, std::memory_order_relaxed) + 1;
        if (bn <= 3) {
            size_t non_black = 0;
            for (size_t i = 0; i + 3 < rowBytes * m_height; i += 64) {
                if (pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0) non_black++;
            }
            fprintf(stderr, "[emugl] blitFromCurrentReadBuffer GL1 #%u (%ux%u prevFbo=%d non_black=%zu)\n",
                    bn, m_width, m_height, prevFbo, non_black);
        }
        for (GLuint y = 0; y < m_height / 2; ++y) {
            uint8_t* top = pixels + (size_t)y * rowBytes;
            uint8_t* bot = pixels + (size_t)(m_height - 1 - y) * rowBytes;
            ::memcpy(tmpRow, top, rowBytes);
            ::memcpy(top, bot, rowBytes);
            ::memcpy(bot, tmpRow, rowBytes);
        }
        ScopedHelperContext context(m_helper);
        if (!context.isOk()) {
            ::free(pixels);
            return false;
        }
        s_gles2.glBindTexture(GL_TEXTURE_2D, m_tex);
        s_gles2.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        s_gles2.glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, m_width, m_height,
                               GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        s_gles2.glFinish();
        ::free(pixels);
        return true;
    }

    ScopedHelperContext context(m_helper);
    if (!context.isOk()) {
        return false;
    }

    if (!bindFbo(&m_fbo, m_tex)) {
        return false;
    }

    // Save current viewport and match it to the current colorbuffer size.
    GLint vport[4] = { 0, };
    s_gles2.glGetIntegerv(GL_VIEWPORT, vport);
    s_gles2.glViewport(0, 0, m_width, m_height);

    // render m_blitTex
    m_helper->getTextureDraw()->draw(m_blitTex, 0., 0, 0);

    // Restore previous viewport.
    s_gles2.glViewport(vport[0], vport[1], vport[2], vport[3]);
    unbindFbo();
    s_gles2.glFinish();

    return true;
}

bool ColorBuffer::bindToTexture() {
    if (!m_eglImage) {
        return false;
    }
    RenderThreadInfo *tInfo = RenderThreadInfo::get();
    if (!tInfo->currContext.get()) {
        return false;
    }
    if (tInfo->currContext->isGL2()) {
        s_gles2.glEGLImageTargetTexture2DOES(GL_TEXTURE_2D, m_eglImage);
    }
    else {
        const size_t nBytes = (size_t)m_width * (size_t)m_height * 4;
        uint8_t* pixels = static_cast<uint8_t*>(::malloc(nBytes));
        if (!pixels) {
            return false;
        }
        {
            ScopedHelperContext context(m_helper);
            if (!context.isOk() || !bindFbo(&m_fbo, m_tex)) {
                ::free(pixels);
                return false;
            }
            s_gles2.glPixelStorei(GL_PACK_ALIGNMENT, 1);
            s_gles2.glReadPixels(0, 0, m_width, m_height, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
            unbindFbo();
        }
        s_gles1.glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
        s_gles1.glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, m_width, m_height, 0,
                             GL_RGBA, GL_UNSIGNED_BYTE, pixels);
        ::free(pixels);
    }
    return true;
}

bool ColorBuffer::bindToRenderbuffer() {
    if (!m_eglImage) {
        return false;
    }
    RenderThreadInfo *tInfo = RenderThreadInfo::get();
    if (!tInfo->currContext.get()) {
        return false;
    }
    if (tInfo->currContext->isGL2()) {
        s_gles2.glEGLImageTargetRenderbufferStorageOES(GL_RENDERBUFFER_OES, m_eglImage);
    }
    else {
        s_gles1.glEGLImageTargetRenderbufferStorageOES(GL_RENDERBUFFER_OES, m_eglImage);
    }
    return true;
}

bool ColorBuffer::post(float rotation, float dx, float dy) {
    // NOTE: Do not call m_helper->setupContext() here!
    return m_helper->getTextureDraw()->draw(m_resizer->update(m_tex), rotation, dx, dy);
}

void ColorBuffer::readback(unsigned char* img) {
    ScopedHelperContext context(m_helper);
    if (!context.isOk()) {
        return;
    }
    if (bindFbo(&m_fbo, m_tex)) {
        int st = s_readback_bgra_state.load(std::memory_order_acquire);
        if (st == 0) {
            (void)s_gles2.glGetError();
            s_gles2.glReadPixels(
                    0, 0, m_width, m_height, GL_BGRA_EXT, GL_UNSIGNED_BYTE, img);
            if (s_gles2.glGetError() == GL_NO_ERROR) {
                s_readback_bgra_state.store(1, std::memory_order_release);
            } else {
                s_readback_bgra_state.store(-1, std::memory_order_release);
                s_gles2.glReadPixels(
                        0, 0, m_width, m_height, GL_RGBA, GL_UNSIGNED_BYTE, img);
            }
        } else {
            s_gles2.glReadPixels(
                    0, 0, m_width, m_height,
                    (st > 0) ? GL_BGRA_EXT : GL_RGBA,
                    GL_UNSIGNED_BYTE, img);
        }
        unbindFbo();
    }
}

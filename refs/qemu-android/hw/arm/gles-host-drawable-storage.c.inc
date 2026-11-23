/* SPDX-License-Identifier: GPL-2.0-or-later */

static int64_t gles_drawable_storage(uint32_t width, uint32_t height)
{
    GLint texture, renderbuffer, framebuffer;
    GLuint color = 0, depth = 0, stencil = 0, fbo = 0;
    GLenum error, status;
    /* Desktop snapshots predate this field; preserve their packed recipe. */
    GLenum depth_format = GL_DEPTH24_STENCIL8_EXT;
#ifdef GLES_HOST_EGL_ES
    depth_format = gh.drawable_depth_format;
#endif
    uint8_t *readback;
    uint64_t charged;
    bool mapped = false;
#ifdef GLES_HOST_AHB
    GLESAhb ahb = { .image = EGL_NO_IMAGE_KHR };
#endif

    if (!width || !height || width > 2048 || height > 2048) {
        gles_refuse("drawable:size:%ux%u", width, height);
        return gles_reject(GL_INVALID_VALUE);
    }
    gh.drawable_announced = true;
    if (width == gh.drawable_width && height == gh.drawable_height) return 0;
    if (!gles_charge_drawable(width, height, &charged)) {
        return gles_reject(GL_OUT_OF_MEMORY);
    }
    readback = g_try_malloc0_n((size_t)width * height, 4);
    if (!readback) {
        gles_charge(gles_charge_table(true),
                    gles_charge_key(GLES_CHARGE_DRAWABLE, 0, 0, 0), charged, NULL);
        gles_refuse("drawable:memory");
        return gles_reject(GL_OUT_OF_MEMORY);
    }

    gles_texture_begin();
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &texture);
    glGetIntegerv(GL_RENDERBUFFER_BINDING_EXT, &renderbuffer);
    glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &framebuffer);
    color = gles_private_name(glIsTexture);
    glBindTexture(GL_TEXTURE_2D, color);
#ifdef GLES_HOST_AHB
    /* CPU-mapped storage, so the present can skip glReadPixels (see gh.ahb). */
    mapped = !gles_no_iosurface && gles_ahb_attach(&ahb, width, height);
#elif defined(GLES_HOST_IOS_EAGL)
    /* Keep resized / landscape drawables on a matching IOSurface when
     * texImageIOSurface is supported, avoiding slow/driver-restricted glReadPixels. */
    gles_present_async_settle();
    mapped = !gles_no_iosurface &&
             gles_eagl_iosurface_bind(width, height, GL_TEXTURE_2D,
                                      GL_RGBA, GL_BGRA, GL_UNSIGNED_BYTE);
#endif
    if (!mapped) {
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height,
                     0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    }
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    gles_drawable_depth_allocate(depth_format, width, height,
                                &depth, &stencil);
    fbo = gles_private_name(glIsFramebufferEXT);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT,
                              GL_TEXTURE_2D, color, 0);
    gles_drawable_depth_attach(depth, stencil);
    status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
#if defined(GLES_HOST_AHB) || defined(GLES_HOST_IOS_EAGL)
    if (mapped && status != GL_FRAMEBUFFER_COMPLETE_EXT) {
        /* Accepted but not renderable: ordinary storage, read back as before. */
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height,
                     0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
#ifdef GLES_HOST_AHB
        gles_ahb_free(&ahb);
#endif
        mapped = false;
        status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
    }
#endif
    error = glGetError();
    if (error == GL_NO_ERROR && status != GL_FRAMEBUFFER_COMPLETE_EXT)
        error = GL_OUT_OF_MEMORY;
    if (error != GL_NO_ERROR) gles_refuse("drawable:storage:0x%x", error);
    if (error == GL_NO_ERROR) {
        if ((GLuint)texture == gh.tex) texture = color;
        renderbuffer = gles_drawable_depth_remap(renderbuffer, gh.depth, gh.stencil,
                                                 depth, stencil);
        if ((GLuint)framebuffer == gh.fbo) framebuffer = fbo;
        glDeleteTextures(1, &gh.tex);
        gles_drawable_depth_delete(gh.depth, gh.stencil);
        glDeleteFramebuffersEXT(1, &gh.fbo);
        g_free(gh.readback);
        gh.tex = color; gh.depth = depth; gh.stencil = stencil; gh.fbo = fbo;
        gh.readback = readback;
        gh.drawable_width = width; gh.drawable_height = height;
        gh.iosurface = mapped;
#ifdef GLES_HOST_AHB
        gles_ahb_free(&gh.ahb);
        gh.ahb = ahb;
#endif
        gh.fb_dirty = true;
        if (gh.fb_complete) g_hash_table_remove_all(gh.fb_complete);
        gh.depth_cleared_this_frame = false;
        gh.resized_frame_logged = false;
        gh.resized_frames_seen = 0;
    } else {
#ifdef GLES_HOST_AHB
        gles_ahb_free(&ahb);
#endif
        glDeleteTextures(1, &color);
        gles_drawable_depth_delete(depth, stencil);
        glDeleteFramebuffersEXT(1, &fbo);
        g_free(readback);
        gles_charge(gles_charge_table(true),
                    gles_charge_key(GLES_CHARGE_DRAWABLE, 0, 0, 0), charged, NULL);
    }
    glBindTexture(GL_TEXTURE_2D, texture);
    glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, renderbuffer);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, framebuffer);
    return error == GL_NO_ERROR ? 0 : gles_reject(error);
}

/* Native renderbuffers belong to the share group. A layer allocated in one
 * context can be attached and rendered in another; per-context surrogate
 * framebuffers cannot stand in for that shared storage. */
static void gles_refresh_drawable_binding(void)
{
    if (!gh.bound_framebuffer || !gh.fbo_drawable ||
        !g_hash_table_size(gh.fbo_drawable)) {
        return;
    }
    uint32_t rb = GPOINTER_TO_UINT(g_hash_table_lookup(
        gh.fbo_drawable, GUINT_TO_POINTER(gh.bound_framebuffer)));
    if (rb && g_hash_table_contains(gh.rb_sized, GUINT_TO_POINTER(rb))) {
        g_hash_table_remove(gh.fbo_drawable, GUINT_TO_POINTER(gh.bound_framebuffer));
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, gh.bound_framebuffer);
    }
}

static int64_t gles_layer_storage(uint32_t width, uint32_t height)
{
    int64_t result = gles_drawable_storage(width, height);
    if (result < 0) return result;
#if !defined(GLES_HOST_EAGL) || defined(GLES_HOST_IOS_EAGL)
    GLuint rb = gh.bound_renderbuffer;
    gh.drawable_renderbuffer = rb;
    if (rb) {
        GLint previous, w = 0, h = 0, format = 0;
        GHashTable *table = gles_charge_table(false);
        gpointer key = gles_charge_key(GLES_CHARGE_RENDERBUFFER, rb, 0, 0);
        uint64_t old;
        if (!gles_charge(table, key, (uint64_t)width * height * 4, &old)) {
            return gles_reject(GL_OUT_OF_MEMORY);
        }
        glGetIntegerv(GL_RENDERBUFFER_BINDING_EXT, &previous);
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, rb);
        glGetRenderbufferParameterivEXT(GL_RENDERBUFFER_EXT, GL_RENDERBUFFER_WIDTH_EXT, &w);
        glGetRenderbufferParameterivEXT(GL_RENDERBUFFER_EXT, GL_RENDERBUFFER_HEIGHT_EXT, &h);
        glGetRenderbufferParameterivEXT(GL_RENDERBUFFER_EXT, GL_RENDERBUFFER_INTERNAL_FORMAT_EXT, &format);
        gles_texture_begin();
        if (w != (GLint)width || h != (GLint)height || format != GL_RGBA8) {
            glRenderbufferStorageEXT(GL_RENDERBUFFER_EXT, GL_RGBA8, width, height);
        }
        GLenum error = glGetError();
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, previous);
        if (error) {
            gles_charge(table, key, old, NULL);
            return gles_reject(error);
        }
        g_hash_table_add(gh.rb_sized, GUINT_TO_POINTER(rb));
        gh.drawable_rb_width = width;
        gh.drawable_rb_height = height;
        if (gh.fb_complete) g_hash_table_remove_all(gh.fb_complete);
        gles_refresh_drawable_binding();
    }
#endif
    return 0;
}

static void gles_record_drawable_attachment(const uint32_t *a)
{
    if (!gh.bound_framebuffer) return;
#ifdef GLES_HOST_IOS_EAGL
    if (gles_eagl_host_api() >= 3) {
        GLint read, draw;
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, gh.bound_framebuffer);
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, a[1], GL_RENDERBUFFER_EXT, a[3]);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, read);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw);
        return;
    }
#endif
#ifndef GLES_HOST_EAGL
    GLint read, draw;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &draw);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, gh.bound_framebuffer);
    glFramebufferRenderbufferEXT(a[0], a[1], a[2], a[3]);
    glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, read);
    glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, draw);
#else
    GLint draw;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &draw);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, gh.bound_framebuffer);
    glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, a[1], GL_RENDERBUFFER_EXT, a[3]);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, draw);
#endif
}

static bool gles_resolve_drawable(void)
{
#if !defined(GLES_HOST_EAGL) || defined(GLES_HOST_IOS_EAGL)
    GLuint rb = gh.drawable_renderbuffer;
    if (!rb || !g_hash_table_contains(gh.rb_sized, GUINT_TO_POINTER(rb))) return true;
    GLint width = gh.drawable_rb_width, height = gh.drawable_rb_height;
    if (width <= 0 || height <= 0) {
        GLint bound = 0;
        glGetIntegerv(GL_RENDERBUFFER_BINDING_EXT, &bound);
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, rb);
        glGetRenderbufferParameterivEXT(GL_RENDERBUFFER_EXT, GL_RENDERBUFFER_WIDTH_EXT, &width);
        glGetRenderbufferParameterivEXT(GL_RENDERBUFFER_EXT, GL_RENDERBUFFER_HEIGHT_EXT, &height);
        glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, bound);
        if (width > 0 && height > 0) {
            gh.drawable_rb_width = width;
            gh.drawable_rb_height = height;
        }
    }
    if (width <= 0 || height <= 0 || gles_drawable_storage(width, height) < 0) return false;
#ifdef GLES_HOST_IOS_EAGL
    if (gles_eagl_host_api() < 3) {
        GLint fb, tex;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &fb);
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex);
        gles_texture_begin();
        if (!gh.resolve_fbo) gh.resolve_fbo = gles_private_name(glIsFramebufferEXT);
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, gh.resolve_fbo);
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT,
                                     GL_RENDERBUFFER_EXT, rb);
        glBindTexture(GL_TEXTURE_2D, gh.tex);
        glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, width, height);
        GLenum error = gles_strict ? glGetError() : GL_NO_ERROR;
        glBindTexture(GL_TEXTURE_2D, tex);
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fb);
        if (error) {
            gles_refuse("drawable:resolve:0x%x", error);
            gles_reject(error);
            return false;
        }
        return true;
    }
    {
        GLint read, draw;
        GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST), mask[4];
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &read);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &draw);
        glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        gles_texture_begin();
        if (!gh.resolve_fbo) gh.resolve_fbo = gles_private_name(glIsFramebufferEXT);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, gh.resolve_fbo);
        glFramebufferRenderbuffer(GL_READ_FRAMEBUFFER, GL_COLOR_ATTACHMENT0_EXT,
                                  GL_RENDERBUFFER_EXT, rb);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, gh.fbo);
        glDisable(GL_SCISSOR_TEST);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glBlitFramebuffer(0, 0, width, height, 0, 0, width, height,
                          GL_COLOR_BUFFER_BIT, GL_NEAREST);
        GLenum error = gles_strict ? glGetError() : GL_NO_ERROR;
        glColorMask(mask[0], mask[1], mask[2], mask[3]);
        if (scissor) glEnable(GL_SCISSOR_TEST);
        glBindFramebuffer(GL_READ_FRAMEBUFFER, read);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, draw);
        if (error) {
            gles_refuse("drawable:resolve:0x%x", error);
            gles_reject(error);
            return false;
        }
        return true;
    }
#else
    {
        GLint read, draw;
        GLboolean scissor = glIsEnabled(GL_SCISSOR_TEST), mask[4];
        glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read);
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &draw);
        glGetBooleanv(GL_COLOR_WRITEMASK, mask);
        gles_texture_begin();
        if (!gh.resolve_fbo) gh.resolve_fbo = gles_private_name(glIsFramebufferEXT);
        glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, gh.resolve_fbo);
        glFramebufferRenderbufferEXT(GL_READ_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT,
                                     GL_RENDERBUFFER_EXT, rb);
        glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, gh.fbo);
        glDisable(GL_SCISSOR_TEST);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glBlitFramebufferEXT(0, 0, width, height, 0, 0, width, height,
                             GL_COLOR_BUFFER_BIT, GL_NEAREST);
        GLenum error = gles_strict ? glGetError() : GL_NO_ERROR;
        glColorMask(mask[0], mask[1], mask[2], mask[3]);
        if (scissor) glEnable(GL_SCISSOR_TEST);
        glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, read);
        glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, draw);
        if (error) {
            gles_refuse("drawable:resolve:0x%x", error);
            gles_reject(error);
            return false;
        }
    }
#endif
#endif
    return true;
}

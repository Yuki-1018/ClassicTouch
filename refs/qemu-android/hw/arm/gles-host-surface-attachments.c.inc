/* SPDX-License-Identifier: GPL-2.0-or-later */

/* An attachment replacement ends writes to the OLD surface just as a framebuffer
 * bind does. Mark it before changing the attachment, but leave writeback at the
 * existing frame boundary: publishing here would expose an unfinished CA pass. */
    case GLES_SLOT_FB_RENDERBUFFER: {    /* target, attach, rbtarget, rb */
        uint32_t attach = a[1], rb = a[3];

        if (attach == GL_COLOR_ATTACHMENT0_EXT) {
            if (gles_sync_surface(cpu)) return -1;
            if (gh.fbo_color_tex) {
                g_hash_table_remove(gh.fbo_color_tex,
                                    GUINT_TO_POINTER(gh.bound_framebuffer));
            }
            /* A color renderbuffer that never got GL storage is the CA
             * drawable, so from now on this framebuffer MEANS gh.fbo. Any
             * other color attachment takes that meaning away again. */
            gles_set_drawable(gh.bound_framebuffer,
                              rb && !g_hash_table_contains(
                                  gh.rb_sized, GUINT_TO_POINTER(rb)) ? rb : 0);
        }
        gles_trace_attach("glFramebufferRenderbuffer", attach, rb);
        gh.fb_dirty = true;
        if (gh.fb_complete) {
            g_hash_table_remove(gh.fb_complete,
                                GUINT_TO_POINTER(gh.bound_framebuffer));
        }
        if (gles_is_drawable(gh.bound_framebuffer)) {
            if (gles_a6) {
                gles_record_drawable_attachment(a);
            }
            return 0;
        }
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, attach,
                                     GL_RENDERBUFFER_EXT, rb);
        return 0;
    }

    case GLES_SLOT_FB_TEXTURE_2D:        /* target, attach, textarget, tex, lvl */
        if (a[1] == GL_COLOR_ATTACHMENT0_EXT) {
            if (gles_sync_surface(cpu)) return -1;
            gles_set_drawable(gh.bound_framebuffer, 0);
            if (a[3]) {
                if (!gh.fbo_color_tex) {
                    gh.fbo_color_tex = g_hash_table_new(g_direct_hash, g_direct_equal);
                }
                g_hash_table_insert(gh.fbo_color_tex,
                                    GUINT_TO_POINTER(gh.bound_framebuffer),
                                    GUINT_TO_POINTER(a[3]));
            } else if (gh.fbo_color_tex) {
                g_hash_table_remove(gh.fbo_color_tex,
                                    GUINT_TO_POINTER(gh.bound_framebuffer));
            }
        }
        gles_trace_attach("glFramebufferTexture2D", a[1], a[3]);
        gh.fb_dirty = true;
        if (gh.fb_complete) {
            g_hash_table_remove(gh.fb_complete,
                                GUINT_TO_POINTER(gh.bound_framebuffer));
        }
        if (gles_is_drawable(gh.bound_framebuffer)) {
            return 0;
        }
        glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, a[1], a[2], a[3], a[4]);
        return 0;

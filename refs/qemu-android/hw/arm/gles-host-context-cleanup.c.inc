/* SPDX-License-Identifier: GPL-2.0-or-later */

static void gles_context_delete_objects(GLESHost *state)
{
#ifdef GLES_HOST_EGL
    if (CGLSetCurrentContext(state->cgl) != 0) {
        return;
    }
#else
    CGLSetCurrentContext(state->cgl);
#endif
#if !defined(GLES_HOST_EAGL) || defined(GLES_HOST_IOS_EAGL)
    gles_queries_free(state);
#endif
    glDeleteFramebuffersEXT(1, &state->fbo);
    if (state->sync_fbo) glDeleteFramebuffersEXT(1, &state->sync_fbo);
    if (state->copy_fbo) glDeleteFramebuffersEXT(1, &state->copy_fbo);
    if (state->resolve_fbo) glDeleteFramebuffersEXT(1, &state->resolve_fbo);
    if (state->fetch_barrier_fbo) glDeleteFramebuffersEXT(1, &state->fetch_barrier_fbo);
#if !defined(GLES_HOST_EAGL) && !defined(GLES_HOST_ANGLE)
    if (state->fetch_position_buffer) glDeleteBuffers(1, &state->fetch_position_buffer);
#endif
    glDeleteTextures(1, &state->tex);
    if (state->feedback_tex) glDeleteTextures(1, &state->feedback_tex);
    if (state->fetch_tex) glDeleteTextures(1, &state->fetch_tex);
    glDeleteRenderbuffersEXT(1, &state->depth);
#if defined(GLES_HOST_EGL_ES) || defined(GLES_HOST_IOS_EAGL)
    if (state->stencil && state->stencil != state->depth)
        glDeleteRenderbuffersEXT(1, &state->stencil);
#endif
    CGLSetCurrentContext(NULL);
}

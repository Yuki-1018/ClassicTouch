/*
* Copyright (C) 2011 The Android Open Source Project
* Licensed under the Apache License, Version 2.0
*/
#include "OpenGLESDispatch/EGLDispatch.h"

extern "C" void* eagl_ios_find_egl_symbol(const char* name);

EGLDispatch s_egl;

#define RENDER_EGL_LOAD_FIELD(return_type, function_name, signature) \
    s_egl. function_name = (function_name ## _t) eagl_ios_find_egl_symbol(#function_name);

#define RENDER_EGL_LOAD_OPTIONAL_FIELD(return_type, function_name, signature) \
    s_egl. function_name = (function_name ## _t) eagl_ios_find_egl_symbol(#function_name);

bool init_egl_dispatch()
{
    LIST_RENDER_EGL_FUNCTIONS(RENDER_EGL_LOAD_FIELD)
    LIST_RENDER_EGL_EXTENSIONS_FUNCTIONS(RENDER_EGL_LOAD_OPTIONAL_FIELD)
    return s_egl.eglGetDisplay != nullptr;
}

/*
* Copyright (C) 2011 The Android Open Source Project
* Licensed under the Apache License, Version 2.0
*/
#include "OpenGLESDispatch/GLESv1Dispatch.h"
#include <stdio.h>

extern "C" void* eagl_ios_find_gles1_symbol(const char* name);

static void gles1_unimplemented() {
    fprintf(stderr, "Called unimplemented GLESv1 API\n");
}

#define RETURN_void return
#define RETURN_GLboolean return GL_FALSE
#define RETURN_GLint return 0
#define RETURN_GLuint return 0U
#define RETURN_GLenum return 0
#define RETURN_int return 0
#define RETURN_GLconstubyteptr return NULL
#define RETURN_(x) RETURN_ ## x

#define DEFINE_DUMMY_FUNCTION(return_type, func_name, signature, args) \
static return_type gles1_dummy_##func_name signature { \
    RETURN_(return_type); \
}
#define DEFINE_DUMMY_EXTENSION_FUNCTION(return_type, func_name, signature, args) \
static return_type gles1_dummy_##func_name signature { \
    RETURN_(return_type); \
}

LIST_GLES1_FUNCTIONS(DEFINE_DUMMY_FUNCTION, DEFINE_DUMMY_EXTENSION_FUNCTION)

bool gles1_dispatch_init(GLESv1Dispatch* dispatch_table) {
#define LOOKUP_SYMBOL(return_type,function_name,signature,callargs) \
    do { \
        void* sym = eagl_ios_find_gles1_symbol(#function_name); \
        dispatch_table-> function_name = sym \
            ? reinterpret_cast< function_name ## _t >(sym) \
            : gles1_dummy_##function_name; \
    } while (0);

    LIST_GLES1_FUNCTIONS(LOOKUP_SYMBOL, LOOKUP_SYMBOL)
    return true;
}

void *gles1_dispatch_get_proc_func(const char *name, void *userData) {
    (void)userData;
    void* func = eagl_ios_find_gles1_symbol(name);
    return func ? func : (void*)gles1_unimplemented;
}

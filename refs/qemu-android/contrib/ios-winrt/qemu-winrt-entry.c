/*
 * Entry point for embedding `libqemu-winrt.dylib` inside ClassicTouch iOS,
 * backed by QEMU's ARM virt machine with Windows RT platform support.
 */

#include "qemu/osdep.h"
#include "qemu-main.h"
#include "qemu/main-loop.h"
#include "system/replay.h"
#include "system/system.h"
#include "qemu-winrt-ui.h"

int (*qemu_main)(void);

int qemu_winrt_main(int argc, char **argv)
{
    int status;

    fprintf(stderr, "[qemu-winrt] main argc=%d\n", argc);
    for (int i = 0; i < argc; i++) {
        fprintf(stderr, "[qemu-winrt] argv[%d]=%s\n", i,
                argv[i] ? argv[i] : "(null)");
    }

    qemu_init(argc, argv);
    qemu_winrt_ui_attach();
    status = qemu_main_loop();
    qemu_winrt_ui_detach();
    qemu_cleanup(status);
    bql_unlock();
    replay_mutex_unlock();
    return status;
}

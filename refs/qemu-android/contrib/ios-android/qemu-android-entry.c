/*
 * Entry point for embedding `libqemu-android.dylib` inside ClassicTouch iOS,
 * backed by the Goldfish (`android51`) Goldfish core.
 */

#include "qemu/osdep.h"
#include "hw/arm/android51/android51_host.h"
#include "qemu-android-ui.h"

extern const Android51Host *qemu_android_ui_host_callbacks(void);
extern void qemu_android_ui_vm_started(void);

int (*qemu_main)(void);

int qemu_android_main(int argc, char **argv)
{
    fprintf(stderr, "[qemu-android] android51 main argc=%d\n", argc);
    for (int i = 0; i < argc; i++) {
        fprintf(stderr, "[qemu-android] argv[%d]=%s\n", i,
                argv[i] ? argv[i] : "(null)");
    }
    qemu_android_ui_vm_started();
    return android51_host_run(argc, argv, qemu_android_ui_host_callbacks());
}

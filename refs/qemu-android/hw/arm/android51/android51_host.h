/*
 * Host ABI header for Android51 Goldfish engine.
 * Licensed under the terms of the GNU General Public License version 2 or later.
 */
#ifndef ANDROID51_HOST_H
#define ANDROID51_HOST_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ANDROID51_HOST_ABI 1

typedef struct Android51Event {
    uint16_t type, code;
    int32_t value;
} Android51Event;

typedef struct Android51Host {
    uint32_t abi, size;
    void *opaque;
    void (*frame)(void *, const uint8_t *, size_t, uint32_t, uint32_t, uint32_t, uint32_t);
    size_t (*input)(void *, Android51Event *, size_t);
    void (*pcm)(void *, const uint8_t *, size_t);
    void (*serial)(void *, const uint8_t *, size_t);
    void (*state)(void *, int); /* 1: init, 2: paused, 3: resumed, 4: stopped, 5: flush err */
} Android51Host;

int android51_host_prepare_graphics(unsigned width, unsigned height, char *error, size_t capacity);
int android51_host_run(int argc, char **argv, const Android51Host *host);
void android51_host_pause(bool paused);
void android51_host_stop(void);
uint64_t android51_host_metric(unsigned index);

void android51_host_frame(const uint8_t *, size_t, uint32_t, uint32_t, uint32_t, uint32_t);
void android51_host_gpu_frame(const uint8_t *, size_t, uint32_t, uint32_t, uint32_t, uint32_t);
void android51_host_pcm(const uint8_t *, size_t);
void android51_host_serial(const uint8_t *, size_t);

bool android51_input_event(uint16_t type, uint16_t code, int32_t value);
void android51_add_boot_property(const char *name, const char *value);
void android51_reset_boot_properties(void);
void android51_set_lcd_density(uint32_t dpi);
void android51_battery_set_status(int ac_online, int status, int level);

#ifdef __cplusplus
}
#endif

#endif

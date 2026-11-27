/*
 * In-process ADB transport over Goldfish qemud pipe.
 */
#ifndef ANDROID51_ADB_H
#define ANDROID51_ADB_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

bool android51_adb_connected(void);
void android51_adb_disconnect(void);
size_t android51_adb_read(uint8_t *, size_t);
size_t android51_adb_write(const uint8_t *, size_t);

#ifdef __cplusplus
}
#endif

void gf_adb_init(void);
bool gf_adb_take_disconnect(void);
void gf_adb_connect(bool);
size_t gf_adb_guest_send(const uint8_t *, size_t);
size_t gf_adb_guest_receive(uint8_t *, size_t);
size_t gf_adb_guest_writable(void);

#endif

#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *rw_addr;
    uint8_t *rx_addr;
    size_t size;
} IosJitDualMapping;

// Low-level trap routines from henge-brk.S
extern void *henge_brk_get_jit_mapping(void *addr, size_t len);
extern void henge_brk_jit_detach(void);
extern uint64_t henge_brk_probe(void);

// High-level JIT manager
void ios_jit_init_protection(void);
bool ios_jit_is_debugger_attached(void);
bool ios_jit_probe_stikdebug(void);
bool ios_jit_probe_stikdebug_timeout(uint32_t timeout_ms, bool *timed_out);
bool ios_jit_is_available(void);
bool ios_jit_is_available_detailed(uint32_t timeout_ms, bool *out_timed_out);
IosJitDualMapping ios_jit_allocate_dual_mapping(size_t size);
void ios_jit_release_dual_mapping(IosJitDualMapping *m);
void ios_jit_detach_stikdebug(void);

bool ios_jit_is_rx_rw_split(void);
void *ios_jit_alloc_region(size_t size);
void ios_jit_protect_write(void);
void ios_jit_protect_exec(void);

#ifdef __cplusplus
}
#endif

/*
 * OpenGL ES 1.1 / 2.0 high-level emulation -- host-side dispatch.
 *
 * Copyright (c) 2026 the qemu-ios contributors.
 */

#include "qemu/osdep.h"
#include "cpu.h"
#include "qemu/main-loop.h"
#include "qemu/rcu.h"
#include "accel/tcg/probe.h"
#include "accel/tcg/cpu-mmu-index.h"
#include "exec/target_page.h"
#include "exec/tlb-flags.h"
#include "hw/arm/guest-services/general.h"
#include "hw/arm/gles-present.h"

void (*gles_present_wait_hook)(void);

/* Serialize GL executor entry across MTTCG vCPUs (such as dual-core A6) while
 * supporting single-core boards whose plain QC_GLES calls enter without BQL.
 * Lock order when both are held: BQL -> gles_execution_lock. */
static QemuMutex gles_execution_lock;
static QemuCond gles_execution_cond;
static gsize gles_execution_once;
static bool gles_execution_busy;
static __thread bool gles_execution_owner;

static void gles_execution_init(void)
{
    if (g_once_init_enter(&gles_execution_once)) {
        qemu_mutex_init(&gles_execution_lock);
        qemu_cond_init(&gles_execution_cond);
        g_once_init_leave(&gles_execution_once, 1);
    }
}

static void gles_execution_enter(void)
{
    CPUState *self = current_cpu;

    assert(!gles_execution_owner);
    gles_execution_init();
    if (self) {
        qatomic_inc(&self->tlbi_quiescent);
        smp_mb();
    }
    qemu_mutex_lock(&gles_execution_lock);
    while (gles_execution_busy) {
        if (bql_locked()) {
            bql_unlock();
            qemu_cond_wait(&gles_execution_cond, &gles_execution_lock);
            qemu_mutex_unlock(&gles_execution_lock);
            bql_lock();
            qemu_mutex_lock(&gles_execution_lock);
        } else {
            qemu_cond_wait(&gles_execution_cond, &gles_execution_lock);
        }
    }
    gles_execution_busy = gles_execution_owner = true;
    qemu_mutex_unlock(&gles_execution_lock);
    if (self) {
        qatomic_dec(&self->tlbi_quiescent);
    }
}

static void gles_execution_leave(void)
{
    assert(gles_execution_owner);
    qemu_mutex_lock(&gles_execution_lock);
    gles_execution_busy = gles_execution_owner = false;
    qemu_cond_broadcast(&gles_execution_cond);
    qemu_mutex_unlock(&gles_execution_lock);
}

bool gles_native_begin(void)
{
    if (!gles_execution_owner || !bql_locked()) {
        return false;
    }
    bql_unlock();
    return true;
}

void gles_native_end(bool unlocked)
{
    if (unlocked) {
        bql_lock();
        assert(gles_execution_owner);
    }
}

/* Active request fault state: protected by gles_execution_lock (and glq
 * release/acquire for sync calls executed on glq_worker while the vCPU waits). */
static struct {
    bool armed, pending;
    MMUAccessType type;
    vaddr va;
    unsigned slot;
} gf_cur;

static __thread struct {
    vaddr last_va;
    unsigned repeats;
} gf_tls;

/*
 * Set on the GL worker thread while it runs a call the vCPU queued and moved on from
 * (gles-host-queue.c.inc): that call's guest memory was read ahead, on the vCPU, and
 * the worker reads it from there. The vCPU's faults are none of its business.
 */
__thread int (*gles_guest_rw_hook)(vaddr va, void *buf, size_t len, bool write);

bool gles_guest_fault_pending(void)
{
    return !gles_guest_rw_hook && gf_cur.pending;
}

bool guest_rw_ram(CPUState *cpu, uint64_t va, uint8_t *buf, size_t len, bool write)
{
    CPUArchState *env = cpu_env(cpu);
    MMUAccessType type = write ? MMU_DATA_STORE : MMU_DATA_LOAD;
    int idx = cpu_mmu_index(cpu, false);
    size_t done = 0;

    if (va + len - 1 < va || va + len - 1 > UINT32_MAX) {
        return false;
    }
    while (done < len) {
        vaddr p = va + done;
        size_t n = MIN(len - done, TARGET_PAGE_SIZE - (p & ~TARGET_PAGE_MASK));
        void *host;

        if (probe_access_flags(env, p, 0, type, idx, true, &host, 0) || !host) {
            return false;
        }
        if (write) {
            memcpy(host, buf + done, n);
        } else {
            memcpy(buf + done, host, n);
        }
        done += n;
    }
    return true;
}

int gles_guest_rw(CPUState *cpu, vaddr va, void *buf, size_t len, bool write)
{
    if (gles_guest_rw_hook) {
        return gles_guest_rw_hook(va, buf, len, write);
    }
    RCU_READ_LOCK_GUARD();
    if (len && !gf_cur.pending && guest_rw_ram(cpu, va, buf, len, write)) {
        return 0;
    }
    /* Probe every page at the caller's privilege first, armed or not: an unarmed
     * call (such as a batch) fails where the guest's own access would fault. */
    if (len) {
        CPUArchState *env = cpu_env(cpu);
        MMUAccessType type = write ? MMU_DATA_STORE : MMU_DATA_LOAD;
        int idx = cpu_mmu_index(cpu, false);
        vaddr p = va, last = va + len - 1;
        void *host;

        if (gf_cur.pending || last < va || last > UINT32_MAX) {
            return -1;
        }
        for (;;) {
            if (probe_access_flags(env, p, 0, type, idx, true, &host, 0) &
                TLB_INVALID_MASK) {
                if (!gf_cur.armed) {
                    return -1;
                }
                gf_cur.pending = true;
                gf_cur.va = p;
                gf_cur.type = type;
                return -1;
            }
            if ((p & TARGET_PAGE_MASK) == (last & TARGET_PAGE_MASK)) {
                break;
            }
            p = (p & TARGET_PAGE_MASK) + TARGET_PAGE_SIZE;
        }
    }
    return cpu_memory_rw_debug(cpu, va, buf, len, write);
}

static void gles_guest_fault_in(CPUState *cpu, bool pending, vaddr va,
                                MMUAccessType type, unsigned slot)
{
    if (!pending) {
        gf_tls.repeats = 0;
        return;
    }
    if (va != gf_tls.last_va) {
        gf_tls.last_va = va;
        gf_tls.repeats = 0;
    } else if (++gf_tls.repeats > 4) {
        if (gles_host_refuse("guest-read:fault-dropped")) {
            fprintf(stderr, "[gles] guest page 0x%08" PRIx64 " still not "
                    "accessible after 4 faults (slot %u, %s, page table: %s); call dropped\n",
                    (uint64_t)va, slot, type == MMU_DATA_STORE ? "store" : "load",
                    cpu_get_phys_page_debug(cpu, va) == -1 ? "unmapped" : "mapped");
        }
        gf_tls.repeats = 0;
        return;
    }
    /* Raises the data abort and does not return (unless it is mapped now). */
    probe_access(cpu_env(cpu), va, 1, type, cpu_mmu_index(cpu, false), 0);
}

static bool gles_null_render(void)
{
    static int on = -1;
    if (on < 0) {
        on = getenv("IT_GLES_NULL") != NULL;
    }
    return on;
}

#define GLES_MAX_SLOTS (GLES_OP_BASE + 16)
#define GLES_MAX_ARGS 12

static uint64_t gles_slot_calls[GLES_MAX_SLOTS];
static uint64_t gles_total_calls;
static uint64_t gles_bad_slots;

static int64_t gles_run_batch(CPUState *cpu, qc_gles_args_t *a)
{
    static uint32_t buf[GLES_BATCH_MAX_WORDS];
    uint32_t n = a->args[1], i = 0;

    if (a->argc != 2 || n > GLES_BATCH_MAX_WORDS ||
        gles_guest_rw(cpu, a->args[0], (uint8_t *)buf, n * 4, 0) != 0) {
        gles_bad_slots++;
        gles_host_refuse("bad-call:batch");
        return -1;
    }
    while (i < n) {
        uint32_t slot = buf[i] & 0xffff, argc = buf[i] >> 16;
        uint32_t args[GLES_MAX_ARGS] = { 0 };

        if (argc > GLES_MAX_ARGS || argc > n - i - 1 || slot >= GLES_OP_BASE) {
            gles_bad_slots++;
            gles_host_refuse("bad-call:batch-record");
            return -1;
        }
        memcpy(args, &buf[i + 1], argc * sizeof(uint32_t));
        gles_slot_calls[slot]++;
        gles_total_calls++;
        if (!gles_null_render()) {
            gles_host_call(cpu, slot, a->ctx, argc, args);
        }
        i += 1 + argc;
    }
    return 0;
}

static int64_t gles_handle_call(CPUState *cpu, qc_gles_args_t *a)
{
    if (a->slot == GLES_OP_BATCH) {
        return gles_run_batch(cpu, a);
    }
    if (a->slot >= GLES_MAX_SLOTS) {
        gles_bad_slots++;
        gles_host_refuse("bad-call:slot");
        return -1;
    }

    gles_slot_calls[a->slot]++;
    gles_total_calls++;

    if (gles_slot_calls[a->slot] == 1 && getenv("IT_GLES_VERBOSE")) {
        fprintf(stderr, "[gles] slot %u first call: ctx=0x%08x argc=%u "
                "spill=0x%08x args %08x %08x %08x %08x\n",
                a->slot, a->ctx, a->argc, a->spill,
                a->args[0], a->args[1], a->args[2], a->args[3]);
    }

    uint32_t args[GLES_MAX_ARGS];
    uint32_t argc = a->argc;

    if (argc > GLES_MAX_ARGS) {
        gles_bad_slots++;
        gles_host_refuse("bad-call:argc:%u", a->slot);
        return -1;
    }
    memset(args, 0, sizeof(args));
    gf_cur.armed = true;
    gf_cur.slot = a->slot;
    if (argc <= QC_GLES_INLINE_ARGS) {
        memcpy(args, a->args, argc * sizeof(uint32_t));
    } else {
        if (!a->spill) {
            gles_host_refuse("bad-call:no-spill:%u", a->slot);
            gf_cur.armed = false;
            return -1;
        }
        if (gles_guest_rw(cpu, a->spill, args, argc * sizeof(uint32_t),
                          false) != 0) {
            if (!gf_cur.pending) {
                gles_host_refuse("guest-read:spill:%u", a->slot);
            }
            return -1;
        }
    }

    if (gles_null_render()) {
        gf_cur.armed = false;
        return 0;
    }

    return gles_host_call(cpu, a->slot, a->ctx, argc, args);
}

int64_t qc_handle_gles(CPUState *cpu, qc_gles_args_t *a)
{
    gles_execution_enter();
    gf_cur.armed = gf_cur.pending = false;
    int64_t result = gles_handle_call(cpu, a);
    bool fault_pending = gf_cur.pending;
    vaddr fault_va = gf_cur.va;
    MMUAccessType fault_type = gf_cur.type;
    unsigned fault_slot = gf_cur.slot;
    gf_cur.armed = gf_cur.pending = false;
    gles_execution_leave();
    /* Release the renderer gate before raising a guest data abort (longjmp). */
    gles_guest_fault_in(cpu, fault_pending, fault_va, fault_type, fault_slot);
    return result;
}

void qc_gles_dump_stats(void)
{
    unsigned i;
    fprintf(stderr, "[gles] %" PRIu64 " calls total, %" PRIu64 " bad slots\n",
            gles_total_calls, gles_bad_slots);
    for (i = 0; i < GLES_MAX_SLOTS; i++) {
        if (gles_slot_calls[i]) {
            fprintf(stderr, "[gles]   slot %4u: %" PRIu64 "\n",
                    i, gles_slot_calls[i]);
        }
    }
}

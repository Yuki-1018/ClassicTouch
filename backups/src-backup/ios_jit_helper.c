#include "ios_jit_helper.h"
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <os/log.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <sys/ucontext.h>
#include <unistd.h>
#include <libkern/OSCacheControl.h>
#include <TargetConditionals.h>

#define STIKDEBUG_PROBE_MAGIC    0xE0000069ull
#define STIKDEBUG_PROBE_MAGIC_LE 0x690000E0ull
#define JIT_LOW_LIMIT            0x7000000000ull

#define JIT_LOG(fmt, ...) \
    do { \
        os_log(OS_LOG_DEFAULT, "[ClassicTouch-JIT] " fmt, ##__VA_ARGS__); \
        fprintf(stderr, "[ClassicTouch-JIT] " fmt "\n", ##__VA_ARGS__); \
        fflush(stderr); \
    } while (0)

static _Thread_local bool g_expecting_jit_trap = false;
static _Thread_local sigjmp_buf g_probe_fault_jmp;
static _Thread_local volatile sig_atomic_t g_probe_fault_armed = 0;
static struct sigaction g_prev_sigtrap;
static struct sigaction g_prev_sigbus;
static atomic_bool g_jit_ready = false;
static IosJitDualMapping g_active_mapping = {NULL, NULL, 0};
static pthread_once_t g_jit_init_once = PTHREAD_ONCE_INIT;

static pthread_mutex_t g_probe_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_probe_cond = PTHREAD_COND_INITIALIZER;
static bool g_probe_in_flight = false;
static uint64_t g_probe_seq = 0;
static uint64_t g_probe_done_seq = 0;
static bool g_probe_last_result = false;

static void jit_trap_handler(int sig, siginfo_t *info, void *ctx) {
    if (g_expecting_jit_trap && ctx != NULL) {
        ucontext_t *uc = (ucontext_t *)ctx;
#if defined(__aarch64__) || defined(__arm64__)
        /* Step over the 4-byte brk instruction and zero x0 (indicating no service) */
        uc->uc_mcontext->__ss.__pc += 4;
        uc->uc_mcontext->__ss.__x[0] = 0;
#endif
        return;
    }

    struct sigaction *prev = (sig == SIGTRAP) ? &g_prev_sigtrap : &g_prev_sigbus;
    if ((prev->sa_flags & SA_SIGINFO) && prev->sa_sigaction != NULL) {
        prev->sa_sigaction(sig, info, ctx);
        return;
    }
    if (!(prev->sa_flags & SA_SIGINFO) && prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN) {
        prev->sa_handler(sig);
        return;
    }
    sigaction(sig, prev, NULL);
    raise(sig);
}

static void jit_install_handlers_once(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sa.sa_sigaction = jit_trap_handler;
    sigemptyset(&sa.sa_mask);

    if (sigaction(SIGTRAP, &sa, &g_prev_sigtrap) != 0) {
        JIT_LOG("sigaction(SIGTRAP) failed: %s", strerror(errno));
    }
    if (sigaction(SIGBUS, &sa, &g_prev_sigbus) != 0) {
        JIT_LOG("sigaction(SIGBUS) failed: %s", strerror(errno));
    }
    JIT_LOG("Universal trap handler installed (SIGTRAP/SIGBUS guarded)");
}

void ios_jit_init_protection(void) {
    pthread_once(&g_jit_init_once, jit_install_handlers_once);
}

bool ios_jit_is_debugger_attached(void) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    info.kp_proc.p_flag = 0;
    if (sysctl(mib, 4, &info, &size, NULL, 0) == 0 && (info.kp_proc.p_flag & 0x00000800) != 0) {
        return true;
    }
    return false;
}

static void *jit_probe_worker(void *arg) {
    uint64_t seq = (uint64_t)(uintptr_t)arg;

    g_expecting_jit_trap = true;
    uint64_t probe = henge_brk_probe();
    g_expecting_jit_trap = false;

    bool ok = false;
    if (probe != 0) {
        uint32_t probe_lo = (uint32_t)probe;
        if (probe_lo == (uint32_t)STIKDEBUG_PROBE_MAGIC || probe_lo == (uint32_t)STIKDEBUG_PROBE_MAGIC_LE) {
            JIT_LOG("StikDebug active with Universal JIT Script! (probe: 0x%llx)", (unsigned long long)probe);
        } else {
            JIT_LOG("Debugger answered probe with non-standard value 0x%llx (active)", (unsigned long long)probe);
        }
        ok = true;
    } else {
        JIT_LOG("StikDebug probe returned 0: debugger not attached or script inactive");
    }

    pthread_mutex_lock(&g_probe_mutex);
    g_probe_last_result = ok;
    g_probe_done_seq = seq;
    g_probe_in_flight = false;
    pthread_cond_broadcast(&g_probe_cond);
    pthread_mutex_unlock(&g_probe_mutex);
    return NULL;
}

bool ios_jit_probe_stikdebug_timeout(uint32_t timeout_ms, bool *timed_out) {
    if (timed_out) *timed_out = false;
    ios_jit_init_protection();

    if (timeout_ms == 0) timeout_ms = 1200;

    pthread_mutex_lock(&g_probe_mutex);
    if (g_probe_in_flight) {
        // An earlier probe is still stalled inside a dead/unresponsive debugger trap; wait briefly instead of stacking threads.
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        uint32_t wait_ms = timeout_ms < 400 ? timeout_ms : 400;
        ts.tv_sec += wait_ms / 1000;
        ts.tv_nsec += (long)(wait_ms % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) {
            ts.tv_sec += 1;
            ts.tv_nsec -= 1000000000L;
        }
        while (g_probe_in_flight) {
            int wrc = pthread_cond_timedwait(&g_probe_cond, &g_probe_mutex, &ts);
            if (wrc == ETIMEDOUT) {
                pthread_mutex_unlock(&g_probe_mutex);
                JIT_LOG("StikDebug probe still stalled from previous unresponsive debugger session");
                if (timed_out) *timed_out = true;
                return false;
            }
        }
    }

    uint64_t seq = ++g_probe_seq;
    g_probe_in_flight = true;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t th;
    int rc = pthread_create(&th, &attr, jit_probe_worker, (void *)(uintptr_t)seq);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        g_probe_in_flight = false;
        pthread_mutex_unlock(&g_probe_mutex);
        return false;
    }

    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += timeout_ms / 1000;
    ts.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (ts.tv_nsec >= 1000000000L) {
        ts.tv_sec += 1;
        ts.tv_nsec -= 1000000000L;
    }

    while (g_probe_done_seq < seq) {
        int wrc = pthread_cond_timedwait(&g_probe_cond, &g_probe_mutex, &ts);
        if (wrc == ETIMEDOUT && g_probe_done_seq < seq) {
            pthread_mutex_unlock(&g_probe_mutex);
            JIT_LOG("StikDebug probe timed out after %u ms (debugger disconnected or hung)", timeout_ms);
            if (timed_out) *timed_out = true;
            return false;
        }
    }
    bool ok = g_probe_last_result;
    pthread_mutex_unlock(&g_probe_mutex);
    return ok;
}

bool ios_jit_probe_stikdebug(void) {
    return ios_jit_probe_stikdebug_timeout(1200, NULL);
}

static void jit_probe_fault_handler(int sig) {
    if (g_probe_fault_armed) {
        siglongjmp(g_probe_fault_jmp, 1);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

static bool jit_selftest_guarded(void *rx, void *rw, size_t size) {
    static const uint32_t kCode[2] = { 0x52800540u, 0xD65F03C0u };
    if (!rx || !rw || size < 16384) {
        return false;
    }

    struct sigaction sa, old_bus, old_segv, old_ill;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = jit_probe_fault_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGBUS, &sa, &old_bus);
    sigaction(SIGSEGV, &sa, &old_segv);
    sigaction(SIGILL, &sa, &old_ill);

    bool ok = false;
    g_probe_fault_armed = 1;
    if (sigsetjmp(g_probe_fault_jmp, 1) == 0) {
        memcpy(rw, kCode, sizeof(kCode));
        sys_icache_invalidate(rx, sizeof(kCode));
        uint32_t readback[2];
        memcpy(readback, rx, sizeof(readback));
        if (readback[0] == kCode[0] && readback[1] == kCode[1]) {
            int (*fn)(void) = (int (*)(void))rx;
            ok = (fn() == 42);
        }
    }
    g_probe_fault_armed = 0;

    sigaction(SIGBUS, &old_bus, NULL);
    sigaction(SIGSEGV, &old_segv, NULL);
    sigaction(SIGILL, &old_ill, NULL);
    return ok;
}

static bool jit_selftest(const IosJitDualMapping *m) {
    /* ARM64 assembly: movz w0, #42; ret */
    if (!m->rw_addr || !m->rx_addr || m->size < 16384) return false;
    bool ok = jit_selftest_guarded(m->rx_addr, m->rw_addr, m->size);
    if (ok) {
        JIT_LOG("Selftest PASSED: Executed generated code via RX alias! Result = 42");
    } else {
        JIT_LOG("Selftest failed: RX alias could not execute written code");
    }
    return ok;
}

static uint8_t *find_rw_alias_near(uint8_t *rx, size_t size) {
    vm_address_t rw = 0;
    vm_prot_t cur_prot = VM_PROT_NONE, max_prot = VM_PROT_NONE;
    kern_return_t kr = KERN_NO_SPACE;
    const uintptr_t step = 16u << 20;     // 16 MB steps
    const uintptr_t reach = (uintptr_t)2 << 30; // 2 GB reach for ADRP

    for (uintptr_t off = 0; off <= reach && kr != KERN_SUCCESS; off += step) {
        for (int side = 0; side < 2 && kr != KERN_SUCCESS; side++) {
            uintptr_t want = (side == 0) ? (uintptr_t)rx + size + off : (uintptr_t)rx - size - off;
            if (side == 1 && (uintptr_t)rx < size + off + step) continue;
            rw = (vm_address_t)want;
            kr = vm_remap(mach_task_self(), &rw, (vm_size_t)size, 0, VM_FLAGS_FIXED,
                          mach_task_self(), (vm_address_t)rx, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
        }
    }

    if (kr != KERN_SUCCESS) {
        rw = 0;
        kr = vm_remap(mach_task_self(), &rw, (vm_size_t)size, 0, VM_FLAGS_ANYWHERE,
                      mach_task_self(), (vm_address_t)rx, FALSE, &cur_prot, &max_prot, VM_INHERIT_NONE);
    }

    if (kr != KERN_SUCCESS) {
        JIT_LOG("vm_remap failed: %d (%s)", (int)kr, mach_error_string(kr));
        return NULL;
    }

    kr = vm_protect(mach_task_self(), rw, (vm_size_t)size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        JIT_LOG("vm_protect(RW) failed on alias: %d", (int)kr);
        vm_deallocate(mach_task_self(), rw, (vm_size_t)size);
        return NULL;
    }

    return (uint8_t *)rw;
}

IosJitDualMapping ios_jit_allocate_dual_mapping(size_t size) {
    IosJitDualMapping result = {NULL, NULL, 0};
    ios_jit_init_protection();

    size_t aligned_size = (size + 0x3FFF) & ~(size_t)0x3FFF;
    if (aligned_size < (16u << 20)) aligned_size = 16u << 20; // At least 16 MB

    // Route 1: StikDebug via BreakGetJITMapping
    if (ios_jit_probe_stikdebug()) {
        for (int attempt = 1; attempt <= 3; attempt++) {
            g_expecting_jit_trap = true;
            void *rx = henge_brk_get_jit_mapping(NULL, aligned_size);
            g_expecting_jit_trap = false;

            if (rx != NULL) {
                if ((uint64_t)(uintptr_t)rx + aligned_size <= JIT_LOW_LIMIT) {
                    uint8_t *rw = find_rw_alias_near((uint8_t *)rx, aligned_size);
                    if (rw != NULL) {
                        result.rw_addr = rw;
                        result.rx_addr = (uint8_t *)rx;
                        result.size = aligned_size;
                        if (jit_selftest(&result)) {
                            atomic_store(&g_jit_ready, true);
                            g_active_mapping = result;
                            JIT_LOG("StikDebug JIT dual mapping ready: rx=%p rw=%p (%zu MB)",
                                    rx, rw, aligned_size >> 20);
                            return result;
                        }
                        ios_jit_release_dual_mapping(&result);
                    }
                } else {
                    JIT_LOG("Allocated region returned above low limit (%p); deallocating", rx);
                    vm_deallocate(mach_task_self(), (vm_address_t)rx, aligned_size);
                }
            }
            usleep(50 * 1000);
        }
    }

    // Route 2: Self-granted MAP_JIT (TrollStore / entitlement mode)
    uint8_t *rx_map = mmap(NULL, aligned_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                           MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (rx_map != MAP_FAILED) {
        uint8_t *rw = find_rw_alias_near(rx_map, aligned_size);
        if (rw != NULL && vm_protect(mach_task_self(), (vm_address_t)rx_map, aligned_size, FALSE,
                                    VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS) {
            result.rw_addr = rw;
            result.rx_addr = rx_map;
            result.size = aligned_size;
            if (jit_selftest(&result)) {
                atomic_store(&g_jit_ready, true);
                g_active_mapping = result;
                JIT_LOG("MAP_JIT dual mapping ready: rx=%p rw=%p (%zu MB)", rx_map, rw, aligned_size >> 20);
                return result;
            }
            ios_jit_release_dual_mapping(&result);
        } else {
            if (rw) vm_deallocate(mach_task_self(), (vm_address_t)rw, aligned_size);
            munmap(rx_map, aligned_size);
        }
    }

    // Route 3: Plain memory with vm_protect (Jailbroken / CS_DEBUGGED mode)
    uint8_t *base = mmap(NULL, aligned_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (base != MAP_FAILED) {
        uint8_t *rw = find_rw_alias_near(base, aligned_size);
        if (rw != NULL && vm_protect(mach_task_self(), (vm_address_t)base, aligned_size, FALSE,
                                    VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS) {
            result.rw_addr = rw;
            result.rx_addr = base;
            result.size = aligned_size;
            if (jit_selftest(&result)) {
                atomic_store(&g_jit_ready, true);
                g_active_mapping = result;
                JIT_LOG("Plain debugged dual mapping ready: rx=%p rw=%p (%zu MB)", base, rw, aligned_size >> 20);
                return result;
            }
            ios_jit_release_dual_mapping(&result);
        } else {
            if (rw) vm_deallocate(mach_task_self(), (vm_address_t)rw, aligned_size);
            munmap(base, aligned_size);
        }
    }

    JIT_LOG("WARNING: No JIT method could be activated. Falling back to interpreter mode.");
    return result;
}

void ios_jit_release_dual_mapping(IosJitDualMapping *m) {
    if (!m) return;
    if (m->rw_addr) {
        vm_deallocate(mach_task_self(), (vm_address_t)m->rw_addr, (vm_size_t)m->size);
        m->rw_addr = NULL;
    }
    if (m->rx_addr) {
        vm_deallocate(mach_task_self(), (vm_address_t)m->rx_addr, (vm_size_t)m->size);
        m->rx_addr = NULL;
    }
    m->size = 0;
    atomic_store(&g_jit_ready, false);
}

void ios_jit_detach_stikdebug(void) {
    ios_jit_init_protection();
    g_expecting_jit_trap = true;
    henge_brk_jit_detach();
    g_expecting_jit_trap = false;
    JIT_LOG("Debugger detached cleanly; dual mappings retained");
}

bool ios_jit_is_rx_rw_split(void) {
    return atomic_load(&g_jit_ready);
}

bool ios_jit_is_available_detailed(uint32_t timeout_ms, bool *out_timed_out) {
    if (out_timed_out) *out_timed_out = false;
    if (ios_jit_is_rx_rw_split()) {
        return true;
    }

    bool timed_out = false;
    if (ios_jit_probe_stikdebug_timeout(timeout_ms, &timed_out)) {
        return true;
    }
    if (timed_out) {
        if (out_timed_out) *out_timed_out = true;
        return false;
    }

    // Check P_TRACED (AltJIT / SideJITServer / Xcode / lldb responding normally without universal.js)
    if (ios_jit_is_debugger_attached()) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
        if (__builtin_available(iOS 26, *)) {
            // Under iOS 26+ TXM, a debugger must handle BreakpointJIT traps cleanly.
            return false;
        }
#endif
        return true;
    }

#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (__builtin_available(iOS 26, *)) {
        // Under iOS 26+ TXM, only an attached debugger (checked above) can bless JIT pages.
        return false;
    }
#endif

    // Check TrollStore / Jailbreak / Entitlement dual-mapping RX+RW capability
    size_t page_size = 16384;
    void *test_rx = mmap(NULL, page_size, PROT_READ | PROT_WRITE | PROT_EXEC,
                         MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (test_rx != MAP_FAILED) {
        uint8_t *test_rw = find_rw_alias_near((uint8_t *)test_rx, page_size);
        bool ok = false;
        if (test_rw != NULL &&
            vm_protect(mach_task_self(), (vm_address_t)test_rx, page_size, FALSE,
                       VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS) {
            ok = jit_selftest_guarded(test_rx, test_rw, page_size);
        }
        if (test_rw) {
            vm_deallocate(mach_task_self(), (vm_address_t)test_rw, page_size);
        }
        munmap(test_rx, page_size);
        if (ok) {
            return true;
        }
    }

    void *test_anon = mmap(NULL, page_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (test_anon != MAP_FAILED) {
        uint8_t *test_rw = find_rw_alias_near((uint8_t *)test_anon, page_size);
        bool ok = false;
        if (test_rw != NULL &&
            vm_protect(mach_task_self(), (vm_address_t)test_anon, page_size, FALSE,
                       VM_PROT_READ | VM_PROT_EXECUTE) == KERN_SUCCESS) {
            ok = jit_selftest_guarded(test_anon, test_rw, page_size);
        }
        if (test_rw) {
            vm_deallocate(mach_task_self(), (vm_address_t)test_rw, page_size);
        }
        munmap(test_anon, page_size);
        if (ok) {
            return true;
        }
    }
    return false;
}

bool ios_jit_is_available(void) {
    return ios_jit_is_available_detailed(1200, NULL);
}

void *ios_jit_alloc_region(size_t size) {
    IosJitDualMapping m = ios_jit_allocate_dual_mapping(size);
    return m.rx_addr;
}

void ios_jit_protect_write(void) {
    // Dual mapped memory does not require toggling permissions because RW view is always writable!
}

void ios_jit_protect_exec(void) {
    // Dual mapped memory does not require toggling permissions because RX view is always executable!
}

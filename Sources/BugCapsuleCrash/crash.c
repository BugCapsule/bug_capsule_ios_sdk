// Async-signal-safe crash writer. See BugCapsuleCrash.h.
//
// Rules for everything reachable from `bc_signal_handler` and the Mach
// exception thread after a crash: no malloc, no locks, no Objective-C or
// Swift, no stdio. Only open/write/close, time, nanosleep, sigaction, raise,
// vm_read_overwrite, thread_get_state and mach_msg, on buffers allocated
// before the crash.
#include "BugCapsuleCrash.h"

#include <TargetConditionals.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define BC_PATH_MAX 1024
#define BC_CONTEXT_MAX (128 * 1024)
#define BC_IMAGES_MAX (256 * 1024)
#define BC_ALTSTACK_SIZE (64 * 1024)

static const int bc_signals[] = {SIGABRT, SIGBUS, SIGFPE, SIGILL, SIGSEGV, SIGTRAP, SIGSYS};
#define BC_SIGNAL_COUNT ((int)(sizeof(bc_signals) / sizeof(bc_signals[0])))

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_installed = 0;
static char g_path[BC_PATH_MAX];
static struct sigaction g_previous[BC_SIGNAL_COUNT];
static stack_t g_altstack;

// Double-buffered so a crash never reads a half-copied context.
static char g_context[2][BC_CONTEXT_MAX];
static size_t g_context_len[2];
static int g_context_slot = -1;
static char g_images[2][BC_IMAGES_MAX];
static size_t g_images_len[2];
static int g_images_slot = -1;

static int g_handling = 0;  // a thread is writing the report
static int g_written = 0;   // the report for this crash exists
static int g_suppress = 0;
static uintptr_t g_frames[BC_CRASH_MAX_FRAMES];

// MARK: - stack walking

static uintptr_t bc_strip(uintptr_t p) {
#if defined(__arm64__) || defined(__aarch64__)
#if TARGET_OS_OSX
    return p & 0x00007FFFFFFFFFFFULL;
#else
    // Pointer-authentication bits of arm64e return addresses.
    return p & 0x0000000FFFFFFFFFULL;
#endif
#else
    return p;
#endif
}

/// Frame-pointer walk. Every read goes through vm_read_overwrite, so a
/// corrupt chain stops the walk instead of faulting again.
static int bc_walk(uintptr_t pc, uintptr_t fp, uintptr_t *out, int max) {
    int n = 0;
    if (pc != 0 && n < max) out[n++] = bc_strip(pc);
    mach_port_t task = mach_task_self();
    for (int guard = 0; n < max && fp != 0 && guard < 4096; guard++) {
        if ((fp & (sizeof(uintptr_t) - 1)) != 0) break;
        uintptr_t record[2] = {0, 0};
        vm_size_t got = 0;
        if (vm_read_overwrite(task, (vm_address_t)fp, sizeof(record), (vm_address_t)record, &got) != KERN_SUCCESS ||
            got != sizeof(record))
            break;
        uintptr_t ret = bc_strip(record[1]);
        if (ret == 0) break;
        out[n++] = ret;
        if (record[0] <= fp) break;  // the stack grows down: callers live higher
        fp = record[0];
    }
    return n;
}

static void bc_thread_registers(thread_t thread, uintptr_t *pc, uintptr_t *fp) {
    *pc = 0;
    *fp = 0;
#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) return;
    *pc = (uintptr_t)arm_thread_state64_get_pc(state);
    *fp = (uintptr_t)arm_thread_state64_get_fp(state);
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) return;
    *pc = (uintptr_t)state.__rip;
    *fp = (uintptr_t)state.__rbp;
#endif
}

int bc_thread_backtrace(uint32_t thread_port, uintptr_t *frames, int max_frames) {
    if (thread_port == 0 || frames == NULL || max_frames <= 0) return 0;
    if (thread_port == pthread_mach_thread_np(pthread_self())) return 0;
    if (thread_suspend(thread_port) != KERN_SUCCESS) return 0;
    uintptr_t pc, fp;
    bc_thread_registers(thread_port, &pc, &fp);
    int n = bc_walk(pc, fp, frames, max_frames);
    thread_resume(thread_port);
    return n;
}

uint32_t bc_current_thread_port(void) { return pthread_mach_thread_np(pthread_self()); }

bool bc_debugger_attached(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return false;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// MARK: - report writing

static void bc_write_all(int fd, const char *bytes, size_t length) {
    while (length > 0) {
        ssize_t n = write(fd, bytes, length);
        if (n <= 0) return;
        bytes += n;
        length -= (size_t)n;
    }
}

static void bc_write_str(int fd, const char *s) { bc_write_all(fd, s, strlen(s)); }

static void bc_write_hex(int fd, uint64_t v) {
    char buf[18];
    int i = 18;
    do {
        buf[--i] = "0123456789abcdef"[v & 0xF];
        v >>= 4;
    } while (v != 0 && i > 2);
    buf[--i] = 'x';
    buf[--i] = '0';
    bc_write_all(fd, buf + i, (size_t)(18 - i));
}

static void bc_write_dec(int fd, int64_t v) {
    char buf[21];
    int i = 21;
    uint64_t u = v < 0 ? (uint64_t)(-(v + 1)) + 1 : (uint64_t)v;
    do {
        buf[--i] = (char)('0' + (u % 10));
        u /= 10;
    } while (u != 0 && i > 1);
    if (v < 0) buf[--i] = '-';
    bc_write_all(fd, buf + i, (size_t)(21 - i));
}

static void bc_write_line(int fd, const char *key, int64_t value) {
    bc_write_str(fd, key);
    bc_write_str(fd, " ");
    bc_write_dec(fd, value);
    bc_write_str(fd, "\n");
}

static void bc_write_blob(int fd, const char *key, const char *slots, size_t slot_size, const size_t *lengths, int *active) {
    int slot = __atomic_load_n(active, __ATOMIC_ACQUIRE);
    if (slot < 0) return;
    size_t length = lengths[slot];
    bc_write_line(fd, key, (int64_t)length);
    bc_write_all(fd, slots + (size_t)slot * slot_size, length);
    bc_write_str(fd, "\n");
}

static void bc_write_report(const char *kind, int sig, int code, uintptr_t addr, int exception, int64_t exc_code,
                            int64_t exc_subcode, const uintptr_t *frames, int count) {
    int fd = open(g_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    bc_write_str(fd, "BCCRASH 1\nkind ");
    bc_write_str(fd, kind);
    bc_write_str(fd, "\n");
    bc_write_line(fd, "signal", sig);
    bc_write_line(fd, "code", code);
    bc_write_str(fd, "addr ");
    bc_write_hex(fd, addr);
    bc_write_str(fd, "\n");
    bc_write_line(fd, "exception", exception);
    bc_write_str(fd, "exceptionCode ");
    bc_write_hex(fd, (uint64_t)exc_code);
    bc_write_str(fd, "\nexceptionSubcode ");
    bc_write_hex(fd, (uint64_t)exc_subcode);
    bc_write_str(fd, "\n");
    bc_write_line(fd, "time", (int64_t)time(NULL));
    bc_write_line(fd, "suppressed", __atomic_load_n(&g_suppress, __ATOMIC_ACQUIRE));
    for (int i = 0; i < count; i++) {
        bc_write_str(fd, "frame ");
        bc_write_hex(fd, frames[i]);
        bc_write_str(fd, "\n");
    }
    bc_write_blob(fd, "context", &g_context[0][0], BC_CONTEXT_MAX, g_context_len, &g_context_slot);
    bc_write_blob(fd, "images", &g_images[0][0], BC_IMAGES_MAX, g_images_len, &g_images_slot);
    bc_write_str(fd, "end\n");
    close(fd);
}

// MARK: - context buffers (not called from handlers)

static void bc_set_slot(char *slots, size_t slot_size, size_t *lengths, int *active, const char *bytes, size_t length) {
    if (bytes == NULL || length > slot_size) return;
    pthread_mutex_lock(&g_lock);
    int current = __atomic_load_n(active, __ATOMIC_ACQUIRE);
    int next = current == 0 ? 1 : 0;
    memcpy(slots + (size_t)next * slot_size, bytes, length);
    lengths[next] = length;
    __atomic_store_n(active, next, __ATOMIC_RELEASE);
    pthread_mutex_unlock(&g_lock);
}

void bc_crash_set_context(const char *bytes, size_t length) {
    bc_set_slot(&g_context[0][0], BC_CONTEXT_MAX, g_context_len, &g_context_slot, bytes, length);
}

void bc_crash_set_images(const char *bytes, size_t length) {
    bc_set_slot(&g_images[0][0], BC_IMAGES_MAX, g_images_len, &g_images_slot, bytes, length);
}

void bc_crash_suppress_next_event(void) { __atomic_store_n(&g_suppress, 1, __ATOMIC_RELEASE); }

// MARK: - signals

static void bc_restore_signal_handlers(void) {
    for (int i = 0; i < BC_SIGNAL_COUNT; i++) sigaction(bc_signals[i], &g_previous[i], NULL);
}

static void bc_signal_handler(int sig, siginfo_t *info, void *context) {
    if (__atomic_exchange_n(&g_handling, 1, __ATOMIC_SEQ_CST) == 0) {
        if (!__atomic_load_n(&g_written, __ATOMIC_ACQUIRE)) {
            uintptr_t pc = 0, fp = 0;
            ucontext_t *uc = (ucontext_t *)context;
            if (uc != NULL && uc->uc_mcontext != NULL) {
#if defined(__arm64__) || defined(__aarch64__)
                pc = (uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
                fp = (uintptr_t)arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
#elif defined(__x86_64__)
                pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
                fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
#endif
            }
            int n = bc_walk(pc, fp, g_frames, BC_CRASH_MAX_FRAMES);
            bc_write_report("signal", sig, info ? info->si_code : 0, info ? (uintptr_t)info->si_addr : 0, 0, 0, 0,
                            g_frames, n);
            __atomic_store_n(&g_written, 1, __ATOMIC_RELEASE);
        }
    } else {
        // Another thread is writing the report: give it a moment.
        for (int i = 0; i < 100 && !__atomic_load_n(&g_written, __ATOMIC_ACQUIRE); i++) {
            struct timespec ts = {0, 10 * 1000 * 1000};
            nanosleep(&ts, NULL);
        }
    }
    // Chain: the previous handler (or the default action) runs when the
    // re-raised signal is delivered after this handler returns.
    bc_restore_signal_handlers();
    raise(sig);
}

// MARK: - Mach exceptions

#define BC_EXC_MASK (EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC | EXC_MASK_BREAKPOINT)

#pragma pack(4)
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t ndr;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    int64_t code[2];
    char padding[512];
} bc_exc_request;

typedef struct {
    mach_msg_header_t header;
    NDR_record_t ndr;
    kern_return_t ret_code;
} bc_exc_reply;
#pragma pack()

static int g_mach = 0;
static mach_port_t g_exc_port = MACH_PORT_NULL;
static pthread_t g_exc_thread;
static exception_mask_t g_prev_masks[EXC_TYPES_COUNT];
static mach_port_t g_prev_ports[EXC_TYPES_COUNT];
static exception_behavior_t g_prev_behaviors[EXC_TYPES_COUNT];
static thread_state_flavor_t g_prev_flavors[EXC_TYPES_COUNT];
static mach_msg_type_number_t g_prev_count = 0;

static void bc_restore_exception_ports(void) {
    task_t task = mach_task_self();
    for (mach_msg_type_number_t i = 0; i < g_prev_count; i++) {
        task_set_exception_ports(task, g_prev_masks[i], g_prev_ports[i], g_prev_behaviors[i], g_prev_flavors[i]);
    }
}

static void *bc_exception_thread(void *arg) {
    (void)arg;
    pthread_setname_np("com.bugcapsule.mach-exception");
    for (;;) {
        bc_exc_request request;
        memset(&request, 0, sizeof(request));
        kern_return_t kr = mach_msg(&request.header, MACH_RCV_MSG | MACH_RCV_LARGE, 0, sizeof(request), g_exc_port,
                                    MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != KERN_SUCCESS) {
            if (kr == MACH_RCV_INVALID_NAME || kr == MACH_RCV_PORT_DIED || kr == MACH_RCV_PORT_CHANGED) return NULL;
            continue;
        }
        if (__atomic_exchange_n(&g_handling, 1, __ATOMIC_SEQ_CST) == 0) {
            if (!__atomic_load_n(&g_written, __ATOMIC_ACQUIRE)) {
                uintptr_t pc, fp;
                bc_thread_registers(request.thread.name, &pc, &fp);
                int n = bc_walk(pc, fp, g_frames, BC_CRASH_MAX_FRAMES);
                int64_t code = request.code_count > 0 ? request.code[0] : 0;
                int64_t subcode = request.code_count > 1 ? request.code[1] : 0;
                bc_write_report("mach", 0, 0, (uintptr_t)subcode, request.exception, code, subcode, g_frames, n);
                __atomic_store_n(&g_written, 1, __ATOMIC_RELEASE);
            }
            // The signal handler runs next (it sees the report and chains).
            __atomic_store_n(&g_handling, 0, __ATOMIC_SEQ_CST);
        }
        // Hand the exception on: previous ports for later exceptions, and
        // KERN_FAILURE so the kernel raises the matching Unix signal now.
        bc_restore_exception_ports();
        bc_exc_reply reply;
        memset(&reply, 0, sizeof(reply));
        reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(request.header.msgh_bits), 0);
        reply.header.msgh_remote_port = request.header.msgh_remote_port;
        reply.header.msgh_local_port = MACH_PORT_NULL;
        reply.header.msgh_size = sizeof(reply);
        reply.header.msgh_id = request.header.msgh_id + 100;
        reply.ndr = NDR_record;
        reply.ret_code = KERN_FAILURE;
        mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        return NULL;
    }
}

static int bc_install_mach(void) {
    task_t task = mach_task_self();
    g_prev_count = EXC_TYPES_COUNT;
    if (task_get_exception_ports(task, BC_EXC_MASK, g_prev_masks, &g_prev_count, g_prev_ports, g_prev_behaviors,
                                 g_prev_flavors) != KERN_SUCCESS) {
        g_prev_count = 0;
        return -1;
    }
    if (mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &g_exc_port) != KERN_SUCCESS) return -1;
    if (mach_port_insert_right(task, g_exc_port, g_exc_port, MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_mod_refs(task, g_exc_port, MACH_PORT_RIGHT_RECEIVE, -1);
        g_exc_port = MACH_PORT_NULL;
        return -1;
    }
    if (pthread_create(&g_exc_thread, NULL, bc_exception_thread, NULL) != 0) {
        mach_port_deallocate(task, g_exc_port);
        mach_port_mod_refs(task, g_exc_port, MACH_PORT_RIGHT_RECEIVE, -1);
        g_exc_port = MACH_PORT_NULL;
        return -1;
    }
    pthread_detach(g_exc_thread);
    if (task_set_exception_ports(task, BC_EXC_MASK, g_exc_port,
                                 (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
                                 THREAD_STATE_NONE) != KERN_SUCCESS) {
        mach_port_deallocate(task, g_exc_port);
        mach_port_mod_refs(task, g_exc_port, MACH_PORT_RIGHT_RECEIVE, -1);
        g_exc_port = MACH_PORT_NULL;
        return -1;
    }
    g_mach = 1;
    return 0;
}

// MARK: - install

int bc_crash_install(const char *report_path, bool mach_exceptions) {
    if (report_path == NULL || strlen(report_path) >= BC_PATH_MAX) return -1;
    pthread_mutex_lock(&g_lock);
    strlcpy(g_path, report_path, sizeof(g_path));
    int result = 0;
    if (!g_installed) {
        // Stack overflows on this (main) thread still get a stack to run on.
        g_altstack.ss_sp = malloc(BC_ALTSTACK_SIZE);
        if (g_altstack.ss_sp != NULL) {
            g_altstack.ss_size = BC_ALTSTACK_SIZE;
            g_altstack.ss_flags = 0;
            sigaltstack(&g_altstack, NULL);
        }
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_sigaction = bc_signal_handler;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK;
        sigemptyset(&action.sa_mask);
        for (int i = 0; i < BC_SIGNAL_COUNT; i++) {
            if (sigaction(bc_signals[i], &action, &g_previous[i]) != 0) result = -1;
        }
        g_installed = 1;
    }
    if (mach_exceptions && !g_mach && !bc_debugger_attached()) bc_install_mach();
    pthread_mutex_unlock(&g_lock);
    return result;
}

void bc_crash_uninstall(void) {
    pthread_mutex_lock(&g_lock);
    if (g_installed) {
        bc_restore_signal_handlers();
        g_installed = 0;
    }
    if (g_mach) {
        bc_restore_exception_ports();
        // Releasing the receive right ends the exception thread.
        mach_port_deallocate(mach_task_self(), g_exc_port);
        mach_port_mod_refs(mach_task_self(), g_exc_port, MACH_PORT_RIGHT_RECEIVE, -1);
        g_exc_port = MACH_PORT_NULL;
        g_mach = 0;
    }
    __atomic_store_n(&g_handling, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_written, 0, __ATOMIC_SEQ_CST);
    __atomic_store_n(&g_suppress, 0, __ATOMIC_SEQ_CST);
    pthread_mutex_unlock(&g_lock);
}

int bc_crash_is_installed(void) { return g_installed; }

int bc_crash_mach_installed(void) { return g_mach; }

int bc_crash_write_test_report(int sig) {
    if (g_path[0] == 0) return -1;
    uintptr_t frames[BC_CRASH_MAX_FRAMES];
    int n = bc_walk(0, (uintptr_t)__builtin_frame_address(0), frames, BC_CRASH_MAX_FRAMES);
    bc_write_report("signal", sig, 0, 0, 0, 0, 0, frames, n);
    return 0;
}

// Async-signal-safe crash writer. See BugCapsuleCrash.h.
//
// Rules for everything reachable from `bc_signal_handler` and the Mach
// exception thread after a crash: no malloc, no locks, no Objective-C or
// Swift, no stdio. Only open/write/close, time, nanosleep, sigaction, raise,
// vm_read_overwrite and Mach thread calls (task_threads, thread_suspend,
// thread_resume, thread_get_state, thread_info, mach_msg), on buffers
// allocated before the crash.
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
#define BC_CONTEXT_MAX BC_CRASH_CONTEXT_MAX
#define BC_IMAGES_MAX (256 * 1024)
#define BC_ALTSTACK_SIZE (64 * 1024)
#define BC_RELEASE_MAX 512
#define BC_ENVIRONMENT_MAX 128
#define BC_SUSPEND_MAX 1024

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
static char g_release[2][BC_RELEASE_MAX];
static size_t g_release_len[2];
static int g_release_slot = -1;
static char g_environment[2][BC_ENVIRONMENT_MAX];
static size_t g_environment_len[2];
static int g_environment_slot = -1;

static int g_handling = 0;  // a thread is writing the report
static int g_written = 0;   // the report for this crash exists
static int g_suppress = 0;
static uintptr_t g_frames[BC_CRASH_MAX_FRAMES];
static bc_thread_sample g_threads[BC_CRASH_MAX_THREADS];
static int g_thread_count = 0;
static char g_suspended[BC_SUSPEND_MAX];
static thread_t g_main_thread = MACH_PORT_NULL;
static thread_t g_exc_thread_port = MACH_PORT_NULL;

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

typedef struct {
    uintptr_t pc;
    uintptr_t fp;
    uintptr_t lr;  // arm64 only (0 elsewhere)
} bc_regs;

static int bc_thread_regs(thread_t thread, bc_regs *r) {
    r->pc = r->fp = r->lr = 0;
#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) return -1;
    r->pc = (uintptr_t)arm_thread_state64_get_pc(state);
    r->fp = (uintptr_t)arm_thread_state64_get_fp(state);
    r->lr = (uintptr_t)arm_thread_state64_get_lr(state);
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) return -1;
    r->pc = (uintptr_t)state.__rip;
    r->fp = (uintptr_t)state.__rbp;
#endif
    return 0;
}

static void bc_context_regs(void *context, bc_regs *r) {
    r->pc = r->fp = r->lr = 0;
    ucontext_t *uc = (ucontext_t *)context;
    if (uc == NULL || uc->uc_mcontext == NULL) return;
#if defined(__arm64__) || defined(__aarch64__)
    r->pc = (uintptr_t)arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
    r->fp = (uintptr_t)arm_thread_state64_get_fp(uc->uc_mcontext->__ss);
    r->lr = (uintptr_t)arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
#elif defined(__x86_64__)
    r->pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
    r->fp = (uintptr_t)uc->uc_mcontext->__ss.__rbp;
#endif
}

/// Whether `lr` returns into the caller of the function that contains `pc`
/// (`insn` is the arm64 instruction at lr - 4). A direct `bl` must target
/// the start of that function: at or below pc, with lr outside
/// [target, pc] (a return address inside that range is a call the
/// crashing function itself made).
static int bc_lr_is_caller(uintptr_t pc, uintptr_t lr, uint32_t insn) {
    if ((insn & 0xFC000000u) == 0x94000000u) {  // BL imm26
        int64_t imm = (int64_t)(insn & 0x03FFFFFFu);
        if (imm & 0x02000000) imm -= 0x04000000;
        uintptr_t target = (uintptr_t)((int64_t)(lr - 4) + imm * 4);
        return target <= pc && !(lr >= target && lr <= pc);
    }
    if ((insn & 0xFFFFFC1Fu) == 0xD63F0000u) return 1;  // BLR Xn
    if ((insn & 0xFEFFF800u) == 0xD63F0800u) return 1;  // BLRAA / BLRAB (Z)
    return 0;
}

int bc_insert_link_register(uintptr_t pc, uintptr_t lr, uintptr_t *frames, int count, int max_frames) {
    if (frames == NULL || count < 1 || max_frames < 2 || count > max_frames) return count;
    pc = bc_strip(pc);
    lr = bc_strip(lr);
    if (lr < 4 || lr == pc || (lr & 3) != 0) return count;
    if (count > 1 && frames[1] == lr) return count;
    uint32_t insn = 0;
    vm_size_t got = 0;
    if (vm_read_overwrite(mach_task_self(), (vm_address_t)(lr - 4), sizeof(insn), (vm_address_t)&insn, &got) !=
            KERN_SUCCESS ||
        got != sizeof(insn))
        return count;
    if (!bc_lr_is_caller(pc, lr, insn)) return count;
    int n = count < max_frames ? count + 1 : max_frames;
    for (int i = n - 1; i > 1; i--) frames[i] = frames[i - 1];
    frames[1] = lr;
    return n;
}

/// Frame-pointer walk plus, on arm64, the link register as the first
/// caller when the pc is in a leaf function (no frame record of its own).
static int bc_walk_regs(const bc_regs *r, uintptr_t *out, int max) {
    int n = bc_walk(r->pc, r->fp, out, max);
#if defined(__arm64__) || defined(__aarch64__)
    n = bc_insert_link_register(r->pc, r->lr, out, n, max);
#endif
    return n;
}

static void bc_thread_name(thread_t thread, char *out, size_t size) {
    out[0] = 0;
    thread_extended_info_data_t info;
    mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
    if (thread_info(thread, THREAD_EXTENDED_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) return;
    size_t i = 0;
    for (; i + 1 < size && i < sizeof(info.pth_name) && info.pth_name[i] != 0; i++) {
        char c = info.pth_name[i];
        out[i] = (c == '\n' || c == '\r') ? ' ' : c;
    }
    out[i] = 0;
}

/// Samples the threads of this task into `out` (at most `max_threads`,
/// `BC_THREAD_MAX_FRAMES` frames each), in task order. `crashed` (or
/// MACH_PORT_NULL) is always included and marked crashed and current; its
/// registers come from `crashed_regs` when given (a signal handler's
/// interrupted context). `self` is skipped unless it is `crashed`, and so is
/// the exception thread. `freeze`: every other thread is suspended for the
/// whole capture (crash); otherwise each is suspended only while it is
/// walked (hang sampling).
static int bc_collect_threads(thread_t crashed, const bc_regs *crashed_regs, thread_t self, bc_thread_sample *out,
                              int max_threads, int freeze) {
    task_t task = mach_task_self();
    thread_act_array_t list = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(task, &list, &count) != KERN_SUCCESS) return 0;
    if (freeze) {
        for (mach_msg_type_number_t i = 0; i < count && i < BC_SUSPEND_MAX; i++) {
            g_suspended[i] = 0;
            if (list[i] == self || list[i] == g_exc_thread_port) continue;
            g_suspended[i] = thread_suspend(list[i]) == KERN_SUCCESS;
        }
    }
    int crashed_seen = crashed == MACH_PORT_NULL;
    int n = 0;
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        thread_t t = list[i];
        int is_crashed = t == crashed;
        if (!is_crashed && (t == self || t == g_exc_thread_port)) continue;
        // Keep a slot for the crashed thread until it has been seen.
        if (!is_crashed && n >= max_threads - (crashed_seen ? 0 : 1)) continue;
        if (n >= max_threads) break;
        bc_thread_sample *rec = &out[n];
        rec->index = i;
        rec->crashed = is_crashed;
        rec->current = is_crashed;
        rec->main = t == g_main_thread;
        rec->count = 0;
        bc_thread_name(t, rec->name, sizeof(rec->name));
        bc_regs regs;
        if (is_crashed && crashed_regs != NULL) {
            regs = *crashed_regs;
            rec->count = bc_walk_regs(&regs, rec->frames, BC_THREAD_MAX_FRAMES);
        } else if (freeze || t == self) {
            if (bc_thread_regs(t, &regs) == 0) rec->count = bc_walk_regs(&regs, rec->frames, BC_THREAD_MAX_FRAMES);
        } else if (thread_suspend(t) == KERN_SUCCESS) {
            if (bc_thread_regs(t, &regs) == 0) rec->count = bc_walk_regs(&regs, rec->frames, BC_THREAD_MAX_FRAMES);
            thread_resume(t);
        }
        if (is_crashed) crashed_seen = 1;
        n++;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (freeze && i < BC_SUSPEND_MAX && g_suspended[i]) thread_resume(list[i]);
        mach_port_deallocate(task, list[i]);
    }
    vm_deallocate(task, (vm_address_t)list, sizeof(thread_t) * count);
    return n;
}

int bc_sample_threads(bc_thread_sample *out, int max_threads) {
    if (out == NULL || max_threads <= 0) return 0;
    thread_t self = mach_thread_self();
    int n = bc_collect_threads(MACH_PORT_NULL, NULL, self, out, max_threads, 0);
    mach_port_deallocate(mach_task_self(), self);
    return n;
}

int bc_thread_backtrace(uint32_t thread_port, uintptr_t *frames, int max_frames) {
    if (thread_port == 0 || frames == NULL || max_frames <= 0) return 0;
    if (thread_port == pthread_mach_thread_np(pthread_self())) return 0;
    if (thread_suspend(thread_port) != KERN_SUCCESS) return 0;
    bc_regs regs;
    int n = bc_thread_regs(thread_port, &regs) == 0 ? bc_walk_regs(&regs, frames, max_frames) : 0;
    thread_resume(thread_port);
    return n;
}

uint32_t bc_current_thread_port(void) { return pthread_mach_thread_np(pthread_self()); }

// Image initializers run on the main thread.
__attribute__((constructor)) static void bc_record_main_thread(void) {
    g_main_thread = pthread_mach_thread_np(pthread_self());
}

uint32_t bc_main_thread_port(void) { return g_main_thread; }

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

static void bc_write_threads(int fd, const bc_thread_sample *threads, int count) {
    for (int t = 0; t < count; t++) {
        const bc_thread_sample *rec = &threads[t];
        bc_write_str(fd, "thread ");
        bc_write_dec(fd, (int64_t)rec->index);
        bc_write_str(fd, rec->crashed ? " 1" : " 0");
        bc_write_str(fd, rec->current ? " 1" : " 0");
        bc_write_str(fd, rec->main ? " 1\n" : " 0\n");
        if (rec->name[0] != 0) {
            bc_write_str(fd, "threadname ");
            bc_write_str(fd, rec->name);
            bc_write_str(fd, "\n");
        }
        for (int i = 0; i < rec->count; i++) {
            bc_write_str(fd, "tframe ");
            bc_write_hex(fd, rec->frames[i]);
            bc_write_str(fd, "\n");
        }
    }
}

static void bc_write_report(const char *kind, int sig, int code, uintptr_t addr, int exception, int64_t exc_code,
                            int64_t exc_subcode, const uintptr_t *frames, int count, const bc_thread_sample *threads,
                            int thread_count) {
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
    bc_write_line(fd, "pid", (int64_t)getpid());
    bc_write_line(fd, "suppressed", __atomic_load_n(&g_suppress, __ATOMIC_ACQUIRE));
    for (int i = 0; i < count; i++) {
        bc_write_str(fd, "frame ");
        bc_write_hex(fd, frames[i]);
        bc_write_str(fd, "\n");
    }
    bc_write_threads(fd, threads, thread_count);
    bc_write_blob(fd, "release", &g_release[0][0], BC_RELEASE_MAX, g_release_len, &g_release_slot);
    bc_write_blob(fd, "environment", &g_environment[0][0], BC_ENVIRONMENT_MAX, g_environment_len, &g_environment_slot);
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

void bc_crash_set_release(const char *release, size_t release_length, const char *environment,
                          size_t environment_length) {
    bc_set_slot(&g_release[0][0], BC_RELEASE_MAX, g_release_len, &g_release_slot, release, release_length);
    bc_set_slot(&g_environment[0][0], BC_ENVIRONMENT_MAX, g_environment_len, &g_environment_slot, environment,
                environment_length);
}

void bc_crash_suppress_next_event(void) { __atomic_store_n(&g_suppress, 1, __ATOMIC_RELEASE); }

// MARK: - signals

static void bc_restore_signal_handlers(void) {
    for (int i = 0; i < BC_SIGNAL_COUNT; i++) sigaction(bc_signals[i], &g_previous[i], NULL);
}

static void bc_signal_handler(int sig, siginfo_t *info, void *context) {
    if (__atomic_exchange_n(&g_handling, 1, __ATOMIC_SEQ_CST) == 0) {
        if (!__atomic_load_n(&g_written, __ATOMIC_ACQUIRE)) {
            bc_regs regs;
            bc_context_regs(context, &regs);
            int n = bc_walk_regs(&regs, g_frames, BC_CRASH_MAX_FRAMES);
            // Best effort: the other threads, frozen while they are walked.
            thread_t self = mach_thread_self();
            g_thread_count = bc_collect_threads(self, &regs, self, g_threads, BC_CRASH_MAX_THREADS, 1);
            bc_write_report("signal", sig, info ? info->si_code : 0, info ? (uintptr_t)info->si_addr : 0, 0, 0, 0,
                            g_frames, n, g_threads, g_thread_count);
            mach_port_deallocate(mach_task_self(), self);
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
    g_exc_thread_port = pthread_mach_thread_np(pthread_self());
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
                bc_regs regs;
                thread_t crashed = request.thread.name;
                int n = bc_thread_regs(crashed, &regs) == 0 ? bc_walk_regs(&regs, g_frames, BC_CRASH_MAX_FRAMES) : 0;
                g_thread_count = bc_collect_threads(crashed, NULL, g_exc_thread_port,
                                                    g_threads, BC_CRASH_MAX_THREADS, 1);
                int64_t code = request.code_count > 0 ? request.code[0] : 0;
                int64_t subcode = request.code_count > 1 ? request.code[1] : 0;
                bc_write_report("mach", 0, 0, (uintptr_t)subcode, request.exception, code, subcode, g_frames, n,
                                g_threads, g_thread_count);
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
    bc_regs regs = {0, (uintptr_t)__builtin_frame_address(0), 0};
    int n = bc_walk_regs(&regs, frames, BC_CRASH_MAX_FRAMES);
    thread_t self = mach_thread_self();
    // Frozen as in a crash (only Mach calls run while the others are suspended).
    pthread_mutex_lock(&g_lock);
    g_thread_count = bc_collect_threads(self, &regs, self, g_threads, BC_CRASH_MAX_THREADS, 1);
    bc_write_report("signal", sig, 0, 0, 0, 0, 0, frames, n, g_threads, g_thread_count);
    pthread_mutex_unlock(&g_lock);
    mach_port_deallocate(mach_task_self(), self);
    return 0;
}

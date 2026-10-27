// Native crash capture for BugCapsule monitoring (internal; used by the
// BugCapsule Swift target).
//
// POSIX signals and Mach exceptions are written to a report file by code
// that only uses async-signal-safe calls (open/write/close, sigaction,
// vm_read_overwrite and Mach thread calls) and buffers allocated at install
// time. The report holds the crashing thread's stack and, best effort, the
// stacks of all other threads (suspended while they are walked). The Swift
// side turns it into a `fatal` event on the next launch.
#ifndef BUGCAPSULE_CRASH_H
#define BUGCAPSULE_CRASH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Maximum frames written for the crashing thread (monitoring-v1 allows 250).
#define BC_CRASH_MAX_FRAMES 250
/// Maximum threads written per report (the crashed thread always is).
#define BC_CRASH_MAX_THREADS 100
/// Maximum frames per thread in the threads section.
#define BC_THREAD_MAX_FRAMES 100
/// Size of the context buffer; longer contexts are dropped.
#define BC_CRASH_CONTEXT_MAX (128 * 1024)

/// One thread's stack (innermost return address first; frames[0] is the pc).
typedef struct {
    /// Position in `task_threads` order (0 is the first thread, normally main).
    uint64_t index;
    int32_t crashed;
    int32_t current;
    int32_t main;
    int32_t count;
    char name[64];
    uintptr_t frames[BC_THREAD_MAX_FRAMES];
} bc_thread_sample;

/// Installs the signal handlers (and, when `mach_exceptions` is true and no
/// debugger is attached, a Mach exception server thread). `report_path` is
/// copied. Returns 0 on success; calling it again only updates the path.
int bc_crash_install(const char *report_path, bool mach_exceptions);

/// Restores the previous signal handlers and exception ports (tests).
void bc_crash_uninstall(void);

int bc_crash_is_installed(void);
int bc_crash_mach_installed(void);

/// Copies the serialized crash context (event template: release, tags,
/// user, breadcrumbs, session) into a preallocated buffer that the crash
/// handler writes verbatim. Longer input is dropped (the previous context
/// stays).
void bc_crash_set_context(const char *bytes, size_t length);

/// Same for the loaded images (debug images JSON).
void bc_crash_set_images(const char *bytes, size_t length);

/// The release and environment of this process, written with every report
/// (so a crash is attributed to the release that crashed even after an
/// update, and when the context was too large to keep).
void bc_crash_set_release(const char *release, size_t release_length, const char *environment,
                          size_t environment_length);

/// The next crash report is written with `suppressed 1`: the uncaught
/// NSException handler already queued the event, the report only marks the
/// session crashed.
void bc_crash_suppress_next_event(void);

/// Captures the stack of another thread of this process (suspends it while
/// walking). Return addresses, innermost first. Returns the frame count.
int bc_thread_backtrace(uint32_t thread_port, uintptr_t *frames, int max_frames);

/// Samples every thread of this process except the caller, each suspended
/// only while it is walked (app hangs). Returns the number written to `out`.
int bc_sample_threads(bc_thread_sample *out, int max_threads);

/// On arm64, inserts `lr` as the first caller (frames[1]) when the pc is in
/// a leaf function: `lr` is not already frames[1] and the instruction
/// before it is a call into the function containing `pc`. Returns the new
/// count (at most `max_frames`; the outermost frame is dropped when full).
int bc_insert_link_register(uintptr_t pc, uintptr_t lr, uintptr_t *frames, int count, int max_frames);

/// This thread's Mach port (for the hang watchdog to sample the main thread).
uint32_t bc_current_thread_port(void);

/// The main thread's Mach port (callable from any thread).
uint32_t bc_main_thread_port(void);

bool bc_debugger_attached(void);

/// Writes a report for `signal` from the calling thread's stack without
/// terminating (tests and diagnostics). Returns 0 on success.
int bc_crash_write_test_report(int signal);

#ifdef __cplusplus
}
#endif

#endif

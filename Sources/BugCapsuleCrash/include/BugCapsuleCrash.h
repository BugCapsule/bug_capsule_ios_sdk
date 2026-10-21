// Native crash capture for BugCapsule monitoring (internal; used by the
// BugCapsule Swift target).
//
// POSIX signals and Mach exceptions are written to a report file by code
// that only uses async-signal-safe calls (open/write/close, sigaction,
// vm_read_overwrite, thread_get_state) and buffers allocated at install
// time. The Swift side turns the report into a `fatal` event on the next
// launch.
#ifndef BUGCAPSULE_CRASH_H
#define BUGCAPSULE_CRASH_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Maximum frames written for the crashing thread.
#define BC_CRASH_MAX_FRAMES 128

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

/// The next crash report is written with `suppressed 1`: the uncaught
/// NSException handler already queued the event, the report only marks the
/// session crashed.
void bc_crash_suppress_next_event(void);

/// Captures the stack of another thread of this process (suspends it while
/// walking). Return addresses, innermost first. Returns the frame count.
int bc_thread_backtrace(uint32_t thread_port, uintptr_t *frames, int max_frames);

/// This thread's Mach port (for the hang watchdog to sample the main thread).
uint32_t bc_current_thread_port(void);

bool bc_debugger_attached(void);

/// Writes a report for `signal` from the calling thread's stack without
/// terminating (tests and diagnostics). Returns 0 on success.
int bc_crash_write_test_report(int signal);

#ifdef __cplusplus
}
#endif

#endif

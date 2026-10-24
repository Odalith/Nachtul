// Spall profiling for Nachtul, off by default and zero-cost when off.
//
// Enable from the shell (no rebuild, no define):
//
//   NACHTUL_SPALL=1 odin run .
//   NACHTUL_SPALL_FILE=/tmp/nachtul.spall NACHTUL_SPALL=1 odin run .
//
// Then drag the .spall file into https://gravitymoth.com/spall/spall-web.html
// (the free web viewer; Odin's core:prof/spall writes this format).
//
// Why manual events, not automatic instrumentation: the automatic hooks
// (-instrument) trace every procedure in the program, including the
// engine and SDL glue, and drown the app-level signal. These events
// trace the boundaries that matter here — one declare per frame on the
// main thread, one job at a time on the library worker — and nothing
// else. Adding a new event is prof_begin(name) + defer prof_end().
//
// Timestamps are monotonic nanoseconds, so there is no 2-second TSC
// calibration at startup: context_create_with_scale(..., false, 1)
// instead of the doc example's context_create, which calibrates.
//
// Odin gotcha, learned the hard way: a `defer prof_shutdown_thread()`
// inside an `if` block runs at the end of that block, not at proc
// exit — so always call prof_init_thread + defer prof_shutdown_thread
// at proc top level. Both are no-ops when profiling is off, so no
// `if prof_enabled` wrapper is needed (or wanted).
// The context is shared across threads (Spall's own pattern); each
// thread owns its buffer via @(thread_local), and buffer_destroy
// flushes it, so the worker's events land before the file closes —
// provided prof_shutdown runs after stop_library joins the worker
// (main.odin registers that defer first, so it runs last).
package nachtul

import "core:os"
import "core:prof/spall"

prof_enabled: bool
prof_ctx: spall.Context

@(thread_local) prof_buffer: spall.Buffer
@(thread_local) prof_backing: []u8
@(thread_local) prof_thread_ready: bool

// Creates the trace file and arms profiling. Returns false when the
// file could not be created, in which case profiling stays off and
// the app runs normally.
prof_init :: proc(filename: string) -> bool {
	ctx, ok := spall.context_create_with_scale(filename, false, 1)
	if !ok {
		return false
	}
	prof_ctx = ctx
	prof_enabled = true
	return true
}

// Reads NACHTUL_SPALL / NACHTUL_SPALL_FILE from the environment.
// Any value except "" and "0" enables; the file defaults to
// "nachtul.spall" in the working directory.
prof_init_from_env :: proc() -> bool {
	flag_buf: [512]u8
	flag := os.get_env(flag_buf[:], "NACHTUL_SPALL")
	if flag == "" || flag == "0" {
		return false
	}
	file_buf: [512]u8
	file := os.get_env(file_buf[:], "NACHTUL_SPALL_FILE")
	if file == "" {
		file = "nachtul.spall"
	}
	return prof_init(file)
}

// Main-thread setup: thread buffer + process name. Call once, after
// prof_init, before the first declare.
prof_init_main :: proc() {
	prof_init_thread("main")
	if prof_thread_ready {
		spall._buffer_name_process(&prof_ctx, &prof_buffer, "Nachtul")
	}
}

// Per-thread setup: a 1 MiB buffer (spall.BUFFER_DEFAULT_SIZE) that
// auto-flushes to the shared file when full. The library worker calls
// this at its start; the main thread goes through prof_init_main.
prof_init_thread :: proc(name: string) {
	if !prof_enabled || prof_thread_ready {
		return
	}
	prof_backing = make([]u8, spall.BUFFER_DEFAULT_SIZE)
	buf, ok := spall.buffer_create(prof_backing, u32(os.get_current_thread_id()), u32(os.get_pid()))
	if !ok {
		delete(prof_backing)
		prof_backing = nil
		return
	}
	prof_buffer = buf
	prof_thread_ready = true
	spall._buffer_name_thread(&prof_ctx, &prof_buffer, name)
}

// Flushes this thread's buffer and frees its backing. The worker's
// defer runs at thread exit; the main thread's runs inside
// prof_shutdown, after the worker has been joined.
prof_shutdown_thread :: proc() {
	if !prof_thread_ready {
		return
	}
	spall.buffer_destroy(&prof_ctx, &prof_buffer)
	delete(prof_backing)
	prof_backing = nil
	prof_thread_ready = false
}

// Closes the trace file. Must run after every thread has shut down
// (see the defer order in main.odin).
prof_shutdown :: proc() {
	if !prof_enabled {
		return
	}
	prof_shutdown_thread()
	spall.context_destroy(&prof_ctx)
	prof_enabled = false
}

// Event pair. Both are no-ops when profiling is off or this thread
// has no buffer, so instrumented code needs no `when` guards and
// headless tests pay one branch per event.
prof_begin :: proc(name: string) {
	if !prof_enabled || !prof_thread_ready {
		return
	}
	spall._buffer_begin(&prof_ctx, &prof_buffer, name, "")
}

prof_end :: proc() {
	if !prof_enabled || !prof_thread_ready {
		return
	}
	spall._buffer_end(&prof_ctx, &prof_buffer)
}

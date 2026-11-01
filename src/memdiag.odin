// TEMPORARY DIAGNOSTIC — the memory-climb experiment (2026-10-31).
// Round 1 answered the GPU-cache question: the cache is flat across
// page turns and purges to zero, so released textures do not stick.
// Round 2 (this revision) chases the residual: RSS climbs ~65 KiB
// per run while the cache sits flat, below the old 0.1 MiB sample
// resolution. Samples are now exact KiB, each run prints its own
// baseline -> post-purge delta, and the "Soak" button chains 200
// runs back to back to answer plateau-vs-linear: a flattening
// baseline series is allocator retention (bounded, ignore it); a
// straight line is a real slow leak. No policy (purge-on-page,
// budget change) follows from this run either way.
// DELETE this file and its hooks (drain counter in library.odin,
// the pager buttons + click arms in app.odin, the memdiag_step call
// in declare) once the table is read.
package nachtul

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import niello "../../NielloUI/niello"
import niello_sdl "../../NielloUI/niello/sdl"

// MEMDIAG_TURNS pages are sampled per run; the wall clock aborts a
// run stalled by a missing page answer (worker wedged, screen
// switched mid-run) instead of hanging the app. A soak chains
// MEMDIAG_SOAK_RUNS runs; each run's DONE line carries its delta,
// so the series reads as a plateau check directly.
MEMDIAG_TURNS :: 12
MEMDIAG_SOAK_RUNS :: 200
MEMDIAG_TIMEOUT :: 30 * time.Second

// Bumped by drain_library_msgs when a Collections_Page applies (the
// hook in library.odin). The step below keys off advances, never off
// page numbers, so a manual Prev/Next mid-run just becomes one more
// sampled advance.
memdiag_pages_applied: int

memdiag_active:             bool
memdiag_start_page:         int
memdiag_turns:              int
memdiag_waiting:            bool
memdiag_applied_at_request: int
memdiag_settle_frames:      int
memdiag_started:            time.Tick
memdiag_run:                int
memdiag_run_start_rss:      int
memdiag_run_start_cache:    u64
memdiag_between_runs:       bool
memdiag_applied_at_finish:  int

// Soak state. soaking is true for the whole chain; soak_remaining
// counts runs still to start (the running one included).
memdiag_soaking:         bool
memdiag_soak_remaining:  int
memdiag_soak_first_rss:   int
memdiag_soak_first_cache: u64
memdiag_soak_first_set:   bool

memdiag_start :: proc() {
	if memdiag_active {
		return
	}
	if !app.loaded || !app.lib_loaded || pager_pages() < 2 {
		fmt.println("[memdiag] needs a loaded library with at least 2 pages; nothing run")
		memdiag_soaking = false
		memdiag_soak_remaining = 0
		return
	}
	memdiag_active = true
	memdiag_between_runs = false
	memdiag_run += 1
	// Wrap off the last page so the run always has pages to turn;
	// the baseline below then reads the previous page's settled
	// state, which is fine — the run's delta is what matters.
	if app.page+1 >= pager_pages() {
		app.page = 0
	}
	memdiag_start_page = app.page
	memdiag_turns = 0
	memdiag_waiting = false
	memdiag_settle_frames = 0
	memdiag_started = time.tick_now()
	fmt.println("[memdiag] run", memdiag_run, "start: paging from page", app.page+1, "of", pager_pages(), "total", app.lib_total, "section", app.section, "sort", app.sort)
	cache, rss := memdiag_sample("baseline")
	memdiag_run_start_cache = cache
	memdiag_run_start_rss = rss
	if memdiag_soaking && !memdiag_soak_first_set {
		memdiag_soak_first_cache = cache
		memdiag_soak_first_rss = rss
		memdiag_soak_first_set = true
	}
}

memdiag_soak_start :: proc() {
	if memdiag_active {
		return
	}
	memdiag_soaking = true
	memdiag_soak_remaining = MEMDIAG_SOAK_RUNS
	memdiag_soak_first_set = false
	fmt.println("[memdiag] soak: chaining", MEMDIAG_SOAK_RUNS, "runs")
	memdiag_start()
}

memdiag_soak_cancel :: proc() {
	if !memdiag_soaking {
		return
	}
	memdiag_soaking = false
	memdiag_soak_remaining = 0
	fmt.println("[memdiag] soak cancelled after the current run")
}

// Runs once per declare, right after the drain point, while a run is
// active. Frames keep flowing via wake_in: the run must not stall
// waiting for a declare that never comes (idle host sleeps).
memdiag_step :: proc() {
	if !memdiag_active {
		return
	}
	niello.wake_in(16)
	if time.tick_diff(memdiag_started, time.tick_now()) > MEMDIAG_TIMEOUT {
		fmt.println("[memdiag] ABORTED: no page answer within 30s; restoring page", memdiag_start_page+1)
		app.page = memdiag_start_page
		memdiag_active = false
		memdiag_between_runs = false
		memdiag_soaking = false
		memdiag_soak_remaining = 0
		return
	}
	if memdiag_between_runs {
		// The restore page landed; the next run's baseline will
		// measure the settled post-restore state, keeping the
		// run-to-run series comparable.
		if memdiag_pages_applied > memdiag_applied_at_finish {
			memdiag_between_runs = false
			if memdiag_soak_remaining > 0 {
				memdiag_start()
			} else {
				memdiag_active = false
			}
		}
		return
	}
	if !memdiag_waiting {
		if memdiag_turns >= MEMDIAG_TURNS || app.page+1 >= pager_pages() {
			memdiag_finish()
			return
		}
		// Advance one page; screen_library's desired-state trigger
		// posts the job on this same declare.
		memdiag_applied_at_request = memdiag_pages_applied
		app.page += 1
		memdiag_waiting = true
		memdiag_settle_frames = 0
		return
	}
	if memdiag_pages_applied > memdiag_applied_at_request {
		// The new page applied in this frame's drain; its textures
		// are only created by the render AFTER this declare. Wait
		// one more frame (wake_in keeps frames flowing) so the
		// sample sees the new page drawn and the old page's
		// textures released-but-cached.
		memdiag_settle_frames += 1
		if memdiag_settle_frames >= 2 {
			memdiag_sample(fmt.tprintf("page %d", app.page+1))
			memdiag_turns += 1
			memdiag_waiting = false
		}
	}
}

memdiag_finish :: proc() {
	niello_sdl.purge_gpu_cache()
	_, rss := memdiag_sample("post-purge")
	fmt.println("[memdiag] run", memdiag_run, "DONE: rss", memdiag_run_start_rss, "->", rss, "KiB (delta", rss-memdiag_run_start_rss, "KiB); restoring page", memdiag_start_page+1)
	app.page = memdiag_start_page
	if memdiag_soaking {
		memdiag_soak_remaining -= 1
	}
	if memdiag_soaking && memdiag_soak_remaining > 0 {
		// Chain the next run once the restore page lands.
		memdiag_between_runs = true
		memdiag_applied_at_finish = memdiag_pages_applied
		memdiag_started = time.tick_now()
		return
	}
	if memdiag_soaking {
		fmt.println("[memdiag] soak DONE:", memdiag_run, "runs; rss first-baseline", memdiag_soak_first_rss, "KiB -> last post-purge", rss, "KiB (delta", rss-memdiag_soak_first_rss, "KiB), cache first-baseline", memdiag_soak_first_cache, "KiB")
		memdiag_soaking = false
	}
	memdiag_active = false
	memdiag_between_runs = false
}

// Exact KiB, no rounding: the residual climb is ~65 KiB per run and
// the old 0.1 MiB prints could not see inside a run at all.
memdiag_sample :: proc(label: string) -> (cache: u64, rss: int) {
	cache = niello_sdl.gpu_cache_bytes()
	rss = memdiag_rss_kib()
	if rss < 0 {
		fmt.println("[memdiag]", label, ": cache", cache/1024, "KiB rss ? thumbs", len(page_thumbs))
	} else {
		fmt.println("[memdiag]", label, ": cache", cache/1024, "KiB rss", rss, "KiB thumbs", len(page_thumbs))
	}
	return cache, rss
}

// VmRSS straight from /proc/self/status: kilobytes, no page-size
// assumption. Linux-only, like the whole diagnostic.
memdiag_rss_kib :: proc() -> int {
	data, err := os.read_entire_file("/proc/self/status", context.allocator)
	if err != nil {
		return -1
	}
	defer delete(data)
	for line in strings.split_lines(string(data)) {
		if strings.has_prefix(line, "VmRSS:") {
			rest := strings.trim_space(line[len("VmRSS:"):])
			fields := strings.fields(rest)
			if len(fields) > 0 {
				if v, pok := strconv.parse_int(fields[0]); pok {
					return v
				}
			}
			return -1
		}
	}
	return -1
}

// TEMPORARY DIAGNOSTIC — the memory-climb experiment (2026-10-31).
// Question: after a page turn releases the old thumbnails, do their
// GPU textures sit in the Graphite cache as evictable residency, or
// stay budgeted (a real leak)? The run pages through the library
// sampling (budgeted cache bytes, RSS) per settled page, then purges
// and samples once more. The table it prints decides it:
//   cache collapses + RSS falls  -> residency, the cache doing its job
//   cache stays high post-purge -> leak in the release path
//   cache low throughout, RSS climbs -> leak outside the GPU cache
// Trigger: the temporary "Mem" button in the pager row. No policy
// (purge-on-page, budget change) follows from this run either way.
// DELETE this file and its three hooks (drain counter in
// library.odin, the pager button + click arm in app.odin, the
// memdiag_step call in declare) once the table is read.
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
// switched mid-run) instead of hanging the app.
MEMDIAG_TURNS :: 12
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

memdiag_start :: proc() {
	if memdiag_active {
		return
	}
	if !app.loaded || !app.lib_loaded || pager_pages() < 2 {
		fmt.println("[memdiag] needs a loaded library with at least 2 pages; nothing run")
		return
	}
	memdiag_active = true
	memdiag_start_page = app.page
	memdiag_turns = 0
	memdiag_waiting = false
	memdiag_settle_frames = 0
	memdiag_started = time.tick_now()
	fmt.println("[memdiag] start: paging from page", app.page+1, "of", pager_pages(), "total", app.lib_total)
	memdiag_sample("baseline")
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
	memdiag_sample("post-purge")
	fmt.println("[memdiag] DONE: restoring page", memdiag_start_page+1)
	app.page = memdiag_start_page
	memdiag_active = false
}

memdiag_sample :: proc(label: string) {
	cache := niello_sdl.gpu_cache_bytes()
	rss := memdiag_rss_kib()
	if rss < 0 {
		fmt.println("[memdiag]", label, ": cache", fmt.tprintf("%.2f MiB", f64(cache)/1048576), "rss ? thumbs", len(page_thumbs))
	} else {
		fmt.println("[memdiag]", label, ": cache", fmt.tprintf("%.2f MiB", f64(cache)/1048576), "rss", fmt.tprintf("%.1f MiB", f64(rss)/1024), "thumbs", len(page_thumbs))
	}
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

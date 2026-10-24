// Spall profiling (src/prof.odin): off by default, and when enabled
// the trace file is a valid Spall stream with events from both
// threads — main-thread declares and library-worker jobs.
package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import niello "../../NielloUI/niello"
import nachtul "../src"

@(test)
test_spall_trace :: proc(t: ^testing.T) {
	setup()
	defer teardown()
	testing.expect(t, !nachtul.prof_enabled, "profiling is off by default")

	path := "/tmp/nachtul_prof_test.spall"
	os.remove(path)

	// Main thread: enable, declare a few frames, shut down.
	testing.expect(t, nachtul.prof_init(path), "trace file opens")
	nachtul.prof_init_main()
	defer nachtul.prof_shutdown()
	settle(2)

	// Library worker: load a seeded DB so its thread emits events too.
	nachtul.stop_library()
	dir := "/tmp/nachtul_t_profflow"
	os.make_directory(dir)
	{
		db, ok := nachtul.db_open(fmt.tprintf("%s/Nachtul.db", dir))
		testing.expect(t, ok, "seed db opens")
		nachtul.db_create_schema(db)
		seed_library(db)
		nachtul.db_close(db)
	}
	nachtul.start_library_load(niello.test_context(), dir)
	testing.expect(t, wait_for(proc() -> bool { return nachtul.app.loaded }), "library loads under profiling")
	// Switch to the Library screen so a screen_library event lands too.
	click(nachtul.instances.nav[1])
	settle(2)
	nachtul.stop_library()
	settle(1)
	nachtul.prof_shutdown()

	data, rerr := os.read_entire_file(path, context.allocator)
	testing.expect(t, rerr == nil, "trace file reads back")
	defer delete(data)
	testing.expect(t, len(data) > 32, "trace has a header and events")
	// Manual stream header: magic u64le(0x0BADF00D), version 3.
	testing.expect(t, data[0] == 0x0D && data[1] == 0xF0 && data[2] == 0xAD && data[3] == 0x0B, "spall magic")
	text := string(data)
	testing.expect(t, strings.contains(text, "declare"), "declare event present")
	testing.expect(t, strings.contains(text, "screen_library"), "screen event present")
	testing.expect(t, strings.contains(text, "library_load"), "worker event present")
	testing.expect(t, strings.contains(text, "library"), "worker thread named")
	testing.expect(t, !nachtul.prof_enabled, "profiling is off again after shutdown")
	os.remove(path)
}

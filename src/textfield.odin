// A single-line text field, borrowed from NielloUI's `form` example
// at Malkj's direction (step 3) — the dedicated TextBox control is
// TODO #12 work; until it lands, this app-side component is the
// search box. Same shape as the example: a [dynamic]u8 buffer + byte
// caret, edited from input_text/input_keys at declare time, rendered
// as pre-caret text / caret / post-caret text inside a focusable row.
//
// Known remainder (inherited from #8): IME composition display.
package nachtul

import niello "../../NielloUI/niello"

// SDL scancodes for the editing keys (Key_Event space is SDL's).
SC_BACKSPACE :: 42
SC_DELETE :: 76
SC_HOME :: 74
SC_END :: 77
SC_RIGHT :: 79
SC_LEFT :: 80

Text_Field :: struct {
	buf:   [dynamic]u8,
	caret: int, // byte offset into buf
	inst:  niello.Instance,
}

text_field_string :: proc(f: ^Text_Field) -> string {
	return string(f.buf[:])
}

text_field_clear :: proc(f: ^Text_Field) {
	clear(&f.buf)
	f.caret = 0
}

rune_before :: proc(buf: []u8, i: int) -> int {
	i := i
	if i > len(buf) {
		i = len(buf)
	}
	if i == 0 {
		return 0
	}
	i -= 1
	for i > 0 && (buf[i] & 0xC0) == 0x80 {
		i -= 1
	}
	return i
}

rune_after :: proc(buf: []u8, i: int) -> int {
	i := i
	if i >= len(buf) {
		return len(buf)
	}
	i += 1
	for i < len(buf) && (buf[i] & 0xC0) == 0x80 {
		i += 1
	}
	return i
}

// Applies this frame's committed text + editing keys to the field.
// Call during declare, before showing it. Returns true if the buffer
// changed (the search re-query trigger).
edit_text_field :: proc(f: ^Text_Field) -> bool {
	if f.inst == 0 {
		return false
	}
	changed := false
	if t := niello.input_text(f.inst); t != "" {
		inject_at(&f.buf, f.caret, ..transmute([]u8)t)
		f.caret += len(t)
		changed = true
	}
	for ev in niello.input_keys(f.inst) {
		if !ev.down {
			continue
		}
		switch ev.scancode {
		case SC_BACKSPACE:
			if f.caret > 0 {
				lo := rune_before(f.buf[:], f.caret)
				remove_range(&f.buf, lo, f.caret)
				f.caret = lo
				changed = true
			}
		case SC_DELETE:
			if f.caret < len(f.buf) {
				remove_range(&f.buf, f.caret, rune_after(f.buf[:], f.caret))
				changed = true
			}
		case SC_LEFT:
			f.caret = rune_before(f.buf[:], f.caret)
		case SC_RIGHT:
			f.caret = rune_after(f.buf[:], f.caret)
		case SC_HOME:
			f.caret = 0
		case SC_END:
			f.caret = len(f.buf)
		}
	}
	return changed
}

show_text_field :: proc(f: ^Text_Field, key: niello.Key, placeholder: string) {
	i, open := niello.begin(lib.field, key)
	f.inst = i
	if !open {
		return
	}
	if len(f.buf) == 0 && !niello.focused(i) {
		niello.show(lib.placeholder_text, niello.key_int(1), {text = placeholder})
	} else if niello.focused(i) {
		if f.caret > 0 {
			niello.show(lib.field_text, niello.key_int(1), {text = string(f.buf[:f.caret])})
		}
		niello.show(lib.caret, niello.key_int(2))
		if f.caret < len(f.buf) {
			niello.show(lib.field_text, niello.key_int(3), {text = string(f.buf[f.caret:])})
		}
	} else {
		niello.show(lib.field_text, niello.key_int(1), {text = string(f.buf[:])})
	}
}

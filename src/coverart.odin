// Cover art for the Now Playing screen, following the C#
// GetCoverImage fallbacks (IoService.cs), trimmed to the two the
// port was asked for:
//   1. the path stored in Songs.coverArt, if it loads;
//   2. the image embedded in the audio file itself, via TagUtils.
// C# also scans the song's directory for the largest image file
// and writes a found path back to the DB; neither is ported here
// (a directory scan can pick unrelated art, and a view should not
// write the DB behind the scanner's back).
//
// TagUtils loads lazily via dynlib, like the audio backend: the
// .so is gitignored and local-only, so a missing library degrades
// to blank covers instead of failing the build or the run. A
// failed load is tried once and then remembered, so a missing .so
// does not print on every song change.

package nachtul

import "core:dynlib"
import "core:fmt"
import "core:strings"

import niello "../../NielloUI/niello"

// Mirrors tagutils.h's ImageData: raw bytes + size. The data
// belongs to TagUtils and must be freed with FreeImageData.
Tag_Image_Data :: struct {
	data: rawptr,
	size: uint, // size_t
}

Tag_Get_Image :: proc "c" (cstring) -> ^Tag_Image_Data
Tag_Free_Image :: proc "c" (^Tag_Image_Data)

tagutils_lib:        dynlib.Library
tagutils_loaded:     bool
tagutils_tried:      bool
tagutils_get_image:  Tag_Get_Image
tagutils_free_image: Tag_Free_Image

tagutils_try_load :: proc() -> bool {
	if tagutils_loaded {
		return true
	}
	if tagutils_tried {
		return false
	}
	tagutils_tried = true
	lib, ok := dynlib.load_library("third_party/native/linux-x64/libTagUtils.so", false, context.allocator)
	if !ok {
		fmt.eprintln("nachtul: libTagUtils.so not found — embedded cover art unavailable")
		return false
	}
	get_sym, gok := dynlib.symbol_address(lib, "GetEmbeddedImage")
	free_sym, fok := dynlib.symbol_address(lib, "FreeImageData")
	if !gok || !fok {
		fmt.eprintln("nachtul: libTagUtils.so missing GetEmbeddedImage/FreeImageData")
		dynlib.unload_library(lib)
		return false
	}
	tagutils_lib = lib
	tagutils_get_image = cast(Tag_Get_Image)get_sym
	tagutils_free_image = cast(Tag_Free_Image)free_sym
	tagutils_loaded = true
	return true
}

// resolve_np_art returns the Now Playing cover for a queue entry:
// the stored coverArt path first, then the file's embedded image.
// (NO_IMAGE, false) when neither yields an image — the screen
// shows the blank panel instead. The embedded bytes are decoded
// synchronously by image_load_memory, so the ImageData is freed
// before returning.
resolve_np_art :: proc(e: Play_Entry) -> (niello.Image, bool) {
	if len(e.cover_art) > 0 {
		if img, ok := niello.image_load(e.cover_art, 320, 320); ok {
			return img, true
		}
	}
	if len(e.location) > 0 && tagutils_try_load() {
		path := strings.clone_to_cstring(e.location, context.allocator)
		defer delete(path)
		img_data := tagutils_get_image(path)
		if img_data != nil && img_data.data != nil && img_data.size > 0 {
			defer tagutils_free_image(img_data)
			bytes := ([^]byte)(img_data.data)[:img_data.size]
			if img, ok := niello.image_load_memory(bytes, 320, 320); ok {
				return img, true
			}
		}
	}
	return niello.NO_IMAGE, false
}

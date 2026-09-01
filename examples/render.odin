/*
Render a `.bml` file to html on stdout.

	odin run examples/render.odin -file -- nt-bidding.bml

`#INCLUDE` is resolved relative to the WORKING DIRECTORY, which is what the python reference does
(it opens the named file directly, which is why its callers have to chdir first). A GUI would pass a
resolver that reads open editor buffers instead.
*/
package main

import lib ".."
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: render <file.bml>")
		os.exit(2)
	}
	source, read_err := os.read_entire_file(os.args[1], context.allocator)
	if read_err != nil {
		fmt.eprintfln("could not read %v: %v", os.args[1], read_err)
		os.exit(1)
	}

	// `render <file> <n>` re-renders n times and reports the per-run cost instead of the html. The
	// interesting number for a live preview is the IN-PROCESS one, which a shell loop cannot see
	// past process startup.
	if runs, is_count := strconv.parse_int(len(os.args) > 2 ? os.args[2] : ""); is_count {
		start := time.now()
		for _ in 0 ..< runs {
			doc := lib.parse(string(source), {resolve_include = read_include})
			html := lib.render_html(doc)
			free_all(context.temp_allocator)
			delete(html)
			lib.destroy(doc)
		}
		elapsed := time.since(start)
		fmt.eprintfln("%v runs, %.2f ms/run", runs, time.duration_milliseconds(elapsed) / f64(runs))
		return
	}

	// `render <file> -links` also checks that every `[label](#Anchor)` lands on a heading this
	// document defines. Off by default for the same reason the library's option is: a chapter of a
	// corpus assembled by a root document links outside itself on purpose.
	check_links := false
	for arg in os.args[2:] {
		if arg == "-links" {
			check_links = true
		}
	}

	doc := lib.parse(string(source), {resolve_include = read_include, check_cross_references = check_links})
	defer lib.destroy(doc)

	for diagnostic in doc.diagnostics {
		fmt.eprintln(lib.diagnostic_text(diagnostic, context.temp_allocator))
	}
	fmt.print(lib.render_html(doc))
}

read_include :: proc(name: string, user: rawptr, allocator: runtime.Allocator) -> (text: string, ok: bool) {
	data, err := os.read_entire_file(name, allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

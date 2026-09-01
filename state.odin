package bml

import "core:mem"

/*
Everything a single parse accumulates.

The python keeps all of this at MODULE scope, which is why converting several documents in one
process leaks the first one's tables into the second and the build has to spawn a subprocess per
file. Here it is a value: `parse` creates one, and two parses cannot see each other.

`clipboard`, `vulnerability` and `seat` are stateful WITHIN a document - a `#VUL` applies to every
table after it - which is why they live here rather than in `create_bidtree`.
*/
Parse_State :: struct {
	clipboard:     map[string]string,
	vulnerability: string,
	seat:          string,
	// Document metadata (`#+TITLE:` and friends). First value for a key wins.
	meta:          map[string]string,
	// Problems worth reporting but not worth refusing the document over. A live preview parses a
	// buffer someone is still typing, so a malformed directive has to degrade rather than abort.
	diagnostics:   [dynamic]Diagnostic,
	// The text the passes produced, and the two tables that turn an offset into it back into a
	// position in the source someone is looking at. See `positions.odin`.
	text:          string,
	origins:       [dynamic]Line_Origin,
	line_starts:   [dynamic]int,
	allocator:     mem.Allocator,
}

@(private)
parse_state_init :: proc(state: ^Parse_State, allocator := context.allocator) {
	state^ = Parse_State {
		clipboard     = make(map[string]string, allocator),
		vulnerability = "00",
		seat          = "0",
		meta          = make(map[string]string, allocator),
		diagnostics   = make([dynamic]Diagnostic, allocator),
		allocator     = allocator,
	}
}

package bml

import "core:mem"
import "core:mem/virtual"
import "core:strings"

/*
How `#INCLUDE other.bml` is resolved.

The reference opens the named file relative to the process's working directory, which is why the
quiz has to `chdir` around every parse. Here it is a callback, so a caller can serve includes from
a directory, from open editor buffers, or refuse them entirely. Returning `ok = false` leaves a
diagnostic and drops the directive.
*/
Include_Resolver :: #type proc(name: string, user: rawptr, allocator: mem.Allocator) -> (text: string, ok: bool)

Parse_Options :: struct {
	resolve_include:        Include_Resolver,
	include_user:           rawptr,
	/*
	Check that every `[label](#Anchor)` lands on a heading this document defines.

	Off by default, and deliberately: the corpus is chapters assembled by one root document, so a
	chapter opened ALONE links to headings that are real but live in a sibling file. An editor
	showing one file wants these as warnings; a build over the root document wants them as errors;
	a caller that knows it is holding a fragment wants them not at all.
	*/
	check_cross_references: bool,
}

/*
A parsed document, owning everything it points at.

All of it - block text, list items, bid tree nodes - is allocated from one arena, so `destroy` is a
single wholesale free. That is what makes re-parsing on every keystroke cheap: there is nothing to
walk and nothing to reference-count.
*/
Document :: struct {
	blocks:      []Block,
	// `#+TITLE:` and friends, first value per key.
	meta:        map[string]string,
	// Problems that did not stop the parse. Always safe to ignore; `diagnostic_text` formats one.
	diagnostics: []Diagnostic,
	arena:       virtual.Arena,
}

/*
Parse BML source into blocks.

Takes SOURCE TEXT rather than a path, which is the whole point of the port: a live preview renders
the buffer someone is still typing, and it has not been saved anywhere.

Four text-level passes, then a classification loop, and the order of the passes matters:

 1. NEWLINES are normalised first, because every pass after this one is written against `\n`.
 2. INCLUDES are expanded next, so an included file's blocks split on the same rules as the host's.
    One pass only - an include inside an included file is not expanded, as in the reference.
 3. COMMENT LINES go before block splitting, so a commented-out line cannot hold two halves of a
    paragraph together.
 4. BLOCKS are split on blank lines. This is the whole "grammar": everything below is a block at a
    time.

Then `classify_block` per block, IN ORDER - it mutates the parse state as it goes, so the loop is
sequential by construction. See the note on that procedure.

The returned document owns everything it points at; `destroy` frees it in one go.
*/
parse :: proc(source: string, options := Parse_Options{}) -> ^Document {
	doc := new(Document)
	_ = virtual.arena_init_growing(&doc.arena)
	allocator := virtual.arena_allocator(&doc.arena)

	state: Parse_State
	parse_state_init(&state, allocator)

	text := normalise_newlines(source, allocator)
	/*
	The line map is built here and then rewritten by each pass that adds or drops lines, so a
	diagnostic raised while classifying a block can still say which line of which FILE it is about.
	`positions.odin` explains why it is recorded as the bytes are written rather than reconstructed
	afterwards.
	*/
	state.origins = origins_of_own_lines(text, allocator)
	text = expand_includes(&state, text, options)
	text = strip_comment_lines(&state, text, allocator)
	state.text = text
	state.line_starts = line_starts_of(text, allocator)

	blocks := make([dynamic]Block, allocator)
	for chunk in split_blocks(text, allocator) {
		if block, ok := classify_block(&state, chunk); ok {
			append(&blocks, block)
		}
	}

	doc.blocks = blocks[:]
	doc.meta = state.meta
	if options.check_cross_references {
		check_cross_references(&state, doc.blocks)
	}
	doc.diagnostics = state.diagnostics[:]
	return doc
}

/*
Free a document and everything in it.

One arena reset: every block, list item, string and `Node` goes at once. Anything still holding a
`^Node`, a `Block` or a `string` taken out of this document is dangling afterwards, so copy first.
*/
destroy :: proc(doc: ^Document) {
	if doc == nil {
		return
	}
	virtual.arena_destroy(&doc.arena)
	free(doc)
}

/*
Turn every line ending into a bare `\n`.

The corpus is CRLF, and everything downstream - the blank line that separates blocks, the
indentation that nests a bid table - is written against `\n`. The reference never had to think about
this because python's text mode does the same translation on read, invisibly; skip it here and a
CRLF document parses as one enormous block that classifies as nothing at all.
*/
@(private = "file")
normalise_newlines :: proc(text: string, allocator := context.allocator) -> string {
	if !strings.contains(text, "\r") {
		return text
	}
	out := strings.builder_make(0, len(text), allocator)
	for i := 0; i < len(text); i += 1 {
		if text[i] == '\r' {
			// Both `\r\n` and a lone `\r` become one newline, as universal newlines does.
			if i + 1 < len(text) && text[i + 1] == '\n' {
				i += 1
			}
			strings.write_byte(&out, '\n')
			continue
		}
		strings.write_byte(&out, text[i])
	}
	return strings.to_string(out)
}

/*
Expand `#INCLUDE name` directives.

ONE pass over the original text, so an include inside an included file is not expanded - the
reference behaves the same way, because `re.sub` scans the string it was given rather than its own
output. Anything relying on nested includes never worked.
*/
@(private = "file")
expand_includes :: proc(state: ^Parse_State, source: string, options: Parse_Options) -> string {
	if !strings.contains(source, "INCLUDE") {
		return source
	}
	/*
	A `Mapped_Builder` rather than a plain one: this is the pass that makes a working line number
	stop meaning a source line number, so every piece is written with the origin it deserves - the
	source's own lines for what passes through, the included file's lines for what it brings in, and
	the DIRECTIVE's line for the two wrapper newlines, which belong to nobody else.
	*/
	mb := mapped_builder_make(len(source), state.allocator)
	written := 0
	written_line := 0
	line_index := 0
	for line_start := 0; line_start <= len(source); {
		newline := strings.index_byte(source[line_start:], '\n')
		line_end := newline < 0 ? len(source) : line_start + newline
		past := newline < 0 ? len(source) : line_end + 1
		line := source[line_start:line_end]

		if name, ok := match_include_line(line); ok {
			mb_write_mapped(&mb, source[written:line_start], origins_slice(state, written_line, line_index))
			here := source_line_of(state, line_index)
			indent := leading_space_count(line)
			at := Source_Span {
				line   = here,
				col    = indent + 1,
				length = len(strings.trim_right_space(line)) - indent,
			}
			// The reference wraps the included text in newlines, so the file's first and last
			// blocks cannot fuse with whatever surrounded the directive.
			mb_write(&mb, "\n", "", here)
			if options.resolve_include != nil {
				if text, resolved := options.resolve_include(name, options.include_user, state.allocator); resolved {
					mb_write(&mb, normalise_newlines(text, state.allocator), name, 1)
				} else {
					diagnose_at(state, at, .Error, "#INCLUDE %v: could not be read", name)
				}
			} else {
				diagnose_at(state, at, .Warning, "#INCLUDE %v: includes are not resolved here", name)
			}
			mb_write(&mb, "\n", "", here)
			written = past
			written_line = line_index + 1
		}
		line_index += 1
		if newline < 0 {
			break
		}
		line_start = past
	}
	if written == 0 {
		return source
	}
	mb_write_mapped(&mb, source[written:], origins_slice(state, written_line, len(state.origins)))
	state.origins = mb.origins
	return strings.to_string(mb.out)
}

// The origins of working lines `from ..< to`, clamped: a pass asking past the end is asking about a
// line that never existed, and an empty slice makes that an unknown position rather than a crash.
@(private = "file")
origins_slice :: proc(state: ^Parse_State, from, to: int) -> []Line_Origin {
	low := clamp(from, 0, len(state.origins))
	high := clamp(to, low, len(state.origins))
	return state.origins[low:high]
}

@(private = "file")
source_line_of :: proc(state: ^Parse_State, index: int) -> int {
	return index >= 0 && index < len(state.origins) ? state.origins[index].line : 0
}

@(private = "file")
match_include_line :: proc(line: string) -> (name: string, ok: bool) {
	cursor := leading_space_count(line)
	if cursor >= len(line) || line[cursor] != '#' {
		return "", false
	}
	cursor += 1
	for cursor < len(line) && is_space_byte(line[cursor]) {
		cursor += 1
	}
	if !strings.has_prefix(line[cursor:], "INCLUDE") {
		return "", false
	}
	cursor += len("INCLUDE")
	for cursor < len(line) && is_space_byte(line[cursor]) {
		cursor += 1
	}
	start := cursor
	for cursor < len(line) && !is_space_byte(line[cursor]) {
		cursor += 1
	}
	if cursor == start {
		return "", false
	}
	return line[start:cursor], true
}

// `//` at the very start of a line comments the line out. Mid-line `//` is left alone: it appears
// inside urls, and stripping it there once truncated real links.
@(private = "file")
strip_comment_lines :: proc(state: ^Parse_State, text: string, allocator := context.allocator) -> string {
	if !strings.contains(text, "//") {
		return text
	}
	// Dropping a line shifts every line number after it, so this pass rebuilds the map too - it
	// carries each kept line's existing origin through rather than counting from one.
	mb := mapped_builder_make(len(text), allocator)
	index := 0
	for line_start := 0; line_start <= len(text); {
		newline := strings.index_byte(text[line_start:], '\n')
		if newline < 0 {
			mb_write_mapped(&mb, text[line_start:], origins_slice(state, index, len(state.origins)))
			break
		}
		past := line_start + newline + 1
		if !strings.has_prefix(text[line_start:], "//") {
			mb_write_mapped(&mb, text[line_start:past], origins_slice(state, index, index + 1))
		}
		index += 1
		line_start = past
	}
	state.origins = mb.origins
	return strings.to_string(mb.out)
}

/*
Split the document into blocks on blank lines.

A separator is two or more line endings in a row, where the lines between may hold spaces. One line
ending does not separate: prose wraps across lines inside a single paragraph.
*/
@(private = "file")
split_blocks :: proc(text: string, allocator := context.allocator) -> []string {
	blocks := make([dynamic]string, allocator)
	start := 0
	i := 0
	for i < len(text) {
		if text[i] != '\n' {
			i += 1
			continue
		}
		endings := 1
		cursor := i + 1
		for {
			spaces := cursor
			for spaces < len(text) && text[spaces] == ' ' {
				spaces += 1
			}
			if spaces < len(text) && text[spaces] == '\n' {
				endings += 1
				cursor = spaces + 1
				continue
			}
			break
		}
		if endings >= 2 {
			append(&blocks, text[start:i])
			start = cursor
			i = cursor
			continue
		}
		i += 1
	}
	if start < len(text) {
		append(&blocks, text[start:])
	}
	return blocks[:]
}

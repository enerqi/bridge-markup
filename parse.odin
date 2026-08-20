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
	resolve_include: Include_Resolver,
	include_user:    rawptr,
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
	// Problems that did not stop the parse. Always safe to ignore.
	diagnostics: []string,
	arena:       virtual.Arena,
}

/*
Parse BML source into blocks.

Takes SOURCE TEXT rather than a path, which is the whole point of the port: a live preview renders
the buffer someone is still typing, and it has not been saved anywhere.
*/
parse :: proc(source: string, options := Parse_Options{}) -> ^Document {
	doc := new(Document)
	_ = virtual.arena_init_growing(&doc.arena)
	allocator := virtual.arena_allocator(&doc.arena)

	state: Parse_State
	parse_state_init(&state, allocator)

	text := normalise_newlines(source, allocator)
	text = expand_includes(&state, text, options)
	text = strip_comment_lines(text, allocator)

	blocks := make([dynamic]Block, allocator)
	for chunk in split_blocks(text, allocator) {
		if block, ok := classify_block(&state, chunk); ok {
			append(&blocks, block)
		}
	}

	doc.blocks = blocks[:]
	doc.meta = state.meta
	doc.diagnostics = state.diagnostics[:]
	return doc
}

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
	out := strings.builder_make(0, len(source), state.allocator)
	written := 0
	for line_start := 0; line_start <= len(source); {
		newline := strings.index_byte(source[line_start:], '\n')
		line_end := newline < 0 ? len(source) : line_start + newline
		past := newline < 0 ? len(source) : line_end + 1
		line := source[line_start:line_end]

		if name, ok := match_include_line(line); ok {
			strings.write_string(&out, source[written:line_start])
			// The reference wraps the included text in newlines, so the file's first and last
			// blocks cannot fuse with whatever surrounded the directive.
			strings.write_byte(&out, '\n')
			if options.resolve_include != nil {
				if text, resolved := options.resolve_include(name, options.include_user, state.allocator); resolved {
					strings.write_string(&out, normalise_newlines(text, state.allocator))
				} else {
					diagnose(state, "#INCLUDE %v: could not be read", name)
				}
			} else {
				diagnose(state, "#INCLUDE %v: includes are not resolved here", name)
			}
			strings.write_byte(&out, '\n')
			written = past
		}
		if newline < 0 {
			break
		}
		line_start = past
	}
	if written == 0 {
		return source
	}
	strings.write_string(&out, source[written:])
	return strings.to_string(out)
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
strip_comment_lines :: proc(text: string, allocator := context.allocator) -> string {
	if !strings.contains(text, "//") {
		return text
	}
	out := strings.builder_make(0, len(text), allocator)
	for line_start := 0; line_start <= len(text); {
		newline := strings.index_byte(text[line_start:], '\n')
		if newline < 0 {
			strings.write_string(&out, text[line_start:])
			break
		}
		past := line_start + newline + 1
		if !strings.has_prefix(text[line_start:], "//") {
			strings.write_string(&out, text[line_start:past])
		}
		line_start = past
	}
	return strings.to_string(out)
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

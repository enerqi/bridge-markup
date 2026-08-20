package bml

import "core:fmt"
import "core:strings"

/*
The clipboard directives, run over a block before its rows are read.

	#CUT name      ... #ENDCUT     store the region and REMOVE it from the text
	#COPY name     ... #ENDCOPY    store the region and LEAVE it in the text
	#PASTE name [target=replacement ...]

A stored region is dedented by the indentation of its opening directive, and a paste re-indents it to
the paste site, so the same fragment can be dropped in at any depth of a bid table.

None of these are used anywhere in the bridge corpus, so corpus parity cannot exercise them; they
have their own tests instead.
*/
@(private)
apply_clipboard_directives :: proc(state: ^Parse_State, text: string) -> string {
	work := text
	for {
		next := take_clipboard_block(state, work, "CUT", "#ENDCUT", remove_body = true) or_break
		work = next
	}
	for {
		next := take_clipboard_block(state, work, "COPY", "#ENDCOPY", remove_body = false) or_break
		work = next
	}
	for {
		next := apply_paste(state, work) or_break
		work = next
	}
	return work
}

// One directive line, located: `<indent>#<spaces><keyword><spaces><key><args>`.
@(private = "file")
Directive :: struct {
	// Offset of the line's first character, and how far it was indented.
	start:     int,
	indent:    int,
	key:       string,
	// The rest of the line after the key, trimmed - `#PASTE`'s `target=replacement` pairs.
	args:      string,
	// Offset just past the line's newline.
	line_past: int,
}

/*
Find one `#CUT`/`#COPY` block, store it, and return the text with the directive consumed.

The end marker is the LAST one in the text rather than the nearest, which is what the python's greedy
`(.*)#ENDCUT` does. Two blocks in one paragraph therefore fold into one - faithful to the reference,
and unreachable from the corpus.
*/
@(private = "file")
take_clipboard_block :: proc(
	state: ^Parse_State,
	text: string,
	keyword: string,
	end_marker: string,
	remove_body: bool,
) -> (
	result: string,
	ok: bool,
) {
	directive := find_directive(text, keyword) or_return
	body_end := strings.last_index(text, end_marker)
	if body_end < directive.line_past {
		return text, false
	}
	body := text[directive.line_past:body_end]
	key := strings.clone(directive.key, state.allocator)
	state.clipboard[key] = dedent(body, directive.indent, state.allocator)

	consumed := body_end + len(end_marker)
	for consumed < len(text) && text[consumed] == ' ' {
		consumed += 1
	}
	if consumed < len(text) && text[consumed] == '\n' {
		consumed += 1
	}

	out := strings.builder_make(0, len(text), state.allocator)
	strings.write_string(&out, text[:directive.start])
	if !remove_body {
		strings.write_string(&out, body)
	}
	strings.write_string(&out, text[consumed:])
	return strings.to_string(out), true
}

@(private = "file")
apply_paste :: proc(state: ^Parse_State, text: string) -> (result: string, ok: bool) {
	directive := find_directive(text, "PASTE") or_return

	stored, found := state.clipboard[directive.key]
	if !found {
		diagnose(state, "#PASTE %v: nothing was cut or copied under that name", directive.key)
	}
	for pair in strings.fields(directive.args, context.temp_allocator) {
		eq := strings.index_byte(pair, '=')
		if eq < 0 {
			diagnose(state, "#PASTE %v: %q is not target=replacement", directive.key, pair)
			continue
		}
		stored, _ = strings.replace_all(stored, pair[:eq], pair[eq + 1:], context.temp_allocator)
	}

	out := strings.builder_make(0, len(text) + len(stored), state.allocator)
	strings.write_string(&out, text[:directive.start])
	rest := stored
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if !first {
			strings.write_byte(&out, '\n')
		}
		first = false
		for _ in 0 ..< directive.indent {
			strings.write_byte(&out, ' ')
		}
		strings.write_string(&out, line)
	}
	strings.write_byte(&out, '\n')
	strings.write_string(&out, text[directive.line_past:])
	return strings.to_string(out), true
}

// `#HIDE` marks a table as parsed but not rendered.
@(private)
take_hide_directive :: proc(text: string) -> (hidden: bool, rest: string) {
	directive, ok := find_directive(text, "HIDE", needs_key = false)
	if !ok {
		return false, text
	}
	return true, strings.concatenate({text[:directive.start], text[directive.line_past:]}, context.temp_allocator)
}

/*
`#BIDTABLE` says "read this block as a table" for blocks that do not look like one.

Only ever at the very START of a block: the python's substitution is anchored to the start of the
string rather than to each line, so a `#BIDTABLE` further down does nothing.
*/
@(private)
take_bidtable_directive :: proc(text: string) -> string {
	directive, ok := find_directive(text, "BIDTABLE", needs_key = false)
	if !ok || directive.start != 0 {
		return text
	}
	return text[directive.line_past:]
}

@(private = "file")
find_directive :: proc(text: string, keyword: string, needs_key := true) -> (directive: Directive, ok: bool) {
	line_start := 0
	for line_start <= len(text) {
		newline := strings.index_byte(text[line_start:], '\n')
		line_end := newline < 0 ? len(text) : line_start + newline
		past := newline < 0 ? len(text) : line_end + 1
		line := text[line_start:line_end]

		if found, key, args := match_directive_line(line, keyword, needs_key); found {
			return Directive {
					start = line_start,
					indent = leading_space_count(line),
					key = key,
					args = args,
					line_past = past,
				},
				true
		}
		if newline < 0 {
			break
		}
		line_start = past
	}
	return {}, false
}

@(private = "file")
match_directive_line :: proc(line, keyword: string, needs_key: bool) -> (ok: bool, key, args: string) {
	cursor := leading_space_count(line)
	if cursor >= len(line) || line[cursor] != '#' {
		return false, "", ""
	}
	cursor += 1
	for cursor < len(line) && line[cursor] == ' ' {
		cursor += 1
	}
	if !strings.has_prefix(line[cursor:], keyword) {
		return false, "", ""
	}
	cursor += len(keyword)

	gap := cursor
	for cursor < len(line) && is_space_byte(line[cursor]) {
		cursor += 1
	}
	if !needs_key {
		// A bare directive owns its whole line; anything after it means this is not that directive.
		return cursor == len(line), "", ""
	}
	if cursor == gap {
		return false, "", "" // `#CUTLERY` is not `#CUT lery`
	}
	key_end := cursor
	for key_end < len(line) && !is_space_byte(line[key_end]) {
		key_end += 1
	}
	if key_end == cursor {
		return false, "", ""
	}
	return true, line[cursor:key_end], strings.trim_space(line[key_end:])
}

// Drop `count` leading characters from every line, the dedent a stored region gets.
@(private = "file")
dedent :: proc(text: string, count: int, allocator := context.allocator) -> string {
	out := strings.builder_make(0, len(text), allocator)
	rest := text
	first := true
	for line in strings.split_lines_iterator(&rest) {
		if !first {
			strings.write_byte(&out, '\n')
		}
		first = false
		strings.write_string(&out, len(line) > count ? line[count:] : "")
	}
	return strings.to_string(out)
}

@(private)
diagnose :: proc(state: ^Parse_State, format: string, args: ..any) {
	append(&state.diagnostics, fmt.aprintf(format, ..args, allocator = state.allocator))
}

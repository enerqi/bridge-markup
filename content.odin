package bml

import "core:strings"

/*
The kinds of block a `.bml` document is made of.

A document is split on blank lines and each block is classified once, by shape. Only some of these
reach html - `Diagram`, `Table`, `Bidding` and `Description` are recognised and then ignored by the
renderer, exactly as the python's `to_html` ignores them. They still have to be classified correctly:
a diagram that fell through to `Paragraph` would start appearing in the output.
*/
Content_Kind :: enum {
	Bidtable,
	Paragraph,
	H1,
	H2,
	H3,
	H4,
	List,
	Enum,
	Diagram,
	Table,
	Description,
	Bidding,
	// `#+CAPTION: text`: a title over the block under it, not a heading (no anchor). `text` holds it.
	Caption,
	// `#BOX` and `#ENDBOX`, each a block of its own (`box_split`): what is between them is drawn as a box of
	// two columns, the diagram / auction / table / caption it starts with on the left, the text beside it.
	Box,
	End_Box,
}

/*
One classified block. Which fields carry anything depends on `kind` - see the comments below.

It is a struct with unused fields rather than a union because consumers switch on `kind` and then
read one field; a union would buy 40-odd bytes per block and cost every caller a type assertion.
Blocks are arena-allocated with the document and die with it.
*/
Block :: struct {
	kind:    Content_Kind,
	// `Paragraph`, the headings and `Caption`; a `Box`'s title.
	text:    string,
	// A `Box`'s callout type: "note", "info", "tip", "warning", or "" (a constant, not allocated).
	variant: string,
	// The headings', `Caption`'s and `Box`'s class hook (`class_hook`): its classes, space separated; "" for none.
	classes: string,
	// `List`, `Enum` and `Description`.
	items:   []string,
	// `Table` and `Bidding`, row by row.
	rows:    [][]string,
	// `Bidtable`.
	tree:    ^Node,
	diagram: Diagram,
}

// A deal diagram. Every field is optional - the notes often show two hands and no auction.
Diagram :: struct {
	// Each hand is the four suits, north/east/south/west, and `has_*` says whether it was given.
	north:        [4]string,
	east:         [4]string,
	south:        [4]string,
	west:         [4]string,
	has_north:    bool,
	has_east:     bool,
	has_south:    bool,
	has_west:     bool,
	dealer:       string, // "N", "E", "S" or "W"
	vul:          string, // "All", "None", "EW" or "NS"
	board:        string,
	lead_suit:    string, // "s", "h", "d" or "c"
	lead_rank:    string,
	// A contract is level + strain + doubling + declarer, or the single strain "P" for a passout.
	level:        string,
	strain:       string,
	doubling:     string,
	declarer:     string,
	has_contract: bool,
}

/*
Classify one block, and fold `#VUL`, `#SEAT` and `#+META:` lines into the parse state.

Returns `ok = false` for a block that produced no content: the settings directives, a metadata line,
and whitespace all land here.

# THE ORDER OF THESE TESTS IS LOAD-BEARING

They are tried in sequence and the FIRST MATCH WINS. Several blocks satisfy more than one test - a
bid table's first row starts with a digit and so does an auction table's first token; a diagram line
starts with a letter and so does prose - so this is not a sequence that can be sorted, rearranged
into a switch on the first byte, or reasoned about one clause at a time. Reordering silently
reclassifies real corpus content, and the symptom is not a crash: it is a paragraph appearing where
a diagram used to be dropped.

A block that matches NOTHING falls through to the paragraph test, which accepts anything holding a
non-space character. That is the trap. A block kind whose detection is too strict does not vanish -
it becomes a visible paragraph. This matters most for the kinds html never renders (`Diagram`,
`Table`, `Bidding`, `Description`): they are dropped by the renderer, so detecting them correctly is
the only thing keeping them out of the output.

# IT IS ALSO STATEFUL

`#VUL`, `#SEAT` and `#+META:` mutate `state` as they go past, and every bid table built afterwards
inherits the current vulnerability and seat. Blocks must therefore be classified strictly in
document order, one at a time - this loop must not become parallel. Each block is a few microseconds
of work, so there is nothing to gain by trying.
*/
@(private)
classify_block :: proc(state: ^Parse_State, text: string) -> (block: Block, ok: bool) {
	allocator := state.allocator

	// Before the classification, and independent of it: a misspelled directive is silently dropped
	// by every branch below, so it is reported here rather than by any one of them.
	if !state.in_rest && strings.contains(text, "#") {
		check_directive_lines(state, text)
	}

	if is_box, end, variant, title := box_marker(text); is_box {
		if end {
			return Block{kind = .End_Box}, true
		}
		return Block {
				kind = .Box,
				variant = variant,
				text = strings.clone(title, allocator),
				classes = box_classes(text, allocator),
			},
			true
	}

	// Headings, deepest first - `**` also starts with `*`.
	heading_markers := [?]string{"****", "***", "**", "*"}
	heading_kinds := [?]Content_Kind{.H4, .H3, .H2, .H1}
	for level, i in heading_markers {
		if strings.has_prefix(text, level) {
			heading, classes := class_hook(strings.trim_left_space(text[len(level):]), allocator)
			return Block{kind = heading_kinds[i], text = strings.clone(heading, allocator), classes = classes}, true
		}
	}

	// A caption line: the caption here, and the rest of the block goes round the parse loop again.
	if caption, is_caption := caption_line(text); is_caption {
		newline := strings.index_byte(text, '\n')
		state.diagram_rest = newline < 0 ? "" : text[newline + 1:]
		caption_text, classes := class_hook(caption, allocator)
		return Block{kind = .Caption, text = strings.clone(caption_text, allocator), classes = classes}, true
	}

	if starts_with_after_space(text, "-") {
		// ` :: ` anywhere in the block turns the list into a description list.
		kind: Content_Kind = strings.contains(text, " :: ") ? .Description : .List
		return Block{kind = kind, items = split_list_items(text, '-', allocator)}, true
	}

	if starts_with_after_space(text, "#VUL") {
		state.vulnerability = second_field(text, allocator)
		return {}, false
	}
	if starts_with_after_space(text, "#SEAT") {
		state.seat = second_field(text, allocator)
		return {}, false
	}

	if starts_with_after_space(text, "1.") {
		return Block{kind = .Enum, items = split_enum_items(text, allocator)}, true
	}

	if is_bidding_block(text) {
		return Block{kind = .Bidding, rows = split_whitespace_rows(text, allocator)}, true
	}

	if looks_like_bidtable(text) {
		tree := create_bidtree(state, text)
		if tree == nil {
			return {}, false
		}
		return Block{kind = .Bidtable, tree = tree}, true
	}

	if starts_with_after_space(text, "|") {
		return Block{kind = .Table, rows = split_pipe_rows(text, allocator)}, true
	}

	// A diagram with text before or after it in the same block (`split_diagram`): text before is classified
	// here and the rest goes round the parse loop again; then the diagram, and the text after goes round.
	if before, head, after, split := split_diagram(text); split {
		if len(strings.trim_space(before)) > 0 {
			in_rest := state.in_rest
			state.in_rest = true // its directive lines were checked with the whole block
			block, ok = classify_block(state, before)
			state.in_rest = in_rest
			state.diagram_rest = text[len(before) + 1:]
			return block, ok
		}
		if diagram, is_diagram := parse_diagram(head, allocator); is_diagram {
			state.diagram_rest = after
			return Block{kind = .Diagram, diagram = diagram}, true
		}
	}
	if diagram, is_diagram := parse_diagram(text, allocator); is_diagram {
		return Block{kind = .Diagram, diagram = diagram}, true
	}

	if key, value, is_meta := match_meta_line(text); is_meta {
		// First value for a key wins, so a chapter cannot overwrite the document's title.
		if key not_in state.meta {
			state.meta[strings.clone(key, allocator)] = strings.clone(value, allocator)
		}
		return {}, false
	}

	// A `#`-led block that was none of the above is a directive-only block: `#CUT` definitions and
	// the like. It goes through the bid table builder, which consumes the directives and usually
	// finds no rows left.
	if starts_with_after_space(text, "#") {
		tree := create_bidtree(state, text)
		if tree == nil {
			return {}, false
		}
		return Block{kind = .Bidtable, tree = tree}, true
	}

	if !has_non_space(text) {
		return {}, false
	}
	// Prose keeps its line breaks but loses the indentation that came with them.
	return Block{kind = .Paragraph, text = unindent_wrapped_prose(text, allocator)}, true
}

/*
Is `line` a `#BOX` or `#ENDBOX` marker (any case, spaces around it and after the `#`)? A `#BOX` line can go on:
`#BOX note|info|tip|warning Title` is a callout of that type (`variant`, lower case) with a title, `#BOX Title` a plain
frame with one. The python reference's `_BOX_RE` and `_box_payload`.
*/
@(private)
box_marker :: proc(line: string) -> (is_box: bool, end: bool, variant: string, title: string) {
	rest := strings.trim(line, " \t")
	if !strings.has_prefix(rest, "#") {
		return
	}
	rest = strings.trim_left(rest[1:], " \t")
	if equal_fold_ascii(rest, "ENDBOX") {
		return true, true, "", ""
	}
	if len(rest) < 3 || !equal_fold_ascii(rest[:3], "BOX") || (len(rest) > 3 && rest[3] != ' ' && rest[3] != '\t') {
		return
	}
	words, _ := class_hook(strings.trim(rest[3:], " \t"), context.temp_allocator)
	first := 0
	for first < len(words) && words[first] != ' ' && words[first] != '\t' {
		first += 1
	}
	for kind in ([]string{"note", "info", "tip", "warning"}) {
		if first > 0 && equal_fold_ascii(words[:first], kind) {
			return true, false, kind, strings.trim_left(words[first:], " \t")
		}
	}
	return true, false, "", words
}

// The class hook of a `#BOX` line (`box_marker` takes it off the title).
@(private)
box_classes :: proc(line: string, allocator := context.allocator) -> string {
	_, classes := class_hook(strings.trim(line, " \t"), allocator)
	return classes
}

/*
A CLASS HOOK: `{.name}` (or `{.one .two}`) at the end of a heading, a `#BOX` line or a `#+CAPTION:` line, after a
space or tab or alone, gives what that line makes those CSS classes, for a stylesheet of the author's own to aim
at. Returns the text without the hook and the classes, space separated ("" and the text unchanged for none).
Names are ASCII: a letter or `_`, then letters, digits, `_` or `-`. The python reference's `_class_hook`.
*/
@(private)
class_hook :: proc(text: string, allocator := context.allocator) -> (rest: string, classes: string) {
	end := len(text)
	// Spaces after it, and newlines: the last block of a file keeps its own.
	for end > 0 && (text[end - 1] == ' ' || text[end - 1] == '\t' || text[end - 1] == '\n' || text[end - 1] == '\r') {
		end -= 1
	}
	if end == 0 || text[end - 1] != '}' {
		return text, ""
	}
	open := strings.last_index_byte(text[:end], '{')
	if open < 0 {
		return text, ""
	}
	names := make([dynamic]string, context.temp_allocator)
	at := open + 1
	for at < end - 1 {
		for at < end - 1 && (text[at] == ' ' || text[at] == '\t') {
			at += 1
		}
		if at == end - 1 {
			break
		}
		if text[at] != '.' || at + 1 >= end - 1 || !is_class_start(text[at + 1]) {
			return text, ""
		}
		start := at + 1
		at = start + 1
		for at < end - 1 && is_class_char(text[at]) {
			at += 1
		}
		append(&names, text[start:at])
	}
	if len(names) == 0 {
		return text, ""
	}
	before := open
	for before > 0 && (text[before - 1] == ' ' || text[before - 1] == '\t') {
		before -= 1
	}
	if before == open && open != 0 {
		return text, "" // glued to the word before it: `Title{.x}` is text
	}
	return text[:before], strings.join(names[:], " ", allocator)
}

@(private = "file")
is_class_start :: #force_inline proc "contextless" (ch: u8) -> bool {
	return ch == '_' || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
}

@(private = "file")
is_class_char :: #force_inline proc "contextless" (ch: u8) -> bool {
	return is_class_start(ch) || ch == '-' || (ch >= '0' && ch <= '9')
}

// A block cut at its `#BOX` / `#ENDBOX` lines, each marker a piece of its own; just the block when it has
// none. The pieces are slices of `block`, so positions still map back to the source.
@(private)
box_split :: proc(block: string, allocator := context.temp_allocator) -> []string {
	pieces := make([dynamic]string, 0, 1, allocator)
	run_start, at := 0, 0
	for at <= len(block) {
		end := strings.index_byte(block[at:], '\n')
		line_end := end < 0 ? len(block) : at + end
		if is_box, _, _, _ := box_marker(block[at:line_end]); is_box {
			if at > run_start {
				append(&pieces, block[run_start:at - 1]) // without the newline before the marker
			}
			append(&pieces, block[at:line_end])
			run_start = line_end + 1
		}
		at = line_end + 1
	}
	if run_start < len(block) {
		append(&pieces, block[run_start:])
	}
	return pieces[:]
}

// The caption of a block whose first line is `#+CAPTION: text` (any case, spaces or tabs before it).
@(private)
caption_line :: proc(text: string) -> (caption: string, ok: bool) {
	line := text
	if newline := strings.index_byte(text, '\n'); newline >= 0 {
		line = text[:newline]
	}
	at := 0
	for at < len(line) && (line[at] == ' ' || line[at] == '\t') {
		at += 1
	}
	MARKER :: "#+CAPTION:"
	if len(line) - at < len(MARKER) || !equal_fold_ascii(line[at:at + len(MARKER)], MARKER) {
		return "", false
	}
	return strings.trim_space(line[at + len(MARKER):]), true
}

/*
Does the block open a bid table?

The first clause is the original detection - a level bid written with letters, `2H ...` or `(2D ...`.
The second adds blocks whose first bid uses the `!x` suit shorthand or does not start with a digit
at all (`Pass--...`, `(2!d)`, `2!c = ...`); requiring a ` = ` somewhere keeps prose that merely opens
bid-shaped from being swallowed.
*/
@(private) // package-wide: the tidy pass (tidy.odin) classifies as the parse does
looks_like_bidtable :: proc(text: string) -> bool {
	body := text[leading_space_count(text):]
	if opens_with_lettered_bid(body) {
		return true
	}
	return opens_bidtable_row(body) && strings.contains(text, " = ")
}

// `\(?\d[A-Za-z]+` - optional bracket, a digit, then at least one letter.
@(private = "file")
opens_with_lettered_bid :: proc(body: string) -> bool {
	rest := strings.has_prefix(body, "(") ? body[1:] : body
	if len(rest) < 2 || !is_digit_byte(rest[0]) {
		return false
	}
	return is_letter_byte(rest[1])
}

@(private = "file")
opens_bidtable_row :: proc(body: string) -> bool {
	// A digit, bracketed or not, with any bid-ish tail: `2H`, `(2D`, `2!c`, `2N+`.
	rest := strings.has_prefix(body, "(") ? body[1:] : body
	if len(rest) > 0 && is_digit_byte(rest[0]) {
		return true
	}
	// An opponent's call in brackets, including the pseudo-bids.
	if strings.has_prefix(body, "(") {
		for word in ([?]string{"Pass", "P", "XX", "X", "Dbl", "Rdbl", "R", "any", "oth"}) {
			if strings.has_prefix(body[1:], word) {
				return true
			}
		}
		return false
	}
	// A bare call, but only where it is acting as a bid: followed by a compound separator or an
	// assignment. `X marks the spot` is prose.
	for word in ([?]string{"Pass", "XX", "X", "Dbl", "Rdbl"}) {
		if !strings.has_prefix(body, word) {
			continue
		}
		tail := body[len(word):]
		if strings.has_prefix(tail, "--") {
			return true
		}
		if strings.has_prefix(strings.trim_left_space(tail), "=") {
			return true
		}
	}
	return false
}

/*
An auction table: every token of its call rows a call (`is_call_token`), at least two of them - with a
`W N E S` row first if wanted, and notes after (`auction_parts`). A row can hold any number of calls, so an
auction that stops short, or one dealt by a seat other than the first column's (`-` for the seats before),
is still one. A bid table is not one: its `=` is not a call. Case-blind: `1d p 1s` is typed as often as
`1D P 1S`, and is written in capitals (`write_auction`). The python reference's `_is_auction` (bml.py).
*/
@(private) // package-wide: the tidy pass (tidy.odin) classifies as the parse does
is_bidding_block :: proc(text: string) -> bool {
	rows := make([dynamic][]string, context.temp_allocator)
	rest := text
	for line in strings.split_iterator(&rest, "\n") {
		if tokens := strings.fields(line, context.temp_allocator); len(tokens) > 0 {
			append(&rows, tokens)
		}
	}
	_, calls, _ := auction_parts(rows[:])
	count := 0
	for row in calls {
		for token in row {
			if !is_call_token(strings.to_upper(token, context.temp_allocator)) {
				return false
			}
			count += 1
		}
	}
	return count >= 2
}

/*
An auction's rows - each a list of tokens, none empty - as the `W N E S` row if the first is one (else nil),
the rows of calls, and the note rows. The notes start at the first row after a row of calls whose first
token starts `*` or `^1`; every row after it is a note, or a note's continuation. The python reference's
`auction_parts` (bml.py).
*/
@(private)
auction_parts :: proc(rows: [][]string) -> (header: []string, calls: [][]string, notes: [][]string) {
	rows := rows
	if len(rows) > 0 && is_seat_row(rows[0]) {
		header, rows = rows[0], rows[1:]
	}
	for row, i in rows {
		first := row[0]
		if i > 0 && (first[0] == '*' || (len(first) > 1 && first[0] == '^' && is_digit_byte(first[1]))) {
			return header, rows[:i], rows[i:]
		}
	}
	return header, rows, nil
}

// A row of seat letters, `W N E S` (or `w n e s`): an auction's header.
@(private)
is_seat_row :: proc(tokens: []string) -> bool {
	for token in tokens {
		switch token {
		case "N", "E", "S", "W", "n", "e", "s", "w":
		case:
			return false
		}
	}
	return true
}

/*
A call's MARK, after it: `!` alerted, `*` / `**` / `^1` for the note under the auction that explains it.
`core` is the call without it.
*/
@(private)
call_mark :: proc(token: string) -> (core, mark: string) {
	if strings.has_suffix(token, "!") {
		return token[:len(token) - 1], "!"
	}
	i := len(token)
	for i > 0 && token[i - 1] == '*' {
		i -= 1
	}
	if i < len(token) {
		return token[:i], token[i:]
	}
	for i > 0 && is_digit_byte(token[i - 1]) {
		i -= 1
	}
	if i < len(token) && i > 0 && token[i - 1] == '^' {
		return token[:i - 1], token[i - 1:]
	}
	return token, ""
}

/*
One call of an auction (in capitals): a level bid (`1H`, `3NT`, `2N`), P, X, XX, D, R, AP, `?` for the call
asked about, or `-` for a seat before the dealer; any of them in brackets for the opponents', and any with
a mark after (`call_mark`).
*/
@(private = "file")
is_call_token :: proc(token: string) -> bool {
	core, _ := call_mark(token)
	call := strings.trim_prefix(core, "(")
	call = strings.trim_suffix(call, ")")
	switch call {
	case "P", "X", "XX", "D", "R", "AP", "?", "-":
		return true
	}
	if len(call) < 2 || call[0] < '1' || call[0] > '7' {
		return false
	}
	switch call[1:] {
	case "C", "D", "H", "S", "N", "NT":
		return true
	}
	return false
}

// `#+KEYWORD: value`
@(private = "file")
match_meta_line :: proc(text: string) -> (key, value: string, ok: bool) {
	cursor := leading_space_count(text)
	if !strings.has_prefix(text[cursor:], "#+") {
		return "", "", false
	}
	cursor += 2
	key_start := cursor
	for cursor < len(text) && (is_letter_byte(text[cursor]) || is_digit_byte(text[cursor]) || text[cursor] == '_') {
		cursor += 1
	}
	if cursor == key_start || cursor >= len(text) || text[cursor] != ':' {
		return "", "", false
	}
	key = text[key_start:cursor]
	cursor += 1
	for cursor < len(text) && (text[cursor] == ' ' || text[cursor] == '\t') {
		cursor += 1
	}
	line_end := strings.index_byte(text[cursor:], '\n')
	value = line_end < 0 ? text[cursor:] : text[cursor:cursor + line_end]
	return key, value, true
}

@(private) // package-wide: the tidy pass (tidy.odin) classifies as the parse does
starts_with_after_space :: proc(text, prefix: string) -> bool {
	return strings.has_prefix(text[leading_space_count(text):], prefix)
}

@(private = "file")
has_non_space :: proc(text: string) -> bool {
	for i in 0 ..< len(text) {
		if !is_space_byte(text[i]) {
			return true
		}
	}
	return false
}

// The whitespace-separated field after the directive keyword, as `#VUL ALL` gives "ALL".
@(private = "file")
second_field :: proc(text: string, allocator := context.allocator) -> string {
	fields := strings.fields(text, context.temp_allocator)
	return len(fields) > 1 ? strings.clone(fields[1], allocator) : ""
}

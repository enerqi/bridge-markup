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
}

/*
One classified block. Which fields carry anything depends on `kind` - see the comments below.

It is a struct with unused fields rather than a union because consumers switch on `kind` and then
read one field; a union would buy 40-odd bytes per block and cost every caller a type assertion.
Blocks are arena-allocated with the document and die with it.
*/
Block :: struct {
	kind:    Content_Kind,
	// `Paragraph` and the headings.
	text:    string,
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

	// Headings, deepest first - `**` also starts with `*`.
	heading_markers := [?]string{"****", "***", "**", "*"}
	heading_kinds := [?]Content_Kind{.H4, .H3, .H2, .H1}
	for level, i in heading_markers {
		if strings.has_prefix(text, level) {
			heading := strings.trim_left_space(text[len(level):])
			return Block{kind = heading_kinds[i], text = strings.clone(heading, allocator)}, true
		}
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
Does the block open a bid table?

The first clause is the original detection - a level bid written with letters, `2H ...` or `(2D ...`.
The second adds blocks whose first bid uses the `!x` suit shorthand or does not start with a digit
at all (`Pass--...`, `(2!d)`, `2!c = ...`); requiring a ` = ` somewhere keeps prose that merely opens
bid-shaped from being swallowed.
*/
@(private = "file")
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
Four call-shaped tokens in a row make an auction table.

Each token is an optional bracket, an optional level, one strain-or-call letter and an optional
closing bracket: `1C  P  1H  P`.
*/
@(private = "file")
is_bidding_block :: proc(text: string) -> bool {
	cursor := leading_space_count(text)
	for _ in 0 ..< 4 {
		start := cursor
		if cursor < len(text) && text[cursor] == '(' {
			cursor += 1
		}
		if cursor < len(text) && '1' <= text[cursor] && text[cursor] <= '7' {
			cursor += 1
		}
		if cursor >= len(text) || !strings.contains(BIDDING_LETTERS, text[cursor:cursor + 1]) {
			return false
		}
		cursor += 1
		if cursor < len(text) && text[cursor] == ')' {
			cursor += 1
		}
		if cursor == start {
			return false
		}
		spaced := cursor
		for cursor < len(text) && is_space_byte(text[cursor]) {
			cursor += 1
		}
		if cursor == spaced && cursor < len(text) {
			return false // tokens must be separated by whitespace
		}
	}
	return true
}

@(private = "file")
BIDDING_LETTERS :: "NTPDRCHS"

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

@(private = "file")
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

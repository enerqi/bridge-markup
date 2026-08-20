package bml

import "core:strings"

/*
Split a bullet list into its items.

An item runs from just after its marker to the start of the next marker's LINE, so it keeps the
newline that ended it - which is why the rendered `<li>` has a line break before its closing tag, and
why that is not a bug to tidy away. Continuation lines belong to the item above them.

`marker` is `-` for a bullet list. Enumerated lists go through `split_enum_items`, which allows a
number in front of the dot.
*/
@(private)
split_list_items :: proc(text: string, marker: byte, allocator := context.allocator) -> []string {
	items := make([dynamic]string, allocator)
	cursor := 0
	item_start := -1
	for {
		sep_start, sep_end, found := next_marker(text, cursor, marker)
		if !found {
			break
		}
		if item_start >= 0 {
			append(&items, strings.clone(text[item_start:sep_start], allocator))
		}
		item_start = sep_end
		cursor = sep_end
	}
	if item_start >= 0 {
		append(&items, strings.clone(text[item_start:], allocator))
	}
	return items[:]
}

/*
Find the next `<line start><whitespace><marker><whitespace>` separator at or after `from`.

The whitespace on either side may cross newlines, matching the reference's `^\s*-\s*`: a marker
preceded by blank lines is still a marker, and the blank lines are part of the separator rather than
of the item before it.
*/
@(private = "file")
next_marker :: proc(text: string, from: int, marker: byte) -> (sep_start, sep_end: int, found: bool) {
	line_start := from
	for line_start <= len(text) {
		cursor := line_start
		for cursor < len(text) && is_space_byte(text[cursor]) {
			cursor += 1
		}
		if cursor < len(text) && text[cursor] == marker {
			cursor += 1
			for cursor < len(text) && is_space_byte(text[cursor]) {
				cursor += 1
			}
			return line_start, cursor, true
		}
		newline := strings.index_byte(text[line_start:], '\n')
		if newline < 0 {
			return 0, 0, false
		}
		line_start += newline + 1
	}
	return 0, 0, false
}

/*
Split an enumerated list: `1.`, `2.`, ... or a bare `.`.

The reference allows ZERO digits before the dot, so a line that is only a dot separates too.
*/
@(private)
split_enum_items :: proc(text: string, allocator := context.allocator) -> []string {
	items := make([dynamic]string, allocator)
	cursor := 0
	item_start := -1
	for {
		sep_start, sep_end, found := next_enum_marker(text, cursor)
		if !found {
			break
		}
		if item_start >= 0 {
			append(&items, strings.clone(text[item_start:sep_start], allocator))
		}
		item_start = sep_end
		cursor = sep_end
	}
	if item_start >= 0 {
		append(&items, strings.clone(text[item_start:], allocator))
	}
	return items[:]
}

@(private = "file")
next_enum_marker :: proc(text: string, from: int) -> (sep_start, sep_end: int, found: bool) {
	line_start := from
	for line_start <= len(text) {
		cursor := line_start
		for cursor < len(text) && is_space_byte(text[cursor]) {
			cursor += 1
		}
		// Zero digits is allowed, so a line that is only a dot separates too.
		for cursor < len(text) && is_digit_byte(text[cursor]) {
			cursor += 1
		}
		if cursor < len(text) && text[cursor] == '.' {
			cursor += 1
			for cursor < len(text) && is_space_byte(text[cursor]) {
				cursor += 1
			}
			return line_start, cursor, true
		}
		newline := strings.index_byte(text[line_start:], '\n')
		if newline < 0 {
			return 0, 0, false
		}
		line_start += newline + 1
	}
	return 0, 0, false
}

// An auction table: every non-empty line split on whitespace.
@(private)
split_whitespace_rows :: proc(text: string, allocator := context.allocator) -> [][]string {
	rows := make([dynamic][]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if line == "" {
			continue
		}
		append(&rows, strings.fields(line, allocator))
	}
	return rows[:]
}

/*
A pipe table: the cells of each row are what follows each `|`.

The trailing cell after the final `|` counts, and a row that ends with a `|` simply has no cell
there. Empty rows contribute an empty row rather than being skipped.
*/
@(private)
split_pipe_rows :: proc(text: string, allocator := context.allocator) -> [][]string {
	rows := make([dynamic][]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		cells := make([dynamic]string, allocator)
		cursor := 0
		for cursor < len(line) {
			bar := strings.index_byte(line[cursor:], '|')
			if bar < 0 {
				break
			}
			cell_start := cursor + bar + 1
			next_bar := strings.index_byte(line[cell_start:], '|')
			cell_end := next_bar < 0 ? len(line) : cell_start + next_bar
			if cell_end > cell_start {
				append(&cells, strings.clone(strings.trim_space(line[cell_start:cell_end]), allocator))
			}
			cursor = cell_end
		}
		append(&rows, cells[:])
	}
	return rows[:]
}

// Prose keeps its line breaks but drops the indentation that a wrapped line came with.
@(private)
unindent_wrapped_prose :: proc(text: string, allocator := context.allocator) -> string {
	trimmed := strings.trim_space(text)
	out := strings.builder_make(0, len(trimmed), allocator)
	i := 0
	for i < len(trimmed) {
		strings.write_byte(&out, trimmed[i])
		if trimmed[i] == '\n' {
			i += 1
			for i < len(trimmed) && trimmed[i] == ' ' {
				i += 1
			}
			continue
		}
		i += 1
	}
	return strings.to_string(out)
}

/*
A deal diagram, if this block is one.

Hands are `N: AKQ2 J43 T98 765` lines, one per seat and in any order. The block counts as a diagram
when the hand lines account for all but at most two of its lines - the slack is the header line that
carries dealer, vulnerability, board number, opening lead and contract, and a possible trailing
blank.
*/
@(private)
parse_diagram :: proc(text: string, allocator := context.allocator) -> (Diagram, bool) {
	diagram: Diagram
	hands := 0
	lines := 0
	rest := text
	first_row := ""
	for line in strings.split_lines_iterator(&rest) {
		if lines == 0 {
			first_row = line
		}
		lines += 1
		seat, suits, ok := parse_hand_line(line, allocator)
		if !ok {
			continue
		}
		hands += 1
		switch seat {
		case 'N':
			diagram.north, diagram.has_north = suits, true
		case 'E':
			diagram.east, diagram.has_east = suits, true
		case 'S':
			diagram.south, diagram.has_south = suits, true
		case 'W':
			diagram.west, diagram.has_west = suits, true
		}
	}
	if hands == 0 || hands + 2 < lines {
		return {}, false
	}
	parse_diagram_header(&diagram, first_row, allocator)
	return diagram, true
}

@(private = "file")
parse_hand_line :: proc(line: string, allocator := context.allocator) -> (seat: byte, suits: [4]string, ok: bool) {
	cursor := leading_space_count(line)
	if cursor >= len(line) {
		return 0, {}, false
	}
	seat = line[cursor]
	if seat != 'N' && seat != 'E' && seat != 'S' && seat != 'W' {
		return 0, {}, false
	}
	cursor += 1
	if cursor < len(line) && line[cursor] == ':' {
		cursor += 1
	}
	for i in 0 ..< 4 {
		for cursor < len(line) && is_space_byte(line[cursor]) {
			cursor += 1
		}
		start := cursor
		for cursor < len(line) && is_card_byte(line[cursor]) {
			cursor += 1
		}
		if cursor == start {
			return 0, {}, false
		}
		suits[i] = strings.clone(line[start:cursor], allocator)
		// Every suit but the last must be followed by whitespace.
		if i < 3 && (cursor >= len(line) || !is_space_byte(line[cursor])) {
			return 0, {}, false
		}
	}
	return seat, suits, true
}

@(private = "file")
is_card_byte :: proc(c: byte) -> bool {
	return ('2' <= c && c <= '9') || c == 'A' || c == 'K' || c == 'Q' || c == 'J' || c == 'T' || c == 'x' || c == '-'
}

/*
Read the diagram's header line.

Every field is optional and they may come in any order, so each whitespace-separated token is tested
against every field in turn. A token may carry a trailing comma - `N, All, #7` - and the first token
that fits a field wins it.
*/
@(private = "file")
parse_diagram_header :: proc(diagram: ^Diagram, row: string, allocator := context.allocator) {
	for raw in strings.fields(row, context.temp_allocator) {
		token := strings.has_suffix(raw, ",") ? raw[:len(raw) - 1] : raw

		if diagram.dealer == "" && len(token) == 1 && strings.contains("NESW", token) {
			diagram.dealer = strings.clone(token, allocator)
			continue
		}
		if diagram.vul == "" {
			for name in ([?]string{"All", "None", "EW", "NS"}) {
				if token == name {
					diagram.vul = strings.clone(token, allocator)
					break
				}
			}
			if diagram.vul != "" {
				continue
			}
		}
		if diagram.board == "" {
			digits := strings.has_prefix(token, "#") ? token[1:] : token
			if len(digits) > 0 && all_digits(digits) {
				diagram.board = strings.clone(digits, allocator)
				continue
			}
		}
		if diagram.lead_suit == "" &&
		   len(token) == 2 &&
		   strings.contains("shdc", token[:1]) &&
		   is_lead_rank(token[1]) {
			diagram.lead_suit = strings.clone(token[:1], allocator)
			diagram.lead_rank = strings.clone(token[1:], allocator)
			continue
		}
		if !diagram.has_contract {
			if token == "PASS" {
				diagram.level = "P"
				diagram.has_contract = true
				continue
			}
			if level, strain, doubling, declarer, ok := parse_contract(token); ok {
				diagram.level = strings.clone(level, allocator)
				diagram.strain = strings.clone(strain, allocator)
				diagram.doubling = strings.clone(doubling, allocator)
				diagram.declarer = strings.clone(declarer, allocator)
				diagram.has_contract = true
			}
		}
	}
}

// `4SXN`: a level, a strain, an optional `X`/`XX`, and the declarer.
@(private = "file")
parse_contract :: proc(token: string) -> (level, strain, doubling, declarer: string, ok: bool) {
	if len(token) < 3 || !is_digit_byte(token[0]) {
		return "", "", "", "", false
	}
	if !strings.contains("SHDCN", token[1:2]) {
		return "", "", "", "", false
	}
	cursor := 2
	doubling_start := cursor
	for cursor < len(token) && token[cursor] == 'X' && cursor - doubling_start < 2 {
		cursor += 1
	}
	if cursor != len(token) - 1 {
		return "", "", "", "", false
	}
	if !strings.contains("NESW", token[cursor:cursor + 1]) {
		return "", "", "", "", false
	}
	return token[0:1], token[1:2], token[doubling_start:cursor], token[cursor:], true
}

@(private = "file")
is_lead_rank :: proc(c: byte) -> bool {
	return ('2' <= c && c <= '9') || c == 'A' || c == 'K' || c == 'Q' || c == 'J' || c == 'T'
}

@(private = "file")
all_digits :: proc(text: string) -> bool {
	for i in 0 ..< len(text) {
		if !is_digit_byte(text[i]) {
			return false
		}
	}
	return len(text) > 0
}

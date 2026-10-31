package bml

import "core:strings"

/*
Inline BML markup, parsed into element nodes AS TEXT ENTERS THE TREE rather than by rewriting
serialised html afterwards.

That ordering is the point. Building the tree first means the scanners never have to dodge tags, the
order of the passes stops mattering, and a link target - which has already been normalised into an
id - is never mistaken for a suit symbol. An opponent's bid in parens renders its suit glyph instead
of being suppressed by a lookahead written to protect the tags.

Two layers: the CONSTRUCTS that can contain further markup (links, strong, em, code) and the PLAIN
substitutions that cannot (suit runs, the `!x` shorthand, long dashes).
*/
//
// `conditions` says this is a bid table's description (`write_bidtable`): its seat and vulnerability conditions
// are tagged too (`condition_at`), inside links and styles as well.
@(private)
fill :: proc(parent: ^Element, text: string, allocator := context.allocator, conditions := Conditions.None) {
	pos := 0
	for {
		match, found := find_inline(text, pos)
		if !found {
			write_conditions(parent, text[pos:], allocator, conditions)
			return
		}
		if match.start > pos {
			write_conditions(parent, text[pos:match.start], allocator, conditions)
		}

		el := sub_element(parent, match.tag, allocator)
		if match.tag == "a" {
			set_attrib(el, "href", normalise_header_id(strings.trim_space(match.target), allocator))
			fill(el, strings.trim_space(match.inner), allocator, conditions)
		} else {
			fill(el, match.inner, allocator, conditions)
		}
		pos = match.end
	}
}

// Whether, and how, a description's conditions are tagged: the python reference's `_lone_seat` choice.
@(private)
Conditions :: enum {
	None,
	// The conditions, and a lone seat (`3rd`) only where it ends the text: `_LONE_SEAT_END_RE`.
	Tagged,
	// The row names seats already (`names_seats`): a lone seat anywhere but before a word that makes it
	// something else (`4th suit`): `_LONE_SEAT_RE`.
	Tagged_Seats,
}

/*
Plain text with its CONDITIONS drawn as small tags, `<span class="bml-cond">`, in a bid table's description;
just `write_plain` otherwise. A condition is where a meaning depends on the seat or the vulnerability: `(NV)` /
`(VUL)`, a bare `NV` / `VUL`, a list of seats `1st/2nd`, `3rd seat` / `4th position`, `passed hand(s)`, and a
lone seat (`lone_seat_at`). The python reference's `_COND_RE` and lone-seat patterns, matched by hand, the same
way round: the first condition from the left - at the same place a `_COND_RE` one - and the next looked for
after it.
*/
@(private = "file")
write_conditions :: proc(parent: ^Element, text: string, allocator := context.allocator, conditions := Conditions.None) {
	if conditions == .None {
		write_plain(parent, text, allocator)
		return
	}
	pos, i := 0, 0
	for i < len(text) {
		end := condition_at(text, i, conditions)
		if end <= i {
			i += 1
			continue
		}
		write_plain(parent, text[pos:i], allocator)
		tag := sub_element(parent, "span", allocator)
		set_attrib(tag, "class", "bml-cond")
		attach_text(tag, text[i:end], allocator)
		i, pos = end, end
	}
	write_plain(parent, text[pos:], allocator)
}

// A word character as python's ASCII `\b` sees one.
@(private = "file")
is_ascii_word_byte :: proc(c: byte) -> bool {
	return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z') || ('0' <= c && c <= '9') || c == '_'
}

@(private = "file")
ends_word :: proc(text: string, end: int) -> bool {
	return end >= len(text) || !is_ascii_word_byte(text[end])
}

@(private = "file")
is_ordinal :: proc(s: string) -> bool {
	return strings.has_prefix(s, "1st") || strings.has_prefix(s, "2nd") || strings.has_prefix(s, "3rd") || strings.has_prefix(s, "4th")
}

// `1st/2nd/3rd` at `text[i]`: the end of the longest run of `/ordinal` that ends a word (a regex `(?:/...)+\b`
// backs off one at a time), or -1.
@(private = "file")
seat_list_end :: proc(text: string, i: int) -> int {
	if !is_ordinal(text[i:]) {
		return -1
	}
	ends := make([dynamic]int, 0, 4, context.temp_allocator)
	end := i + 3
	for end + 1 < len(text) && text[end] == '/' && is_ordinal(text[end + 1:]) {
		end += 4
		append(&ends, end)
	}
	#reverse for candidate in ends {
		if ends_word(text, candidate) {
			return candidate
		}
	}
	return -1
}

// `3rd seat` / `4th position` at `text[i]`: its end, or -1.
@(private = "file")
seat_place_end :: proc(text: string, i: int) -> int {
	if !is_ordinal(text[i:]) {
		return -1
	}
	for place in ([]string{" seat", " position"}) {
		if strings.has_prefix(text[i + 3:], place) && ends_word(text, i + 3 + len(place)) {
			return i + 3 + len(place)
		}
	}
	return -1
}

// Does a description row name seats - a list or `Nth seat|position` (`_SEAT_CONTEXT_RE`)? Then a lone seat in it
// is one too (`Conditions.Tagged_Seats`).
@(private)
names_seats :: proc(row: string) -> bool {
	for i in 0 ..< len(row) {
		if i > 0 && is_ascii_word_byte(row[i - 1]) {
			continue
		}
		if seat_list_end(row, i) > 0 || seat_place_end(row, i) > 0 {
			return true
		}
	}
	return false
}

// The end of the condition starting at `text[i]`, or -1 - the alternatives of `_COND_RE` in its order, then a
// lone seat.
@(private = "file")
condition_at :: proc(text: string, i: int, conditions: Conditions) -> int {
	rest := text[i:]
	if strings.has_prefix(rest, "(NV)") {
		return i + 4
	}
	if strings.has_prefix(rest, "(VUL)") {
		return i + 5
	}
	// Every other alternative starts with `\b` at a word character.
	if i > 0 && is_ascii_word_byte(text[i - 1]) {
		return -1
	}
	for word in ([]string{"NV", "VUL"}) {
		if strings.has_prefix(rest, word) && ends_word(text, i + len(word)) {
			return i + len(word)
		}
	}
	if end := seat_list_end(text, i); end > 0 {
		return end
	}
	if end := seat_place_end(text, i); end > 0 {
		return end
	}
	// `(?:un)?[Pp]assed hands?`
	for start in ([]int{i + 2, i}) {
		if start == i + 2 && !strings.has_prefix(rest, "un") {
			continue
		}
		if start >= len(text) || (text[start] != 'P' && text[start] != 'p') || !strings.has_prefix(text[start + 1:], "assed hand") {
			continue
		}
		end := start + len("Passed hand")
		if end < len(text) && text[end] == 's' && ends_word(text, end + 1) {
			return end + 1
		}
		if ends_word(text, end) {
			return end
		}
	}
	return lone_seat_at(text, i, conditions)
}

/*
A LONE seat at `text[i]` (the `\b` before it already checked), `3rd`: its end, or -1. Not the start of a list
(`3rd/`). With `.Tagged` only where it ends the text - the end, `.;:)]`, or ` NV` / ` VUL` after it; not before
a comma or `or`, which list other things too (`1st or 2nd round control`, `(2nd, 3rd & 4th honour)`). With
`.Tagged_Seats` anywhere but before a word that makes it something else (`4th suit`, `2nd round`).
*/
@(private = "file")
lone_seat_at :: proc(text: string, i: int, conditions: Conditions) -> int {
	if !is_ordinal(text[i:]) || !ends_word(text, i + 3) {
		return -1
	}
	end := i + 3
	if end < len(text) && text[end] == '/' {
		return -1
	}
	after := text[end:]
	if conditions == .Tagged {
		if after == "" || strings.index_byte(".;:)]", after[0]) >= 0 {
			return end
		}
		for word in ([]string{" NV", " VUL"}) {
			if strings.has_prefix(after, word) && ends_word(text, end + len(word)) {
				return end
			}
		}
		return -1
	}
	Noun :: struct {
		word:   string,
		plural: bool,
	}
	NOUNS :: [?]Noun {
		{"suit", true},
		{"round", true},
		{"ask", false},
		{"honour", true},
		{"highest", false},
		{"step", false},
		{"bid", true},
		{"break", false},
		{"from", false},
		{"shortage", false},
		{"double", false},
		{"card", true},
		{"hand", true},
	}
	nouns := NOUNS
	for noun in nouns {
		if len(after) < 1 + len(noun.word) || after[0] != ' ' || !strings.has_prefix(after[1:], noun.word) {
			continue
		}
		past := end + 1 + len(noun.word)
		if ends_word(text, past) || (noun.plural && past < len(text) && text[past] == 's' && ends_word(text, past + 1)) {
			return -1
		}
	}
	return end
}

/*
One line of BML text as the html the renderer would put in its place: suit runs and `!x` as glyph spans,
long dashes, links, strong, em and code - `1C--1!s` becomes `1<span class="ccolor">...`. No block
structure, so it is for a heading or a table cell's text, not a document.

PUBLIC for a host that shows SOURCE text in its own html, the way the page would show it: the workbench's
heading palette lists headings as they read on the page rather than as they were typed.
*/
render_inline :: proc(text: string, allocator := context.allocator) -> string {
	root := element_make("span", context.temp_allocator)
	fill(root, text, context.temp_allocator)
	return serialise_content(root, allocator)
}

@(private = "file")
Inline_Match :: struct {
	start:  int,
	end:    int,
	tag:    string,
	inner:  string,
	target: string,
}

/*
The leftmost inline construct at or after `from`.

At any one position the alternatives are tried in the reference's order - link, strong, em, code -
so a `[` wins over a `*` that starts at the same index.
*/
@(private = "file")
find_inline :: proc(text: string, from: int) -> (match: Inline_Match, found: bool) {
	for i in from ..< len(text) {
		switch text[i] {
		case '[':
			if m, ok := match_link(text, i); ok {
				return m, true
			}
		case '*':
			// `*strong*` may open a text node or follow whitespace or a `>`.
			if i == 0 || is_space_byte(text[i - 1]) || text[i - 1] == '>' {
				if m, ok := match_delimited(text, i, '*', "strong"); ok {
					return m, true
				}
			}
		case '/':
			// `/em/` and `=code=` must follow whitespace, so mid-word `/` and `=` - "GF/FG",
			// "count = 15" - are left alone.
			if i == 0 || is_space_byte(text[i - 1]) {
				if m, ok := match_delimited(text, i, '/', "em"); ok {
					return m, true
				}
			}
		case '=':
			if i == 0 || is_space_byte(text[i - 1]) {
				if m, ok := match_delimited(text, i, '=', "code"); ok {
					return m, true
				}
			}
		case '_':
			// `_underline_` needs no boundary: a hand's honours are underlined inside a word, `A_*K*_JTx`.
			if m, ok := match_delimited(text, i, '_', "u"); ok {
				return m, true
			}
		}
	}
	return {}, false
}

// `[label](target)`: no brackets inside the label, no parens inside the target.
@(private = "file")
match_link :: proc(text: string, start: int) -> (match: Inline_Match, ok: bool) {
	label_end := -1
	for i in start + 1 ..< len(text) {
		if text[i] == '[' {
			return {}, false
		}
		if text[i] == ']' {
			label_end = i
			break
		}
	}
	if label_end < 0 || label_end + 1 >= len(text) || text[label_end + 1] != '(' {
		return {}, false
	}
	target_start := label_end + 2
	for i in target_start ..< len(text) {
		if text[i] == '(' {
			return {}, false
		}
		if text[i] == ')' {
			if i == target_start {
				return {}, false // the target must not be empty
			}
			return Inline_Match {
					start = start,
					end = i + 1,
					tag = "a",
					inner = text[start + 1:label_end],
					target = text[target_start:i],
				},
				true
		}
	}
	return {}, false
}

/*
`*strong*`, `/em/`, `=code=`.

The content is `\S(?:[^*]*\S)?` in the reference: a non-space character, then optionally a run
holding no delimiter followed by one more non-space character. The subtlety is that the TRAILING
`\S` matches a delimiter quite happily, so `**bold**` really does parse as strong-inside-strong -
the outer match takes `*bold*` as its content and the recursive fill finds emphasis again. The
published pages contain `<strong><strong>...</strong></strong>` for exactly that reason, so it is
behaviour to reproduce and not a bug to quietly fix here.

The run is greedy with backtracking, which is why the closing delimiter is searched for from the
FURTHEST candidate inwards: `*one*` has to fall back past the delimiter-as-content reading before it
finds the ordinary one.
*/
@(private = "file")
match_delimited :: proc(text: string, start: int, delimiter: byte, tag: string) -> (match: Inline_Match, ok: bool) {
	first := start + 1
	if first >= len(text) || is_space_byte(text[first]) {
		return {}, false
	}

	// How far a run containing no delimiter reaches.
	run_end := first + 1
	for run_end < len(text) && text[run_end] != delimiter {
		run_end += 1
	}

	last := min(run_end, len(text) - 1)
	for k := last; k >= first + 1; k -= 1 {
		if is_space_byte(text[k]) {
			continue
		}
		if k + 1 < len(text) && text[k + 1] == delimiter {
			return Inline_Match{start = start, end = k + 2, tag = tag, inner = text[first:k + 1]}, true
		}
	}
	// The optional run matched nothing: a single character between the delimiters.
	if first + 1 < len(text) && text[first + 1] == delimiter {
		return Inline_Match{start = start, end = first + 2, tag = tag, inner = text[first:first + 1]}, true
	}
	return {}, false
}

/*
The substitutions that cannot nest: a digit-led suit run, the `!x` shorthand, and the long dashes.

A suit run is a digit followed by suit letters, so `2C` becomes "2" and a club glyph. `N` is a suit
letter here only when it is NOT followed by `T`: that is what leaves `1NT` alone as literal text
while turning `2N` into "2NT" - the digit, then the letters spelled out.
*/
@(private = "file")
write_plain :: proc(parent: ^Element, text: string, allocator := context.allocator) {
	pos := 0
	i := 0
	for i < len(text) {
		if is_digit_byte(text[i]) {
			run_end := suit_run_end(text, i)
			if run_end > i + 1 {
				attach_text(parent, text[pos:i], allocator)
				attach_text(parent, text[i:i + 1], allocator)
				for c in transmute([]u8)text[i + 1:run_end] {
					if c == 'N' {
						attach_text(parent, "NT", allocator)
					} else {
						write_suit_span(parent, c, allocator)
					}
				}
				i = run_end
				pos = i
				continue
			}
		}
		if text[i] == '!' && i + 1 < len(text) && strings.contains("cdhs", text[i + 1:i + 2]) {
			attach_text(parent, text[pos:i], allocator)
			write_suit_span(parent, text[i + 1] - ('a' - 'A'), allocator)
			i += 2
			pos = i
			continue
		}
		if text[i] == '-' && i + 1 < len(text) && text[i + 1] == '-' {
			attach_text(parent, text[pos:i], allocator)
			if i + 2 < len(text) && text[i + 2] == '-' {
				attach_text(parent, "—", allocator) // em dash
				i += 3
			} else {
				attach_text(parent, "–", allocator) // en dash
				i += 2
			}
			pos = i
			continue
		}
		i += 1
	}
	attach_text(parent, text[pos:], allocator)
}

// How far a digit-led suit run reaches. `N` counts only when NOT followed by `T`, so `2N` is a run
// and `1NT` is not one at all - the run needs at least one letter, so the match fails outright and
// `1NT` stays literal text.
@(private = "file")
suit_run_end :: proc(text: string, digit_at: int) -> int {
	i := digit_at + 1
	for i < len(text) {
		c := text[i]
		if c == 'C' || c == 'D' || c == 'H' || c == 'S' {
			i += 1
			continue
		}
		if c == 'N' && (i + 1 >= len(text) || text[i + 1] != 'T') {
			i += 1
			continue
		}
		break
	}
	return i
}

@(private = "file")
write_suit_span :: proc(parent: ^Element, letter: byte, allocator := context.allocator) {
	span := sub_element(parent, "span", allocator)
	switch letter {
	case 'C':
		set_attrib(span, "class", "ccolor")
		span.text = "♣"
	case 'D':
		set_attrib(span, "class", "dcolor")
		span.text = "♦"
	case 'H':
		set_attrib(span, "class", "hcolor")
		span.text = "♥"
	case 'S':
		set_attrib(span, "class", "scolor")
		span.text = "♠"
	}
}

/*
The id form of a heading, used both for the heading's own `id` and for the targets that link to it.

Spaces become underscores and a `<digit><suit letter>` pair is lowercased, so a cross-reference
written `[1D](#1C--1D)` lands on the anchor the heading generated.
PUBLIC, and the reason is a second consumer rather than tidiness: a HOST that has both the source and the
rendered page needs to find the element a source heading became, and the rendered heading's TEXT will not
do it - `* 1!c opening` renders as `1<span class="ccolor">a</span> opening`, so nothing in the document
reads back as what was typed. The `id` is the only thing computed from the SOURCE text, which makes this
procedure the mapping between the two halves. (The workbench's notes editor scrolls its preview to the
heading the caret is under with it.)
*/
normalise_header_id :: proc(text: string, allocator := context.allocator) -> string {
	spaced, _ := strings.replace_all(text, " ", "_", context.temp_allocator)
	trimmed := strings.trim_space(spaced)

	out := strings.builder_make(0, len(trimmed), allocator)
	i := 0
	for i < len(trimmed) {
		if i + 1 < len(trimmed) && is_digit_byte(trimmed[i]) && strings.contains("CDHS", trimmed[i + 1:i + 2]) {
			strings.write_byte(&out, trimmed[i])
			strings.write_byte(&out, trimmed[i + 1] + ('a' - 'A'))
			i += 2
			continue
		}
		strings.write_byte(&out, trimmed[i])
		i += 1
	}
	return strings.to_string(out)
}

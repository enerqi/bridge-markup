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
@(private)
fill :: proc(parent: ^Element, text: string, allocator := context.allocator) {
	pos := 0
	for {
		match, found := find_inline(text, pos)
		if !found {
			write_plain(parent, text[pos:], allocator)
			return
		}
		if match.start > pos {
			write_plain(parent, text[pos:match.start], allocator)
		}

		el := sub_element(parent, match.tag, allocator)
		if match.tag == "a" {
			set_attrib(el, "href", normalise_header_id(strings.trim_space(match.target), allocator))
			fill(el, strings.trim_space(match.inner), allocator)
		} else {
			fill(el, match.inner, allocator)
		}
		pos = match.end
	}
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

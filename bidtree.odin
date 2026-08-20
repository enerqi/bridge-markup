package bml

import "core:strings"

/*
Parse one block of text into a bid table.

Returns nil when the block holds no rows, which is how the caller learns that a `#`-led block was a
directive (a `#CUT` definition, say) rather than a table.

Before any rows are read, the clipboard directives run: `#CUT`/`#ENDCUT` lifts a region out of the
text and stores it, `#COPY`/`#ENDCOPY` stores it and leaves it in place, and `#PASTE` drops a stored
region back in at the paste site's indentation, optionally rewriting `target=replacement` pairs
given on the paste line. None of these appear anywhere in the bridge corpus - only `#INCLUDE` does -
so they are covered by their own tests against the python rather than by corpus parity.
*/
create_bidtree :: proc(state: ^Parse_State, text: string) -> ^Node {
	allocator := state.allocator
	work := apply_clipboard_directives(state, text)

	root := new_node(ROOT_SENTINEL, ROOT_SENTINEL, -1, -1, nil, allocator)
	root.vul = state.vulnerability
	root.seat = state.seat

	if hidden, rest := take_hide_directive(work); hidden {
		root.export = false
		work = rest
	}
	work = take_bidtable_directive(work)

	if strings.trim_space(work) == "" {
		return nil
	}

	last := root
	for row in strings.split_lines_iterator(&work) {
		if strings.trim_space(row) == "" {
			continue
		}
		indentation := leading_space_count(row)
		stripped := strings.trim_space(row)

		// A line indented under the current bid that is not itself a bid row is a description
		// continuation - a line break inside the description. The test is the line's SHAPE (a
		// bid-like first token, or a ` = ` separator), not an absolute column, so a short bid like
		// `X` does not make a genuine child row collide with the parent's description column. And a
		// continuation need not be indented at all: a lettered prose list under a top-level bid
		// sits in the same column as the bid it explains.
		if indentation >= last.indentation && last.desc != ROOT_SENTINEL && !is_bid_row(stripped) {
			last.desc = strings.concatenate({last.desc, DESC_ROW_SEPARATOR, stripped}, allocator)
			continue
		}

		bid, desc, desc_indentation := split_bid_row(row, stripped, allocator)

		for indentation < last.indentation {
			last = last.parent
		}
		if indentation > last.indentation {
			last = add_child(last, bid, desc, indentation, desc_indentation, allocator)
		} else {
			// Same column as the previous row: a sibling, so it hangs off that row's parent.
			last = add_child(last.parent, bid, desc, indentation, desc_indentation, allocator)
		}
	}
	return root
}

/*
Split `<bid> <description>` and report the column the description began in.

The description keeps its own leading `=` stripped (`3C = artificial` and `3C artificial` are the
same row), and `desc_indentation` is measured against the ORIGINAL row so it still points at the
description after that `=` is gone.
*/
@(private = "file")
split_bid_row :: proc(
	row, stripped: string,
	allocator := context.allocator,
) -> (
	bid, desc: string,
	desc_indentation: int,
) {
	// Splitting on a single space and rejoining with one is the identity on the remainder, so the
	// python's `" ".join(row.split(" ")[1:])` is just "everything after the first space".
	space := strings.index_byte(stripped, ' ')
	if space < 0 {
		bid = stripped
		desc = ""
	} else {
		bid = stripped[:space]
		desc = strings.trim_space(stripped[space + 1:])
	}

	desc_indentation = desc == "" ? 0 : strings.index(row, desc)
	trimmed := trim_leading_equals(desc)
	desc_indentation += len(desc) - len(trimmed)
	return bid, strings.clone(trimmed, allocator), desc_indentation
}

// `= ` at the start of a description is a separator, not content.
@(private = "file")
trim_leading_equals :: proc(desc: string) -> string {
	if !strings.has_prefix(desc, "=") {
		return desc
	}
	i := 1
	for i < len(desc) && is_space_byte(desc[i]) {
		i += 1
	}
	return desc[i:]
}

/*
A new bid row, as opposed to a wrapped-description continuation line.

Bid rows are `<bid> = <desc>` (or `<bid> <desc>`, or a bare `<bid>`), where the bid may be a real
call, a pseudo-bid word (`any`, `other`), a compound sequence (`Pass--(1H)--X`), or any of those
wrapped in a markdown link. Pseudo-bids are caught by the ` = ` separator; genuine continuation
lines are prose with neither that nor a bid-like first token.
*/
@(private = "file")
is_bid_row :: proc(stripped: string) -> bool {
	first_token := stripped
	if label, ok := link_label(stripped); ok {
		first_token = label
	} else if space := strings.index_byte(stripped, ' '); space >= 0 {
		first_token = stripped[:space]
	}
	return looks_like_bid(first_token) || strings.contains(stripped, " = ")
}

/*
The label of a leading markdown link, `[1D](#1C--1D)` -> `1D`.

The link's TARGET may contain spaces (`(#1C Weak Strong)`), so the label cannot be found by splitting
on whitespace. The label itself must be a single word, which is what stops a prose line that merely
opens with a link from being read as a bid.
*/
@(private = "file")
link_label :: proc(text: string) -> (label: string, ok: bool) {
	if !strings.has_prefix(text, "[") {
		return "", false
	}
	close := -1
	for i in 1 ..< len(text) {
		c := text[i]
		if c == ']' {
			close = i
			break
		}
		if is_space_byte(c) {
			return "", false // whitespace inside the label: not a link bid
		}
	}
	if close <= 1 || close + 1 >= len(text) || text[close + 1] != '(' {
		return "", false
	}
	for i in close + 2 ..< len(text) {
		if text[i] == ')' {
			return text[1:close], true
		}
	}
	return "", false
}

/*
Does this token open a bid row?

An opponent bid in parens is always bracketed (`(2D)`, `(P)`, `(any)`); a level bid is a digit
followed by suits/NT and possibly `!x` shorthand, `+` or alternatives; and a bare pass/double/
redouble is spelled out. The trailing "not a letter" check is what stops `P`/`X`/`R` matching the
start of prose words like "Points" or "Xfer".
*/
@(private = "file")
looks_like_bid :: proc(token: string) -> bool {
	// ...except that "starts with (" also describes a lettered prose list nested in a bid table:
	//
	//     3C = artificial, multi-meaning.
	//     (a) minimum (semi)balanced no singleton
	//     (d) void hand, any strength
	//
	// which would otherwise become phantom auction positions. A bracketed SINGLE LETTER is a call
	// only for the call letters, matched case-sensitively: `(P)`, `(X)`, `(D)` are calls, `(a)` to
	// `(d)` are list markers. Bracketed WORDS stay bids - `(any)`, `(cue)`, `(overcall)` are real
	// pseudo-bid rows.
	if len(token) >= 3 && token[0] == '(' && token[2] == ')' && is_letter_byte(token[1]) {
		if !strings.contains(CALL_LETTERS, token[1:2]) {
			return false
		}
	}
	if len(token) == 0 {
		return false
	}
	if token[0] == '(' {
		return true
	}
	if is_digit_byte(token[0]) {
		return true
	}
	for word in BARE_CALL_WORDS {
		if strings.has_prefix(token, word) {
			rest := token[len(word):]
			if len(rest) == 0 || !is_letter_byte(rest[0]) {
				return true
			}
		}
	}
	return false
}

@(private = "file")
CALL_LETTERS :: "PXRD"

// Ordered longest-first within each initial, mirroring the python's alternation: `Pass` is tried
// before `P` and `XX` before `X`, so the longer spelling wins.
@(private = "file")
BARE_CALL_WORDS := [?]string{"Pass", "P", "XX", "X", "Dbl", "Rdbl", "R"}

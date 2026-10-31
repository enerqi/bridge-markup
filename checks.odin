package bml

import "core:strings"

/*
Checks that report a problem without changing what is rendered.

The parser is deliberately permissive - a block that matches nothing becomes a paragraph, a
directive it does not know is consumed by the bid table builder and disappears - which is right for a
build and useless for an editor. Nothing here alters a document; each check only appends to
`Parse_State.diagnostics`, so the html is byte-identical whether they run or not, and corpus parity
cannot notice them.
*/

/*
The directive keywords the parser acts on. Everything else beginning a line with `#` is a typo.

The list is the reference's, not an invention: `#CUT`/`#ENDCUT`, `#COPY`/`#ENDCOPY`, `#PASTE`,
`#HIDE`, `#BIDTABLE`, `#INCLUDE`, `#VUL`, `#SEAT`, and that is all of them. `#+KEY: value` is
metadata rather than a directive and is matched separately.
*/
@(private = "file")
KNOWN_DIRECTIVES :: [?]string {
	"INCLUDE",
	"CUT",
	"ENDCUT",
	"COPY",
	"ENDCOPY",
	"BOX",
	"ENDBOX",
	"PASTE",
	"HIDE",
	"BIDTABLE",
	"VUL",
	"SEAT",
}

/*
Report every line of a block that opens with a `#` keyword the parser does not know.

Why this is worth a check of its own: an unknown directive is SILENT. `#HDIE` is not a directive, so
the block falls through to the bid table builder, which finds no rows and returns nil, and the whole
block - directive, body and all - is dropped from the output. Nothing is logged and the page simply
comes up short, which is the hardest kind of mistake to find in a document.

Only a line whose first non-space character is `#` counts, so a `[label](#Anchor)` in the middle of
prose is not a directive and neither is a `#` inside a description.
*/
@(private)
check_directive_lines :: proc(state: ^Parse_State, text: string) {
	rest := text
	for len(rest) > 0 {
		newline := strings.index_byte(rest, '\n')
		line := newline < 0 ? rest : rest[:newline]
		rest = newline < 0 ? "" : rest[newline + 1:]

		cursor := leading_space_count(line)
		if cursor >= len(line) || line[cursor] != '#' {
			continue
		}
		// `#+TITLE:` and friends are metadata, and the reference allows spaces after the `#`.
		if cursor + 1 < len(line) && line[cursor + 1] == '+' {
			continue
		}
		keyword_start := cursor + 1
		for keyword_start < len(line) && is_space_byte(line[keyword_start]) {
			keyword_start += 1
		}
		keyword_end := keyword_start
		for keyword_end < len(line) && is_letter_byte(line[keyword_end]) {
			keyword_end += 1
		}
		keyword := line[keyword_start:keyword_end]
		if keyword == "" {
			continue
		}
		known := false
		for candidate in KNOWN_DIRECTIVES {
			if equal_fold_ascii(keyword, candidate) {
				known = true
				break
			}
		}
		if known {
			continue
		}
		at := span_of(state, line, within = cursor, length = keyword_end - cursor)
		diagnose_at(state, at, .Error, "#%v is not a directive, so this block is dropped", keyword)
	}
}

/*
Report every `[label](#Anchor)` that no heading in this document defines.

The anchors are generated from the heading text by `normalise_header_id`, the same procedure the
renderer uses for both ends of the link, so this asks exactly the question a reader's click asks.

OFF unless `Parse_Options.check_cross_references` says otherwise, because the corpus is chapters
assembled by a root document: a chapter opened on its own links to headings that exist, in a file it
does not include. See the option's own comment.
*/
@(private)
check_cross_references :: proc(state: ^Parse_State, blocks: []Block, known: []string = nil) {
	anchors := make(map[string]bool, 64, state.allocator)
	for id in known {
		anchors[id] = true
	}
	for block in blocks {
		switch block.kind {
		case .H1, .H2, .H3, .H4:
			anchors[normalise_header_id(block.text, state.allocator)] = true
		case .Bidtable, .Paragraph, .List, .Enum, .Diagram, .Table, .Description, .Bidding, .Caption, .Box, .End_Box:
		}
	}

	text := state.text
	cursor := 0
	for {
		found := strings.index(text[cursor:], "](#")
		if found < 0 {
			return
		}
		target_start := cursor + found + len("](")
		close := strings.index_byte(text[target_start:], ')')
		if close < 0 {
			return
		}
		target := text[target_start:target_start + close]
		cursor = target_start + close
		// `[Top](#)` is the page itself, which every document has.
		if len(target) <= 1 {
			continue
		}
		id := normalise_header_id(target[1:], state.allocator)
		if id in anchors {
			continue
		}
		at := span_at_offset(state, target_start, len(target))
		diagnose_at(state, at, .Warning, "no heading here defines the anchor %v", target)
	}
}

/*
Every anchor a parsed document's headings define, as `normalise_header_id` makes them, in `allocator`.
What `Parse_Options.known_anchors` takes: an editor gathers the headings of the assembled page a chapter is
read in, so the chapter's links to its siblings resolve.
*/
heading_anchors :: proc(doc: ^Document, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 64, allocator)
	for block in doc.blocks {
		#partial switch block.kind {
		case .H1, .H2, .H3, .H4:
			append(&out, normalise_header_id(block.text, allocator))
		}
	}
	return out[:]
}

/*
Report a bid-table row whose indentation nests it in a way that is easy to misread. Called by the table
builder for every bid row when `Parse_Options.check_indentation` is on, with `previous` the row before it
and `above` the row it was measured against after stepping back up (the same node when it did not step).

The tree is built by comparing columns, never by counting steps (`create_bidtree`), so 2, 4 or 3 spaces a
level all parse. What reads wrongly is different:

  - A TAB in the indent counts as one space, so a row that LOOKS a level deeper can be a sibling.
  - A step BACK to a column no row above uses (0, 4, then 2) nests the row under the nearest shallower
    bid, beside rows at another column - a sibling drawn where no sibling is.
  - A child ONE column in (a bid at 4, the next at 5) is a child, where one stray space was usually meant
    as a sibling.
*/
@(private)
check_row_indentation :: proc(state: ^Parse_State, row: string, indentation: int, previous, above: ^Node) {
	if strings.index_byte(row[:indentation], '\t') >= 0 {
		diagnose_at(
			state,
			span_of(state, row, length = indentation),
			.Warning,
			"this row is indented with a tab, which counts as one space: it may not nest as it looks",
		)
		return // and that is the whole story: a tab is one column, so it would be "one column in" too
	}
	stepped_back := previous != above
	if stepped_back && indentation > above.indentation {
		if above.desc == ROOT_SENTINEL {
			// The usual cause is not the column at all but a BLANK LINE further up: it ends the table, so the rows
			// after it are a new one whose first row is deeper than this (reported, 2diamond-opening.bml:304,
			// where `2N+` read as being under `2D` and was not). So the message names that first row and the cause.
			first, first_bid := 0, ""
			if len(above.children) > 0 {
				first, first_bid = above.children[0].indentation, above.children[0].bid
			}
			diagnose_at(
				state,
				span_of(state, row, length = indentation),
				.Warning,
				"this row is left of its table's first row (%v, column %v), so it is a top-level row - if it belongs under a bid further up, a blank line between them has ended the table",
				first_bid,
				first,
			)
		} else {
			diagnose_at(
				state,
				span_of(state, row, length = indentation),
				.Warning,
				"this row steps back to column %v, which no row above it uses: it nests under %v",
				indentation,
				above.bid,
			)
		}
	} else if !stepped_back && above.desc != ROOT_SENTINEL && indentation == above.indentation + 1 {
		diagnose_at(
			state,
			span_of(state, row, length = indentation),
			.Warning,
			"this row is one column deeper than %v, so it is that bid's child: one space is usually a slip",
			above.bid,
		)
	}
}

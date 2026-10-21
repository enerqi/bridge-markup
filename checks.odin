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
		case .Bidtable, .Paragraph, .List, .Enum, .Diagram, .Table, .Description, .Bidding:
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

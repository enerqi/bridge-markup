package bml

import "core:mem"
import "core:mem/virtual"
import "core:strings"

/*
Render a parsed document to html.

The output is meant to be byte-identical to the reference's `bml2html.py`, which is why the order
things are appended here looks arbitrary in places - the `<title>` really does go in last, after the
whole body has been built, and the reference's ElementTree emits it at the end of `<head>` because
of that.

Diagrams, pipe tables, description lists and auctions are rendered as the reference renders them
(`write_diagram` and the three after it, each mirroring a function of `bml2html.py`); they were dropped by
both until 2026-10-26.
*/
render_html :: proc(doc: ^Document, allocator := context.allocator) -> string {
	// The element tree is scratch: it exists only to be serialised.
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	build := virtual.arena_allocator(&scratch)

	html := element_make("html", build)
	head := sub_element(html, "head", build)

	stylesheet := sub_element(head, "link", build)
	set_attrib(stylesheet, "rel", "stylesheet")
	set_attrib(stylesheet, "type", "text/css")
	set_attrib(stylesheet, "href", "bml.css")

	font := sub_element(head, "link", build)
	set_attrib(font, "href", "https://fonts.googleapis.com/css?family=Open Sans")
	set_attrib(font, "rel", "stylesheet")

	// `#+CSS: mine.css` (several, space separated): the author's own stylesheets, after bml.css so their rules
	// win - aimed, usually, at the classes of `{.name}` hooks. Paths are the page's, relative to it.
	for href in strings.fields(doc.meta["CSS"] or_else "", build) {
		own := sub_element(head, "link", build)
		set_attrib(own, "rel", "stylesheet")
		set_attrib(own, "type", "text/css")
		set_attrib(own, "href", href)
	}

	charset := sub_element(head, "meta", build)
	set_attrib(charset, "charset", "UTF-8")

	keywords := sub_element(head, "meta", build)
	set_attrib(keywords, "name", "keywords")
	set_attrib(keywords, "content", "contract, bridge, bidding")

	body := sub_element(html, "body", build)
	set_attrib(body, "class", "content")

	// The `<h1>`s are collected on the way past and become the navigation list at the foot.
	Heading :: struct {
		id:   string,
		text: string,
	}
	headings := make([dynamic]Heading, build)

	// `#BOX`: the blocks go into its left column (`side`) while they are what sits beside text - a diagram,
	// an auction, a table, a caption - and the rest into its right column (`box_text`). `#ENDBOX`, a heading,
	// or another `#BOX` closes it. The box and each column are made when a block goes in: an empty one is
	// written `<div ... />`, which html does not close, so what follows would land inside it.
	//
	// `#BOX note|info|tip|warning Title` (or `#BOX Title`) puts the box in a CALLOUT frame (`frame`): a head with the
	// type's label and the title, made at once since the head is never empty, then the box inside it.
	//
	// A class hook (`{.name}`, `Block.classes`) adds its classes to what its line makes: the heading, the
	// caption, the callout frame - or, for a `#BOX {.name}` with no type or title, the box itself.
	parent := body
	box, side: ^Element
	box_classes := ""
	boxing := false
	frame := body
	for block in doc.blocks {
		#partial switch block.kind {
		case .Box, .End_Box, .H1, .H2, .H3, .H4:
			parent, box, side, boxing, frame = body, nil, nil, block.kind == .Box, body
			box_classes = block.kind == .Box ? block.classes : ""
		}
		if block.kind == .Box && (block.variant != "" || block.text != "") {
			frame = sub_element(body, "div", build)
			frame_class := block.variant != "" ? strings.concatenate({"bml-callout bml-", block.variant}, build) : "bml-callout"
			set_attrib(frame, "class", with_classes(frame_class, box_classes, build))
			box_classes = ""
			frame_head := sub_element(frame, "div", build)
			set_attrib(frame_head, "class", "bml-callout-head")
			if block.variant != "" {
				label := sub_element(frame_head, "span", build)
				set_attrib(label, "class", "bml-callout-label")
				attach_text(label, callout_label(block.variant), build)
				if block.text != "" {
					attach_text(frame_head, " ", build) // a real space: the workbench's preview ignores a margin on the label
				}
			}
			if block.text != "" {
				title := sub_element(frame_head, "span", build)
				set_attrib(title, "class", "bml-callout-title")
				fill(title, block.text, build)
			}
		}
		if block.kind == .Box || block.kind == .End_Box || (block.kind == .Bidtable && !block.tree.export) {
			continue
		}
		if boxing {
			beside := block.kind == .Diagram || block.kind == .Bidding || block.kind == .Table || block.kind == .Caption
			if box == nil {
				box = sub_element(frame, "div", build)
				set_attrib(box, "class", with_classes("bml-box", box_classes, build))
				parent = sub_element(box, "div", build)
				set_attrib(parent, "class", beside ? "bml-box-side" : "bml-box-text")
				side = beside ? parent : nil
			} else if parent == side && !beside {
				parent = sub_element(box, "div", build)
				set_attrib(parent, "class", "bml-box-text")
			}
		}
		switch block.kind {
		case .Paragraph:
			fill(sub_element(parent, "p", build), block.text, build)
		case .Bidtable:
			if !block.tree.export {
				continue
			}
			table := sub_element(parent, "div", build)
			set_attrib(table, "class", "bidtable")
			write_bidtable(table, block.tree.children[:], true, build)
		case .H1:
			id := normalise_header_id(block.text, build)
			append(&headings, Heading{id = id, text = block.text})
			heading := sub_element(body, "h1", build)
			set_attrib(heading, "id", id)
			if block.classes != "" {
				set_attrib(heading, "class", block.classes)
			}
			fill(heading, block.text, build)
		case .H2, .H3, .H4:
			tag := block.kind == .H2 ? "h2" : block.kind == .H3 ? "h3" : "h4"
			heading := sub_element(body, tag, build)
			set_attrib(heading, "id", normalise_header_id(block.text, build))
			if block.classes != "" {
				set_attrib(heading, "class", block.classes)
			}
			fill(heading, block.text, build)
		case .List:
			list := sub_element(parent, "ul", build)
			for item in block.items {
				fill(sub_element(list, "li", build), item, build)
			}
		case .Enum:
			list := sub_element(parent, "ol", build)
			for item in block.items {
				fill(sub_element(list, "li", build), item, build)
			}
		case .Diagram:
			write_diagram(parent, block.diagram, build)
		case .Table:
			write_table(parent, block.rows, build)
		case .Description:
			write_description(parent, block.items, build)
		case .Bidding:
			write_auction(parent, block.rows, build)
		case .Caption:
			caption := sub_element(parent, "div", build)
			set_attrib(caption, "class", with_classes("bml-caption", block.classes, build))
			fill(caption, block.text, build)
		case .Box, .End_Box:
		}
	}

	top := sub_element(body, "a", build)
	set_attrib(top, "class", "top-link")
	set_attrib(top, "href", "#")
	top.text = "Top"

	nav := sub_element(body, "div", build)
	set_attrib(nav, "class", "nav-links")
	for heading in headings {
		// One `<ul>` per link, which is what the reference builds.
		list := sub_element(nav, "ul", build)
		item := sub_element(list, "li", build)
		link := sub_element(item, "a", build)
		set_attrib(link, "href", strings.concatenate({"#", heading.id}, build))
		fill(link, heading.text, build)
	}

	title := sub_element(head, "title", build)
	title.text = doc.meta["TITLE"] or_else ""

	return serialise(html, allocator)
}

/*
One level of a bid table, and then its children.

`even_indent` alternates down the tree so each depth gets its own css class, which is how the
rendered table stripes its columns.
*/
@(private = "file")
write_bidtable :: proc(parent: ^Element, children: []^Node, even_indent: bool, allocator := context.allocator) {
	if len(children) == 0 {
		return
	}
	div_class := even_indent ? "start" : "startOddIndent"
	list := sub_element(parent, "ul", allocator)
	for child in children {
		item := sub_element(list, "li", allocator)
		bid_div := sub_element(item, "div", allocator)
		set_attrib(bid_div, "class", div_class)
		fill(bid_div, spell_out_bare_call(bid_caps(child.bid)), allocator)

		rows := desc_rows(child, allocator)
		// The first description row is mixed content inside the same `<li>`, following the bid.
		fill(item, rows[0], allocator, conditions = names_seats(rows[0]) ? .Tagged_Seats : .Tagged)

		/*
		The remaining rows live INSIDE this `li`, before the child bids, so they read directly
		under the bid they belong to. As sibling `<li>`s of the same `<ul>` they would be emitted
		after the whole child subtree instead. The empty bid div reproduces the bid column at every
		breakpoint, so no extra css is needed to line them up.
		*/
		for row in rows[1:] {
			row_div := sub_element(item, "div", allocator)
			set_attrib(row_div, "class", "descRow")
			spacer := sub_element(row_div, "div", allocator)
			set_attrib(spacer, "class", div_class)
			spacer.text = " "
			fill(row_div, row, allocator, conditions = names_seats(row) ? .Tagged_Seats : .Tagged)
		}

		write_bidtable(item, child.children[:], !even_indent, allocator)
	}
}

// A bid written as a bare letter is spelled out for the reader: `P` -> `Pass`, `D` -> `Dbl`.
@(private = "file")
spell_out_bare_call :: proc(bid: string) -> string {
	switch bid {
	case "P":
		return "Pass"
	case "R":
		return "Rdbl"
	case "D":
		return "Dbl"
	}
	return bid
}

// The seats by letter, for a diagram's header.
@(private = "file")
seat_name :: proc(letter: string) -> string {
	switch letter {
	case "N":
		return "North"
	case "E":
		return "East"
	case "S":
		return "South"
	case "W":
		return "West"
	}
	return letter
}

/*
A deal diagram (`html_diagram` in the reference): the header as one line, then a three-by-three table with
North on top, West and East either side of an empty compass cell, South below. A hand is four lines of suit
symbol and cards, a void written as a dash; a seat with no hand is an empty cell.
*/
@(private = "file")
write_diagram :: proc(body: ^Element, diagram: Diagram, allocator := context.allocator) {
	box := sub_element(body, "div", allocator)
	set_attrib(box, "class", "bml-diagram")

	parts := make([dynamic]string, 0, 5, allocator)
	if diagram.board != "" {
		append(&parts, strings.concatenate({"Board ", diagram.board}, allocator))
	}
	if diagram.dealer != "" {
		append(&parts, strings.concatenate({"Dealer ", seat_name(diagram.dealer)}, allocator))
	}
	if diagram.vul != "" {
		append(&parts, strings.concatenate({"Vul ", diagram.vul}, allocator))
	}
	if diagram.has_contract {
		if diagram.level == "P" {
			append(&parts, "Passed out")
		} else {
			strain := diagram.strain == "N" ? "NT" : strings.concatenate({"!", strings.to_lower(diagram.strain, allocator)}, allocator)
			append(
				&parts,
				strings.concatenate({diagram.level, strain, diagram.doubling, " by ", seat_name(diagram.declarer)}, allocator),
			)
		}
	}
	if diagram.lead_suit != "" {
		append(&parts, strings.concatenate({"Lead !", strings.to_lower(diagram.lead_suit, allocator), diagram.lead_rank}, allocator))
	}
	if len(parts) > 0 {
		caption := sub_element(box, "div", allocator)
		set_attrib(caption, "class", "bml-deal-head")
		fill(caption, strings.join(parts[:], " · ", allocator), allocator)
	}

	hand :: proc(row: ^Element, suits: [4]string, given: bool, allocator: mem.Allocator) {
		cell := sub_element(row, "td", allocator)
		if !given {
			return
		}
		set_attrib(cell, "class", "hand")
		symbols := [4]string{"!s ", "!h ", "!d ", "!c "}
		for cards, i in suits {
			fill(sub_element(cell, "div", allocator), strings.concatenate({symbols[i], cards == "-" ? "—" : cards}, allocator), allocator)
		}
	}
	table := sub_element(box, "table", allocator)
	set_attrib(table, "class", "bml-deal")
	top := sub_element(table, "tr", allocator)
	sub_element(top, "td", allocator)
	hand(top, diagram.north, diagram.has_north, allocator)
	sub_element(top, "td", allocator)
	middle := sub_element(table, "tr", allocator)
	hand(middle, diagram.west, diagram.has_west, allocator)
	compass := sub_element(middle, "td", allocator)
	set_attrib(compass, "class", "compass")
	write_compass(compass, diagram, allocator)
	hand(middle, diagram.east, diagram.has_east, allocator)
	bottom := sub_element(table, "tr", allocator)
	sub_element(bottom, "td", allocator)
	hand(bottom, diagram.south, diagram.has_south, allocator)
	sub_element(bottom, "td", allocator)
}

/*
The middle of a diagram as a hand record draws it: N E S W round the edge, the board number in the middle, the
dealer's letter marked (`dealer`) and the vulnerable seats in red (`vul`). The python reference's `_compass`.
*/
@(private = "file")
write_compass :: proc(cell: ^Element, diagram: Diagram, allocator := context.allocator) {
	vulnerable := ""
	switch diagram.vul {
	case "All":
		vulnerable = "NESW"
	case "NS":
		vulnerable = "NS"
	case "EW":
		vulnerable = "EW"
	}
	seat :: proc(row: ^Element, letter: string, diagram: Diagram, vulnerable: string, allocator: mem.Allocator) {
		classes := "seat"
		if diagram.dealer == letter {
			classes = strings.concatenate({classes, " dealer"}, allocator)
		}
		if strings.contains(vulnerable, letter) {
			classes = strings.concatenate({classes, " vul"}, allocator)
		}
		td := sub_element(row, "td", allocator)
		set_attrib(td, "class", classes)
		attach_text(td, letter, allocator)
	}
	grid := sub_element(cell, "table", allocator)
	set_attrib(grid, "class", "bml-compass")
	top := sub_element(grid, "tr", allocator)
	sub_element(top, "td", allocator)
	seat(top, "N", diagram, vulnerable, allocator)
	sub_element(top, "td", allocator)
	middle := sub_element(grid, "tr", allocator)
	seat(middle, "W", diagram, vulnerable, allocator)
	board := sub_element(middle, "td", allocator)
	set_attrib(board, "class", "board")
	if diagram.board != "" {
		attach_text(board, diagram.board, allocator)
	}
	seat(middle, "E", diagram, vulnerable, allocator)
	bottom := sub_element(grid, "tr", allocator)
	sub_element(bottom, "td", allocator)
	seat(bottom, "S", diagram, vulnerable, allocator)
	sub_element(bottom, "td", allocator)
}

// A `|---+---|` row: a line in the table, not data.
@(private = "file")
is_rule_row :: proc(cells: []string) -> bool {
	if len(cells) == 0 || cells[0] == "" {
		return false
	}
	for c in transmute([]u8)cells[0] {
		if c != '+' && c != '-' {
			return false
		}
	}
	return true
}

/*
A pipe table (`html_table`): rows before the first rule are header cells, and a later rule draws a line above
the row after it. Empty rows are left out.
*/
@(private = "file")
write_table :: proc(body: ^Element, all_rows: [][]string, allocator := context.allocator) {
	rows := make([dynamic][]string, 0, len(all_rows), allocator)
	// A row with no cell filled in is left out, like an empty one: the editor's tab adds one past the last cell.
	for row in all_rows {
		for cell in row {
			if len(cell) > 0 {
				append(&rows, row)
				break
			}
		}
	}
	first_rule := -1
	for row, i in rows {
		if is_rule_row(row) {
			first_rule = i
			break
		}
	}
	table := sub_element(body, "table", allocator)
	set_attrib(table, "class", "bml-table")
	ruled := false
	for cells, i in rows {
		if is_rule_row(cells) {
			ruled = i != first_rule
			continue
		}
		tr := sub_element(table, "tr", allocator)
		if ruled {
			set_attrib(tr, "class", "rule")
			ruled = false
		}
		tag := i < first_rule ? "th" : "td"
		for cell in cells {
			fill(sub_element(tr, tag, allocator), cell, allocator)
		}
	}
}

// A description list (`html_description`): `term :: text` as a term and its text, an item without one as text.
@(private = "file")
write_description :: proc(body: ^Element, items: []string, allocator := context.allocator) {
	list := sub_element(body, "dl", allocator)
	set_attrib(list, "class", "bml-desc")
	for item in items {
		if at := strings.index(item, " :: "); at >= 0 {
			fill(sub_element(list, "dt", allocator), strings.trim_space(item[:at]), allocator)
			fill(sub_element(list, "dd", allocator), strings.trim_space(item[at + len(" :: "):]), allocator)
		} else {
			fill(sub_element(list, "dd", allocator), strings.trim_space(item), allocator)
		}
	}
}

/*
An auction (`html_auction`): the `W N E S` header, the calls - in capitals, since the test
(`is_bidding_block`) is case-blind, so `1d p 1s` is an auction too - with `P`/`D`/`R`/`AP` spelled out and
every other call a bid, each with its mark; then the notes under it (`auction_parts`).
*/
@(private = "file")
write_auction :: proc(body: ^Element, all_rows: [][]string, allocator := context.allocator) {
	rows := make([dynamic][]string, 0, len(all_rows), context.temp_allocator)
	for row in all_rows {
		if len(row) > 0 {
			append(&rows, row)
		}
	}
	header, calls, notes := auction_parts(rows[:])
	table := sub_element(body, "table", allocator)
	set_attrib(table, "class", "bml-auction")
	if header != nil {
		tr := sub_element(table, "tr", allocator)
		for seat in header {
			fill(sub_element(tr, "th", allocator), strings.to_upper(seat, context.temp_allocator), allocator)
		}
	}
	for row in calls {
		tr := sub_element(table, "tr", allocator)
		for token in row {
			call, mark := call_mark(strings.to_upper(token, context.temp_allocator))
			td := sub_element(tr, "td", allocator)
			fill(td, spell_call(call), allocator)
			if mark != "" {
				write_mark(td, mark, allocator)
			}
		}
	}
	if len(notes) == 0 {
		return
	}
	// Each note is its mark and its words; a row without a mark continues the note above it.
	Note :: struct {
		mark:  string,
		words: [dynamic]string,
	}
	items := make([dynamic]Note, context.temp_allocator)
	for row in notes {
		if mark, rest, ok := note_mark(row[0]); ok {
			words := make([dynamic]string, context.temp_allocator)
			if rest != "" {
				append(&words, rest)
			}
			append(&words, ..row[1:])
			append(&items, Note{mark, words})
		} else {
			append(&items[len(items) - 1].words, ..row)
		}
	}
	div := sub_element(body, "div", allocator)
	set_attrib(div, "class", "bml-auction-notes")
	for item in items {
		note := sub_element(div, "div", allocator)
		write_mark(note, item.mark, allocator)
		words := strings.join(item.words[:], " ", context.temp_allocator)
		fill(note, strings.concatenate({" ", words}, context.temp_allocator), allocator)
	}
}

// A call as the auction writes it, inside its brackets too: `(X)` is `(Dbl)`.
@(private = "file")
spell_call :: proc(call: string) -> string {
	opening := "(" if strings.has_prefix(call, "(") else ""
	rest := call[len(opening):]
	closing := ")" if strings.has_suffix(rest, ")") else ""
	word: string
	switch rest[:len(rest) - len(closing)] {
	case "P":
		word = "Pass"
	case "D", "X":
		word = "Dbl"
	case "R", "XX":
		word = "Rdbl"
	case "AP":
		word = "All pass"
	case "-":
		word = "" // a seat before the dealer's
	case:
		return call
	}
	return strings.concatenate({opening, word, closing}, context.temp_allocator)
}

// A call's or a note's mark, superscript: `^1` is written 1.
@(private = "file")
write_mark :: proc(parent: ^Element, mark: string, allocator := context.allocator) {
	sup := sub_element(parent, "sup", allocator)
	set_attrib(sup, "class", "bml-alert" if mark == "!" else "bml-note")
	attach_text(sup, strings.trim_left(mark, "^"), allocator)
}

// A note's mark at its start, `*`s or `^1`, and the rest of that token.
@(private = "file")
note_mark :: proc(token: string) -> (mark, rest: string, ok: bool) {
	i := 0
	for i < len(token) && token[i] == '*' {
		i += 1
	}
	if i == 0 && len(token) > 1 && token[0] == '^' && is_digit_byte(token[1]) {
		i = 1
		for i < len(token) && is_digit_byte(token[i]) {
			i += 1
		}
	}
	return token[:i], token[i:], i > 0
}

/*
A bid typed in lower case, `1d` `2nt` `1hs`: its strain in capitals, so it gets its suit glyphs. Only a level
and strain letters that end the word - `3cue`, `6higher`, `1step` are words, and `2m` / `3x` classes, left
alone. The python reference's `_bid_caps` (bml2html.py).
*/
@(private = "file")
bid_caps :: proc(bid: string) -> string {
	is_letter :: proc(text: string, i: int) -> bool {
		return i < len(text) && is_letter_byte(text[i])
	}
	out: []u8
	for i := 0; i < len(bid); i += 1 {
		if bid[i] < '1' || bid[i] > '7' || (i > 0 && (is_letter_byte(bid[i - 1]) || is_digit_byte(bid[i - 1]))) {
			continue
		}
		start, end := i + 1, i + 1
		if strings.has_prefix(bid[start:], "nt") && !is_letter(bid, start + 2) {
			end = start + 2
		} else if end < len(bid) && bid[end] == 'n' && !is_letter(bid, end + 1) {
			end += 1
		} else {
			for end < len(bid) && strings.contains_rune("cdhs", rune(bid[end])) {
				end += 1
			}
			if is_letter(bid, end) {
				end = start
			}
		}
		if end == start {
			continue
		}
		if out == nil {
			out = transmute([]u8)strings.clone(bid, context.temp_allocator)
		}
		for k in start ..< end {
			out[k] -= 'a' - 'A'
		}
		i = end - 1
	}
	return bid if out == nil else string(out)
}

// A class attribute: `base`, then a class hook's classes after it.
@(private = "file")
with_classes :: proc(base, classes: string, allocator := context.allocator) -> string {
	return classes == "" ? base : strings.concatenate({base, " ", classes}, allocator)
}

// A callout's label, by its `#BOX` type (`box_marker`).
@(private = "file")
callout_label :: proc(variant: string) -> string {
	switch variant {
	case "note":
		return "Note"
	case "info":
		return "Info"
	case "tip":
		return "Tip"
	case "warning":
		return "Warning"
	}
	return ""
}

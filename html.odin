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

	for block in doc.blocks {
		switch block.kind {
		case .Paragraph:
			fill(sub_element(body, "p", build), block.text, build)
		case .Bidtable:
			if !block.tree.export {
				continue
			}
			table := sub_element(body, "div", build)
			set_attrib(table, "class", "bidtable")
			write_bidtable(table, block.tree.children[:], true, build)
		case .H1:
			id := normalise_header_id(block.text, build)
			append(&headings, Heading{id = id, text = block.text})
			heading := sub_element(body, "h1", build)
			set_attrib(heading, "id", id)
			fill(heading, block.text, build)
		case .H2, .H3, .H4:
			tag := block.kind == .H2 ? "h2" : block.kind == .H3 ? "h3" : "h4"
			heading := sub_element(body, tag, build)
			set_attrib(heading, "id", normalise_header_id(block.text, build))
			fill(heading, block.text, build)
		case .List:
			list := sub_element(body, "ul", build)
			for item in block.items {
				fill(sub_element(list, "li", build), item, build)
			}
		case .Enum:
			list := sub_element(body, "ol", build)
			for item in block.items {
				fill(sub_element(list, "li", build), item, build)
			}
		case .Diagram:
			write_diagram(body, block.diagram, build)
		case .Table:
			write_table(body, block.rows, build)
		case .Description:
			write_description(body, block.items, build)
		case .Bidding:
			write_auction(body, block.rows, build)
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
		fill(bid_div, spell_out_bare_call(child.bid), allocator)

		rows := desc_rows(child, allocator)
		// The first description row is mixed content inside the same `<li>`, following the bid.
		fill(item, rows[0], allocator)

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
			fill(row_div, row, allocator)
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
	set_attrib(sub_element(middle, "td", allocator), "class", "compass")
	hand(middle, diagram.east, diagram.has_east, allocator)
	bottom := sub_element(table, "tr", allocator)
	sub_element(bottom, "td", allocator)
	hand(bottom, diagram.south, diagram.has_south, allocator)
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
	for row in all_rows {
		if len(row) > 0 {
			append(&rows, row)
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

// An auction (`html_auction`): a row of cells a line, `P`/`D`/`R`/`AP` spelled out and every other call a bid.
@(private = "file")
write_auction :: proc(body: ^Element, rows: [][]string, allocator := context.allocator) {
	table := sub_element(body, "table", allocator)
	set_attrib(table, "class", "bml-auction")
	for calls in rows {
		if len(calls) == 0 {
			continue
		}
		tr := sub_element(table, "tr", allocator)
		for call in calls {
			spelled := call
			switch call {
			case "P":
				spelled = "Pass"
			case "D":
				spelled = "Dbl"
			case "R":
				spelled = "Rdbl"
			case "AP":
				spelled = "All pass"
			}
			fill(sub_element(tr, "td", allocator), spelled, allocator)
		}
	}
}

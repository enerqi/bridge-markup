package bml

import "core:mem/virtual"
import "core:strings"

/*
Render a parsed document to html.

The output is meant to be byte-identical to the reference's `bml2html.py`, which is why the order
things are appended here looks arbitrary in places - the `<title>` really does go in last, after the
whole body has been built, and the reference's ElementTree emits it at the end of `<head>` because
of that.

Blocks the reference recognises but does not render - diagrams, tables, auction tables, description
lists - are skipped here too.
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
		case .Diagram, .Table, .Description, .Bidding:
		// Recognised by the parser, not rendered - same as the reference.
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

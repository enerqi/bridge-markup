/*
Parse a small BML document and render it.

	just example basic

BML is org-mode-like: `*` headings, blank lines between blocks, and bid tables that nest by
INDENTATION. The interesting part of the api is that `parse` takes source text rather than a path -
see `render.odin` for the file-reading version, and the README for why.

WATCH THE IMPORT DEPTH. In `-file` mode a relative import resolves against the file's own directory,
so this file - one level below the library - imports `".."`. The layout other Odin libraries use,
`examples/<name>/main.odin`, is one level deeper and imports `"../.."`.

The import is aliased to `lib` rather than to the package's own name so that renaming the package
leaves this file alone.
*/
package main

import lib ".."
import "core:fmt"

SOURCE :: `#+TITLE: A Tiny System

* Opening Bids

1N = 15-17 balanced
  2C = stayman
    2D = no major
  2D = transfer to !h

Responder bids *up the line* with 4-4 in the majors.
`

main :: proc() {
	doc := lib.parse(SOURCE)
	defer lib.destroy(doc)

	fmt.println("title: ", doc.meta["TITLE"])
	fmt.println("blocks:", len(doc.blocks))
	for block in doc.blocks {
		fmt.printf("  %-10v ", block.kind)
		switch block.kind {
		case .H1, .H2, .H3, .H4, .Paragraph:
			fmt.println(block.text)
		case .Bidtable:
			print_bids(block.tree, 1)
		case .List, .Enum, .Description:
			fmt.println(len(block.items), "items")
		case .Table, .Bidding:
			fmt.println(len(block.rows), "rows")
		case .Diagram:
			fmt.println("deal diagram")
		}
	}

	html := lib.render_html(doc)
	defer delete(html)
	fmt.println()
	fmt.println(html)
}

// A bid table is a tree: every call may have replies, which may have replies of their own.
print_bids :: proc(node: ^lib.Node, depth: int) {
	for child in node.children {
		if depth > 1 || child != node.children[0] {
			fmt.printf("             ")
		}
		for _ in 0 ..< depth {
			fmt.print("  ")
		}
		// `bidrepr` is the canonical spelling: a compound token like `1H--2C` reads `1H (P) 2C`.
		fmt.printfln("%v = %v", child.bidrepr, child.desc)
		print_bids(child, depth + 1)
	}
}

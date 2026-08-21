package bml

import "core:strings"

/*
A node in a bidding table.

The tree is built by INDENTATION, not by brackets: a row indented further than the row above is that
row's child. `indentation` is kept because the builder needs it while walking back up, and
`desc_indentation` because it records the column the description started in.

`desc` holds continuation lines joined by a LITERAL BACKSLASH-N (two characters), not a newline -
that is the python's marker for "the author wrapped this description over several lines", and the
html renderer splits on it to lay the extra rows out under the bid. `desc_rows` is the way to read
it back. The marker is kept rather than replaced with a `[]string` so a node dumped from here can be
compared directly against the reference's parse output when a parity failure needs isolating.

LIFETIME: nodes come from the owning `Document`'s arena, as do the `children` array and every string
on them. They are freed together with the document, so a `^Node` must not outlive it. Nothing frees
an individual node - `#CUT` discards a whole subtree by never building it.

The `parent` pointer exists for two reasons: the builder walks back UP it when a row is less
indented than the one before, and `node_sequence` reconstructs the auction from a leaf. `add_child`
is the only thing that ever sets it.
*/
Node :: struct {
	bid:              string,
	desc:             string,
	// The canonical spelling of `bid`; see `bid_representation`.
	bidrepr:          string,
	indentation:      int,
	desc_indentation: int,
	vul:              string,
	seat:             string,
	// Cleared by a `#HIDE` directive: the table is parsed but not rendered.
	export:           bool,
	parent:           ^Node,
	children:         [dynamic]^Node,
}

ROOT_SENTINEL :: "root"

@(private)
new_node :: proc(
	bid, desc: string,
	indentation, desc_indentation: int,
	parent: ^Node,
	allocator := context.allocator,
) -> ^Node {
	node := new(Node, allocator)
	node^ = Node {
		bid              = bid,
		desc             = desc,
		bidrepr          = bid_representation(bid, allocator),
		indentation      = indentation,
		desc_indentation = desc_indentation,
		vul              = "00",
		seat             = "0",
		export           = true,
		parent           = parent,
		children         = make([dynamic]^Node, allocator),
	}
	return node
}

@(private)
add_child :: proc(
	parent: ^Node,
	bid, desc: string,
	indentation, desc_indentation: int,
	allocator := context.allocator,
) -> ^Node {
	child := new_node(bid, desc, indentation, desc_indentation, parent, allocator)
	// Vulnerability and seat are inherited at the moment the child is created, so a `#VUL`/`#SEAT`
	// later in the file does not retroactively change a table already built.
	child.vul = parent.vul
	child.seat = parent.seat
	append(&parent.children, child)
	return child
}

/*
The bids from the top of the table down to and including this node.

Returns nil for the synthetic root itself. The sequence is built from `bidrepr` rather than `bid`, so
a compound token contributes the auction it stands for.
*/
node_sequence :: proc(node: ^Node, allocator := context.allocator) -> []string {
	if node == nil || node.parent == nil {
		return nil
	}
	depth := 0
	for walk := node; walk != nil && walk.parent != nil; walk = walk.parent {
		depth += 1
	}
	out := make([]string, depth, allocator)
	i := depth - 1
	for walk := node; walk != nil && walk.parent != nil; walk = walk.parent {
		out[i] = walk.bidrepr
		i -= 1
	}
	return out
}

// The description split back into the rows the author wrote. Always at least one element.
desc_rows :: proc(node: ^Node, allocator := context.allocator) -> []string {
	return strings.split(node.desc, DESC_ROW_SEPARATOR, allocator)
}

// Two characters, a backslash and an `n` - see the note on `Node`.
DESC_ROW_SEPARATOR :: "\n"

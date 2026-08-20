package bml

import "core:fmt"
import "core:strings"
import "core:testing"

/*
Bid table tests.

The expected values here were taken from the python reference by running it on these exact inputs,
not from reading its source - the clipboard directives in particular appear NOWHERE in the bridge
corpus, so nothing else in this project would notice if they were wrong.
*/

@(private = "file")
Row :: struct {
	indentation: int,
	bid:         string,
	desc:        string,
}

// `<indent> <bid> = <desc>` for every node of a parsed table, depth first.
@(private = "file")
tree_rows :: proc(t: ^testing.T, text: string, allocator := context.allocator) -> ([]Row, ^Node) {
	state: Parse_State
	parse_state_init(&state, allocator)
	root := create_bidtree(&state, text)
	rows := make([dynamic]Row, allocator)
	if root != nil {
		walk_rows(root, &rows)
	}
	return rows[:], root
}

@(private = "file")
walk_rows :: proc(node: ^Node, rows: ^[dynamic]Row) {
	for child in node.children {
		append(rows, Row{child.indentation, child.bid, child.desc})
		walk_rows(child, rows)
	}
}

@(private = "file")
expect_rows :: proc(t: ^testing.T, got: []Row, want: []Row, loc := #caller_location) {
	if !testing.expectf(t, len(got) == len(want), "%d rows, want %d: %v", len(got), len(want), got, loc = loc) {
		return
	}
	for row, i in got {
		testing.expectf(t, row == want[i], "row %d is %v, want %v", i, row, want[i], loc = loc)
	}
}

@(test)
test_indentation_nests_the_table :: proc(t: ^testing.T) {
	rows, _ := tree_rows(t, "1C = strong\n  1D = negative\n    1H = relay\n  1S = positive\n", context.temp_allocator)
	expect_rows(t, rows, {{0, "1C", "strong"}, {2, "1D", "negative"}, {4, "1H", "relay"}, {2, "1S", "positive"}})
}

@(test)
test_lettered_prose_list_is_not_a_bid :: proc(t: ^testing.T) {
	/*
	`(a)`..`(d)` under a bid explains it; they are not four calls. Both halves matter: a bracketed
	single letter is a call only for the call letters, and a continuation need not be indented -
	these sit in the same column as the bid they belong to.
	*/
	rows, _ := tree_rows(
		t,
		"3C = artificial, multi-meaning.\n(a) minimum balanced\n(d) void hand, any strength\n  3D = relay\n",
		context.temp_allocator,
	)
	if !testing.expectf(t, len(rows) == 2, "expected 3C and 3D only, got %v", rows) {
		return
	}
	testing.expect_value(t, rows[0].bid, "3C")
	testing.expect_value(t, rows[1].bid, "3D")

	desc := rows[0].desc
	testing.expect(t, strings.has_prefix(desc, "artificial, multi-meaning."))
	testing.expect(t, strings.contains(desc, "(a) minimum balanced"))
	testing.expect(t, strings.contains(desc, "(d) void hand, any strength"))
	testing.expect_value(t, strings.count(desc, DESC_ROW_SEPARATOR), 2)
}

@(test)
test_bracketed_calls_and_pseudo_bids_still_nest :: proc(t: ^testing.T) {
	rows, _ := tree_rows(
		t,
		"(2D)\n    (P) = they passed\n    (X) = takeout\n    (any) = interference\n",
		context.temp_allocator,
	)
	expect_rows(
		t,
		rows,
		{{0, "(2D)", ""}, {4, "(P)", "they passed"}, {4, "(X)", "takeout"}, {4, "(any)", "interference"}},
	)
}

@(test)
test_cut_stores_a_fragment_and_removes_it :: proc(t: ^testing.T) {
	rows, _ := tree_rows(t, "#CUT frag\n1C = strong\n  1D = negative\n#ENDCUT\n2C = weak\n", context.temp_allocator)
	expect_rows(t, rows, {{0, "2C", "weak"}})
}

@(test)
test_copy_keeps_the_fragment_and_paste_repeats_it :: proc(t: ^testing.T) {
	rows, _ := tree_rows(t, "#COPY frag\n1C = strong\n#ENDCOPY\n2D = weak\n#PASTE frag\n", context.temp_allocator)
	expect_rows(t, rows, {{0, "1C", "strong"}, {0, "2D", "weak"}, {0, "1C", "strong"}})
}

@(test)
test_paste_rewrites_the_pairs_it_is_given :: proc(t: ^testing.T) {
	rows, _ := tree_rows(t, "#CUT frag\n1C = strong\n#ENDCUT\n#PASTE frag 1C=1H\n", context.temp_allocator)
	expect_rows(t, rows, {{0, "1H", "strong"}})
}

@(test)
test_paste_reindents_to_the_paste_site :: proc(t: ^testing.T) {
	// The fragment was cut at column 0 and pasted at column 2, so it lands as a child.
	rows, _ := tree_rows(t, "#CUT frag\n1D = neg\n#ENDCUT\n1C = strong\n  #PASTE frag\n", context.temp_allocator)
	expect_rows(t, rows, {{0, "1C", "strong"}, {2, "1D", "neg"}})
}

@(test)
test_paste_of_an_unknown_name_is_a_diagnostic_not_a_crash :: proc(t: ^testing.T) {
	// The reference raises `KeyError` here and takes the whole build with it. A live preview parses
	// half-typed text, so this has to degrade instead.
	state: Parse_State
	parse_state_init(&state, context.temp_allocator)
	root := create_bidtree(&state, "#PASTE nothing\n1C = strong\n")
	testing.expect(t, root != nil)
	testing.expect_value(t, len(state.diagnostics), 1)
	testing.expect(t, strings.contains(state.diagnostics[0], "nothing"))
}

@(test)
test_hide_parses_the_table_but_clears_export :: proc(t: ^testing.T) {
	rows, root := tree_rows(t, "#HIDE\n1C = strong\n", context.temp_allocator)
	expect_rows(t, rows, {{0, "1C", "strong"}})
	testing.expect(t, !root.export)
}

@(test)
test_bidtable_directive_forces_a_table :: proc(t: ^testing.T) {
	rows, root := tree_rows(t, "#BIDTABLE\nany = whatever\n", context.temp_allocator)
	expect_rows(t, rows, {{0, "any", "whatever"}})
	testing.expect(t, root.export)
}

@(test)
test_a_directive_only_block_yields_no_table :: proc(t: ^testing.T) {
	state: Parse_State
	parse_state_init(&state, context.temp_allocator)
	testing.expect_value(t, create_bidtree(&state, "#CUT frag\n1C = strong\n#ENDCUT\n"), nil)
}

@(test)
test_the_sequence_is_the_path_to_the_node :: proc(t: ^testing.T) {
	_, root := tree_rows(t, "1H--2C = ours twice\n  2S = fourth suit\n", context.temp_allocator)
	deepest := root.children[0].children[0]
	sequence := node_sequence(deepest, context.temp_allocator)
	got := fmt.tprintf("%v", sequence)
	testing.expect_value(t, got, `["1H (P) 2C", "2S"]`)
}

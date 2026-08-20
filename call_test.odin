package bml

import "core:testing"

/*
These mirror `tests/test_bml_nodes.py` in the python reference, case for case. Where a case exists
there because a bug once shipped, the comment saying so is kept - it is the reason the case is not
redundant.
*/

@(private = "file")
repr :: proc(t: ^testing.T, bid: string, expected: string, loc := #caller_location) {
	got := bid_representation(bid, context.temp_allocator)
	testing.expectf(t, got == expected, "%q -> %q, want %q", bid, got, expected, loc = loc)
}

@(test)
test_single_call_is_unchanged :: proc(t: ^testing.T) {
	repr(t, "1C", "1C")
	repr(t, "(2D)", "(2D)")
	repr(t, "1NT", "1N")
	repr(t, "2N+", "2N+") // a trailing qualifier is part of the call
}

@(test)
test_compound_auction_keeps_every_call :: proc(t: ^testing.T) {
	// `--` separates successive calls. Stripping the dashes first glued them into one run, and
	// re-finding calls with a digit-led pattern ate any that were not digit-led: `1C--P--1H` used
	// to come back as `1CP (P) 1H`.
	repr(t, "1C--P--1H", "1C P 1H")
	repr(t, "(1CD)--1H--2C", "(1CD) 1H 2C")
	repr(t, "(2D)--P--(2H)", "(2D) P (2H)")
	repr(t, "Pass--(1H)--X", "Pass (1H) X")
}

@(test)
test_implicit_opponent_passes_are_shown :: proc(t: ^testing.T) {
	// When the token names only our calls, the opponents passed in between.
	repr(t, "1H--2C", "1H (P) 2C")
	repr(t, "1N--2C--2D", "1N (P) 2C (P) 2D")
}

@(test)
test_single_dashes_separate_only_between_calls :: proc(t: ^testing.T) {
	// A lone dash is ambiguous: a separator in `1c-2d-3d`, a word joiner in `new-suit`. It splits
	// only when every part is itself call-shaped.
	repr(t, "1c-2d-3d-3s-4c", "1c (P) 2d (P) 3d (P) 3s (P) 4c")
	repr(t, "P-1H", "P 1H")
	repr(t, "new-suit", "newsuit")
	repr(t, "jump-cue", "jumpcue")
	repr(t, "2-Cue", "2Cue")
}

@(test)
test_alternation_is_not_two_calls :: proc(t: ^testing.T) {
	// `3S/4C` is one call written as a choice; it used to be rewritten into a two-call auction.
	repr(t, "3S/4C", "3S/4C")
	repr(t, "2N/3x", "2N/3x")
	repr(t, "P/2S", "P/2S")
}

@(test)
test_link_bids_are_left_whole :: proc(t: ^testing.T) {
	// A markdown link's target contains its own `--`, so it is never split.
	repr(t, "[1D](#1C--1D)", "[1D](#1C1D)")
}

@(test)
test_the_root_sentinel_survives :: proc(t: ^testing.T) {
	// `create_bidtree` names its root node "root" and compares against that spelling later, so the
	// representation of it has to be the word itself.
	repr(t, "root", "root")
}

package bml

import "core:strings"
import "core:testing"

/*
Rendering tests.

Every expected string here is the reference's actual output for that input, captured by running it.
The whole 19-file corpus is checked byte-for-byte by `just parity`; these cover the small cases that
make a failure readable, and the escaping rules that the corpus happens not to exercise.
*/

@(private = "file")
inline_html :: proc(text: string, allocator := context.allocator) -> string {
	root := element_make("p", allocator)
	fill(root, text, allocator)
	return serialise(root, allocator)
}

@(private = "file")
expect_inline :: proc(t: ^testing.T, source, expected: string, loc := #caller_location) {
	got := inline_html(source, context.temp_allocator)
	testing.expectf(t, got == expected, "%q rendered %v, want %v", source, got, expected, loc = loc)
}

@(test)
test_suit_runs_become_glyphs :: proc(t: ^testing.T) {
	// `N` is a suit letter only when it is not followed by `T`, which is what leaves `1NT` alone
	// while turning `2N` into the spelled-out "2NT".
	expect_inline(t, "2C and 2N and 1NT", `<p>2<span class="ccolor">&#9827;</span> and 2NT and 1NT</p>`)
}

@(test)
test_the_bang_shorthand_becomes_glyphs :: proc(t: ^testing.T) {
	expect_inline(
		t,
		"!c !d !h !s",
		`<p><span class="ccolor">&#9827;</span> <span class="dcolor">&#9830;</span> <span class="hcolor">&#9829;</span> <span class="scolor">&#9824;</span></p>`,
	)
}

@(test)
test_an_opponents_bid_in_parens_keeps_its_glyph :: proc(t: ^testing.T) {
	expect_inline(t, "(2D) opponents", `<p>(2<span class="dcolor">&#9830;</span>) opponents</p>`)
}

@(test)
test_long_dashes :: proc(t: ^testing.T) {
	expect_inline(t, "a -- b --- c", "<p>a &#8211; b &#8212; c</p>")
}

@(test)
test_double_asterisks_nest_the_emphasis :: proc(t: ^testing.T) {
	/*
	`**double**` really does render as strong inside strong. The content pattern ends with `\S`,
	which matches an asterisk quite happily, so the outer match swallows `*double*` and the
	recursive fill finds emphasis a second time. The published pages contain this, so it is
	reproduced rather than tidied up.
	*/
	expect_inline(
		t,
		"*bold* and **double**",
		"<p><strong>bold</strong> and <strong><strong>double</strong></strong></p>",
	)
}

@(test)
test_em_and_code_need_a_boundary :: proc(t: ^testing.T) {
	expect_inline(t, "x /em/ and =code= here", "<p>x <em>em</em> and <code>code</code> here</p>")
	// ...and mid-word delimiters are left alone, which is why "GF/FG" survives.
	expect_inline(t, "GF/FG and count = 15", "<p>GF/FG and count = 15</p>")
}

@(test)
test_links_normalise_their_target :: proc(t: ^testing.T) {
	// A link target may contain spaces, so it cannot be found by splitting on whitespace; and the
	// target is normalised into the id form the heading generated.
	expect_inline(
		t,
		"[1D](#1C Weak Strong) link",
		`<p><a href="#1c_Weak_Strong">1<span class="dcolor">&#9830;</span></a> link</p>`,
	)
}

@(test)
test_markup_characters_are_escaped :: proc(t: ^testing.T) {
	expect_inline(t, "a > b & c < d", "<p>a &gt; b &amp; c &lt; d</p>")
}

@(test)
test_header_ids_lowercase_suit_pairs :: proc(t: ^testing.T) {
	// Spaces become underscores BEFORE the trim, so surrounding whitespace survives as underscores.
	testing.expect_value(t, normalise_header_id("1C Weak Strong", context.temp_allocator), "1c_Weak_Strong")
	testing.expect_value(
		t,
		normalise_header_id("Two Suited 2D Openings", context.temp_allocator),
		"Two_Suited_2d_Openings",
	)
	testing.expect_value(t, normalise_header_id("  spaced  ", context.temp_allocator), "__spaced__")
}

@(test)
test_a_whole_small_document :: proc(t: ^testing.T) {
	doc := parse("* Heading One\n\nSome prose here.\n\n- item a\n- item b\n\n1N = 15-17 balanced\n  2C = stayman\n")
	defer destroy(doc)
	got := render_html(doc, context.temp_allocator)

	// A list item keeps the newline that ended it, which is why `item a` has one and `item b`,
	// being last, does not.
	expected :=
		`<html><head><link rel="stylesheet" type="text/css" href="bml.css" />` +
		`<link href="https://fonts.googleapis.com/css?family=Open Sans" rel="stylesheet" />` +
		`<meta charset="UTF-8" /><meta name="keywords" content="contract, bridge, bidding" />` +
		`<title /></head><body class="content">` +
		`<h1 id="Heading_One">Heading One</h1><p>Some prose here.</p>` +
		"<ul><li>item a\n</li><li>item b</li></ul>" +
		`<div class="bidtable"><ul><li><div class="start">1NT</div>15-17 balanced` +
		`<ul><li><div class="startOddIndent">2<span class="ccolor">&#9827;</span></div>stayman</li></ul>` +
		`</li></ul></div>` +
		`<a class="top-link" href="#">Top</a>` +
		`<div class="nav-links"><ul><li><a href="#Heading_One">Heading One</a></li></ul></div>` +
		`</body></html>`
	testing.expectf(t, got == expected, "rendered\n%v\nwant\n%v", got, expected)
}

@(test)
test_a_hidden_table_is_parsed_but_not_rendered :: proc(t: ^testing.T) {
	doc := parse("#HIDE\n1C = strong\n")
	defer destroy(doc)
	testing.expect_value(t, len(doc.blocks), 1)
	testing.expect(t, !strings.contains(render_html(doc, context.temp_allocator), "bidtable"))
}

@(test)
test_crlf_source_parses_the_same_as_lf :: proc(t: ^testing.T) {
	// The corpus is CRLF. Python's text mode hides that; here it has to be handled, and getting it
	// wrong makes the whole file one block that classifies as nothing.
	lf := parse("* Heading\n\nProse.\n")
	defer destroy(lf)
	crlf := parse("* Heading\r\n\r\nProse.\r\n")
	defer destroy(crlf)
	testing.expect_value(t, len(crlf.blocks), len(lf.blocks))
	testing.expect_value(t, render_html(crlf, context.temp_allocator), render_html(lf, context.temp_allocator))
}

@(test)
test_metadata_keeps_the_first_value_for_a_key :: proc(t: ^testing.T) {
	doc := parse("#+TITLE: First\n\n#+TITLE: Second\n\nProse.\n")
	defer destroy(doc)
	testing.expect_value(t, doc.meta["TITLE"], "First")
	testing.expect(t, strings.contains(render_html(doc, context.temp_allocator), "<title>First</title>"))
}

package bml

import "core:slice"
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
test_inline_text_renders_as_the_page_would :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		render_inline("1C--1!s", context.temp_allocator),
		`1<span class="ccolor">&#9827;</span>&#8211;1<span class="scolor">&#9824;</span>`,
	)
	testing.expect_value(t, render_inline("2N & 1NT", context.temp_allocator), "2NT &amp; 1NT")
	testing.expect_value(t, render_inline("What is our *first double*?", context.temp_allocator), "What is our <strong>first double</strong>?")
	testing.expect_value(t, render_inline("", context.temp_allocator), "")
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

@(test)
test_underline_needs_no_boundary :: proc(t: ^testing.T) {
	// Inside a word too: a hand's honours, bold and underlined.
	expect_inline(t, "A_*K*_JTx and _plain_", "<p>A<u><strong>K</strong></u>JTx and <u>plain</u></p>")
}

@(test)
test_a_table_row_with_no_cell_filled_in_is_left_out :: proc(t: ^testing.T) {
	doc := parse("| a | b |\n|---+---|\n| 1 | 2 |\n|   |   |\n")
	defer destroy(doc)
	html := render_html(doc, context.temp_allocator)
	testing.expect_value(t, strings.count(html, "<tr>"), 2)
}

@(test)
test_text_after_a_diagram_in_its_block_is_a_block_of_its_own :: proc(t: ^testing.T) {
	// Two lines after it used to fail the diagram test and leave the block to the `#` branch, a bid table;
	// one line was taken into the diagram and dropped.
	hands := "N: AKxx Qxx Kxx Axx\nS: Qxx AKxx Axx Kxx\n"
	for after in ([]string{"First line.\nSecond line.", "One line."}) {
		doc := parse(strings.concatenate({"#1, Dealer N, None vul\n", hands, after, "\n"}, context.temp_allocator))
		defer destroy(doc)
		testing.expect_value(t, len(doc.blocks), 2)
		testing.expect_value(t, doc.blocks[0].kind, Content_Kind.Diagram)
		testing.expect_value(t, doc.blocks[1].kind, Content_Kind.Paragraph)
	}
	// Nothing after it: one block, as before.
	doc := parse(strings.concatenate({"#1, Dealer N\n", hands}, context.temp_allocator))
	defer destroy(doc)
	testing.expect_value(t, len(doc.blocks), 1)
}

@(test)
test_text_before_a_diagram_in_its_block_is_a_block_of_its_own :: proc(t: ^testing.T) {
	// Text above the hands used to be taken for the header: it was lost, and so was the real header. The line
	// above the hands is the header only when it has a header's field.
	hands := "N: AKxx Qxx Kxx Axx\nS: Qxx AKxx Axx Kxx\n"
	with_header := parse(strings.concatenate({"a diagram\n#1, Dealer N, None vul\n", hands}, context.temp_allocator))
	defer destroy(with_header)
	testing.expect_value(t, len(with_header.blocks), 2)
	testing.expect_value(t, with_header.blocks[0].kind, Content_Kind.Paragraph)
	testing.expect_value(t, with_header.blocks[1].kind, Content_Kind.Diagram)
	testing.expect_value(t, with_header.blocks[1].diagram.board, "1")
	testing.expect_value(t, with_header.blocks[1].diagram.dealer, "N")

	no_header := parse(strings.concatenate({"a diagram\n", hands, "and after\n"}, context.temp_allocator))
	defer destroy(no_header)
	testing.expect_value(t, len(no_header.blocks), 3)
	testing.expect_value(t, no_header.blocks[1].kind, Content_Kind.Diagram)
	testing.expect_value(t, no_header.blocks[1].diagram.board, "")
	testing.expect_value(t, no_header.blocks[2].kind, Content_Kind.Paragraph)
}

@(test)
test_an_auction_is_calls_only :: proc(t: ^testing.T) {
	// Any number of calls a line, X and XX, 3NT, `-` for a seat before the dealer, and a `W N E S` header.
	doc := parse("W N E S\n- 1H X 2NT\n(XX) 3NT AP\n")
	defer destroy(doc)
	testing.expect_value(t, len(doc.blocks), 1)
	testing.expect_value(t, doc.blocks[0].kind, Content_Kind.Bidding)
	html := render_html(doc, context.temp_allocator)
	testing.expect(t, strings.contains(html, "<tr><th>W</th><th>N</th><th>E</th><th>S</th></tr><tr><td />"), html)
	testing.expect(t, strings.contains(html, "<td>Dbl</td><td>2NT</td></tr><tr><td>(Rdbl)</td><td>3NT</td><td>All pass</td>"), html)

	// Two calls are enough; a token that is not a call, or an `=`, is not an auction.
	Case :: struct {
		source: string,
		want:   Content_Kind,
	}
	for c in ([]Case{{"1H P\n", .Bidding}, {"w n e s\n1d p 1s\n", .Bidding}, {"P S\n", .Paragraph}}) {
		got := parse(c.source)
		defer destroy(got)
		testing.expectf(t, len(got.blocks) == 1 && got.blocks[0].kind == c.want, "%q: %v", c.source, got.blocks)
	}
}

@(test)
test_an_auctions_calls_carry_marks_for_notes_under_it :: proc(t: ^testing.T) {
	// `*` / `**` / `^1` after a call point at a note; `!` is an alert. The notes are the rows from the first
	// one starting `*` or `^1`; a row without a mark continues the note above.
	doc := parse("1H 2C* 2NT^1 p!\n* natural\n  5+ clubs\n^1 Lebensohl: 3C = relay\n")
	defer destroy(doc)
	testing.expect_value(t, len(doc.blocks), 1)
	testing.expect_value(t, doc.blocks[0].kind, Content_Kind.Bidding)
	html := render_html(doc, context.temp_allocator)
	for want in ([]string {
			`<sup class="bml-note">*</sup></td>`,
			`2NT<sup class="bml-note">1</sup>`,
			`Pass<sup class="bml-alert">!</sup>`,
			`<div class="bml-auction-notes"><div><sup class="bml-note">*</sup> natural 5+ clubs</div>`,
			`<div><sup class="bml-note">1</sup> Lebensohl: 3<span class="ccolor">&#9827;</span> = relay</div></div>`,
		}) {
		testing.expectf(t, strings.contains(html, want), "no %s in %s", want, html)
	}
}

@(test)
test_a_caption_titles_the_block_under_it :: proc(t: ^testing.T) {
	// `#+CAPTION:` as a block's first line, any case: a caption, and the rest of the block is classified as if
	// it stood alone - here an auction, then a diagram with its header. Not a heading, so no anchor.
	doc := parse("#+CAPTION: Lebensohl after *their* 2H\nW N E S\n- 1N 2H 2N*\n* relay\n\n#+caption: Board 3\n#3, Dealer S\nN: AKxx Qxx Kxx Axx\nS: Qxx AKxx Axx Kxx\n")
	defer destroy(doc)
	kinds := [?]Content_Kind{.Caption, .Bidding, .Caption, .Diagram}
	testing.expect_value(t, len(doc.blocks), len(kinds))
	for kind, i in kinds {
		if i < len(doc.blocks) {
			testing.expect_value(t, doc.blocks[i].kind, kind)
		}
	}
	testing.expect_value(t, doc.blocks[3].diagram.board, "3")
	html := render_html(doc, context.temp_allocator)
	testing.expect(t, strings.contains(html, `<div class="bml-caption">Lebensohl after <strong>their</strong> 2<span class="hcolor">&#9829;</span></div><table class="bml-auction">`), html)
	testing.expect(t, strings.contains(html, `<div class="bml-caption">Board 3</div>`), html)

	// A caption alone in its block is still one.
	alone := parse("#+CAPTION: just this\n")
	defer destroy(alone)
	testing.expect(t, len(alone.blocks) == 1 && alone.blocks[0].kind == .Caption && alone.blocks[0].text == "just this", "alone")
}

@(test)
test_a_box_puts_the_diagram_and_auction_beside_the_text :: proc(t: ^testing.T) {
	// `#BOX` / `#ENDBOX` are blocks of their own wherever they stand in a block. The caption, diagram and auction
	// it starts with go in the left column, the text after them in the right; after `#ENDBOX` the page goes on.
	doc := parse("#BOX\n#+CAPTION: Board 3\nN: AKxx Qxx Kxx Axx\nS: Qxx AKxx Axx Kxx\n\n1N P 3N\n\nWe stop in game.\n\nThe squeeze.\n#ENDBOX\nAfter.\n")
	defer destroy(doc)
	kinds := [?]Content_Kind{.Box, .Caption, .Diagram, .Bidding, .Paragraph, .Paragraph, .End_Box, .Paragraph}
	got := make([dynamic]Content_Kind, context.temp_allocator)
	for block in doc.blocks {
		append(&got, block.kind)
	}
	testing.expectf(t, slice.equal(got[:], kinds[:]), "%v", got[:])
	html := render_html(doc, context.temp_allocator)
	for want in ([]string {
			`<div class="bml-box"><div class="bml-box-side"><div class="bml-caption">Board 3</div><div class="bml-diagram">`,
			`</table></div><table class="bml-auction">`,
			`<div class="bml-box-text"><p>We stop in game.</p><p>The squeeze.</p></div></div><p>After.</p>`,
		}) {
		testing.expectf(t, strings.contains(html, want), "no %s in %s", want, html)
	}

	// A heading closes a box nobody closed; `# box` in any case is the marker.
	open := parse("# box\n1H P\n\nText.\n\n* Next\n\nOutside.\n")
	defer destroy(open)
	html = render_html(open, context.temp_allocator)
	testing.expect(t, strings.contains(html, `<div class="bml-box-side"><table class="bml-auction">`) && strings.contains(html, `<p>Text.</p></div></div><h1 id="Next">Next</h1><p>Outside.</p>`), html)
}

@(test)
test_a_diagram_compass_shows_the_board_dealer_and_vulnerability :: proc(t: ^testing.T) {
	// N E S W round the middle box, the board number inside it, the dealer marked, the vulnerable seats `vul`.
	doc := parse("#7, Dealer S, NS\nN: AKxx Qxx Kxx Axx\nS: xxx Axx AJx KQJx\n\nN: AKxx Qxx Kxx Axx\nS: xxx Axx AJx KQJx\n")
	defer destroy(doc)
	html := render_html(doc, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(
			html,
			`<td class="compass"><table class="bml-compass"><tr><td /><td class="seat vul">N</td><td /></tr><tr><td class="seat">W</td><td class="board">7</td><td class="seat">E</td></tr><tr><td /><td class="seat dealer vul">S</td><td /></tr></table></td>`,
		),
		html,
	)
	// No header: the letters alone, an empty middle.
	testing.expect(t, strings.contains(html, `<tr><td class="seat">W</td><td class="board" /><td class="seat">E</td></tr>`), html)
}

@(test)
test_a_box_with_a_type_is_a_callout :: proc(t: ^testing.T) {
	// `#BOX warning Title`, any case: a callout frame with the type's label and the title, the box inside it.
	// `#BOX Title` alone: the frame with the title and no label. `#BOX note` alone: the label, no title. Plain
	// `#BOX` stays unframed, and `#BOXES` is no marker.
	doc := parse(
		"#BOX Warning  Don't *forget*\nSystems on after 1NT.\n#ENDBOX\n\n" +
		"#box Board 3\nN: AKxx Qxx Kxx Axx\n\nText.\n#ENDBOX\n\n" +
		"#BOX note\nA note.\n#ENDBOX\n\n" +
		"#BOX info Heads up\nAn info box.\n#ENDBOX\n\n" +
		"#BOX\nPlain.\n#ENDBOX\n",
	)
	defer destroy(doc)
	html := render_html(doc, context.temp_allocator)
	for want in ([]string {
			`<div class="bml-callout bml-warning"><div class="bml-callout-head"><span class="bml-callout-label">Warning</span> <span class="bml-callout-title">Don't <strong>forget</strong></span></div><div class="bml-box"><div class="bml-box-text"><p>Systems on after 1NT.</p></div></div></div>`,
			`<div class="bml-callout"><div class="bml-callout-head"><span class="bml-callout-title">Board 3</span></div><div class="bml-box"><div class="bml-box-side"><div class="bml-diagram">`,
			`<div class="bml-callout bml-note"><div class="bml-callout-head"><span class="bml-callout-label">Note</span></div><div class="bml-box"><div class="bml-box-text"><p>A note.</p>`,
			`<div class="bml-callout bml-info"><div class="bml-callout-head"><span class="bml-callout-label">Info</span> <span class="bml-callout-title">Heads up</span></div>`,
			`<div class="bml-box"><div class="bml-box-text"><p>Plain.</p></div></div>`,
		}) {
		testing.expectf(t, strings.contains(html, want), "no %s in %s", want, html)
	}
	testing.expect_value(t, strings.count(html, `<div class="bml-callout"`) + strings.count(html, `<div class="bml-callout bml-`), 4)

	not_marker := parse("#BOXES\n")
	defer destroy(not_marker)
	for block in not_marker.blocks {
		testing.expect(t, block.kind != .Box, "#BOXES is not a box")
	}
}

@(test)
test_seat_and_vulnerability_conditions_are_tagged_in_a_description :: proc(t: ^testing.T) {
	// In a bid table's description: (NV) / (VUL), bare NV / VUL, seat lists, `Nth seat|position`, passed
	// hand(s) - inside a link too. A lone ordinal (`4th suit`), a word containing NV, and a list that runs into
	// a word are not conditions; a paragraph is not a description.
	doc := parse(
		"2H = 5+ (NV) / 6+ (VUL), 1st/2nd/3rdx, 3rd/4th to play\n" +
		"    2N = [ask (NV)](#Ask), stopped or NV, INV, NVL, 4th suit\n" +
		"    3C = by passed hand, unpassed hands, 3rd seat, 4th position\n" +
		"\n" +
		"A paragraph, 1st/2nd (NV).\n",
	)
	defer destroy(doc)
	html := render_html(doc, context.temp_allocator)
	tag :: proc(text: string) -> string {return strings.concatenate({`<span class="bml-cond">`, text, `</span>`}, context.temp_allocator)}
	for want in ([]string{"(NV)", "(VUL)", "1st/2nd", "3rd/4th", "passed hand", "unpassed hands", "3rd seat", "4th position"}) {
		testing.expectf(t, strings.contains(html, tag(want)), "no tag for %s in %s", want, html)
	}
	testing.expect(t, strings.contains(html, `<a href="#Ask">ask <span class="bml-cond">(NV)</span></a>`), "a condition inside a link")
	testing.expect(t, strings.contains(html, `stopped or <span class="bml-cond">NV</span>, INV, NVL, 4th suit`), "only the bare word")
	testing.expect_value(t, strings.count(html, `class="bml-cond"`), 10)
	testing.expect(t, strings.contains(html, "<p>A paragraph, 1st/2nd (NV).</p>"), "not in a paragraph")

	// A LONE seat: in a row that names seats, anywhere but before a word that makes it something else; in any
	// other row only where it ends the text, or before NV / VUL - not before a comma or `or`, which list other
	// things (reported 2026-10-28: `3rd both minors` was not tagged).
	lone := parse(
		"4N = 1st/2nd solid preempt, 3rd both minors, 4th suit, 2nd round\n" +
		"5C = maybe 5 cards 1st NV or 3rd\n" +
		"5D = lead directing in 3rd. Not 1st or 2nd round control, (2nd, 3rd & 4th honour)\n",
	)
	defer destroy(lone)
	html = render_html(lone, context.temp_allocator)
	for want in ([]string{`<span class="bml-cond">3rd</span> both minors`, `<span class="bml-cond">1st</span> <span class="bml-cond">NV</span> or <span class="bml-cond">3rd</span>`, `in <span class="bml-cond">3rd</span>.`}) {
		testing.expectf(t, strings.contains(html, want), "no %s in %s", want, html)
	}
	for unwanted in ([]string{"4th suit", "2nd round", "Not 1st or 2nd round control", "(2nd, 3rd &amp; 4th honour)"}) {
		testing.expectf(t, strings.contains(html, unwanted), "%s should be left alone in %s", unwanted, html)
	}
}

@(test)
test_a_lower_case_bid_gets_its_suit_glyphs :: proc(t: ^testing.T) {
	// `1d` is `1D`; words that start with a level (`3cue`, `6higher`) and classes (`2m`) are left as written.
	doc := parse("1c = x\n    1d = a\n    1nt = b\n    3cue = c\n    2m = d\n")
	defer destroy(doc)
	html := render_html(doc, context.temp_allocator)
	for want in ([]string{`1<span class="ccolor">`, `1<span class="dcolor">`, ">1NT<", ">3cue<", ">2m<"}) {
		testing.expectf(t, strings.contains(html, want), "no %s in %s", want, html)
	}
}

@(test)
test_a_class_hook_reaches_the_html :: proc(t: ^testing.T) {
	// `{.name}` at the end of a heading, `#BOX` or `#+CAPTION:` line: classes on what the line makes, and not
	// part of the text - the anchor is the heading without it. Glued to a word, or a bad name, it is text.
	doc := parse(
		"* Opening {.big}\n\n** Defence\t{ .a.b  .c-d_9 }  \n\n#+CAPTION: Board 3 {.small}\n| a | b |\n\n" +
		"#BOX tip Systems on {.compact}\nText.\n#ENDBOX\n\n#BOX {.plain}\nMore.\n#ENDBOX\n\n" +
		"** Glued{.x}\n\n** Bad {.9x}\n\n** Last {.end}\n", // the last block of a file keeps its newline
	)
	defer destroy(doc)
	html := render_html(doc, context.temp_allocator)
	for want in ([]string {
			`<h1 id="Opening" class="big">Opening</h1>`,
			`<h2 id="Defence" class="a b c-d_9">Defence</h2>`,
			`<div class="bml-caption small">Board 3</div>`,
			`<div class="bml-callout bml-tip compact">`,
			`<div class="bml-box plain">`,
			`<h2 id="Glued{.x}">Glued{.x}</h2>`,
			`<h2 id="Bad_{.9x}">Bad {.9x}</h2>`,
			`<h2 id="Last" class="end">Last</h2>`,
		}) {
		testing.expectf(t, strings.contains(html, want), "no %s in %s", want, html)
	}
}

@(test)
test_own_stylesheets_are_linked_after_bml_css :: proc(t: ^testing.T) {
	// `#+CSS: a.css b.css`: the author's stylesheets, linked after bml.css (and the font) so their rules win.
	doc := parse("#+CSS: mine.css  extra/b.css\n\nText.\n")
	defer destroy(doc)
	html := render_html(doc, context.temp_allocator)
	want := `<link rel="stylesheet" type="text/css" href="bml.css" /><link href="https://fonts.googleapis.com/css?family=Open Sans" rel="stylesheet" /><link rel="stylesheet" type="text/css" href="mine.css" /><link rel="stylesheet" type="text/css" href="extra/b.css" />`
	testing.expectf(t, strings.contains(html, want), "no %s in %s", want, html)
}

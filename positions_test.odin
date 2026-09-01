package bml

import "base:runtime"
import "core:strings"
import "core:testing"

/*
Diagnostic position tests.

What is being pinned is a MAPPING, not a message: the parse walks a text that had its newlines
normalised, its includes expanded and its comment lines removed, and every diagnostic still has to
point at a line and column of the source someone is looking at. Each test below breaks that mapping
in one specific way - an include ahead of the problem, comment lines ahead of it, CRLF, a problem
inside an included file - because those are the four ways the working text stops agreeing with the
buffer.
*/

@(private = "file")
parse_temp :: proc(source: string, options := Parse_Options{}) -> ^Document {
	return parse(source, options)
}

@(private = "file")
serve :: proc(name: string, user: rawptr, allocator: runtime.Allocator) -> (text: string, ok: bool) {
	files := (^map[string]string)(user)
	text, ok = files[name]
	return
}

@(test)
test_a_missing_include_points_at_its_own_line :: proc(t: ^testing.T) {
	// No resolver at all: the directive cannot be honoured and the diagnostic is the only trace.
	doc := parse_temp("* Heading\n\n  #INCLUDE chapter.bml\n\nprose\n")
	defer destroy(doc)
	if !testing.expect_value(t, len(doc.diagnostics), 1) {
		return
	}
	diagnostic := doc.diagnostics[0]
	testing.expect_value(t, diagnostic.file, "")
	testing.expect_value(t, diagnostic.line, 3)
	// Column 3, past the two spaces of indentation, and the underline covers `#INCLUDE chapter.bml`.
	testing.expect_value(t, diagnostic.col, 3)
	testing.expect_value(t, diagnostic.length, len("#INCLUDE chapter.bml"))
	testing.expect_value(t, diagnostic.severity, Severity.Warning)
}

@(test)
test_an_unresolvable_include_is_an_error_a_missing_resolver_is_a_warning :: proc(t: ^testing.T) {
	// A resolver that says no is a real mistake - the name is wrong or the file is gone. No resolver
	// at all is the caller's own choice, so it cannot be the document's fault.
	files := make(map[string]string, 1, context.temp_allocator)
	doc := parse_temp("#INCLUDE gone.bml\n", {resolve_include = serve, include_user = &files})
	defer destroy(doc)
	if !testing.expect_value(t, len(doc.diagnostics), 1) {
		return
	}
	testing.expect_value(t, doc.diagnostics[0].severity, Severity.Error)
	testing.expect_value(t, doc.diagnostics[0].line, 1)
}

@(test)
test_a_diagnostic_after_an_include_still_counts_buffer_lines :: proc(t: ^testing.T) {
	// The include brings in four lines plus two wrapper newlines, so by the working text's own
	// counting the bad directive is nowhere near line 5. This is the mapping's whole reason to exist.
	files := make(map[string]string, 1, context.temp_allocator)
	files["chapter.bml"] = "* One\n\nprose\n\nmore prose\n"
	doc := parse_temp("#INCLUDE chapter.bml\n\n#HDIE\n1C = strong\n", {resolve_include = serve, include_user = &files})
	defer destroy(doc)
	if !testing.expect_value(t, len(doc.diagnostics), 1) {
		return
	}
	testing.expect_value(t, doc.diagnostics[0].file, "")
	testing.expect_value(t, doc.diagnostics[0].line, 3)
	testing.expect_value(t, doc.diagnostics[0].col, 1)
}

@(test)
test_a_problem_inside_an_included_file_names_that_file :: proc(t: ^testing.T) {
	files := make(map[string]string, 1, context.temp_allocator)
	files["chapter.bml"] = "* One\n\n#HDIE\n1C = strong\n"
	doc := parse_temp("prose\n\n#INCLUDE chapter.bml\n", {resolve_include = serve, include_user = &files})
	defer destroy(doc)
	if !testing.expect_value(t, len(doc.diagnostics), 1) {
		return
	}
	// Line 3 OF THE INCLUDED FILE, which is a different line 3 from the host buffer's.
	testing.expect_value(t, doc.diagnostics[0].file, "chapter.bml")
	testing.expect_value(t, doc.diagnostics[0].line, 3)
}

@(test)
test_comment_lines_do_not_shift_the_numbers :: proc(t: ^testing.T) {
	// Three commented lines are gone from the working text before any block is classified.
	doc := parse_temp("//one\n//two\n//three\n#HDIE\n1C = strong\n")
	defer destroy(doc)
	if !testing.expect_value(t, len(doc.diagnostics), 1) {
		return
	}
	testing.expect_value(t, doc.diagnostics[0].line, 4)
}

@(test)
test_crlf_source_counts_the_same_lines :: proc(t: ^testing.T) {
	// The corpus is CRLF and a text widget speaks LF, so both have to land on the same line.
	doc := parse_temp("prose\r\n\r\n#HDIE\r\n1C = strong\r\n")
	defer destroy(doc)
	if !testing.expect_value(t, len(doc.diagnostics), 1) {
		return
	}
	testing.expect_value(t, doc.diagnostics[0].line, 3)
}

@(test)
test_an_unknown_directive_underlines_the_keyword :: proc(t: ^testing.T) {
	doc := parse_temp("1C = strong\n\n  #HDIE\n  1D = negative\n")
	defer destroy(doc)
	if !testing.expect_value(t, len(doc.diagnostics), 1) {
		return
	}
	diagnostic := doc.diagnostics[0]
	testing.expect_value(t, diagnostic.line, 3)
	testing.expect_value(t, diagnostic.col, 3)
	testing.expect_value(t, diagnostic.length, len("#HDIE"))
	testing.expect(t, strings.contains(diagnostic.message, "#HDIE"))
}

@(test)
test_every_real_directive_is_accepted :: proc(t: ^testing.T) {
	// The check has to know the reference's whole list, or a valid document grows squiggles.
	source := "#CUT frag\n1C = strong\n#ENDCUT\n\n#COPY two\n1D = neg\n#ENDCOPY\n\n#HIDE\n#BIDTABLE\n#PASTE frag\n\n#VUL All\n\n#SEAT 1\n\n#+TITLE: Notes\n"
	doc := parse_temp(source)
	defer destroy(doc)
	testing.expect_value(t, len(doc.diagnostics), 0)
}

@(test)
test_a_hash_in_prose_is_not_a_directive :: proc(t: ^testing.T) {
	// A link's `#Anchor` and a mid-line `#` are the two ways this check could cry wolf.
	doc := parse_temp("* Anchor\n\nsee [Anchor](#Anchor) and c#4 for the rest\n")
	defer destroy(doc)
	testing.expect_value(t, len(doc.diagnostics), 0)
}

@(test)
test_cross_references_are_checked_only_on_request :: proc(t: ^testing.T) {
	source := "* Real Heading\n\nsee [there](#No Such Heading)\n"
	quiet := parse_temp(source)
	testing.expect_value(t, len(quiet.diagnostics), 0)
	destroy(quiet)

	doc := parse_temp(source, {check_cross_references = true})
	defer destroy(doc)
	if !testing.expect_value(t, len(doc.diagnostics), 1) {
		return
	}
	diagnostic := doc.diagnostics[0]
	testing.expect_value(t, diagnostic.severity, Severity.Warning)
	testing.expect_value(t, diagnostic.line, 3)
	// Column 13 is the `#`, and the underline runs to the closing bracket.
	testing.expect_value(t, diagnostic.col, 13)
	testing.expect_value(t, diagnostic.length, len("#No Such Heading"))
}

@(test)
test_a_cross_reference_that_resolves_is_quiet :: proc(t: ^testing.T) {
	// Anchors are normalised at both ends - spaces to underscores, `1C` to `1c` - so a link written
	// the reference's way has to match the heading it names. `[Top](#)` is the page itself.
	source := "* 1C Weak Strong\n\n** Sub Heading\n\nsee [it](#1C Weak Strong), [sub](#Sub_Heading) and [top](#)\n"
	doc := parse_temp(source, {check_cross_references = true})
	defer destroy(doc)
	testing.expect_value(t, len(doc.diagnostics), 0)
}

@(test)
test_an_anchor_defined_by_an_included_file_resolves :: proc(t: ^testing.T) {
	// The check runs over the assembled document, which is what makes it usable on a root file.
	files := make(map[string]string, 1, context.temp_allocator)
	files["chapter.bml"] = "* Included Heading\n"
	doc := parse_temp(
		"see [it](#Included Heading)\n\n#INCLUDE chapter.bml\n",
		{resolve_include = serve, include_user = &files, check_cross_references = true},
	)
	defer destroy(doc)
	testing.expect_value(t, len(doc.diagnostics), 0)
}

@(test)
test_diagnostic_text_prints_what_is_known :: proc(t: ^testing.T) {
	full := diagnostic_text(
		Diagnostic{message = "bad", severity = .Warning, at = {file = "chapter.bml", line = 12, col = 4}},
		context.temp_allocator,
	)
	testing.expect_value(t, full, "chapter.bml:12:4: warning: bad")

	// A position that was lost prints as a plain sentence rather than as a row of zeroes.
	bare := diagnostic_text(Diagnostic{message = "bad"}, context.temp_allocator)
	testing.expect_value(t, bare, "bad")
}

@(test)
test_a_paste_diagnostic_points_at_the_paste_line :: proc(t: ^testing.T) {
	doc := parse_temp("1C = strong\n\n#PASTE nothing\n1D = negative\n")
	defer destroy(doc)
	if !testing.expect_value(t, len(doc.diagnostics), 1) {
		return
	}
	testing.expect_value(t, doc.diagnostics[0].line, 3)
	testing.expect_value(t, doc.diagnostics[0].col, 1)
}

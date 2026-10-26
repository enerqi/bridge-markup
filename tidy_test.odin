package bml

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// Levels become `step` spaces each; the first row keeps its column; a continuation keeps its offset.
@(test)
test_tidy_reindents_by_level :: proc(t: ^testing.T) {
	source := "1C = strong\n  1D = negative\n     1H = relay\n       with a long\n  1S = positive\n"
	got, changed := tidy_indentation(source, 4, context.temp_allocator)
	testing.expect_value(t, got, "1C = strong\n    1D = negative\n        1H = relay\n          with a long\n    1S = positive\n")
	testing.expect_value(t, changed, 4)
}

// The tree decides, not the columns: a step back to a column no row above uses (0, 4, then 2) nests under
// the nearest shallower bid, so it is written at THAT level - beside the 4, not between.
@(test)
test_tidy_follows_the_parse_not_the_columns :: proc(t: ^testing.T) {
	got, _ := tidy_indentation("1C = a\n    1D = b\n  1H = c\n", 4, context.temp_allocator)
	testing.expect_value(t, got, "1C = a\n    1D = b\n    1H = c\n")
}

// Only bid tables: prose, lists, headings, `#` directive blocks and comment lines are left as they are,
// and `\r\n` survives.
@(test)
test_tidy_leaves_everything_else :: proc(t: ^testing.T) {
	source := "* Heading\r\n\r\nSome prose\r\n   indented oddly.\r\n\r\n- a list\r\n   - nested\r\n\r\n#HIDE\r\n1C = x\r\n  1D = y\r\n\r\n1C = x\r\n  1D = y\r\n// 1H = commented\r\n"
	got, changed := tidy_indentation(source, 4, context.temp_allocator)
	testing.expect_value(t, changed, 1)
	testing.expect(t, strings.has_suffix(got, "1C = x\r\n    1D = y\r\n// 1H = commented\r\n"), got)
	testing.expect(t, strings.contains(got, "#HIDE\r\n1C = x\r\n  1D = y\r\n"), "a directive block is left alone")
}

// A tab counts as one space in the parse, so it is written as one level's worth of what it parsed as.
@(test)
test_tidy_replaces_tabs :: proc(t: ^testing.T) {
	got, _ := tidy_indentation("1C = a\n\t1D = b\n", 4, context.temp_allocator)
	testing.expect_value(t, got, "1C = a\n    1D = b\n")
}

// Nothing to do: the source comes back as it was, and nothing is allocated for it.
@(test)
test_tidy_of_tidy_text_is_unchanged :: proc(t: ^testing.T) {
	source := "1C = a\n    1D = b\n"
	got, changed := tidy_indentation(source, 4, context.temp_allocator)
	testing.expect_value(t, changed, 0)
	testing.expect(t, raw_data(got) == raw_data(source), "unchanged text should be the source itself")
}

// The check's three cases, each reported once, and nothing for plain 0/4/8 nesting or a clean step back.
@(test)
test_check_indentation_reports_misleading_rows :: proc(t: ^testing.T) {
	count :: proc(source: string) -> int {
		doc := parse(source, {check_indentation = true})
		defer destroy(doc)
		return len(doc.diagnostics)
	}
	testing.expect_value(t, count("1C = a\n    1D = b\n        1H = c\n    1S = d\n2C = e\n"), 0)
	testing.expect_value(t, count("1C = a\n\t1D = b\n"), 1) // a tab
	testing.expect_value(t, count("1C = a\n    1D = b\n  1H = c\n"), 1) // back to a column no row above uses
	testing.expect_value(t, count("1C = a\n    1D = b\n     1H = c\n"), 1) // one column in
	testing.expect_value(t, count("    1C = a\n1D = b\n"), 1) // left of the first row
	doc := parse("1C = a\n    1D = b\n  1H = c\n")
	defer destroy(doc)
	testing.expect_value(t, len(doc.diagnostics), 0) // off unless asked for
}

/*
THE CONTRACT, on the real corpus: every file tidied, and every document rendered from the tidied files,
is byte-for-byte the page the untidied files make - and a second tidy changes nothing. Skipped when the
notes checkout is not there (`BRIDGE_SYSTEM_HOME`, default `~/docs/bridge/bridge-bidding-system`).
*/
@(test)
test_tidy_keeps_the_corpus_rendering :: proc(t: ^testing.T) {
	dir := os.get_env("BRIDGE_SYSTEM_HOME", context.temp_allocator)
	if dir == "" {
		home := os.get_env("USERPROFILE", context.temp_allocator)
		dir, _ = filepath.join({home, "docs", "bridge", "bridge-bidding-system"}, context.temp_allocator)
	}
	infos, err := os.read_directory_by_path(dir, 0, context.temp_allocator)
	if err != nil {
		return
	}
	Corpus :: struct {
		original, tidied: map[string]string,
		use_tidied:       bool,
	}
	corpus := Corpus {
		original = make(map[string]string, 32, context.temp_allocator),
		tidied   = make(map[string]string, 32, context.temp_allocator),
	}
	for info in infos {
		if !strings.has_suffix(info.name, ".bml") {
			continue
		}
		data, rerr := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
		if rerr != nil {
			continue
		}
		original := normalise_newlines(string(data), context.temp_allocator)
		tidied, _ := tidy_indentation(original, 4, context.temp_allocator)
		again, changed := tidy_indentation(tidied, 4, context.temp_allocator)
		testing.expectf(t, changed == 0 && again == tidied, "%s: a second tidy changed %d lines", info.name, changed)
		corpus.original[info.name] = original
		corpus.tidied[info.name] = tidied
	}
	resolve :: proc(name: string, user: rawptr, allocator: mem.Allocator) -> (string, bool) {
		corpus := cast(^Corpus)user
		texts := corpus.tidied if corpus.use_tidied else corpus.original
		text, found := texts[filepath.base(name)]
		return strings.clone(text, allocator), found
	}
	for name, original in corpus.original {
		corpus.use_tidied = false
		before_doc := parse(original, {resolve_include = resolve, include_user = &corpus})
		before := render_html(before_doc, context.temp_allocator)
		destroy(before_doc)
		corpus.use_tidied = true
		after_doc := parse(corpus.tidied[name], {resolve_include = resolve, include_user = &corpus})
		after := render_html(after_doc, context.temp_allocator)
		destroy(after_doc)
		testing.expectf(t, before == after, "%s renders differently once tidied", name)
	}
}

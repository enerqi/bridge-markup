package bml

import "core:strings"

/*
Re-indent every bid table in a source text to `step` spaces a level, keeping its tree.

Nothing about the NESTING changes, and that is the whole contract: the new indent of each row is worked
out by the builder's own rules (`create_bidtree`) - a row deeper than the bid above is its child, the same
column is a sibling, a shallower one steps back up - so the levels are the parse's levels, written again
at `step` spaces each. A tidied document renders byte-for-byte as it did (the corpus test holds that).

  - A table keeps its first row's column; only the levels below it move.
  - A description CONTINUATION (a row that is not a bid, under one) keeps its offset from its bid.
  - Tabs in an indent go, as the count they were: the parse counts a tab as one space.
  - Only what the parse would read as a bid table is touched. A block with a `#` directive in it is left
    alone (`#CUT`, `#PASTE`, `#HIDE` and `#INCLUDE` rewrite the rows the builder sees), as are `//`
    comment lines, headings, lists, auctions and prose.

Works on SOURCE TEXT, `\n` or `\r\n` (a line's `\r` is kept). Returns the new text and how many lines
changed; the text is `source` itself, unallocated, when none did.
*/
tidy_indentation :: proc(source: string, step := 4, allocator := context.allocator) -> (text: string, changed: int) {
	lines := strings.split(source, "\n", context.temp_allocator)
	indents := make([]int, len(lines), context.temp_allocator) // the new indent, or -1 for "leave it"
	for &indent in indents {
		indent = -1
	}

	// The blocks, as `split_blocks` cuts them once the comment lines are gone: runs of lines between lines
	// that hold nothing but spaces.
	block := make([dynamic]int, 0, 32, context.temp_allocator)
	for i := 0; i <= len(lines); i += 1 {
		content := i < len(lines) ? strings.trim_right(lines[i], "\r") : ""
		if i < len(lines) && strings.has_prefix(content, "//") {
			continue
		}
		if i < len(lines) && strings.trim_left(content, " ") != "" {
			append(&block, i)
			continue
		}
		if len(block) > 0 {
			tidy_block(lines, block[:], indents, step)
			clear(&block)
		}
	}

	out := strings.builder_make(0, len(source) + len(source) / 8, allocator)
	for line, i in lines {
		if i > 0 {
			strings.write_byte(&out, '\n')
		}
		old := leading_space_count(line)
		if indents[i] < 0 || (indents[i] == old && strings.index_byte(line[:old], '\t') < 0) {
			strings.write_string(&out, line)
			continue
		}
		changed += 1
		for _ in 0 ..< indents[i] {
			strings.write_byte(&out, ' ')
		}
		strings.write_string(&out, line[old:])
	}
	if changed == 0 {
		strings.builder_destroy(&out)
		return source, 0
	}
	return strings.to_string(out), changed
}

// One block's new indents into `indents`, if the parse would read the block as a bid table.
@(private = "file")
tidy_block :: proc(lines: []string, block: []int, indents: []int, step: int) {
	rows := make([]string, len(block), context.temp_allocator)
	for index, i in block {
		rows[i] = strings.trim_right(lines[index], "\r")
	}
	text := strings.join(rows, "\n", context.temp_allocator)

	// The classification's order (`classify_block`), as far as a bid table: anything it would have called
	// something else first is not one.
	if strings.has_prefix(text, "*") || starts_with_after_space(text, "-") || starts_with_after_space(text, "1.") ||
	   is_bidding_block(text) || !looks_like_bidtable(text) {
		return
	}
	for row in rows {
		if strings.has_prefix(strings.trim_left_space(row), "#") {
			return
		}
	}

	// The builder's walk (`create_bidtree`), keeping each level's new column instead of building nodes.
	Level :: struct {
		old, new: int,
	}
	stack := make([dynamic]Level, 0, 8, context.temp_allocator)
	append(&stack, Level{old = -1, new = -1}) // the root
	base := -1
	for row, i in rows {
		indentation := leading_space_count(row)
		stripped := strings.trim_space(row)
		last := stack[len(stack) - 1]
		if len(stack) > 1 && indentation >= last.old && !is_bid_row(stripped) {
			indents[block[i]] = last.new + (indentation - last.old)
			continue
		}
		if base < 0 {
			base = indentation
		}
		for indentation < stack[len(stack) - 1].old {
			pop(&stack)
		}
		top := stack[len(stack) - 1]
		if indentation > top.old {
			level := Level{old = indentation, new = base if top.old < 0 else top.new + step}
			append(&stack, level)
		} else {
			stack[len(stack) - 1].old = indentation // a sibling: the same level, measured from this row now
		}
		indents[block[i]] = stack[len(stack) - 1].new
	}
}

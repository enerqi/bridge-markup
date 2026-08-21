package bml

import "core:strings"

/*
The canonical spelling of a bid token - the auction it stands for, written as calls separated by
spaces.

A bid token in a bid table is usually one call (`1C`, `(2D)`), but it may spell out a whole auction:
`1C--P--1H`, `(1CD)--1H--2C`, or with single dashes `1c-2d-3d-3s-4c`. Those separators have to be
split on BEFORE anything else touches the text. Stripping the dashes first glues the calls into one
unreadable run (`(1CD)1H2C`), and re-finding calls afterwards with a digit-led pattern silently drops
any that do not start with a digit - `1C--P--1H` came back as `1CP (P) 1H`, the pass swallowed by the
call in front of it.
*/
bid_representation :: proc(bid: string, allocator := context.allocator) -> string {
	// A call written as a markdown link, `[1D](#1C--1D)`. Its *target* legitimately contains `--`,
	// so such a token is never split.
	if is_link_token(strings.trim_space(bid)) {
		return normalise_call(bid, allocator)
	}

	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	for part in split_on_dash_run(bid, context.temp_allocator) {
		// `p.strip("-")` in the python: a part that is nothing but dashes is not a call.
		if strings.trim(part, "-") != "" {
			append(&parts, part)
		}
	}

	// A single dash is ambiguous - it also joins words inside a pseudo-bid (`new-suit`, `jump-cue`,
	// `2-Cue`) - so it only separates when EVERY part it produces is itself call-shaped.
	if len(parts) < 2 {
		single := make([dynamic]string, 0, 8, context.temp_allocator)
		for part in strings.split(bid, "-", context.temp_allocator) {
			if part != "" {
				append(&single, part)
			}
		}
		if len(single) > 1 {
			all_calls := true
			for part in single {
				if !is_call_shaped(part) {
					all_calls = false
					break
				}
			}
			if all_calls {
				parts = single
			}
		}
	}

	calls := make([dynamic]string, 0, 8, context.temp_allocator)
	for part in parts {
		call := normalise_call(part, context.temp_allocator)
		if call != "" {
			append(&calls, call)
		}
	}
	if len(calls) < 2 {
		return normalise_call(bid, allocator)
	}

	// `1H--2C` is our side bidding twice, so the opponents passed in between and it reads
	// `1H (P) 2C`. `1C--P--1H` and `(1CD)--1H--2C` already say who called, so they are left alone.
	spelled_out := false
	for call in calls {
		if strings.has_prefix(call, "(") || is_explicit_call(call) {
			spelled_out = true
			break
		}
	}
	separator := spelled_out ? " " : " (P) "
	return strings.join(calls[:], separator, allocator)
}

// Calls that say the auction was spelled out in full rather than abbreviated to our side's bids.
@(rodata)
@(private = "file")
explicit_calls := [?]string{"P", "PASS", "X", "XX", "D", "DBL", "R", "RDBL"}

@(private = "file")
is_explicit_call :: proc(text: string) -> bool {
	for call in explicit_calls {
		if equal_fold_ascii(text, call) {
			return true
		}
	}
	return false
}

// A level bid or a bare pass/double/redouble, bracketed or not.
@(private = "file")
is_call_shaped :: proc(text: string) -> bool {
	rest := strings.has_prefix(text, "(") ? text[1:] : text
	if len(rest) > 0 && rest[0] >= '1' && rest[0] <= '7' {
		return true
	}
	return is_explicit_call(text)
}

// A bid written as a markdown link, `[1D](#1C--1D)`. Its TARGET legitimately contains `--`, which
// is why such a token is never split into an auction.
@(private = "file")
is_link_token :: proc(text: string) -> bool {
	if !strings.has_prefix(text, "[") {
		return false
	}
	close := strings.index_byte(text, ']')
	if close < 0 {
		return false
	}
	return close + 1 < len(text) && text[close + 1] == '('
}

// One call, tidied: `NT` -> `N`, stray dashes and semicolons dropped. The order matters and matches
// the python: the dashes go first, so `N-T` normalises to `N` too.
@(private = "file")
normalise_call :: proc(text: string, allocator := context.allocator) -> string {
	stripped := strings.builder_make(0, len(text), context.temp_allocator)
	for i in 0 ..< len(text) {
		if text[i] != '-' && text[i] != ';' {
			strings.write_byte(&stripped, text[i])
		}
	}
	// `NT` -> `N` is applied AFTER the dashes go, exactly as the python chains the two, so `N-T`
	// normalises to `N` as well. Non-overlapping, left to right.
	bare := strings.to_string(stripped)
	out := strings.builder_make(0, len(bare), allocator)
	i := 0
	for i < len(bare) {
		if i + 1 < len(bare) && bare[i] == 'N' && bare[i + 1] == 'T' {
			strings.write_byte(&out, 'N')
			i += 2
		} else {
			strings.write_byte(&out, bare[i])
			i += 1
		}
	}
	return strings.to_string(out)
}

// Split on runs of two or more dashes, the compound-auction separator.
@(private = "file")
split_on_dash_run :: proc(text: string, allocator := context.allocator) -> []string {
	parts := make([dynamic]string, 0, 8, allocator)
	start, i := 0, 0
	for i < len(text) {
		if text[i] != '-' {
			i += 1
			continue
		}
		run := i
		for run < len(text) && text[run] == '-' {
			run += 1
		}
		if run - i >= 2 {
			append(&parts, text[start:i])
			start = run
		}
		i = run
	}
	append(&parts, text[start:])
	return parts[:]
}

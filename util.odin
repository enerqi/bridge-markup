package bml

// ASCII-only case-insensitive comparison. The python compares `text.upper()` against a set of call
// spellings; every one of them is ASCII, and a unicode-aware fold would be both slower and, for
// tokens like `X`, subtly different.
@(private)
equal_fold_ascii :: proc(a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x, y := a[i], b[i]
		if 'a' <= x && x <= 'z' {
			x -= 'a' - 'A'
		}
		if 'a' <= y && y <= 'z' {
			y -= 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

// Python's `str.strip()`/`lstrip()` treat these as whitespace; the corpus never uses the exotic
// unicode spaces, so byte tests are enough and keep the scanners branch-cheap.
@(private)
is_space_byte :: proc(c: byte) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'
}

@(private)
is_digit_byte :: proc(c: byte) -> bool {
	return '0' <= c && c <= '9'
}

@(private)
is_letter_byte :: proc(c: byte) -> bool {
	return ('a' <= c && c <= 'z') || ('A' <= c && c <= 'Z')
}

// The count of leading whitespace CHARACTERS, which is what the python's
// `len(row) - len(row.lstrip())` measures and what the bid tree nests on. A tab counts as one.
@(private)
leading_space_count :: proc(row: string) -> int {
	i := 0
	for i < len(row) && is_space_byte(row[i]) {
		i += 1
	}
	return i
}

package bml

import "core:fmt"
import "core:strings"

/*
Where a diagnostic points, in the SOURCE the caller handed over rather than in the text the parse
actually walked.

Those are two different strings. `parse` normalises newlines, expands `#INCLUDE`, and drops
commented-out lines before it splits a single block, so an offset into the working text is nobody's
idea of a position. An editor needs a line and a column in the buffer someone is looking at, and a
problem inside an included file has to say which file.

`line` and `col` are 1-based, `col` and `length` are BYTES - which is what a per-line scan in a text
widget wants, and the corpus is ASCII apart from the odd glyph. Zeroes are the "not known" values,
and they nest: `line = 0` means the position was lost, `col = 0` means the whole line, `length = 0`
means from `col` to the end of the line.

One known limitation, in exchange for keeping the parity-critical passes byte-for-byte: a source
using LONE `\r` line endings has its lines counted after normalisation, so its numbers shift. CRLF
and LF - the whole corpus, and everything a text widget produces - are exact.
*/
Source_Span :: struct {
	// "" is the parsed buffer itself; otherwise the `#INCLUDE` name the line came from.
	file:   string,
	line:   int,
	col:    int,
	length: int,
}

// How much a diagnostic wants to be believed. Neither value refuses the document.
Severity :: enum {
	Error,
	Warning,
}

/*
One problem, and where it is.

A struct rather than the string it used to be, because a squiggle needs the position and a build log
needs the sentence. `diagnostic_text` writes the sentence with the position in front of it, which is
what a command-line consumer wants.
*/
Diagnostic :: struct {
	message:  string,
	severity: Severity,
	using at: Source_Span,
}

/*
`file:line:col: message`, the shape a compiler prints and an editor's error list parses.

Whatever is not known is left out rather than printed as a zero.
*/
diagnostic_text :: proc(diagnostic: Diagnostic, allocator := context.allocator) -> string {
	out := strings.builder_make(0, len(diagnostic.message) + 32, allocator)
	if diagnostic.file != "" {
		fmt.sbprintf(&out, "%v:", diagnostic.file)
	}
	if diagnostic.line > 0 {
		fmt.sbprintf(&out, "%v:", diagnostic.line)
		if diagnostic.col > 0 {
			fmt.sbprintf(&out, "%v:", diagnostic.col)
		}
	}
	if strings.builder_len(out) > 0 {
		strings.write_byte(&out, ' ')
	}
	if diagnostic.severity == .Warning {
		strings.write_string(&out, "warning: ")
	}
	strings.write_string(&out, diagnostic.message)
	return strings.to_string(out)
}

/*
Record a problem with no position - the fallback, for something the parse cannot place.

Kept because it is honest: a diagnostic raised about text that was BUILT rather than sliced out of
the buffer has no line to point at, and inventing one would put a squiggle under innocent code.
*/
@(private)
diagnose :: proc(state: ^Parse_State, format: string, args: ..any) {
	append(
		&state.diagnostics,
		Diagnostic{message = fmt.aprintf(format, ..args, allocator = state.allocator), severity = .Error},
	)
}

// Record a problem at a span. `at` may be a zero value, which reads as "position not known".
@(private)
diagnose_at :: proc(state: ^Parse_State, at: Source_Span, severity: Severity, format: string, args: ..any) {
	append(
		&state.diagnostics,
		Diagnostic{message = fmt.aprintf(format, ..args, allocator = state.allocator), severity = severity, at = at},
	)
}

// Which source line one line of the working text came from.
@(private)
Line_Origin :: struct {
	file: string,
	line: int,
}

/*
A builder that records where every line it writes came from.

The text passes assemble their output from whole-line pieces, and each piece's origin is known at the
moment it is written - the source's own lines for the text that passes through, the included file's
lines for what an `#INCLUDE` brought in. Recording it here, as the bytes go by, is what keeps the
passes themselves byte-identical: an after-the-fact alignment of two texts that have gained and lost
lines is guesswork, and the parity harness would be the thing that noticed.

`open` is "a line has been started and not yet terminated", which is what gives an empty line - a
`\n` written when nothing is open - an origin of its own.
*/
@(private)
Mapped_Builder :: struct {
	out:     strings.Builder,
	origins: [dynamic]Line_Origin,
	open:    bool,
}

@(private)
mapped_builder_make :: proc(capacity: int, allocator := context.allocator) -> Mapped_Builder {
	return Mapped_Builder {
		out = strings.builder_make(0, capacity, allocator),
		origins = make([dynamic]Line_Origin, 0, 64, allocator),
	}
}

// Write text whose first line came from `file` line `start_line`, each newline advancing one line.
@(private)
mb_write :: proc(mb: ^Mapped_Builder, text: string, file: string, start_line: int) {
	line := start_line
	for i in 0 ..< len(text) {
		if !mb.open {
			append(&mb.origins, Line_Origin{file = file, line = line})
			mb.open = true
		}
		if text[i] == '\n' {
			mb.open = false
			line += 1
		}
	}
	strings.write_string(&mb.out, text)
}

// Write text that is passing through unchanged, carrying the origins it already had.
@(private)
mb_write_mapped :: proc(mb: ^Mapped_Builder, text: string, origins: []Line_Origin) {
	next := 0
	for i in 0 ..< len(text) {
		if !mb.open {
			append(&mb.origins, next < len(origins) ? origins[next] : Line_Origin{})
			next += 1
			mb.open = true
		}
		if text[i] == '\n' {
			mb.open = false
		}
	}
	strings.write_string(&mb.out, text)
}

// The origin of every line of `text`, read as the buffer itself: line 1, 2, 3 and so on.
@(private)
origins_of_own_lines :: proc(text: string, allocator := context.allocator) -> [dynamic]Line_Origin {
	origins := make([dynamic]Line_Origin, 0, 64, allocator)
	line := 1
	open := false
	for i in 0 ..< len(text) {
		if !open {
			append(&origins, Line_Origin{line = line})
			open = true
		}
		if text[i] == '\n' {
			open = false
			line += 1
		}
	}
	return origins
}

// Byte offset of each line of the working text, so an offset can be turned into a line and column.
@(private)
line_starts_of :: proc(text: string, allocator := context.allocator) -> [dynamic]int {
	starts := make([dynamic]int, 0, 64, allocator)
	open := false
	for i in 0 ..< len(text) {
		if !open {
			append(&starts, i)
			open = true
		}
		if text[i] == '\n' {
			open = false
		}
	}
	return starts
}

/*
An offset into the WORKING text as a span in the source.

`length` is clamped to the line: a squiggle is a per-line thing in every editor, and a multi-line
underline is not worth the API.
*/
@(private)
span_at_offset :: proc(state: ^Parse_State, offset: int, length := 0) -> Source_Span {
	if offset < 0 || len(state.line_starts) == 0 {
		return {}
	}
	// The last line whose start is at or before `offset`.
	low, high := 0, len(state.line_starts) - 1
	for low < high {
		mid := (low + high + 1) / 2
		if state.line_starts[mid] <= offset {
			low = mid
		} else {
			high = mid - 1
		}
	}
	index := low
	if index >= len(state.origins) {
		return {}
	}
	origin := state.origins[index]
	line_end := index + 1 < len(state.line_starts) ? state.line_starts[index + 1] - 1 : len(state.text)
	span := Source_Span {
		file = origin.file,
		line = origin.line,
		col  = offset - state.line_starts[index] + 1,
	}
	if length > 0 {
		span.length = min(length, max(line_end - offset, 0))
	}
	return span
}

/*
Where a string that came out of the working text sits in it.

Slices are what the parse passes around - a block is a subslice of the working text, and a row is a
subslice of the block - so the position of anything the classifier is holding is a pointer
subtraction away. A string that was BUILT instead (a paste's output, a cloned paragraph) is not in
there, and this says so rather than inventing a line: `ok = false` becomes a diagnostic with no
position, which every consumer already has to handle.
*/
@(private)
working_offset :: proc(state: ^Parse_State, piece: string) -> (offset: int, ok: bool) {
	if len(state.text) == 0 || len(piece) == 0 {
		return 0, false
	}
	base := uintptr(raw_data(state.text))
	at := uintptr(raw_data(piece))
	if at < base || at + uintptr(len(piece)) > base + uintptr(len(state.text)) {
		return 0, false
	}
	return int(at - base), true
}

// The span of `piece` (a slice of the working text), offset into it by `within` bytes.
@(private)
span_of :: proc(state: ^Parse_State, piece: string, within := 0, length := -1) -> Source_Span {
	offset, ok := working_offset(state, piece)
	if !ok {
		return {}
	}
	underline := length >= 0 ? length : len(piece) - within
	return span_at_offset(state, offset + within, underline)
}

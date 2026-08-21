package bml

import "core:strconv"
import "core:strings"

/*
A minimal element tree with python's `xml.etree.ElementTree` semantics.

This exists to be BYTE-COMPATIBLE with `ET.tostring`, because the reference renderer builds an
ElementTree and the goldens are its output. Two of its habits are load-bearing and would never be
chosen fresh:

  - TEXT AND TAIL. An element carries `text` (before its first child) and each child carries `tail`
    (the text after it). That is how mixed content - a bid `<div>` followed by loose description
    text inside the same `<li>` - is represented.
  - `tostring` with no encoding argument serialises as US-ASCII, so every non-ascii character comes
    out as a DECIMAL CHARACTER REFERENCE. The suit glyphs in the published pages are `&#9827;` and
    friends, not utf-8 bytes.
*/
@(private)
Element :: struct {
	tag:      string,
	attribs:  [dynamic]Attribute,
	text:     string,
	children: [dynamic]^Element,
	tail:     string,
}

@(private)
Attribute :: struct {
	name:  string,
	value: string,
}

@(private)
element_make :: proc(tag: string, allocator := context.allocator) -> ^Element {
	el := new(Element, allocator)
	el^ = Element {
		tag      = tag,
		attribs  = make([dynamic]Attribute, allocator),
		children = make([dynamic]^Element, allocator),
	}
	return el
}

@(private)
sub_element :: proc(parent: ^Element, tag: string, allocator := context.allocator) -> ^Element {
	child := element_make(tag, allocator)
	append(&parent.children, child)
	return child
}

@(private)
set_attrib :: proc(el: ^Element, name, value: string) {
	append(&el.attribs, Attribute{name = name, value = value})
}

/*
Append text or an element to a parent, following the text/tail model.

Text before any child lands on the parent's `text`; text after a child lands on that child's `tail`.
Getting this wrong is invisible in the tree and obvious in the output.
*/
@(private)
attach_text :: proc(parent: ^Element, text: string, allocator := context.allocator) {
	if text == "" {
		return
	}
	if len(parent.children) == 0 {
		parent.text = concat_if(parent.text, text, allocator)
	} else {
		last := parent.children[len(parent.children) - 1]
		last.tail = concat_if(last.tail, text, allocator)
	}
}

@(private = "file")
concat_if :: proc(existing, addition: string, allocator := context.allocator) -> string {
	if existing == "" {
		return addition
	}
	return strings.concatenate({existing, addition}, allocator)
}

// Serialise a tree the way `ET.tostring` does. See `write_escaped` for the encoding rules.
@(private)
serialise :: proc(root: ^Element, allocator := context.allocator) -> string {
	out := strings.builder_make(0, 64 * 1024, allocator)
	write_element(&out, root)
	return strings.to_string(out)
}

/*
One element: its tag, its attributes in INSERTION ORDER, then text, children and closing tag.

The tail is written after the closing tag because it belongs to the parent's content, not to this
element - that is the ElementTree model, and it is what makes mixed content round-trip.
*/
@(private = "file")
write_element :: proc(out: ^strings.Builder, el: ^Element) {
	strings.write_byte(out, '<')
	strings.write_string(out, el.tag)
	for attrib in el.attribs {
		strings.write_byte(out, ' ')
		strings.write_string(out, attrib.name)
		strings.write_string(out, `="`)
		write_escaped(out, attrib.value, in_attribute = true)
		strings.write_byte(out, '"')
	}
	// An element with neither text nor children closes itself, and ElementTree puts a space before
	// the slash.
	if el.text == "" && len(el.children) == 0 {
		strings.write_string(out, " />")
	} else {
		strings.write_byte(out, '>')
		write_escaped(out, el.text, in_attribute = false)
		for child in el.children {
			write_element(out, child)
		}
		strings.write_string(out, "</")
		strings.write_string(out, el.tag)
		strings.write_byte(out, '>')
	}
	write_escaped(out, el.tail, in_attribute = false)
}

/*
Escape as ElementTree does.

Character data escapes `&`, `<` and `>`. An attribute value escapes those plus `"` and turns the
whitespace controls into numeric references. Everything outside ascii becomes a decimal character
reference in both, which is the us-ascii serialisation the reference produces.
*/
@(private = "file")
write_escaped :: proc(out: ^strings.Builder, text: string, in_attribute: bool) {
	for r in text {
		switch r {
		case '&':
			strings.write_string(out, "&amp;")
		case '<':
			strings.write_string(out, "&lt;")
		case '>':
			strings.write_string(out, "&gt;")
		case '"':
			if in_attribute {
				strings.write_string(out, "&quot;")
			} else {
				strings.write_byte(out, '"')
			}
		case '\r':
			if in_attribute {
				strings.write_string(out, "&#13;")
			} else {
				strings.write_byte(out, '\r')
			}
		case '\n':
			if in_attribute {
				strings.write_string(out, "&#10;")
			} else {
				strings.write_byte(out, '\n')
			}
		case '\t':
			if in_attribute {
				strings.write_string(out, "&#09;")
			} else {
				strings.write_byte(out, '\t')
			}
		case:
			if r < 0x80 {
				strings.write_byte(out, byte(r))
			} else {
				write_charref(out, r)
			}
		}
	}
}

@(private = "file")
write_charref :: proc(out: ^strings.Builder, r: rune) {
	buf: [8]byte
	strings.write_string(out, "&#")
	strings.write_string(out, strconv.write_int(buf[:], i64(r), 10))
	strings.write_byte(out, ';')
}

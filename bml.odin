/*
An Odin port of BML (Bridge Markup Language) - the `.bml` notation used for contract bridge bidding
system notes, and its rendering to html.

The reference implementation is the python in `enerqi/bml` (a fork of `Kungsgeten/bml`), and it stays
the reference: the goldens in that repository's `tests/` are what this package is checked against, and
the intent is byte-identical html for the whole corpus.

Two things drove the port, and they shape the API:

  - A LIVE PREVIEW parses the buffer someone is still typing, so the entry point takes SOURCE TEXT,
    not a path. The python's `content_from_file` cannot serve that at all.
  - Parsing must hold NO GLOBAL STATE. The python module accumulates `content`, `clipboard`,
    `vulnerability`, `seat` and `meta` at module scope, which is why converting several documents
    needs one process each. Here every parse gets its own `Document`.

Not ported, and no plan to: the LaTeX (`bml2latex.py`) and BSS (`bml2bss.py`) back ends. Html is what
this project renders. Adding one back would be a new file beside `html.odin` and no change to the
parser.
*/
package bml

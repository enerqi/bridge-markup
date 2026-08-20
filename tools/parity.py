#!/usr/bin/env python
"""Byte-compare this library's html against the python reference, over a whole corpus.

    just parity                  # every .bml in BRIDGE_DIR
    just parity nt-bidding.bml   # just these

The reference is `enerqi/bml` (BML_TOOLS_DIRECTORY, else ~/dev/bml) and the corpus is the bridge
bidding system notes (BRIDGE_DIR). Both are outside this repository, so a missing one is reported
as "skipped" rather than as a failure - the unit tests are what run everywhere.

Each file is rendered by a FRESH python process, because the reference module accumulates state at
module scope and cannot convert two documents in one process. Both sides run with the working
directory set to the corpus, since `#INCLUDE` resolves relative to it.
"""

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOME = os.path.expanduser("~")

BRIDGE = os.environ.get("BRIDGE_DIR", os.path.join(HOME, "docs", "bridge", "bridge-bidding-system"))
BML_TOOLS = os.environ.get("BML_TOOLS_DIRECTORY", os.path.join(HOME, "dev", "bml"))
RENDER = os.path.join(HERE, "target", "render.exe" if os.name == "nt" else "render")

CONTEXT = 60


def reference_html(path):
    code = (
        "import sys; sys.path.insert(0, r'%s')\n"
        "import bml, bml2html\n"
        "content = bml.content_from_file(r'%s')\n"
        "sys.stdout.buffer.write(bml2html.to_html(content).encode('utf-8'))\n"
    ) % (BML_TOOLS, path)
    done = subprocess.run([sys.executable, "-c", code], cwd=BRIDGE, capture_output=True)
    if done.returncode != 0:
        return None, done.stderr.decode("utf-8", "replace")
    return done.stdout, None


def library_html(path):
    done = subprocess.run([RENDER, path], cwd=BRIDGE, capture_output=True)
    if done.returncode != 0:
        return None, done.stderr.decode("utf-8", "replace")
    return done.stdout, None


def first_difference(want, got):
    for i in range(min(len(want), len(got))):
        if want[i] != got[i]:
            break
    else:
        i = min(len(want), len(got))
    start = max(0, i - CONTEXT)
    show = lambda b: b[start : i + CONTEXT].decode("utf-8", "replace").replace("\n", "\\n")
    return i, show(want), show(got)


def main(argv):
    for label, path in (("corpus", BRIDGE), ("reference", BML_TOOLS)):
        if not os.path.isdir(path):
            print("skipped: no %s at %s" % (label, path))
            return 0
    if not os.path.exists(RENDER):
        print("build the renderer first:  odin build examples/render.odin -file -o:speed -out:%s" % RENDER)
        return 1

    names = argv[1:] or sorted(f for f in os.listdir(BRIDGE) if f.endswith(".bml"))
    identical, different, failed = [], [], []

    for name in names:
        path = os.path.join(BRIDGE, name)
        want, why = reference_html(path)
        if want is None:
            failed.append((name, "reference: " + why.strip().splitlines()[-1]))
            continue
        got, why = library_html(path)
        if got is None:
            failed.append((name, "library: " + why.strip()))
            continue
        (identical if got == want else different).append(
            name if got == want else (name, len(want), len(got), first_difference(want, got))
        )

    print("IDENTICAL %d/%d" % (len(identical), len(names)))
    for name in identical:
        print("   ok   ", name)
    for name, want_len, got_len, (at, want_ctx, got_ctx) in different:
        print("   DIFF  %s  reference %d bytes, library %d bytes, first differ at %d" % (name, want_len, got_len, at))
        print("      reference: ...%s..." % want_ctx)
        print("      library  : ...%s..." % got_ctx)
    for name, why in failed:
        print("   FAIL  ", name, why)
    return 1 if different or failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

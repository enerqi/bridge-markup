# `cmd.exe` starts in ~9ms and always available. just launches a shell per recipe line.
#  - alternatives: `nu -c` ~41ms, `powershell -NoLogo -NoProfile -Command` ~143ms
#  - cost: it is a poor language for a multi-line recipe, hence uv -> python preferred for more complex tasks
[windows]
set shell := ["cmd.exe", "/c"]
[unix]
set shell := ["bash", "-c"]
set minimum-version := "1.49.0"  # user-defined functions (1.49). Keep the README and `odin-skel doctor` in step.
set unstable  # user-defined functions, [script]
set lazy
# `python` alone is not a reliable cross-platform lookup (cf. python/python3/python3.x)
# uv resolves/downloads on every platform and --no-project means no looking for pyproject.toml / local .venv
# just recipes opt in with the bare `[script]` attribute (no interpreter argument)
set script-interpreter := ["uv", "run", "--no-project", "-p", "3.14", "python"]

import '.just/toolchain.just'
import '.just/editor.just'
# Optional features add their recipes by shipping a `.just` file, not by editing this one, which lets
# `odin-skel add bench` be a plain copy and `rm -rf bench/` the uninstall.
import? 'bench/bench.just'

test_main_name := "test-main.exe"

# `join`, not the `/` operator: `/` always emits a forward slash, and cmd.exe rejects a forward-slash
# path in *command* position ("'target' is not recognized") even quoted.
target_path(dir, name) := join("target", dir, name)

# Which linker Odin hands the object files to: `default` (Odin picks - MSVC `link.exe` on Windows),
# `lld`, `radlink` (Windows only, bundled with Odin, hence the Windows default here) or `mold` (Linux
# only, not bundled). Odin has no build cache and relinks on every build, so this is a per-iteration cost.
# An env var rather than a recipe argument because `odin` errors on a repeated flag, so a `-linker:` in a
# recipe's `*args` would collide:  ODIN_LINKER=lld just test -lto:thin   (-lto needs lld on Windows).
# Which value to pick, and the lld-on-macOS and incremental-linking caveats: README, "Choosing a linker".
linker := env_var_or_default("ODIN_LINKER", if os() == "windows" { "radlink" } else { "default" })


# ============================================================= qa =========

# `{{odinfmt_bin}}`, never a bare `odinfmt` - pins the binary (see .just/toolchain.just) for consistency.
# ---
# odinfmt every odin file under this directory or subdirectories
[group('qa')]
format: ensure-odinfmt
	"{{odinfmt_bin}}" -w .

# `-vet-tabs` is the only compiler-side enforcement of .editorconfig's `indent_style = tab`; not implied
# by `-strict-style`. Nothing in the Odin toolchain checks line endings - .gitattributes and odinfmt.json
# hold those. Accepts extra args like `-show-timings`.
# ---
# lint checks for style and potential bugs. No code generation
[group('qa')]
lint *args:
	odin check . -vet -vet-cast -strict-style -vet-tabs -no-entry-point {{args}}

# What `just run` is to a program: the fast "does it still compile" loop. Deliberately without the vet and
# style flags `lint` carries - those are worth a separate, slower pass rather than noise between an edit
# and knowing whether it type checks. `odin check .` covers the root package, which for a single-package
# library is all of it; once there are subpackages, an aggregator example sweeps them (see the README).
# ---
# type check the library
[group('qa')]
check *args:
	odin check . -no-entry-point {{args}}


# =================================================== housekeeping =========

# Every recipe that produces a binary depends on this. Odin does not create the out directory.
# ---
# ensure the build artifacts top level directory exists
[group('housekeeping')]
[unix]
@mktarget_dirs:
	mkdir -p target/debug target/fast_debug target/release_debug target/release target/release_nochecks

# `if not exist` rather than swallowing md's "already exists" with `2>nul`, so a genuine failure still
# sets a non-zero exit. The loop var is a single `%d`, NOT the `%%d` that a .bat file would use.
# ---
# ensure the build artifacts top level directory exists
[group('housekeeping')]
[windows]
@mktarget_dirs:
	for %d in (debug fast_debug release_debug release release_nochecks) do @if not exist target\%d md target\%d || exit /b 1

# simple delete of all debug databases and executables in the target directory
[group('housekeeping')]
[unix]
clean:
	rm -rf target
	just mktarget_dirs

# simple delete of all debug databases and executables in the target directory
[group('housekeeping')]
[windows]
clean:
	if exist target rmdir /s /q target
	just mktarget_dirs


# =========================================================== docs =========
#
# There is no binary of this project to run, so the inner loop is a type check plus the tests, and the
# examples are what prove the package is usable from outside it.

# `-file` is not optional here: without it odin reads examples/ as one package and the several `main`
# procedures in it collide. It is also what makes the examples' `".."` import resolve to this directory.
# Usage:  just example basic
# ---
# build and run one example from examples/
[group('docs')]
example name *args: mktarget_dirs
	odin run examples/{{name}}.odin -file -debug -microarch:native -linker:{{linker}} -out:{{ target_path("debug", f"example-{{name}}.exe") }} {{args}}

# An example is documentation, and documentation stops being true the moment the API moves under it. This
# is the cheap guard against that. A `[script]` because just has no loop and cmd.exe is a poor place for one.
# ---
# type check every example in examples/
[group('docs')]
[script]
examples:
	import glob, subprocess, sys

	files = sorted(glob.glob("examples/*.odin"))
	if not files:
		sys.exit("no examples found in examples/")

	for path in files:
		# flush=True because python fully buffers stdout when it is a pipe (CI logs, `just examples > f`),
		# which would land these lines after the compiler's stderr and lose which example broke.
		print("checking " + path, flush=True)
		# `-no-entry-point` so an aggregator example works: a `package all` file of `@(require) import ".."`
		# lines has no `main`, and is how a library with subpackages type checks its whole tree (README).
		result = subprocess.run(
			["odin", "check", path, "-file", "-no-entry-point", "-vet", "-vet-cast", "-strict-style", "-vet-tabs"]
		)
		if result.returncode != 0:
			sys.exit(result.returncode)
	print("checked " + str(len(files)) + " example(s)")

# Writes to stdout; redirect it to keep a copy. Deliberately NOT `-all-packages`, which documents every
# package the project *uses* - all of `core:` included - rather than this one.
# ---
# print the library's documentation
[group('docs')]
doc *args:
	odin doc . {{args}}


# =========================================================== test =========

# run all tests
[group('test')]
test *args: mktarget_dirs
	odin test . -debug -file -microarch:native -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# Filtering is a `core:testing` define, not a compiler flag - there is no `-test-name:`, and a stale
# spelling of one fails with `Unknown flag: 'test-name'` before anything builds. NAME takes a
# comma-separated list and the package prefix is optional, so `pkg.my_test`, `my_test` and `one,two` all
# work:  just test1 my_test
# ---
# run one named test (comma-separated for several)
[group('test')]
test1 name *args: mktarget_dirs
	odin test . -debug -file -microarch:native -define:ODIN_TEST_NAMES={{name}} -linker:{{linker}} -out:{{ target_path("debug", test_main_name) }} {{args}}

# The unit tests pin behaviour; THIS pins fidelity. It renders every `.bml` of the bridge corpus with both
# this library and the python reference it was ported from, and compares the bytes. It needs two checkouts
# that live outside this repository - the corpus (BRIDGE_DIR) and the reference (BML_TOOLS_DIRECTORY) -
# and reports "skipped" rather than failing when they are absent.
# ---
# byte-compare the rendered html against the python reference over the whole corpus
[group('test')]
parity *files: (_build_render)
	uv run --no-project -p 3.14 python tools/parity.py {{files}}

# the renderer used by `parity`, built optimised because it runs once per corpus file
[group('test')]
[private]
_build_render: mktarget_dirs
	odin build examples/render.odin -file -o:speed -out:{{ target_path(".", "render.exe") }}

# KIND is `address` (default, ASan), `memory` or `thread`; only `address` is widely supported. ON WINDOWS
# `address` CATCHES STACK ERRORS BUT NOT HEAP ERRORS - Odin allocates through `HeapAlloc`, which ASan does
# not intercept, so a clean run there says nothing about your heap. (Probed a 16-byte allocation at +16,
# +24, +32, +64, +256: Linux reports `heap-buffer-overflow` from +24 on, Windows at none.) The rest, and
# the Linux `libclang_rt.asan.a` install: README, "Tasks".
#
# Deliberately omits `-linker:{{linker}}` - do not "fix" the inconsistency. A sanitizer has to interpose
# on the runtime and not every linker cooperates: `radlink` (this file's Windows default, and bundled with
# Odin, so it is what you get by accident) links an ASan binary that dies on startup with a bare
# `0xc000001d` illegal-instruction exception and no usable stack, while `-linker:default` runs it. Link
# speed is worth nothing on a diagnostic run anyway.
# Usage:  just test_sanitize   or   just test_sanitize thread
# ---
# run the tests under a sanitizer (address | memory | thread)
[group('test')]
test_sanitize kind="address" *args: mktarget_dirs
	odin test . -debug -file -sanitize:{{kind}} -out:{{ target_path("debug", f"sanitize-{{kind}}-{{test_main_name}}") }} {{args}}

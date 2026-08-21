# bridge-markup

An Odin implementation of **BML** (Bridge Markup Language) — the `.bml` notation used for contract
bridge bidding system notes — and its rendering to html.

```odin
import bml "markup:."

doc := bml.parse(source, {resolve_include = read_include})
defer bml.destroy(doc)

html := bml.render_html(doc)
```

[`ARCHITECTURE.md`](ARCHITECTURE.md) is the implementation guide: the pipeline, why the block
classifier's test order is load-bearing, the memory model, everything reproduced bug-for-bug on
purpose, and how to debug a parity failure. Read `~/dev/bml/ARCHITECTURE.md` alongside it for how
BML parsing works in the first place — that is the reference's document and is not repeated here.

## Why this exists

It is a port of the python in [`enerqi/bml`](https://github.com/enerqi/bml) (a fork of
`Kungsgeten/bml`), which stays the reference implementation. Two things the reference cannot do
drove the port:

- **It renders a file, not a buffer.** `content_from_file` takes a path, so a live preview of text
  someone is still typing has nothing to hand it. `parse` here takes SOURCE TEXT.
- **It keeps its state in module globals.** `content`, `clipboard`, `vulnerability`, `seat` and
  `meta` all live at module scope, so converting several documents means one process each — which
  is exactly what the notes build does. Here a parse owns its state and two parses cannot see each
  other.

Speed came along with it. Rendering one chapter, in-process: **1.9 ms** against the reference's
29 ms plus interpreter startup plus a process spawn. The whole 1.2 MB system with all its includes:
**17.6 ms** against 262 ms.

## Fidelity

The goal is BYTE-IDENTICAL html, and `just parity` is what holds it to that: it renders every file
of the bridge corpus with both implementations and compares the bytes.

```
IDENTICAL 19/19
```

That is why several things here look odd and are commented as deliberate:

- `**bold**` renders as `<strong><strong>bold</strong></strong>`. The reference's content pattern
  ends with `\S`, which matches an asterisk, so the outer match swallows `*bold*` and the recursive
  fill finds emphasis a second time.
- A list item keeps the newline that ended it, so `<li>` closes on the next line.
- The `<title>` is emitted at the END of `<head>`, because the reference appends it after building
  the whole body.
- Output is US-ASCII with decimal character references — the suit glyphs are `&#9827;` and friends,
  not utf-8 bytes — because `ET.tostring` with no encoding argument serialises that way.

`just parity` needs two checkouts that live outside this repository: the corpus (`BRIDGE_DIR`) and
the reference (`BML_TOOLS_DIRECTORY`). It reports "skipped" when they are absent, so it is safe to
run anywhere. The unit tests (`just test`) have no such dependency and cover what the corpus cannot
reach — the `#CUT`/`#COPY`/`#PASTE`/`#HIDE` directives appear nowhere in it, so their expected
values were captured by running the reference on those exact inputs.

## Not ported

The LaTeX (`bml2latex.py`) and BSS (`bml2bss.py`) back ends. Html is what this project renders.
Either would be a new file beside `html.odin` and no change to the parser.

## No regular expressions

The reference is built on them, and this is not, for one blocking reason: it relies on LOOKAROUND in
eight places, and neither `core:text/regex` nor rure (Rust's regex, via bindings) supports it —
linear-time automata engines give it up by construction. Since those patterns need rewriting either
way, a regex engine buys no fidelity, and hand-written scanners keep the library dependency-free and
single-pass. The reference makes ~30 regex passes over the text; this makes one.



## Odin Programming Language Project Skeleton

A minimal project skeleton for the [Odin programming language](http://odin-lang.org/)


**A library project** is an Odin source package with nothing to build, so nothing is output under `target`. See
[Library layout](#library-layout).

- [Library layout](#library-layout) — why the repository root is the package, and the constraints that follow from it
- [Tasks](#tasks) — every `just` recipe, grouped by what you are trying to do
- [Pinned tooling](#pinned-tooling) — why `odinfmt` and `ols` are fetched by version rather than taken from `PATH`
- [Some recipes need uv](#some-recipes-need-uv) — why a few recipe bodies are Python, and the one tool that needs installing
- [Choosing a linker](#choosing-a-linker) — four values, what each costs, and when the default is the wrong one
- [Timing a recipe](#timing-a-recipe) — `just --time`, and hyperfine when it is the program you want timed
- [Benchmarking](#benchmarking) — the opt-in `bench/` harness, and where its documentation lives
- [Sublime Text editor specific files](#sublime-text-editor-specific-files) — build systems and snippets, installed once for every project
- [Language Server Configuration](#language-server-configuration) — `ols.json`, resolving imports from outside the project, and what OLS treats as the project root




### Library layout

A library is laid out differently from the executable skeleton: there is no `main`, nothing lands in `target/`, and
**the repository root is the package.** That is the layout the surrounding Odin ecosystem uses — a consumer clones or copies the library
directory into their own tree, frequently renaming it on the way, and imports it by path:

```
git clone <the library repo> libs/toml     # the directory name they pick becomes the import path
```

```odin
import "libs/toml"                  # or through a collection: -collection:libs=libs, then import "libs:toml"
```

```
.
├── <pkg>.odin           <- the package; add more files beside it
├── <pkg>_test.odin
├── examples/
│   └── basic.odin       <- package main, built with -file
└── justfile  .just/  README.md  ...
```

**The package name must be a valid Odin identifier**, which a repository name often is not: `odin-toml` is a fine
directory name and an illegal `package` clause. `odin-skel new --lib` derives one by turning `-`, `.` and spaces into
underscores, or takes `--pkg=NAME` if you would rather choose.

**Examples are single-file `main` packages**, built with `-file` so several can share `examples/` without their
`main` procedures colliding. In `-file` mode a relative import resolves against the file's own directory, so an
example imports `".."` — one level, not two. Get it wrong and Odin reports
`Syntax Error: Empty directory that contains no .odin files: ../..`, which names the path but not the reason.
`just examples` type checks all of them, which is what stops an API change from quietly invalidating the docs.

**Tests live in the package**, as `<pkg>_test.odin` beside the source, so they can reach `@(private)` symbols. The
cost is that a consumer building the package also builds `import "core:testing"`, and optimization does not remove
it: the `@(test)` bodies are eliminated, but `core:testing`'s transitive `@(init)`/`@(fini)` procedures are entry
points and stay live. Measured on `-o:speed`, that is up to ~8.6 KB against a consumer importing nothing else from
`core`, and ~80 bytes against one already using `core:log` — nearly all of the cost is overlap with packages a real
program links anyway. If it matters (a freestanding or WASM consumer, say), move the tests into a `tests/` package
that imports this one, the way Odin's own `core` does.

**Growing past one package**: add subdirectories, each its own package, and keep the root package as the entry
point. `odin check .` only ever covers the root package and there is no whole-tree `check`, so once there are
subpackages, add an aggregator example that names them all:

```odin
package all

@(require) import lib ".."
@(require) import "../sub"
```

`just examples` then type checks the whole tree through it. Two things are load-bearing here:

* `@(require)` — without it an unreferenced import is dropped and the check passes vacuously
* the explicit `lib` name on the `".."` import. Odin derives an import's name from its directory, and a
  repository directory is often not a valid identifier: from a checkout named `odin-toml` a bare
  `import ".."` fails with `Import name 'odin-toml' is not a valid identifier`. The same applies to the
  examples themselves, which is why `basic.odin` imports `lib ".."`

**Tag your releases.** Odin has no package manager, so a consumer pins you by git tag or by whatever
revision they happened to copy. A tag is the only thing that lets them say which version they have, and
the only way you can change an API without breaking whoever vendored you last month. Nothing here
automates that — a `CHANGELOG.md` and a tagging habit are yours to add if you want them.

### Tasks

A `justfile` is part of this opinionated setup and you may need to edit the tasks as new packages are added in
sub-directories. [Just >=1.49](https://just.systems/) is a CLI task runner that you *need to install*. Run any task
with `just TASK`:


**Build & check** — a library has no binary of its own, so there is no build ladder. The inner loop is a type check,
and the examples are what prove the package is usable from outside it:

* `just check` — type check the library. The fast "does it still compile" pass, without the vet and style flags
  `just lint` carries
* `just example NAME` — build and run `examples/NAME.odin`
* `just examples` — type check every example, so an API change cannot quietly invalidate the documentation
* `just doc` — print the package documentation (`odin doc .`)

**Benchmarks** — present only once `bench/` is, which it is not by default. See
[Benchmarking](#benchmarking):

* `just bench [NAME] [--samples=N …]` — build and run the benchmarks; `NAME` filters by substring
* `just bench_build` / `just rerun_bench` — build without running / run without rebuilding
* `just bench_lint` — type check and vet `bench/`, which the root `lint` does not reach
* `just bench_save` / `just bench_cmp` — record a timing baseline / re-run and diff against it
* `just bench_count` / `just bench_count_check` — the same for *instruction counts* under callgrind,
  which do not drift between runs and can therefore gate a merge (needs valgrind)

**Quality:**

* `just lint` — type checking, vet warnings, strict style. No code generation
* `just format` — runs the pinned `odinfmt -w .` over the whole tree, fetching it first if needed
* `just fetch-ols` — install the pinned `ols` + `odinfmt` into `~/.odin-tools` (`--check` / `--force`)
* `just bump-ols [TAG]` — rewrite the pin in `.just/toolchain.just` to the latest (or named) ols release (`--check`)
* `just test` / `just test1 NAME` — run all tests / one named test
* `just test_sanitize [KIND]` — run the tests under a sanitizer. `KIND` is
  `address` (default), `memory` or `thread`. Only `address` is widely supported; `memory` and `thread` need a
  clang-ish toolchain and are unavailable on some platforms (notably Windows/MSVC).

  **On Windows, `address` catches stack errors but not heap errors** — a clean run there does not mean your
  heap is clean. Odin allocates through `HeapAlloc` rather than `malloc` on Windows, and ASan's redzones come
  from intercepting the allocator, so it never sees the allocation. Verified by overflowing a 16-byte
  allocation at +24, +32, +64 and +256 bytes: Linux reports `heap-buffer-overflow` at every one, Windows at
  none. The `interception_win: unhandled instruction` line these builds print is that limitation, not a fault
  in your code. Chase a suspected heap bug on Linux, or with a tracking allocator, which does not rely on ASan.

  On Linux the sanitizer runtime is a separate install — without it the link fails on a missing
  `libclang_rt.asan.a`. On Debian/Ubuntu with clang 21 that is `libclang-rt-21-dev`.

**Housekeeping:**

* `just clean` — wipe the `target` directory
* `just mktarget_dirs` — create the `target` directory tree (auto-called by every task that builds)

**Editor setup** (these three run on Python via [uv](https://docs.astral.sh/uv/) — see
[Some recipes need uv](#some-recipes-need-uv)):

* `just ols-config NAME=PATH...` — (re)generate the `ols.json` collection list (see [Language Server Configuration](#language-server-configuration))
* `just install-sublime` — install the snippets + build systems into Sublime Text's global config (see the Sublime section)
* `just sublime-build-init` — add a project-local build-system stub to the `.sublime-project` (see the Sublime section)
* `just sublime-lsp-init` — point the project's Sublime LSP client at the pinned `ols` (see [Pinned tooling](#pinned-tooling))


Notes:

- **Library:** `check`, `test*`, `example` and `doc` accept optional extra variadic arguments; add `--` before
  passing arguments to an example's own `main`. Edit the `test_main_name` output executable name as needed.
- `format` does **not** use an `odinfmt` on your `PATH` — it fetches a pinned one and runs that. See
  [Pinned tooling](#pinned-tooling).
- Recipes run under `bash` everywhere except Windows, where they run under `cmd.exe /c`. just launches a shell per
  recipe *line*, so shell startup is a fixed tax on every build, and cmd is the cheapest thing that is on every
  Windows: ~9ms to start, against ~143ms for `powershell -NoLogo -NoProfile -Command` (which it replaced) and ~41ms
  for `nu -c`. It also has no profile to make a recipe unreproducible. The cost is that cmd is a poor language for
  anything with logic — which does not bite here, because every Windows recipe body is a single command and
  everything else uses `[script]` (see [Some recipes need uv](#some-recipes-need-uv)). See
  [configuring the just shell](https://just.systems/man/en/chapter_63.html?highlight=set%20shell#configuring-the-shell)
  to change it.
- The two recipes that cannot be written once for both shells — `mktarget_dirs` and `clean` — are split with just's
  `[unix]` / `[windows]` attributes. cmd spells `rm -rf target` as `if exist target rmdir /s /q target`, and has no
  `mkdir -p`, so the directories are created with `for %d in (...) do @if not exist target\%d md target\%d`.
  Everything else is shell-agnostic: the recipes invoke `odin`, `just` and `odinfmt` directly rather than leaning on
  shell builtins.


### Pinned tooling

`odinfmt` is not interchangeable across versions. It ships inside an [ols](https://github.com/DanielGavin/ols)
release, has **no `--version` flag**, and two releases format the same source differently. So a copy on `PATH` tells
you nothing about which one it is, and the failure mode is a developer running `just format`, getting a clean local
tree, and failing a CI diff on files they never touched.

`.just/toolchain.just` therefore pins the ols release and formats with that copy:

```
ols_tag    := "dev-2026-06"
ols_plat   := ...    # the release asset for this OS/arch
ols_sha256 := ...    # that asset's published digest, per platform
```

`just fetch-ols` downloads `ols-<platform>.zip`, checks it against `ols_sha256` **before** extracting anything, and
installs all three things the archive holds:

```
~/.odin-tools/ols/dev-2026-06/
    ols(.exe)         the language server
    odinfmt(.exe)     the formatter `just format` runs
    builtin/          the package ols resolves beside its own executable, and errors without
```

The tag is *in the path*, so the file being there is the pin being satisfied — there is no state where the right
path holds the wrong binary, which a single unversioned `~/.odin-tools/odinfmt` would reintroduce the first time the
pin moved. Several tags coexist, so switching branches switches formatter with no re-download. The root is
`$ODIN_TOOLS` if set, else `~/.odin-tools` — outside the repository, because one copy serves every checkout and
worktree, it survives `just clean`, and it needs no `.gitignore` line.

* `just format` depends on `ensure-odinfmt`, which installs on first use. You never call `fetch-ols` by hand.
* `just fetch-ols --check` exits non-zero when the install is missing or incomplete and downloads nothing — for CI.
* `just fetch-ols --force` reinstalls over an existing directory. Close any editor running `ols` first: Windows
  refuses to replace a directory holding a running executable, and the recipe says so rather than half-installing.
* Extraction goes to a `.part` directory that is renamed into place, so an interrupted run leaves either nothing or
  a finished install — necessary, because the existence test above never re-hashes anything.
* `ODINFMT=odinfmt just format` opts out of the pin and uses `PATH` — the guard skips the download when it is set.
  Pointing the editor at the pinned server is opt-in, so forcing the formatter with no way out would be the odd
  one of the pair. The pin is the default because unpinned is the failure above; it is not a cage.

A freshly scaffolded project arrives with the pin already brought up to date and the tools installed — scaffolding
runs the two recipes below for you, warning rather than failing if either cannot. So the commands here are the ones
for keeping an existing project current.

**Bumping the pin.** `just bump-ols` reads the latest release from GitHub's API and rewrites `ols_tag` and all
five digests in `.just/toolchain.just` for you — copying six values by hand is where a wrong pin comes from:

```
just bump-ols                 # rewrite the pin to the latest release
just bump-ols dev-2026-07     # ... to a named release instead
just bump-ols --check         # is there a newer one? changes nothing, exits non-zero if so
just fetch-ols --force        # install it; the digests just written are checked on the way in
just format                   # review this diff - see below
```

It edits `.just/toolchain.just` and stops: no fetch, no format, no commit. `/releases/latest` skips prereleases, which is
what keeps the continuously re-cut `nightly` tag out of it — a moving tag cannot be hash-pinned. Digests come from
the API's per-asset `digest` field; an older release without one is downloaded and hashed instead.

Expect to do this fairly often. ols vendors its own copy of the Odin parser, and Odin is pre-1.0 and moving, so a
pin left far behind your compiler will fail to parse code the compiler accepts. A digest that does not match is a
hard failure rather than an install: a re-cut tag has to be adopted deliberately, which is the whole point.

**Pointing the editor at the same ols.** `just sublime-lsp-init` writes the pinned server's path into the
`.sublime-project` file:

```json
"settings": {
    "LSP": {
        "odin": { "command": ["$home/.odin-tools/ols/dev-2026-06/ols.exe"] }
    }
}
```

Sublime's LSP client merges this over the global `clients.odin` config *per key*: `command` is replaced outright,
while `initializationOptions` is deep-merged — so whatever `enable_*` flags you have set globally still apply, and
windows without this project keep using the global server. Sublime expands `$home` in `command`, so the file stays
identical on every machine and can be committed; it does **not** expand environment variables there, so a custom
`$ODIN_TOOLS` root has to be written out in full. Re-run the recipe after bumping `ols_tag` (it refuses to
overwrite, so delete the `"LSP"` key first).

Nothing in the justfile runs `ols` — the language server is the editor's business. Pinning it costs one extra file
from an archive already downloaded, and it means the analysis you see and the formatting you commit come from the
same release.

The Odin compiler itself is deliberately *not* pinned: pre-1.0 it moves fast enough that pinning would cost more
than it saves.


### Some recipes need uv

`fetch-ols`, `bump-ols`, `ols-config`, `install-sublime`, `sublime-build-init`, `sublime-lsp-init` — and `examples` in a
library — are `[script]` recipes: their
bodies are Python, run through [uv](https://docs.astral.sh/uv/) rather than a bare `python`/`python3` on `PATH`. The
justfile pins this in one place:

```
set script-interpreter := ["uv", "run", "--no-project", "-p", "3.14", "python"]
```

A bare `python` is not a reliable cross-platform lookup — on Windows via [Scoop](https://scoop.sh/) it is whatever
version was last `scoop install`ed with no pin, and on Linux it is whatever the distro shipped. `uv run -p 3.14
python` downloads the interpreter it needs (uv-managed, not the system one) so the same version runs everywhere, and
`--no-project` stops `uv run` from walking up the directory tree looking for an unrelated `pyproject.toml`/`uv.toml`
to treat as a project root.

**In a library uv is needed for `just examples`**, and otherwise optional: `check`/`test*`/`lint`/`format`/`example`
and `doc` touch no Python, but `examples` — the recipe that stops an API change from quietly invalidating the
documentation — is one of these `[script]` recipes, so it is not only an editor-setup concern here.
Install from
[docs.astral.sh/uv](https://docs.astral.sh/uv/getting-started/installation/) (or via Scoop: `scoop install uv`) if
you plan to use those recipes.


### Choosing a linker

Odin has no build cache, so it relinks on every build. Which linker does that work is a `linker` variable at the
top of the justfile, passed to every recipe that links:

| value | notes |
| --- | --- |
| `default` | Odin picks — MSVC `link.exe` on Windows. Portable, and the default everywhere except Windows |
| `lld` | LLVM's linker. Windows and Linux. **Not on a stock macOS** — Odin links through clang, and Apple's clang ships no lld, so it fails with `invalid linker name in argument '-fuse-ld=lld'` unless you installed LLVM yourself |
| `radlink` | RAD Debugger's linker. **Windows only**, and bundled with the Odin toolchain, so it needs no install — which is why it is the Windows default here |
| `mold` | **Linux only**, and *not* bundled — `apt install mold` or equivalent first |

Override for a single command without editing anything:

```sh
ODIN_LINKER=lld just test
```

To change the default for good, edit that `linker` line in the justfile.


Nothing falls back silently, but the two ways a linker can be unavailable fail differently. Odin knows mold is
Linux-only, so asking for it on Windows exits 1 with `'mold' linker is not supported on this platform` before any work
happens. `lld` on macOS gets no such check — Odin accepts the value and clang rejects it further down with
`invalid linker name in argument '-fuse-ld=lld'`. Either way you get exit 1 and no binary, just with more or less
explanation. `ODIN_LINKER` is an environment variable
rather than a recipe argument because `odin` errors on a repeated flag, so a `-linker:` passed through a recipe's extra
args would collide with the one the recipe already adds.

**When the default is the better choice.** Neither radlink nor mold is an *incremental* linker; MSVC `link.exe` is.
Paired with `-use-separate-modules` — which `-lto` implies — an incremental relink of one changed module can beat a
full link that is individually faster. That is not the shape of a stock Odin build, though: single-module builds give
LTO little to work with, and statically linked external C libraries do not get LTO either way. Measure on your own
project before assuming. `-lto` is also a hard conflict rather than a preference — on Windows it *requires*
`-linker:lld` — so reach for the override there:

```sh
ODIN_LINKER=lld just test -lto:thin
```


### Timing a recipe

`just --time <recipe>` prints how long the recipe took (`JUST_TIME=true` as an env var; note it wants
`true`, not `1`):

```
just --time test           ---> test completed in 0.412s
```

Odin has no build cache, so every recipe here recompiles and its timing is mostly the compiler. That
makes `just --time` useful for tracking what the *build* costs as the library grows, rather than what
the code costs at runtime.

Note that any external measurement includes process startup, which was ~31ms on this machine, so for
sub-second work put `time.now()` / `time.since` around the specific phase you care about instead.


### Benchmarking


`bench/` holds the harness, your benchmarks, and a `bench.just` carrying the recipes. The justfile's
`import? 'bench/bench.just'` is an *optional* import: it does nothing while the directory is absent, so
the `just bench*` recipes appear the moment it arrives and `rm -rf bench/` takes them away again.

Odin has no `cargo bench`, and `core:time`'s `benchmark()` is a stopwatch — it calls your procedure
once and divides, with no warmup, repeat samples, spread or baseline, so it cannot answer "did this
change make it slower". The harness borrows what makes
[criterion](https://github.com/bheisler/criterion.rs) worth using: a warmup, samples across a ramp of
iteration counts fitted with a robust line, R² and outlier counts to say whether the samples describe
one thing at all, and a Mann–Whitney U test against a saved baseline so a change is called out on a
p-value plus a magnitude threshold rather than a percentage.

**The documentation is [`bench/README.md`](bench/README.md)**, which arrives with the directory — the
statistics and how to read them, the `keep` / `opaque` rules without which `-o:speed` deletes your
benchmark and reports the empty loop, timing baselines and where they stop being trustworthy, and
instruction counting under callgrind for a gate that does not flake. It lives with the feature rather
than here so that a project which never adds the harness never carries its manual either.

#### What to use instead, and when

* **hyperfine** for anything at process level — CLI startup, a whole run, comparing build flags. It has
  warmup, statistics and `--export-json`, and its process floor is irrelevant at that scale and fatal
  below it. The executable skeleton wires it up as `just time_release` and `just time_profiles`
* **spall** (`-define:SPALL_ENABLE=true` in the executable skeleton) for *why* something is slow, not
  whether it got slower. It produces a trace to read, not numbers to compare

### [Sublime Text](https://www.sublimetext.com/) editor specific files

The `OdinJustTarget.sublime-build` file is an example [sublime build file](https://www.sublimetext.com/docs/build_systems.html). Delete it if no developer is using sublime text.
The `Odin.sublime-build` file is similar but doesn't assume you have `just` installed.
Same for the very basic `.sublime-project` file.

If you install the `.sublime-build` file(s) you get a lot of build options for *compiling* either the individual file
or the current package of the file open in the editor. The artifacts are output to the `target` directory (or
current directory if not using `just`).

The build options also include *linting* and *testing*.

This is a basic sublime build system and can be improved upon. You may want your own project specific `just` build
tasks or sublime build files. More flexibility is needed if you need things like custom `-define` compile time
parameters or multi stage conditional build steps. Rare custom steps are easy enough to run from the cli with extra
task arguments, but frequently ran things maybe more conveniently executed through a sublime build file and so require
some project specific customisation.

Three `.sublime-snippet` files ship here. Each carries a `tabTrigger` (type it, press Tab) and a `description`, which is
what shows beside the trigger in the completion popup and is how they are listed under Tools → Snippets… — worth knowing,
because a `tabTrigger` only helps somebody who already knows to type it:

| trigger | scope | fills in |
| --- | --- | --- |
| `main` | `source.odin` | the `main.odin` program skeleton — logging, tracking allocator, backtraces. Useful for a quick script file without a `justfile` |
| `odin` | `source.just` | a justfile for an Odin **program** — the build tiers, `test`, `lint` |
| `odinlib` | `source.just` | a justfile for an Odin **library** — `check`, `example`, `examples`, `doc`, `test` |

The two justfile snippets exist separately because a justfile is one project kind's justfile; unlike the build systems
below, one copy cannot serve both.

Sublime snippets and build systems are installed **globally**, not per project: Sublime loads everything under its
`Packages/User` folder and offers it (snippets by `tabTrigger` within the matching `scope`; build systems in the
Tools → Build System menu) in all windows. So you install them once and they apply everywhere.

`just install-sublime` does this for you, cross platform — it copies the three `.sublime-snippet` files and the two
`.sublime-build` files into Sublime's `Packages/User` directory (resolved per-OS; override with the `SUBLIME_USER_DIR`
env var if your install is non-standard). The per-project `.sublime-project` file is intentionally not installed.

Because that install is global, the `.sublime-build` files list **both** project kinds' recipes and are copied verbatim
into every scaffolded project — a copy specialised to the project it came from would take the other kind's build
variants away everywhere. A variant naming a recipe your project does not define simply fails if you pick it.

If instead you want a **project-local** build system — one that only shows up when this project is open and needs no
global install — Sublime reads it from the `"build_systems"` key inside the `.sublime-project` file (loaded
automatically when you open the project). `just sublime-build-init` seeds that key with one working `just test` build plus
commented-out variant examples (release / test / lint / current-file) for you to extend; it refuses if the project
file already has a `build_systems` entry. (`.sublime-project` is loose JSON — `//` comments and trailing commas are
allowed.)

`just sublime-lsp-init` writes into the same file, pointing this project's language server at the pinned `ols` —
see [Pinned tooling](#pinned-tooling).


### Language Server Configuration

This is also optional, delete if not needed. As the [Odin language server](https://github.com/DanielGavin/ols) docs
show you can configure OLS settings in ways specific to your editor, often in a global manner - once per all projects.

However, you can also use the `ols.json` file, perhaps to add odin "collections" specific to your project.
This is initially an empty collection list.

If you do need extra collections (so OLS resolves `import "xyz:pkg"` from a directory outside this project), the
`ols-config` just task writes the collection list for you. Each argument is `name=path`:

```sh
just ols-config xyz=../xyz-lib abc=/opt/odin/abc
just ols-config                                   # print what is currently configured
```

The arguments are the *whole* collection list — rerunning replaces it, so there is no add/remove pair of commands
to keep straight. Every other key in `ols.json` (`enable_document_symbols`, `checker_path`, `odin_command` …) is
read back and preserved, so the recipe and hand-editing can coexist.

**Prefer a relative path.** OLS resolves a relative collection path against the project root, so a collection kept
as a sibling checkout (`../xyz-lib`) produces an `ols.json` that is identical on every machine — delete the
`ols.json` line from `.gitignore` and commit it. An absolute path is machine-specific, which is why the skeleton
ignores the file by default and each developer regenerates it after cloning. A leading `~` is expanded, but on
Linux and macOS only; on Windows write the path out in full.

`ols.json` itself is plain JSON with no variable substitution — OLS does not expand environment variables in
collection paths — which is why a recipe generates the file rather than the file reading `XYZ_HOME` itself.

#### What "the project root" means to OLS

Everything above depends on one directory: `ols.json` is read from it, relative collection paths resolve against
it, and a profile's `checker_path` is joined to it. That directory is **not** discovered by searching upwards from
the file being edited. The editor tells the server what it is, once, and OLS keeps it for the life of the process
(`workspace_folders[0]` at `initialize`). Worth knowing before grouping several checkouts into one window.

For Sublime Text with the [LSP](https://github.com/sublimelsp/LSP) package, the rules are:

* **One server process per window**, not per folder, and it handles every `.odin` file in that window — including
  files in a folder it is not rooted at, and files belonging to no folder at all.
* **The root is the folder containing whichever `.odin` file started the server.** LSP sorts the window's folders
  so the ones containing that file come first (deepest match first) and hands the first one over as `rootUri`.
* **Adding or removing folders later does not re-root it.** OLS does not advertise the workspace-folders
  capability, so LSP never sends the notification. `LSP: Restart Server` re-runs `initialize` and re-roots to
  whatever file is active then — an escape hatch, not a fix.
* **A `.sublime-project` file inside one of the folders is never read.** A window has exactly one project; a
  project file sitting in a subfolder is just a file on disk.

If you are coming from Visual Studio the analogy is close enough to mislead:

| Visual Studio | Sublime + LSP |
| --- | --- |
| `.sln` | `.sublime-project` — one per window, groups roots, carries the settings |
| solution folder (organisational only) | an entry in `"folders"` — this is what a folder actually is |
| `.csproj`: own settings, own references, own build | **no equivalent** |
| language service re-evaluates per project as you navigate | one server, one root, chosen at startup |

There is no per-project layer: a folder carries no settings, no references and no identity. So a Sublime project
is closer to a `.sln` containing exactly *one* `.csproj` than to a solution of several. Group five repositories
into one window and you do not get five projects — you get one, whose root is decided by the first file you open.

**So: one window per Odin project.** If you do want them together, make the containing directory the window's
single folder and register each sub-repository as a collection with `just ols-config`. That is the shape OLS
models — one project with several collections, like one `.csproj` referencing several libraries — and it is
deterministic where a folder-per-repository window is not.

Opening a bare directory (`subl -n thedir`, no project file) is a milder version of the same thing. The window
still has a folder, so `rootUri` is that directory and `thedir/ols.json` is read normally; what is missing is the
`.sublime-project` file, and with it any per-project override of the global LSP client settings. Opening a lone
file with no folder at all leaves the root empty, and then no project `ols.json` is read at all — only the global
editor configuration applies.

# ocamlgrep VSCode Demo

[![CircleCI](https://circleci.com/gh/mjambon/ocamlgrep-vscode-demo.svg?style=svg)](https://app.circleci.com/pipelines/github/mjambon/ocamlgrep-vscode-demo)

A proof-of-concept VS Code integration for **ocamlgrep** — a project-wide search
for OCaml expression patterns based on type and structure rather than text.

---

## What is ocamlgrep?

ocamlgrep searches a compiled OCaml project for sub-expressions that match a
given *pattern*.  Patterns are written as ordinary OCaml expressions with special
wildcard syntax:

| Pattern syntax | Meaning |
|----------------|---------|
| `__` | Matches any expression (wildcard) |
| `__1`, `__2` | Numbered metavariable — all occurrences with the same number must match the same expression |
| `(e : t)` | Matches expressions whose inferred type unifies with `t` |
| `f __` | Matches any call to `f` (or `Some.Module.f`) with any argument |

The search operates on `.cmt` files (compiled typed trees produced by
`dune build @check`), so it is **type-aware** and not fooled by naming
or formatting differences.

### Example queries

```
List.filter __ __          →  all calls to List.filter
(__ : int list)            →  all expressions of type int list
match __ with | Ok _ -> _ | Error _ -> _
                           →  all pattern-matches on Result.t
__1 :: __1                 →  cons cells with the same head and tail (unusual!)
String.concat __ __        →  all String.concat calls
```

---

## Demo

The demo searches the [ocaml-lsp](https://github.com/ocaml/ocaml-lsp) source
tree, which is already present as a submodule and built as part of setup.

https://github.com/mjambon/ocamlgrep-vscode-demo/raw/main/web/ocamlgrep-demo.mp4

<video src="https://github.com/user-attachments/assets/6d0d1fad-827a-4eb0-9ce3-44c9ed61e6b2" controls width="100%"></video>

---

## Running the Demo

### Prerequisites

- [Docker](https://docs.docker.com/get-docker/) or [Podman](https://podman.io/getting-started/installation)
- [VS Code](https://code.visualstudio.com/) with the
  [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)

### Steps

1. **Clone this repo with submodules**

   ```bash
   git clone --recurse-submodules <this-repo-url>
   cd ocamlgrep-vscode-demo
   ```

2. **Open in VS Code and reopen in container**

   ```
   code .
   ```

   VS Code will offer "Reopen in Container" — accept it.
   The first build takes **10–20 minutes** (compiling OCaml from source).
   Subsequent starts are instant.

3. **Open the demo project**

   Once the container is ready, open the ocaml-lsp source tree in VS Code:

   ```
   File > Open Folder > /workspace/ocaml-lsp
   ```

4. **Run the command**

   - Open any `.ml` file
   - Press `Ctrl+Shift+P` (or `Cmd+Shift+P` on macOS)
   - Type **"OCaml: Search expressions with ocamlgrep"**
   - Enter a pattern (e.g. `List.filter __ __`)
   - Select a result to jump to it

### Without Docker (manual setup)

If you have opam + OCaml 5.x installed:

```bash
git clone --recurse-submodules <this-repo-url>
cd ocamlgrep-vscode-demo
bash scripts/setup.sh
```

Then open VS Code on `/workspace/ocaml-lsp`.

---

## How It Works

The integration spans three repositories (included as submodules on the
`ocamlgrep` branch):

```
vscode-ocaml-platform  →  ocaml-lsp  →  merlin
(VS Code extension)       (LSP server)   (analysis)
```

1. **merlin** (`ocamlgrep` branch): Implements `Expr_search` — the pattern
   parser and typed-AST matcher.  Exposed as the `ocamlmerlin single ocamlgrep`
   subcommand.

2. **ocaml-lsp** (`ocamlgrep` branch): Adds `req_ocamlgrep.ml`, a custom LSP
   request handler for method `ocamllsp/ocamlgrep`.  Accepts `{textDocument, query}`
   and returns `{findings: [{uri, range, lines}], warnings: []}`.

3. **vscode-ocaml-platform** (`ocamlgrep` branch): Adds the `ocaml.ocamlgrep`
   VS Code command with an InputBox → QuickPick UI.

See [NOTES.md](NOTES.md) for detailed technical notes.

---

## Repository Layout

```
ocamlgrep-vscode-demo/
├── README.md                   ← this file
├── NOTES.md                    ← technical notes (architecture, gotchas, TODOs)
├── merlin/                     ← submodule (ocamlgrep branch)
├── ocaml-lsp/                  ← submodule (ocamlgrep branch)
├── vscode-ocaml-platform/      ← submodule (ocamlgrep branch)
├── web/                        ← demo video
├── scripts/
│   └── setup.sh                ← builds everything and installs the extension
└── .devcontainer/
    └── devcontainer.json       ← Docker-based dev environment
```

---

## Pattern Language Reference

The full pattern syntax is documented in the
[ocamlgrep README](https://github.com/LexiFi/ocamlgrep).

Key points:

- Patterns are parsed as OCaml expressions (standard syntax)
- `__` is the anonymous wildcard (matches anything)
- `__1`, `__2` are metavariables — structural equality is enforced across
  all occurrences with the same number within one pattern
- `(expr : type)` constrains the type of the matched expression
- Match arms and record fields are matched as **sets** (order-independent)
- Identifiers are matched as **path suffixes**: `filter` matches `List.filter`,
  `Stdlib.List.filter`, etc.

---

## Status

This is a **prototype demo** — the branches have not been submitted for code
review yet.  If the demo is successful, we plan to open PRs against the
upstream repositories.

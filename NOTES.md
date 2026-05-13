# Technical Notes

Internal notes on the integration architecture and decisions.
Update this file whenever you discover something non-obvious.

---

## Architecture Overview

```
VSCode Extension                 LSP Server                 Merlin
(vscode-ocaml-platform)         (ocaml-lsp)                (ocamlgrep branch)
        │                              │                          │
        │  Custom LSP request          │                          │
        │  method: ocamllsp/ocamlgrep  │                          │
        │  params: {textDocument,      │                          │
        │           query}             │                          │
        │ ────────────────────────►   │                          │
        │                              │  Query_protocol.         │
        │                              │  Ocamlgrep(query, None)  │
        │                              │ ──────────────────────►  │
        │                              │                          │
        │                              │  {findings, warnings}    │
        │                              │ ◄──────────────────────  │
        │                              │                          │
        │  {findings: [{uri,range,     │                          │
        │               lines}],       │                          │
        │   warnings: []}              │                          │
        │ ◄────────────────────────   │                          │
        │                              │
     QuickPick UI
     → navigate to file:line
```

---

## Repository Structure

| Repo | Branch | Role |
|------|--------|------|
| `merlin` | `ocamlgrep` | Adds `Query_protocol.Ocamlgrep` and `Expr_search` analysis |
| `ocaml-lsp` | `ocamlgrep` | Adds `req_ocamlgrep.ml` custom request handler |
| `vscode-ocaml-platform` | `ocamlgrep` | Adds `Ocamlgrep` command and QuickPick UI |

---

## Merlin Integration

### Query Protocol

`Query_protocol.Ocamlgrep : string * string option -> ocamlgrep_result t`

- First arg: pattern string (OCaml expression with `__` wildcards)
- Second arg: optional project root (merlin walks up to find `dune-project` if given a subdir)
- When `None`: merlin uses CWD (= LSP workspace root)

### Result Type

```ocaml
type ocamlgrep_finding = { loc : Location.t; lines : string list }
type ocamlgrep_result = { findings : ocamlgrep_finding list; warnings : string list }
```

### Finding Locations

`loc.loc_start.pos_fname` is the **project-relative** path (e.g. `src/foo.ml`).
The `req_ocamlgrep.ml` handler prepends `State.workspace_root` to construct absolute
`file://` URIs for the LSP client.

---

## ocaml-lsp Changes

**New file**: `ocaml-lsp-server/src/custom_requests/req_ocamlgrep.ml`

- LSP method: `"ocamllsp/ocamlgrep"`
- Capability key: `"handleOcamlgrep"` (advertised in `InitializeResult`)
- Params: `{textDocument: {uri}, query: string}`
- Response: `{findings: [{uri, range, lines}], warnings: []}`
  - `uri`: absolute `file://` URI
  - `range`: LSP-style 0-based line/character positions
  - `lines`: source lines covering the match

**Modified files**:
- `custom_request.ml/mli`: adds `module Ocamlgrep = Req_ocamlgrep`
- `ocaml_lsp_server.ml`: wires capability + request handler

### Key design note

`Query_protocol.Ocamlgrep` ignores the pipeline's buffer — it scans the whole
project's `.cmt` files. We still use `Document.Merlin.with_pipeline_exn` to get
a merlin pipeline (which sets up the right project context), but the buffer
content is irrelevant. The `root_opt = None` means merlin determines the project
root from CWD (the workspace root passed during LSP initialization).

---

## vscode-ocaml-platform Changes

**New command**: `ocaml.ocamlgrep`
- Registered in `package.json` as `"OCaml: Search expressions with ocamlgrep"`
- Defined in `extension_commands.ml` as `module Ocamlgrep`
- Handle in `command_api.ml`: `let ocamlgrep = unit_handle "ocamlgrep"`

**Custom request**: `Custom_requests.Ocamlgrep` module in `custom_requests.ml/mli`
- Encodes params to JSON (`textDocument.uri` + `query`)
- Decodes response: parses `{findings: [{uri, range, lines}]}` back to OCaml types

**Capability check**: `Ocaml_lsp.can_handle_ocamlgrep` checks `handleOcamlgrep`
from the server's `InitializeResult`. If the running ocamllsp doesn't support
ocamlgrep, the user sees a message suggesting an upgrade.

**UI flow**:
1. InputBox: user types pattern
2. LSP request sent using the URI of the currently open file (just for project context)
3. QuickPick: each result shows `index: file.ml:line` as label and matched source as detail
4. On selection: `Window.showTextDocument'` opens the file with `selection` set to the range

---

## Demo Project (ocaml-lsp submodule)

We use the `ocaml-lsp` submodule (`/workspace/ocaml-lsp`) as the demo project.
It is already present, its dependencies are installed by setup.sh (step 6), and
`dune build @check` is run at the end of setup to produce the `.cmt` files that
ocamlgrep searches over.

We originally planned to use the Dune repo but it requires `(lang dune 3.23)`
which is newer than the dune installed in the container.

### Suggested demo patterns

| Pattern | What it finds |
|---------|---------------|
| `List.filter __ __` | All calls to List.filter |
| `(__ : int list)` | All expressions typed as `int list` |
| `match __ with \| Ok __ -> __ \| Error __ -> __` | Result-matching |
| `String.concat __ __` | String concatenations |
| `__1 :: __1` | Cons cells where both elements are the same |

---

## Build Process

### opam pins (applied before `opam install`)

```
merlin / merlin-lib / dot-merlin-reader  →  ./merlin (ocamlgrep branch)
jsonrpc / lsp / ocaml-lsp-server         →  ./ocaml-lsp (ocamlgrep branch)
```

The version in the merlin submodule is `5.7.1-504` (tag on ocamlgrep branch),
which satisfies ocaml-lsp's constraint `merlin-lib >= 5.7 & < 5.8`.

### vscode-ocaml-platform build

Uses opam for OCaml deps + bun for JS deps + js_of_ocaml for OCaml→JS.
The extension's OCaml code does NOT depend on merlin or ocaml-lsp at compile time
(they are only `{with-dev-setup}` dependencies). The extension communicates with
`ocamllsp` purely via the LSP protocol at runtime.

---

## Submodule URLs

The `.gitmodules` file uses relative paths (`../merlin` etc.) because the repos
are siblings on disk. Before publishing this demo, update the URLs to point to
the actual GitHub remotes once the `ocamlgrep` branches are pushed.

```
[submodule "merlin"]
    url = https://github.com/ocaml/merlin.git
    branch = ocamlgrep
[submodule "ocaml-lsp"]
    url = https://github.com/ocaml/ocaml-lsp.git
    branch = ocamlgrep
[submodule "vscode-ocaml-platform"]
    url = https://github.com/ocaml/vscode-ocaml-platform.git
    branch = ocamlgrep
```

---

## Known Issues / TODOs

- [ ] The extension doesn't display a progress indicator while the search runs.
      Large projects may take several seconds.
- [ ] The QuickPick doesn't support preview-on-hover (would require `onDidChangeActive`).
- [ ] The active file determines which project is searched: ocamlgrep uses the
      active editor's document to obtain a merlin pipeline, so the file must
      belong to a project with a working dune/merlin config.  If merlin reports
      "No config found for file …", the wrong file is active.  For the demo,
      keep a file from /workspace/ocaml-lsp active before running the command.
- [ ] Multi-root workspaces are not handled.
- [ ] The devcontainer's `postCreateCommand` can take 10-20 minutes on first run
      (compiling OCaml from source). A pre-built Docker image would speed this up.
- [ ] The `.gitmodules` relative URLs won't work for users cloning from GitHub;
      update to absolute GitHub URLs before sharing publicly.

## Hard-won implementation notes

### QuickPick.set: all fields must be set explicitly
VS Code calls `.filter` and `.slice` on `activeItems`, `selectedItems`, and
`buttons` before showing the QuickPick. If any of these are `undefined`
(because OCaml optional parameters default to `None`), you get a JS runtime
error. Always pass `~activeItems:[] ~selectedItems:[] ~buttons:[] ~busy:false
~enabled:true` even when not needed.

### InputBox must be hidden before showing the QuickPick
VS Code only shows one QuickInput at a time. If the InputBox is still active
when `QuickPick.show` is called, the QuickPick is suppressed silently.
`InputBox.hide` must be bound explicitly (it was missing from the bindings)
and called before `QuickPick.show`.

### cmt file paths are CWD-relative in merlin's scan.ml
`Sys.file_exists` and `read_lines` in `scan.ml` used relative paths that only
worked when CWD was the project root. The LSP server's CWD is not guaranteed
to be the project root. Fixed by using `Filename.concat paths.project_root rel`
to make paths absolute.

### cmt_sourcefile can point into _build/
Dune records the build-directory path in `cmt_sourcefile` for some files.
Reading from `_build/default/...` gives the preprocessed (sometimes binary)
content instead of the source. Fixed by detecting the build-dir prefix and
redirecting to the project source tree.

### ocaml-lsp base commit selection
The `ocamlgrep` branch is based on commit `838b58a6` (just before "fix: compile
with Dune 3.22"). The dune-3.22 commit requires `dune-rpc >= 3.22.0` which is
not yet in the stable opam repository. We cherry-picked `fcd116a8` separately
to get the merlin 5.7 API compatibility fix (`Merlin_utils.Misc` →
`Ocaml_utils.Misc`).

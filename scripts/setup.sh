#!/usr/bin/env bash
# setup.sh — Builds merlin, ocaml-lsp, and the VSCode extension from the
# submodules, then clones and builds the Dune repo as the demo project.
#
# Expected to run inside the devcontainer (or any system with opam and a
# recent OCaml switch).  Safe to re-run; most steps are idempotent.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_PROJECT_DIR="$REPO_ROOT/demo-project"

log() { echo ""; echo "==> $*"; }

# ── 1. Opam environment ────────────────────────────────────────────────────────

# Unset OPAMSWITCH so opam uses whatever switch exists in this image,
# then let 'opam env' set the right values.
unset OPAMSWITCH
eval "$(opam env)"
log "OCaml: $(ocaml --version)"

# ── 2. Install bun (fast JS runtime / bundler) ────────────────────────────────

# Always extend PATH with the bun install location so re-runs find it without
# needing a fresh shell (bun's installer exports this but doesn't persist it).
export PATH="$HOME/.bun/bin:$PATH"

if ! command -v bun &>/dev/null; then
    log "Installing bun..."
    curl -fsSL https://bun.sh/install | bash
fi
log "bun: $(bun --version)"

# ── 3. Refresh opam package index ─────────────────────────────────────────────

log "Updating opam package index..."
opam update -y

# ── 4. Pin ocamlgrep-lib from submodule ───────────────────────────────────────

OCAMLGREP_VER=$(git -C "$REPO_ROOT/ocamlgrep" describe --tags --abbrev=0 \
    2>/dev/null | sed 's/^v//') || true

log "Pinning ocamlgrep-lib..."
if [ -n "$OCAMLGREP_VER" ]; then
    opam pin add "ocamlgrep-lib.$OCAMLGREP_VER" "$REPO_ROOT/ocamlgrep" --no-action -y
else
    # No git tags in submodule clone; pin without explicit version
    opam pin add ocamlgrep-lib "$REPO_ROOT/ocamlgrep" --no-action -y
fi

# ── 5. Pin ocaml-lsp from submodule ───────────────────────────────────────────

LSP_VER=$(git -C "$REPO_ROOT/ocaml-lsp" describe --tags --abbrev=0 \
    2>/dev/null | sed 's/^v//') || true
LSP_VER=$(opam info ocaml-lsp-server --field=all-versions 2>/dev/null \
    | tr ' ' '\n' | sort -V | tail -1) 2>/dev/null || LSP_VER="${LSP_VER:-1.25.0}"

log "Pinning ocaml-lsp packages at version $LSP_VER..."
opam pin add "jsonrpc.$LSP_VER"          "$REPO_ROOT/ocaml-lsp" --no-action -y
opam pin add "lsp.$LSP_VER"              "$REPO_ROOT/ocaml-lsp" --no-action -y
opam pin add "ocaml-lsp-server.$LSP_VER" "$REPO_ROOT/ocaml-lsp" --no-action -y

git -C "$REPO_ROOT/ocaml-lsp" checkout -- . 2>/dev/null || true

# ── 6. Install ocamlgrep-lib and ocaml-lsp-server ─────────────────────────────

log "Installing ocamlgrep-lib and ocaml-lsp-server (this takes a while on first run)..."
# dune >= 3.21 has a Chan API incompatible with our ocaml-lsp base commit
# (838b58a6).  Constraining dune.3.20.2 is sufficient.
opam install ocamlgrep-lib ocaml-lsp-server "dune.3.20.2" -y
eval "$(opam env)"
log "ocamllsp:      $(ocamllsp --version)"
log "ocamlgrep-lib: $(opam info ocamlgrep-lib --field=installed-version 2>/dev/null || echo 'unknown')"

# ── 8. Build the VSCode extension ─────────────────────────────────────────────

log "Installing JS dependencies for vscode-ocaml-platform..."
cd "$REPO_ROOT/vscode-ocaml-platform"
bun install --frozen-lockfile

log "Installing OCaml dependencies for vscode-ocaml-platform..."
opam install --deps-only --yes . 2>&1 | tail -5

# Install test/dev deps so 'dune describe workspace' succeeds in the demo
# project; ocamlgrep runs that command at query time to enumerate source files.
# ppx_inline_test and ppx_expect are needed by jsonrpc-fiber's test suite but
# do not appear in any top-level opam file, so we install them explicitly.
log "Installing ocaml-lsp test dependencies (needed by dune describe workspace)..."
opam install --deps-only --with-test --yes "$REPO_ROOT/ocaml-lsp" 2>&1 | tail -5
opam install ppx_inline_test ppx_expect -y 2>&1 | tail -5

log "Building vscode-ocaml-platform extension..."
cd "$REPO_ROOT/vscode-ocaml-platform"
make build

log "Packaging extension as .vsix..."
make pkg
# Extension installation requires the 'code' CLI which is only available after
# VS Code attaches.  The devcontainer.json postAttachCommand handles this.

# ── 9. Build .cmt files for the demo project (ocaml-lsp submodule) ────────────
#
# We use the ocaml-lsp source tree as the demo project: it's already present,
# already has its dependencies installed (step 6 above), and is a good-sized
# real OCaml codebase.  'dune build @check' generates the .cmt files that
# ocamlgrep needs to search over.

log "Building .cmt files in demo project (ocaml-lsp)..."
cd "$REPO_ROOT/ocaml-lsp"
# @check type-checks every source file (including vendors) and writes .cmt
# files that ocamlgrep reads at query time.  Test deps must be installed first.
opam exec -- dune build @check 2>&1 | tail -10

# ── Done ──────────────────────────────────────────────────────────────────────

log "Setup complete!"
echo ""
echo "  The demo project is the ocaml-lsp source tree:"
echo "    $REPO_ROOT/ocaml-lsp"
echo ""
echo "  Open any .ml file there, run the command palette, and choose:"
echo "    OCaml: Search expressions with ocamlgrep"
echo ""
echo "  Example patterns:"
echo "    List.filter __ __"
echo "    (__ : int list)"
echo "    match __ with | Ok __ -> __ | Error __ -> __"

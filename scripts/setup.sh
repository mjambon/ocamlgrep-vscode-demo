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

eval "$(opam env)"
log "OCaml: $(ocaml --version)"

# ── 2. Install bun (fast JS runtime / bundler) ────────────────────────────────

if ! command -v bun &>/dev/null; then
    log "Installing bun..."
    curl -fsSL https://bun.sh/install | bash
    export PATH="$HOME/.bun/bin:$PATH"
fi
log "bun: $(bun --version)"

# ── 3. Pin merlin from submodule ───────────────────────────────────────────────
#
# merlin.opam has "merlin-lib" {= version}, so all packages in the merlin repo
# MUST be pinned with the same version string.  We derive it from the nearest
# git tag so opam's version constraint {= version} stays consistent.

MERLIN_VER=$(git -C "$REPO_ROOT/merlin" describe --tags --abbrev=0 | sed 's/^v//')
log "Pinning merlin packages from submodule at version $MERLIN_VER..."
opam pin add merlin            "$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y
opam pin add merlin-lib        "$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y
opam pin add dot-merlin-reader "$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y
opam pin add ocaml-index       "$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y 2>/dev/null || true

# ── 4. Pin ocaml-lsp from submodule ───────────────────────────────────────────

LSP_VER=$(git -C "$REPO_ROOT/ocaml-lsp" describe --tags --abbrev=0 | sed 's/^v//')
log "Pinning ocaml-lsp packages from submodule at version $LSP_VER..."
opam pin add jsonrpc           "$LSP_VER" "$REPO_ROOT/ocaml-lsp" --no-action -y
opam pin add lsp               "$LSP_VER" "$REPO_ROOT/ocaml-lsp" --no-action -y
opam pin add ocaml-lsp-server  "$LSP_VER" "$REPO_ROOT/ocaml-lsp" --no-action -y

# ── 5. Install merlin and ocaml-lsp (provides ocamlmerlin + ocamllsp) ─────────

log "Installing merlin and ocaml-lsp-server (this takes a while on first run)..."
opam install merlin ocaml-lsp-server -y
eval "$(opam env)"
log "ocamllsp: $(ocamllsp --version)"
log "ocamlmerlin: $(ocamlmerlin --version | head -1)"

# ── 6. Build the VSCode extension ─────────────────────────────────────────────

log "Installing JS dependencies for vscode-ocaml-platform..."
cd "$REPO_ROOT/vscode-ocaml-platform"
bun install --frozen-lockfile

log "Installing OCaml dependencies for vscode-ocaml-platform..."
opam install --deps-only --yes . 2>&1 | tail -5

log "Building vscode-ocaml-platform extension..."
make build

log "Packaging extension as .vsix..."
make pkg

# ── 7. Install the extension (requires 'code' CLI) ────────────────────────────

log "Installing extension..."
if command -v code &>/dev/null; then
    make install
elif command -v code-server &>/dev/null; then
    VSIX=$(ls "$REPO_ROOT/vscode-ocaml-platform"/*.vsix | head -1)
    code-server --install-extension "$VSIX" --force
else
    VSIX=$(ls "$REPO_ROOT/vscode-ocaml-platform"/*.vsix | head -1)
    echo ""
    echo "  NOTE: 'code' CLI not found.  Install the extension manually:"
    echo "    code --install-extension $VSIX"
fi

# ── 8. Clone the demo project (Dune repo) ─────────────────────────────────────

if [ ! -d "$DEMO_PROJECT_DIR/.git" ]; then
    log "Cloning dune repo as the demo project..."
    git clone --depth=1 https://github.com/ocaml/dune.git "$DEMO_PROJECT_DIR"
else
    log "Demo project already present at $DEMO_PROJECT_DIR"
fi

log "Building .cmt files in demo project (dune build @check)..."
cd "$DEMO_PROJECT_DIR"
opam exec -- dune build @check 2>&1 | tail -10 || {
    echo "  WARNING: dune build @check had errors (possibly missing system deps)."
    echo "  Try 'opam install --deps-only .' in $DEMO_PROJECT_DIR"
}

# ── Done ──────────────────────────────────────────────────────────────────────

log "Setup complete!"
echo ""
echo "  Next: open VS Code on the demo project:"
echo "    code $DEMO_PROJECT_DIR"
echo ""
echo "  Then open any .ml file, run the command palette, and choose:"
echo "    OCaml: Search expressions with ocamlgrep"
echo ""
echo "  Example patterns:"
echo "    List.filter __ __"
echo "    (__ : int list)"
echo "    match __ with | Ok __ -> __ | Error __ -> __"

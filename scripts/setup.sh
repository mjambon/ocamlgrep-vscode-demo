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

# Always extend PATH with the bun install location so re-runs find it without
# needing a fresh shell (bun's installer exports this but doesn't persist it).
export PATH="$HOME/.bun/bin:$PATH"

if ! command -v bun &>/dev/null; then
    log "Installing bun..."
    curl -fsSL https://bun.sh/install | bash
fi
log "bun: $(bun --version)"

# ── 3. Pin merlin from submodule ───────────────────────────────────────────────
#
# merlin.opam declares "merlin-lib" {= version}, so all packages must be pinned
# at the same version string.  We read the version that opam would infer for
# 'merlin' and then explicitly pass the same string to every other pin in the
# repo.  If git describe fails (no tags in the submodule clone), we fall back to
# the latest version in the opam repository.

merlin_infer_version() {
    # opam uses git-describe to version a local pin; replicate the same logic.
    local ver
    ver=$(git -C "$REPO_ROOT/merlin" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//') \
        || true
    if [ -z "$ver" ]; then
        # No tags in submodule clone (common when cloned from a local path whose
        # remote doesn't have the tags).  Fetch tags from the real upstream.
        log "No tags found in merlin submodule — fetching from upstream..."
        git -C "$REPO_ROOT/merlin" remote add upstream \
            https://github.com/ocaml/merlin.git 2>/dev/null || true
        git -C "$REPO_ROOT/merlin" fetch --tags upstream 2>&1 | tail -3 || true
        ver=$(git -C "$REPO_ROOT/merlin" describe --tags --abbrev=0 2>/dev/null \
                | sed 's/^v//') || true
    fi
    if [ -z "$ver" ]; then
        # Last resort: ask opam what the latest released merlin version is.
        ver=$(opam info merlin --field=all-versions 2>/dev/null \
                | tr ' ' '\n' | sort -V | tail -1) || true
    fi
    echo "${ver:-dev}"
}

MERLIN_VER=$(merlin_infer_version)
log "Pinning merlin packages from submodule at version $MERLIN_VER..."
opam pin add merlin            "$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y
opam pin add merlin-lib        "$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y
opam pin add dot-merlin-reader "$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y
opam pin add ocaml-index       "$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y \
    2>/dev/null || true

# ── 4. Pin ocaml-lsp from submodule ───────────────────────────────────────────
#
# Same approach: all three packages in the ocaml-lsp repo share a version via
# {= version} constraints, so they must be pinned identically.

lsp_infer_version() {
    local ver
    ver=$(git -C "$REPO_ROOT/ocaml-lsp" describe --tags --abbrev=0 2>/dev/null \
            | sed 's/^v//') || true
    if [ -z "$ver" ]; then
        log "No tags in ocaml-lsp submodule — fetching from upstream..."
        git -C "$REPO_ROOT/ocaml-lsp" remote add upstream \
            https://github.com/ocaml/ocaml-lsp.git 2>/dev/null || true
        git -C "$REPO_ROOT/ocaml-lsp" fetch --tags upstream 2>&1 | tail -3 || true
        ver=$(git -C "$REPO_ROOT/ocaml-lsp" describe --tags --abbrev=0 2>/dev/null \
                | sed 's/^v//') || true
    fi
    if [ -z "$ver" ]; then
        ver=$(opam info ocaml-lsp-server --field=all-versions 2>/dev/null \
                | tr ' ' '\n' | sort -V | tail -1) || true
    fi
    echo "${ver:-dev}"
}

LSP_VER=$(lsp_infer_version)
log "Pinning ocaml-lsp packages from submodule at version $LSP_VER..."
opam pin add jsonrpc           "$LSP_VER" "$REPO_ROOT/ocaml-lsp" --no-action -y
opam pin add lsp               "$LSP_VER" "$REPO_ROOT/ocaml-lsp" --no-action -y
opam pin add ocaml-lsp-server  "$LSP_VER" "$REPO_ROOT/ocaml-lsp" --no-action -y

# ── 5. Install merlin and ocaml-lsp (provides ocamlmerlin + ocamllsp) ─────────

log "Installing merlin and ocaml-lsp-server (this takes a while on first run)..."
# --ignore-constraints-on is a safety valve: if version strings diverge between
# merlin and merlin-lib pins despite the above alignment, opam can still resolve.
opam install merlin ocaml-lsp-server -y \
    --ignore-constraints-on merlin-lib,dot-merlin-reader,ocaml-index
eval "$(opam env)"
log "ocamllsp:     $(ocamllsp --version)"
log "ocamlmerlin:  $(ocamlmerlin --version | head -1)"

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

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

# ── 4. Pin merlin from submodule ───────────────────────────────────────────────
#
# merlin.opam declares "merlin-lib" {= version}, so all packages must be pinned
# at the same version string.  We read the version that opam would infer for
# 'merlin' and then explicitly pass the same string to every other pin in the
# repo.  If git describe fails (no tags in the submodule clone), we fall back to
# the latest version in the opam repository.

# fetch_tags_if_missing REPO_DIR UPSTREAM_URL
# Fetches tags from the upstream if the submodule clone has none.
# Writes progress to stderr so it doesn't pollute command-substitution output.
fetch_tags_if_missing() {
    local dir="$1" upstream="$2"
    if ! git -C "$dir" describe --tags --abbrev=0 &>/dev/null; then
        echo "  No tags in $(basename "$dir") submodule — fetching from upstream..." >&2
        git -C "$dir" remote add upstream "$upstream" 2>/dev/null || true
        git -C "$dir" fetch --tags upstream 2>&1 | tail -3 >&2 || true
    fi
}

# infer_version REPO_DIR PACKAGE_NAME
# Prints the version string opam should use for a pin; falls back to the latest
# opam-registry version for PACKAGE_NAME if git describe still finds nothing.
infer_version() {
    local dir="$1" pkg="$2"
    local ver
    ver=$(git -C "$dir" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//') || true
    if [ -z "$ver" ]; then
        ver=$(opam info "$pkg" --field=all-versions 2>/dev/null \
                | tr ' ' '\n' | sort -V | tail -1) || true
    fi
    echo "${ver:-dev}"
}

fetch_tags_if_missing "$REPO_ROOT/merlin"    https://github.com/ocaml/merlin.git
fetch_tags_if_missing "$REPO_ROOT/ocaml-lsp" https://github.com/ocaml/ocaml-lsp.git

MERLIN_VER=$(infer_version "$REPO_ROOT/merlin"    merlin)
LSP_VER=$(infer_version    "$REPO_ROOT/ocaml-lsp" ocaml-lsp-server)

log "Pinning merlin packages at version $MERLIN_VER..."
# opam pin add syntax for an explicit version is PACKAGE.VERSION TARGET
opam pin add "merlin.$MERLIN_VER"            "$REPO_ROOT/merlin" --no-action -y
opam pin add "merlin-lib.$MERLIN_VER"        "$REPO_ROOT/merlin" --no-action -y
opam pin add "dot-merlin-reader.$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y
opam pin add "ocaml-index.$MERLIN_VER"       "$REPO_ROOT/merlin" --no-action -y \
    2>/dev/null || true

# ── 5. Pin ocaml-lsp from submodule ───────────────────────────────────────────

log "Pinning ocaml-lsp packages at version $LSP_VER..."
opam pin add "jsonrpc.$LSP_VER"          "$REPO_ROOT/ocaml-lsp" --no-action -y
opam pin add "lsp.$LSP_VER"              "$REPO_ROOT/ocaml-lsp" --no-action -y
opam pin add "ocaml-lsp-server.$LSP_VER" "$REPO_ROOT/ocaml-lsp" --no-action -y

# ocaml-lsp-server.opam upstream contains pin-depends that re-pin merlin-lib
# from GitHub main; our fork removes those, but re-assert our local pins here
# as a safety valve in case they were overridden.
opam pin add "merlin-lib.$MERLIN_VER"  "$REPO_ROOT/merlin" --no-action -y
opam pin add "ocaml-index.$MERLIN_VER" "$REPO_ROOT/merlin" --no-action -y

# ── 6. Install merlin and ocaml-lsp (provides ocamlmerlin + ocamllsp) ─────────

log "Installing merlin and ocaml-lsp-server (this takes a while on first run)..."
# --ignore-constraints-on is a safety valve: if version strings diverge between
# merlin and merlin-lib pins despite the above alignment, opam can still resolve.
opam install merlin ocaml-lsp-server -y \
    --ignore-constraints-on merlin-lib,dot-merlin-reader,ocaml-index
eval "$(opam env)"
log "ocamllsp:     $(ocamllsp --version)"
log "merlin:       $(opam info merlin --field=installed-version 2>/dev/null || echo 'unknown')"

# ── 7. Build the VSCode extension ─────────────────────────────────────────────

log "Installing JS dependencies for vscode-ocaml-platform..."
cd "$REPO_ROOT/vscode-ocaml-platform"
bun install --frozen-lockfile

log "Installing OCaml dependencies for vscode-ocaml-platform..."
opam install --deps-only --yes . 2>&1 | tail -5

log "Building vscode-ocaml-platform extension..."
make build

log "Packaging extension as .vsix..."
make pkg

# ── 8. Install the extension (requires 'code' CLI) ────────────────────────────

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

# ── 9. Build .cmt files for the demo project (ocaml-lsp submodule) ────────────
#
# We use the ocaml-lsp source tree as the demo project: it's already present,
# already has its dependencies installed (step 6 above), and is a good-sized
# real OCaml codebase.  'dune build @check' generates the .cmt files that
# ocamlgrep needs to search over.

log "Building .cmt files in demo project (ocaml-lsp)..."
cd "$REPO_ROOT/ocaml-lsp"
opam exec -- dune build @check 2>&1 | tail -10 || {
    echo "  WARNING: dune build @check had errors."
}

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

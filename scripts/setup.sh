#!/usr/bin/env bash
# setup.sh — Builds ocamlgrep-lib, ocaml-lsp, and the VSCode extension.
#
# Usage:
#   bash scripts/setup.sh [--from N]
#
# --from N  Skip all steps before step N (useful when re-running after a
#           partial failure).  Steps:
#   1  opam environment
#   2  bun
#   3  opam update          (slow, safe to skip on re-runs)
#   4  pin ocamlgrep-lib
#   5  pin ocaml-lsp
#   6  install packages     (slow)
#   7  build vscode extension
#   8  build .cmt files     (slow)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Parse --from argument ──────────────────────────────────────────────────────

START_FROM=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)    START_FROM="$2"; shift 2 ;;
        --from=*)  START_FROM="${1#--from=}"; shift ;;
        *)         echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

log() { echo ""; echo "==> $*"; }

should_run_step() {
    local n="$1"
    if [ "$n" -ge "$START_FROM" ]; then
        return 0  # true: run this step
    else
        log "Skipping step $n (--from $START_FROM)"
        return 1  # false: skip
    fi
}

# ── Always: set up opam env and PATH so skipped steps don't break later ones ──

unset OPAMSWITCH
eval "$(opam env)"
export PATH="$HOME/.bun/bin:$PATH"

# ── 1. Opam environment ────────────────────────────────────────────────────────

if should_run_step 1; then
    log "OCaml: $(ocaml --version)"
fi

# ── 2. Install bun ────────────────────────────────────────────────────────────

if should_run_step 2; then
    if ! command -v bun &>/dev/null; then
        log "Installing bun..."
        curl -fsSL https://bun.sh/install | bash
    fi
    log "bun: $(bun --version)"
fi

# ── 3. Refresh opam package index ─────────────────────────────────────────────

if should_run_step 3; then
    log "Pointing opam at the live package server..."
    opam repo set-url default https://opam.ocaml.org
    log "Updating opam package index..."
    opam update -y
fi

# ── 4. Pin ocamlgrep-lib from submodule ───────────────────────────────────────
# merlin-lib is available in the opam registry at 5.7.1-504 — no pin needed.

if should_run_step 4; then
    OCAMLGREP_VER=$(git -C "$REPO_ROOT/ocamlgrep" describe --tags --abbrev=0 \
        2>/dev/null | sed 's/^v//') || true
    log "Pinning ocamlgrep-lib..."
    if [ -n "$OCAMLGREP_VER" ]; then
        opam pin add "ocamlgrep-lib.$OCAMLGREP_VER" "$REPO_ROOT/ocamlgrep" --no-action -y
    else
        opam pin add ocamlgrep-lib "$REPO_ROOT/ocamlgrep" --no-action -y
    fi
fi

# ── 5. Pin ocaml-lsp from submodule ───────────────────────────────────────────

if should_run_step 5; then
    # Use the version from the local repo's git tag, not the registry's latest.
    LSP_VER=$(git -C "$REPO_ROOT/ocaml-lsp" describe --tags --abbrev=0 \
        2>/dev/null | sed 's/^v//') || LSP_VER='1.25.0'
    log "Pinning ocaml-lsp packages at version $LSP_VER..."
    opam pin add "jsonrpc.$LSP_VER"          "$REPO_ROOT/ocaml-lsp" --no-action -y
    opam pin add "lsp.$LSP_VER"              "$REPO_ROOT/ocaml-lsp" --no-action -y
    opam pin add "ocaml-lsp-server.$LSP_VER" "$REPO_ROOT/ocaml-lsp" --no-action -y
    git -C "$REPO_ROOT/ocaml-lsp" checkout -- . 2>/dev/null || true
fi

# ── 6. Install packages ────────────────────────────────────────────────────────

if should_run_step 6; then
    log "Installing ocamlgrep-lib and ocaml-lsp-server (this takes a while)..."
    opam install ocamlgrep-lib ocaml-lsp-server -y
    eval "$(opam env)"
    log "ocamllsp:      $(ocamllsp --version)"
    log "ocamlgrep-lib: $(opam info ocamlgrep-lib --field=installed-version 2>/dev/null || echo unknown)"
fi

eval "$(opam env)"

# ── 7. Build the VSCode extension ─────────────────────────────────────────────

if should_run_step 7; then
    log "Installing JS dependencies for vscode-ocaml-platform..."
    cd "$REPO_ROOT/vscode-ocaml-platform"
    bun install --frozen-lockfile

    log "Installing OCaml dependencies for vscode-ocaml-platform..."
    opam install --deps-only --yes . 2>&1 | tail -5

    log "Installing ocaml-lsp test dependencies (needed by dune describe workspace)..."
    opam install --deps-only --with-test --yes "$REPO_ROOT/ocaml-lsp" 2>&1 | tail -5
    opam install ppx_inline_test ppx_expect -y 2>&1 | tail -5

    log "Building vscode-ocaml-platform extension..."
    cd "$REPO_ROOT/vscode-ocaml-platform"
    make build

    log "Packaging extension as .vsix..."
    make pkg
fi

# ── 8. Build .cmt files ────────────────────────────────────────────────────────

if should_run_step 8; then
    log "Building .cmt files in demo project (ocaml-lsp)..."
    cd "$REPO_ROOT/ocaml-lsp"
    opam exec -- dune build @check 2>&1 | tail -10
fi

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

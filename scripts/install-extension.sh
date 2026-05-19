#!/usr/bin/env bash
# install-extension.sh — installs the built .vsix into the running VS Code.
# Called from devcontainer.json postAttachCommand, where the 'code' CLI may
# not be in PATH but is available somewhere under ~/.vscode-server/.

VSIX="/workspace/vscode-ocaml-platform/ocaml-platform.vsix"

if [ ! -f "$VSIX" ]; then
    echo "Extension not built yet (run scripts/setup.sh first)."
    exit 0
fi

# Find the 'code' CLI: try PATH first, then search the known VS Code server
# locations (/vscode/vscode-server is used by the devcontainer image;
# ~/.vscode-server is the default for Remote-SSH and older setups).
CODE=""
if command -v code &>/dev/null; then
    CODE="code"
else
    CODE=$(find /vscode/vscode-server "$HOME/.vscode-server" \
               -name "code" -type f 2>/dev/null | head -1)
fi

if [ -z "$CODE" ]; then
    echo ""
    echo "  NOTE: Could not find the 'code' CLI."
    echo "  Install the extension manually from inside VS Code:"
    echo "    code --install-extension $VSIX"
    exit 0
fi

echo "Installing OCaml Platform extension..."
"$CODE" --install-extension "$VSIX" --force
echo "Done. Reload the window (Ctrl+Shift+P → Developer: Reload Window) if needed."

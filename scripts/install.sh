#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_FILE="${BASE_DIR}/packages.txt"

if [ "$EUID" -ne 0 ]; then
    echo "⚠️  Please run as root (sudo)." >&2
    exit 1
fi

echo "--> Installing required system packages from packages.txt..."
if [ -f "$PKG_FILE" ]; then
    dnf update -y -q
    xargs -a "$PKG_FILE" dnf install -y -q
    echo "✅ Packages installed successfully."
fi

echo "--> Setting executable permissions..."
chmod +x "${BASE_DIR}/bin/"* "${BASE_DIR}"/*/*.sh 2>/dev/null || true

echo "--> Symlinking bin wrappers to /usr/local/bin..."
for file in "${BASE_DIR}/bin/"*; do
    if [ -f "$file" ]; then
        filename=$(basename "$file")
        ln -sf "$file" "/usr/local/bin/${filename}"
        echo "  Symlinked: /usr/local/bin/${filename}"
    fi
done

echo "✅ Setup complete. All management utilities are globally available!"

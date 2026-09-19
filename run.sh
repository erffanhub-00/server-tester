#!/usr/bin/env bash
# Server Tester - Quick Launch (Linux/macOS)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoProfile -File "$SCRIPT_DIR/ServerTester.ps1" "$@"
else
    echo "Error: PowerShell (pwsh) not found." >&2
    echo "Install from https://github.com/PowerShell/PowerShell" >&2
    exit 1
fi
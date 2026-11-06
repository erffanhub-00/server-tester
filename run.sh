#!/usr/bin/env bash
# Server Tester - Quick Launch (Linux/macOS)

set -e

if [ -z "${BASH_SOURCE[0]:-}" ]; then
    echo "Error: run this script with bash: bash run.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "Error: PowerShell (pwsh) not found." >&2
    echo "Install from https://github.com/PowerShell/PowerShell" >&2
    exit 1
fi

if ! pwsh -NoProfile -Command 'exit ([int]($PSVersionTable.PSVersion.Major -lt 7))'; then
    echo "Error: PowerShell 7 or later is required." >&2
    exit 1
fi

exec pwsh -NoProfile -File "$SCRIPT_DIR/ServerTester.ps1" "$@"

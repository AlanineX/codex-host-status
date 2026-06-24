#!/usr/bin/env bash
set -euo pipefail

prefix="${PREFIX:-${HOME}/.local}"
bin_dir="${prefix%/}/bin"
codex_home="${CODEX_HOME:-${HOME}/.codex}"

rm -f "$codex_home/host-status.sh"
rm -f "$bin_dir/codex-status"

if [ -f "$bin_dir/codex" ] && grep -q 'codex-status' "$bin_dir/codex" 2>/dev/null; then
    rm -f "$bin_dir/codex"
fi

printf 'Removed Codex host status wrapper files.\n'
printf 'If an original Codex binary was backed up during install, restore the matching %s/codex.bak.* file manually.\n' "$bin_dir"

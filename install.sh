#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prefix="${PREFIX:-${HOME}/.local}"
bin_dir="${prefix%/}/bin"
codex_home="${CODEX_HOME:-${HOME}/.codex}"

mkdir -p "$bin_dir" "$codex_home"

install -m 0755 "$repo_root/scripts/host-status.sh" "$codex_home/host-status.sh"
install -m 0755 "$repo_root/bin/codex-status" "$bin_dir/codex-status"

if [ "${CODEX_STATUS_INSTALL_WRAPPER:-1}" != "0" ]; then
    wrapper="$bin_dir/codex"
    if [ -e "$wrapper" ] && ! grep -q 'codex-status' "$wrapper" 2>/dev/null; then
        backup="${wrapper}.bak.$(date +%Y%m%d%H%M%S)"
        mv "$wrapper" "$backup"
        printf 'Backed up existing %s to %s\n' "$wrapper" "$backup"
    fi

    tmp=$(mktemp)
    {
        printf '#!/usr/bin/env bash\n'
        printf 'exec %q "$@"\n' "$bin_dir/codex-status"
    } > "$tmp"
    install -m 0755 "$tmp" "$wrapper"
    rm -f "$tmp"
fi

printf 'Installed Codex host status files:\n'
printf '  %s\n' "$codex_home/host-status.sh"
printf '  %s\n' "$bin_dir/codex-status"
if [ "${CODEX_STATUS_INSTALL_WRAPPER:-1}" != "0" ]; then
    printf '  %s\n' "$bin_dir/codex"
fi

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *)
        printf '\nAdd this to your shell rc file if codex still resolves to the old binary:\n'
        printf '  export PATH="%s:$PATH"\n' "$bin_dir"
        ;;
esac

printf '\nPreview:\n'
"$codex_home/host-status.sh" || true

printf '\nRestart your shell, or run: hash -r\n'
printf 'Then start Codex normally with: codex\n'

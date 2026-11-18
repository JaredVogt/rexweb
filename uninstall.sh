#!/bin/sh
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
config_file="${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}"
config="$(dirname "$config_file")"
appdir="${APPDIR:-$HOME/Applications}"
bindir="${PREFIX:-$HOME/.local}/bin"
cli="$bindir/rexweb"

if [ -x "$cli" ]; then
  if "$cli" links status 2>/dev/null | grep -q '^On'; then
    echo "putting your previous default browser back (macOS asks you to confirm)"
    "$cli" links off || echo "warning: couldn't restore your default browser. Choose one in System Settings > Desktop & Dock." >&2
  fi
  if command -v rex >/dev/null 2>&1; then
    "$cli" ls --json 2>/dev/null | jq -r '.panels[].id' 2>/dev/null | while read -r id; do
      rex block close "$id" >/dev/null 2>&1 || true
    done
  fi
fi

make -C "$here" uninstall APPDIR="$appdir" PREFIX="$(dirname "$bindir")" >/dev/null
rm -rf "$config/rexweb"
if [ -f "$config_file" ]; then
  sed -i '' -E "/require[[:space:]]*\(?[\"']rexweb[\"']/d" "$config_file"
fi
rex config reload >/dev/null 2>&1 || true

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/.rexweb" "$HOME/Library/WebKit/dev.coey.rexweb" "$HOME/Library/Caches/dev.coey.rexweb" \
    "$HOME/Library/HTTPStorages/dev.coey.rexweb" "$HOME/Library/Saved Application State/dev.coey.rexweb.savedState"
  rm -f "$config_file.before-rexweb"
  echo "removed rexweb, its settings, and its cookies and site data"
else
  echo "removed rexweb. Its settings, cookies, and site data are still in ~/.rexweb and ~/Library."
  echo "Run ./uninstall.sh --purge to delete them too."
fi

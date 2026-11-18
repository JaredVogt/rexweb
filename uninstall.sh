#!/bin/sh
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
config="${XDG_CONFIG_HOME:-$HOME/.config}/rex"

make -C "$here" uninstall
rm -rf "$config/rexweb"
if [ -f "$config/init.lua" ]; then
  sed -i '' '/require("rexweb")/d' "$config/init.lua"
fi
rex config reload >/dev/null 2>&1 || true

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$HOME/.rexweb" "$HOME/Library/WebKit/dev.coey.rexweb" "$HOME/Library/Caches/dev.coey.rexweb"
  echo "removed rexweb and its browser data"
else
  echo "removed rexweb (run with --purge to also delete its cookies and site data)"
fi

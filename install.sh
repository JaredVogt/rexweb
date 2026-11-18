#!/bin/sh
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
config_file="${REX_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/rex/init.lua}"
config="$(dirname "$config_file")"
appdir="${APPDIR:-$HOME/Applications}"
bindir="${PREFIX:-$HOME/.local}/bin"

fail() { echo "rexweb: $*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || fail "rexweb runs on macOS only."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 14 ] || fail "rexweb needs macOS 14 or later. This Mac has $(sw_vers -productVersion)."
xcode-select -p >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1 ||
  fail "rexweb needs the Xcode command line tools. Run: xcode-select --install, then run ./install.sh again."
command -v jq >/dev/null 2>&1 || fail "rexweb needs jq. Run: brew install jq"
command -v rex >/dev/null 2>&1 || fail "rexweb needs Rex and its rex command: https://www.superlogical.com/rex/docs/installation"
rex_bin="$(command -v rex)"
rex version >/dev/null 2>&1 || fail "$rex_bin doesn't run. Check your Rex install."

echo "building RexWeb.app"
make -C "$here" install APPDIR="$appdir" PREFIX="$(dirname "$bindir")" >/dev/null

mkdir -p "$HOME/.rexweb"
cfg="$HOME/.rexweb/config.json"
if [ -f "$cfg" ] && jq -e 'type == "object"' "$cfg" >/dev/null 2>&1; then
  tmp="$(mktemp)"; jq --arg b "$rex_bin" '.rex_bin = $b' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
elif [ -f "$cfg" ]; then
  echo "warning: $cfg isn't valid JSON, so rexweb ignores it. Fix it, then run ./install.sh again." >&2
else
  jq -n --arg b "$rex_bin" '{rex_bin: $b}' > "$cfg"
fi

mkdir -p "$config/rexweb"
sed "s|@APPDIR@|$appdir|" "$here/lua/init.lua" > "$config/rexweb/init.lua"

line='require("rexweb").setup{}'
if ! grep -Eqs "require[[:space:]]*\(?[\"']rexweb[\"']" "$config_file"; then
  [ -f "$config_file" ] && cp "$config_file" "$config_file.before-rexweb"
  printf '\n%s\n' "$line" >> "$config_file"
  if rex config check "$config_file" >/dev/null 2>&1 || ! rex config check --help >/dev/null 2>&1; then
    echo "added $line to $config_file"
  else
    if [ -f "$config_file.before-rexweb" ]; then cp "$config_file.before-rexweb" "$config_file"; fi
    fail "adding $line made $config_file invalid, so rexweb put it back. Add the line yourself, then run: rex config reload"
  fi
fi
rex config reload >/dev/null 2>&1 || echo "warning: rex config reload failed. Check $config_file with: rex config check" >&2

echo
case ":$PATH:" in
  *":$bindir:"*) "$bindir/rexweb" doctor || true ;;
  *)
    "$bindir/rexweb" doctor || true
    echo
    echo "$bindir isn't on your PATH. Add it with:"
    echo "  echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zprofile && export PATH=\"$bindir:\$PATH\""
    echo "Until then, run $bindir/rexweb"
    ;;
esac
echo
echo "rexweb is installed. Press Shift-Cmd-B in Rex, or run: rexweb open example.com"

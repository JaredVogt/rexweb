#!/bin/sh
set -eu

here="$(cd "$(dirname "$0")" && pwd -P)"
config="${XDG_CONFIG_HOME:-$HOME/.config}/rex"

for tool in swiftc jq curl rex; do
  command -v "$tool" >/dev/null 2>&1 || {
    case "$tool" in
      swiftc) echo "rexweb needs the Xcode command line tools. Run: xcode-select --install" >&2 ;;
      jq) echo "rexweb needs jq. Run: brew install jq" >&2 ;;
      rex) echo "rexweb needs Rex: https://www.superlogical.com/rex/docs/installation" >&2 ;;
      *) echo "rexweb needs $tool" >&2 ;;
    esac
    exit 1
  }
done

make -C "$here" install

mkdir -p "$config/rexweb"
cp "$here/lua/init.lua" "$config/rexweb/init.lua"

line='require("rexweb").setup{}'
if ! grep -qs 'require("rexweb")' "$config/init.lua"; then
  [ -f "$config/init.lua" ] && cp "$config/init.lua" "$config/init.lua.before-rexweb"
  printf '\n%s\n' "$line" >> "$config/init.lua"
  echo "added $line to $config/init.lua"
fi
rex config reload >/dev/null 2>&1 || true

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "note: add ~/.local/bin to PATH to use the rexweb command" ;;
esac

echo "rexweb is installed. Press Shift-Cmd-B in Rex, or run: rexweb open example.com"

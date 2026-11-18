# rexweb

Native WebKit browser panes for [Rex](https://www.superlogical.com/rex), the
terminal multiplexer by [Superlogical](https://www.superlogical.com).

Press `Shift-Cmd-B`. A browser pane opens beside the current pane. It's the
engine Safari uses, with an address bar, back, forward, and reload. It follows
its pane through splits, resizes, tabs, and zoom, and its title shows in the
pane's header. Agents drive the same pane from the command line.

```sh
rexweb open localhost:3000
rexweb snapshot          # [e1] link "Docs" -> /docs, [e2] button "Sign in", ...
rexweb click e2
rexweb type --submit 'input[name=email]' 'me@example.com'
rexweb screenshot ~/Desktop/after.png
```

## Install

rexweb needs macOS 14 or later, Rex, `jq`, and the Xcode command line tools.
From a checkout, run:

```sh
./install.sh
```

The installer builds `RexWeb.app` into `~/Applications`, links the `rexweb`
command into `~/.local/bin`, and adds `require("rexweb").setup{}` to
`~/.config/rex/init.lua`. Run it again to update.

## Usage

Press **`Shift-Cmd-B`** in Rex to open a browser pane. It's also in the command
palette as **Open Browser Pane** and **Open Browser Tab**, and on the command
line:

```sh
rexweb open github.com                  # beside this pane
rexweb open 5173 --split=below --ratio 40  # localhost:5173, below this pane
rexweb open --tab docs.rs               # in a new tab
rex do rexweb_open url=example.com      # the same action the shortcut runs
```

Close the pane like any Rex pane. In a browser pane:

| Key | Does |
| --- | --- |
| `Cmd-L` | Focus the address bar |
| `Cmd-R`, `Shift-Cmd-R` | Reload, or reload without the cache |
| `Cmd-[`, `Cmd-]` | Back, forward |
| `Cmd-+`, `Cmd--`, `Cmd-0` | Zoom in, out, reset |
| `Cmd-W` | Close the pane |
| `Ctrl-Opt-Arrow` | Move focus to the Rex pane in that direction |
| `Cmd`-click a link | Open it in a new browser pane |

Moving Rex's focus onto a browser pane gives it the keyboard. Right-click and
choose **Inspect Element** for Web Inspector.

## Agents

Every command that acts on a pane takes `-b BLOCK`: the pane's block ID, an ID
suffix, or its label. Without it, rexweb uses the browser pane you used most
recently. Most commands take `--json`.

| Command | Does |
| --- | --- |
| `rexweb ls` | List browser panes |
| `rexweb nav URL` | Go to URL and wait for it to load |
| `rexweb snapshot` | Print the interactive elements, numbered `e1`, `e2`, ..., and the page's text |
| `rexweb click TARGET` | Click `e3` or a CSS selector with a real mouse click |
| `rexweb type TARGET TEXT` | Type into a field, with `--clear` and `--submit` |
| `rexweb press KEY` | Press `enter`, `tab`, `escape`, an arrow, and so on |
| `rexweb eval JS` | Run JavaScript, `await` included, and print the result as JSON |
| `rexweb wait` | Wait for `--selector`, `--text`, or the page to load |
| `rexweb screenshot [PATH]` | Save a PNG of the page |

Run `rexweb COMMAND --help` for each command's options. The `rexweb` command
talks to `RexWeb.app` over HTTP on `127.0.0.1:18802`, so any program on your Mac
can use the same API.

## Signing in

Every browser pane shares one profile, kept between restarts, so you sign in to
a site once.

Passkeys and security keys don't work in rexweb. macOS offers them only to
browsers that Apple has approved with a special entitlement, and a build you
make yourself doesn't have it. On a single sign-on page that only offers a
passkey, the pane says the sign-in was cancelled or timed out.

Sign in with Chrome instead, then import the sign-in:

```sh
rexweb cookies import --domain example.com --reload
```

`--domain` limits the import to that domain and its subdomains. Repeat it for
each domain your sign-in uses, such as your identity provider's. Without it,
rexweb imports every cookie in your Chrome profile. The first import asks for
the **Chrome Safe Storage** key in your Keychain. Once your identity provider's
session is imported, other sites that sign in through it work without a passkey
until that session expires.

Sign-in popups, which use `window.open`, open in their own window so they can
report back to the page that opened them.

## Configure

Change the shortcut and where panes open in the `setup` call in
`~/.config/rex/init.lua`:

```lua
require("rexweb").setup{
  key = "shift+cmd+b",  -- false for no shortcut
  split = "right",      -- right, left, above, or below
  ratio = 0.5,          -- the browser pane's share of the split
  home = "",            -- the page a new pane opens; empty focuses the address bar
}
```

`~/.rexweb/config.json` sets the rest. Every key is optional:

```json
{
  "search_url": "https://duckduckgo.com/?q=%s",
  "port": 18802
}
```

If a pane doesn't line up with its Rex pane, adjust `top`, `left`, `right`,
`bottom`, `gap`, and `header`, in points, and restart RexWeb.

## How it works

Rex draws its panes itself and has no way to show a web page in one. So each
browser pane is a terminal pane running `rexweb-pane`, a small program that
holds the pane, with a borderless WebKit window from `RexWeb.app` laid exactly
over it.

RexWeb reads the layout from `rex api call session.view`, follows changes with
`rex events`, and finds the Rex window on screen. It keeps each browser window
directly above its Rex window, below every other app's windows, and hides it
when its tab isn't showing or another pane is zoomed. When you close the pane,
`rexweb-pane` exits and RexWeb closes the browser window.

Because the browser is a separate window from a separate app, clicking into it
makes RexWeb the active app, and Rex's title bar dims.

## Uninstall

```sh
./uninstall.sh          # keeps your cookies and site data
./uninstall.sh --purge  # deletes them too
```

## Acknowledgements

Thanks to [Superlogical](https://www.superlogical.com) for building Rex. Its Lua
configuration and open API made this project possible.

rexweb is a community project. Superlogical does not maintain or endorse it.

## License

MIT

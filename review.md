# Open items

Things left open after the tabs work and the move to a public fork. Written
2026-11-23. Tick an item off, or delete it, when it is done.

Background: [docs/EXTENSIONS.md](docs/EXTENSIONS.md) explains what the fork
adds, and [docs/tabs/PLAN.md](docs/tabs/PLAN.md) is the design record for
the tabs.

## Not yet checked with real input

These were built and read, but nobody has pressed the keys or clicked the
mouse. Scripted tests cannot make real key presses or modifier clicks.

- [ ] **Keyboard shortcuts.** `Cmd-T`, `Cmd-W`, `Ctrl-Tab`, `Ctrl-Shift-Tab`
  while a browser pane has the keyboard.
- [ ] **`Cmd-Q` quits Rex.** It used to quit the browser app. Confirm Rex
  comes forward and quits, in both a WebKit and a Chromium pane.
- [ ] **Saved tabs after quitting Rex.** Read, not run: the Rex server is a
  separate background process, so quitting Rex.app should leave the pane
  scripts (`bin/rexweb-pane`) running and the tabs in place. Quit Rex with
  tabs open and reopen it to confirm. A stop of the Rex server does end the
  scripts, and their exit handler then forgets the saved tabs, but those
  panes come back as plain shells either way.
- [ ] **Clicking the tab strip.** Select a tab, the close button on a tab,
  and the plus button.
- [ ] **Modifier clicks on links.** `Cmd`-click (background tab),
  `Cmd-Shift`-click (foreground tab), `Cmd-Opt`-click (pane beside). WebKit
  was checked by reading the code. Chromium was checked with clicks sent
  through the DevTools Protocol, and its `Cmd-Opt`-click path to a pane beside
  has never run.
- [ ] **A one-tab pane looks as it did before tabs.** A capture was taken
  after the first stage of the work, not after the later changes.
- [ ] **Unloading skips a tab with DevTools open (Chromium) or a popup open
  (WebKit).** The code is there; neither case was run.
- [ ] **WebKit scripted input on harder targets.** `click`, `type` and
  `press` now send events straight to the web view. That was tested on
  buttons, links, inputs and a plain `contenteditable`. Not tested: native
  `<select>` menus, file inputs, drag, and a real rich editor such as
  ProseMirror.
- [ ] **WebKit `press` while the address field has focus.** Before tabs, the
  key went to the address field. The change to event delivery may have fixed
  it; nobody re-checked.

## Known defects and gaps

- [ ] **The tab strip does not scroll.** The smallest tab is 44 points wide.
  Past about eight tabs in a 400 point pane, the rest are cut off under the
  plus button and cannot be clicked.
- [ ] **Idle CPU with several live WebKit tabs.** RexWeb measured 4 to 6% with
  three live tabs, against a target of about 3%. With one tab it was 1.5 to
  3%. Not investigated.
- [ ] **One 10 Hz poll per live Chromium tab.** `ChromiumEngine` runs a timer
  per engine. Before tabs that meant one per pane. Twenty live tabs give 200
  polls a second until the tabs are unloaded.
- [ ] **The off-screen check is stricter than Chromium needs.** `Core.swift`
  refuses `click`, `type` and `press` when the pane is off screen. Chromium
  takes input there without trouble. The check could be per engine.
- [ ] **Dialogs from background tabs.** An `alert`, a `confirm` or a file
  chooser from a background tab opens over the visible tab, with nothing to
  say which tab asked.
- [ ] **Chromium popups do not keep a tab loaded.** The unload check does not
  know about native popup windows in Chromium, so their opener can be
  unloaded.
- [ ] **WebKit misses `beforeunload` listeners.** The unload check sees
  `window.onbeforeunload` but not a handler added with `addEventListener`.
- [ ] **Older WebKit bugs, present before the fork's tab work.** `nav` can
  return before the page has loaded. `back` can hang for about 40 seconds.
  `html SELECTOR` can fail right after such a `nav`.

## Security and privacy

- [ ] **`_isPlayingAudio` is a private WebKit property.** The WebKit unload
  check reads it by name to keep a tab that is playing sound. It is the only
  signal that covers Web Audio and players inside cross-site frames, but a
  macOS update could remove it. Decide whether to keep it.

## Repo housekeeping

- [ ] **Test window picking after the upstream change.** `3f62eb0` and
  `1869542` ("Guess a window only for the session Rex focused last") were
  ported by hand into `Sources/Core.swift`; a cherry-pick no longer applies.
  A pane now takes an unlearned Rex window only if its session is the one
  Rex focused last. With two Rex windows, check that panes in the second
  window appear, and how soon, after `pkill -x RexWeb`.
- [ ] **Read the docs end to end.** `README.md`, `AGENTS.md` and
  `docs/EXTENSIONS.md` were written from the code and have not been read
  through by a person. In the "Problems found on the way" table of
  `docs/EXTENSIONS.md`, the rows on the background-tab screenshot and on
  non-web links describe the old symptom from a commit message, not from
  something seen.
- [ ] **Delete stale local branches and refs.** `feat/tabs`,
  `feat/cef-engine` and `feat/console-capture` are all contained in `fork`.
  The tag `backup/pre-rewrite-tabs` and `refs/original/*` hold the commits
  from before the author email was rewritten. None of these are on GitHub.

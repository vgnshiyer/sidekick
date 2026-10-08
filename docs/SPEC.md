# Sidekick v1 spec

This spec is read-only for build agents. If something is missing, report the gap; do not add features.

Sidekick is a native macOS desktop pet. It floats above all windows and keeps tabs on active coding-agent threads in **Claude Code** and **Codex**. A stack of speech bubbles above the pet shows one bubble per thread, and the stack scrolls. Clicking a bubble opens a small chat window. It shows the latest messages, has a box for sending a command into that same live thread, and has an **Open** button that jumps to the thread in its native UI. You can switch between pets.

## In v1

1. **Pet overlay.** The pet sits in a borderless, transparent, non-activating `NSPanel`.
   - Level `.floating`, collection behavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`. It never steals focus.
   - Clicks pass through everywhere except the pet's opaque pixels and the bubbles (cursor monitor toggles `ignoresMouseEvents`).
   - It can be dragged anywhere. Its position is remembered per display. The default is the bottom-left of the main screen, inset 24 pt.
2. **Pet sprite.** The pet comes from a Codex-format pet pack (see "Pet format").
   - Display size is 96x104 pt by default, an integer scale of the 48x52 art. The menu offers Small (48x52), Medium (96x104) and Large (144x156).
   - The animation follows the most urgent thread's status. While being dragged, the pet plays the run-left or run-right row.
3. **Bubble stack.** There is one bubble per active thread: a platform badge (Claude / Codex), the title, a status chip and a one-line subtitle (last assistant line or activity).
   - Sort order: Needs input > Failed > Ready > Running > Idle, then most recent first.
   - At most about 4 bubbles are visible. The rest scroll, with soft fade masks.
   - Hovering a bubble shows a small round **Open in {Terminal | Claude | Codex}** button at the end of its subtitle line. It jumps straight to the thread in its native UI without opening the chat.
   - Clicking the pet collapses or expands the stack. When collapsed, the pet shows a count badge of threads that need attention (Needs input + Failed + Ready).
4. **Chat window.** Clicking a bubble opens a second non-activating panel that *can* become key, so you can type without the terminal or IDE losing active-app status.
   - It shows the last ~20 user and assistant text messages and a "Reply to {title}" composer (Return sends, Shift+Return adds a newline).
   - It has an **Open in {Terminal | Claude | Codex}** button and inline send feedback: Sent / Queued / Copied.
   - Esc closes it. Opening it acknowledges the thread, which turns Ready into Idle.
5. **Claude provider** (terminal CLI, Claude.app Code tab, VS Code). See "Claude" below.
6. **Codex provider** (Codex CLI, Codex desktop app). See "Codex" below.
7. **Bridge server.** An HTTP/1.1 server on a Unix socket at `~/Library/Application Support/Sidekick/bridge.sock`, mode 0600, in a 0700 dir. It serves:
   - the Claude bridge mod: register, poll outbox, ack, turn events
   - the Codex hook script: hook events
   - the local CLI: list, send and open
8. **Claude bridge mod** `sidekick-bridge`. This is a Claude Code plugin.
   - It polls the bridge for this session's outbox and submits items with `$.prompt.submit({text, asUser: true})`.
   - It reports `turn.start` and `turn.complete`.
   - It stays silent when Sidekick isn't running.
9. **Codex hooks.** A stable script at `~/Library/Application Support/Sidekick/bin/codex-hook` forwards hook stdin to the bridge. `bridge/codex-hooks/` has a hooks.json template plus an installer that *merges* into `~/.codex/hooks.json`, with a backup. The installer runs only after the user approves it.
10. **Menu bar item.** Pets submenu with checkmark, Show/Hide Pet, Pet Size submenu, bridge status lines ("Claude bridge: N sessions connected", "Codex hooks: installed or not"), and Quit.
11. **`--demo` and `--snapshot <dir>` flags.**
    - `--demo` uses fake threads covering every status.
    - `--snapshot` renders the tray, the chat panel and each pet's rows to PNGs offscreen, then exits. Agents use it to check the visuals without Screen Recording permission.
12. **`sidekick-cli`.**
    - `list [--json]` and `messages <threadId>` run standalone through the providers.
    - `send <threadId> <text>` and `open <threadId>` go through the running app's bridge socket.

## Not in v1

Global hotkey; launch at login; sounds or notifications; voice; approving or denying permissions from the bubble; dismissing or swiping bubbles; settings window; OpenCode or other tools; cloud or remote sessions; keystroke injection into terminals; the Claude inbox socket (`/tmp/cc-socks`); Claude Channels or Remote Control; Codex app-server or daemon connections (`thread/resume`, `turn/start`) and the desktop IPC socket; showing Codex built-in pets; pet creation; auto-update.

## Status model

`ThreadStatus` values, in rank order:
- `needsInput`: waiting on a permission prompt, a question, or other input
- `failed`: the last turn errored
- `ready`: finished and not yet acknowledged
- `running`
- `idle`

Providers report raw status. `ThreadStore` turns `idle` into `ready` when `lastTurnEndedAt` is later than the thread's acknowledgement time. The default acknowledgement time is first-seen minus 15 min. Clicking a bubble, sending or opening acknowledges the thread.

Mapping to pet rows (Codex atlas):

| Status | Row | Playback |
|---|---|---|
| needsInput | `waiting` | 3 plays, repeated every ~8 s while it is still the top status |
| failed | `failed` | 3 plays |
| ready | `jumping` then `review` | 1 play of `jumping`, then 3 plays of `review` |
| running | `running` (the laptop row) | 3 plays, repeated every ~20 s |
| idle / none | `idle` | slow loop |

Interactions: hover over the pet plays `waving` once. Dragging plays `running-right` or `running-left`. If Reduce Motion is on, show frame 0 only.

## Claude

Do everything read-only. Never write under `~/.claude`.

- **Discover.** Read `~/.claude/sessions/<pid>.json`; only names matching `^\d+\.json$` count.
  - A session is alive only if `kill(pid,0)` succeeds and the trimmed `procStart` equals `LC_ALL=C TZ=UTC ps -o lstart= -p <pid>`. Cache that check per pid.
  - Keep `kind` interactive (or absent).
  - Dedupe by `hostSessionId`. Prefer the row that has a transcript and a `messagingSocketPath`. Desktop side-fork helpers have no transcript.
  - Never enumerate `/tmp/cc-socks`.
- **Transcript.** The path is `~/.claude/projects/<cwd with every non-alphanumeric char → '-'>/<sessionId>.jsonl`; fall back to a glob over the project dirs. Read the head once, then only a 256 KiB tail when the file's size or mtime changes.
- **Title.**
  1. last `custom-title.customTitle`
  2. last `ai-title.aiTitle`
  3. the registry `name` (desktop sessions, or when `nameSource == "user"`)
  4. `last-prompt.lastPrompt`
  5. the first real user prompt
  6. "New session"
- **Status.**
  - `waiting` with waitingFor "permission prompt" → needsInput, detail "Needs permission".
  - `waiting` with any other waitingFor → needsInput, detail "Waiting for you".
  - `busy` → running. On desktop, if the main-thread turn has ended, add the detail "Background work running".
  - `shell` → running, detail "Background task running".
  - `idle` → idle, or failed when the last assistant line is a synthetic API error (`isApiErrorMessage`).
  - `lastTurnEndedAt` is the timestamp of the last assistant `end_turn` after the last real user prompt.
- **Messages.** Use user prompts: string content or text blocks. Skip `isMeta`, `isSidechain`, tool_result, and strings starting with `<task-notification`, `<command-name>`, `<local-command-stdout>` or `<bash-input>`. Keep `origin.kind == "plugin"` prompts. Use assistant `text` blocks; iterate every block on every line.
- **Send.**
  - If the bridge mod for that session polled within the last 5 s, enqueue the message in `BridgeHub` and wait up to 15 s for the ack. The result is `.delivered`, or `.queued("Runs after the current turn")` while the session is busy.
  - Text starting with `/` can't be submitted by a plugin. So that text, and any session without a bridge, takes the fallback: copy to clipboard, run Open, and return `.copiedToClipboard`.
- **Open.**
  - desktop → `claude://code/continue?session=<hostSessionId>`
  - vscode → `vscode://anthropic.claude-code/open?session=<sessionId>`
  - cli → `TerminalFocus`, in this order:
    1. tmux: find the server through the claude process's ancestry, `select-window`/`select-pane`, then activate the terminal app hosting the tmux client
    2. the Terminal.app tab whose tty matches
    3. a Ghostty terminal whose working directory equals the cwd and whose title contains the thread title
    4. activate the GUI app among the claude process's ancestors

## Codex

Do everything read-only, except `codex queue`.

- **Discover.** Open `~/.codex/state_5.sqlite` (threads) and `thread_history_1.sqlite` (thread_turns) with `SQLITE_OPEN_READONLY`; never `immutable`, since the databases are live WAL. List non-archived threads that are updated within 24 h, or have a turn `inProgress`, or have a lock in `thread-writer-locks/`, or had a hook event within 24 h. Cap the list at 20, most recent first.
  - Surface: originator "Codex Desktop" → desktop; "codex-tui" or source "cli" → terminal; Cursor/VS Code originators → ide.
- **Status.**
  - needsInput if the latest hook event for the thread is `PermissionRequest` with no later `PostToolUse`, `Stop`, `UserPromptSubmit` or turn change.
  - running if a turn is `inProgress`.
  - failed if the last turn failed.
  - ready if the thread is in the desktop unread list (`.codex-global-state.json` → `electron-thread-read-state-v1.unreadByIdentity.*`, both the `local:` and `durable:` buckets), or by the ack rule.
  - idle otherwise.
- **Messages.** Tail the rollout JSONL: user messages and agent messages only.
- **Send.** `codex queue --thread <id> --message <text>`, using the newest codex binary: the desktop-bundled one under `/Applications/ChatGPT.app/Contents/Resources/codex-cli/` or Homebrew `codex`, whichever is newer. The result is `.queued("Runs when Codex is idle (up to ~10 s)")`. If the thread's last turn was interrupted, the result is `.queued("Paused in Codex — open to resume")` instead.
- **Open.** desktop → `codex://threads/<id>`; terminal → `TerminalFocus` by cwd (and by title if it contains the thread id); fallback `codex://threads/<id>`.
- **Never** start or connect to `codex app-server` or the daemon, call `thread/resume`, or touch `~/.codex/ipc`.

## Pet format

Pets use the Codex pets contract. Each pet is a folder `<id>/` containing `pet.json` and `spritesheet.png`.
- `pet.json` fields: `{id, displayName, description, spriteVersionNumber: 1, spritesheetPath: "spritesheet.png"}`.
- The atlas is 1536x1872: 8 columns x 9 rows of 192x208 cells. Unused cells are transparent.
- Rows, frames per row and timings (ms):

| Row | Name | Frames | Timing (ms) |
|---|---|---|---|
| 0 | idle | 6 | 280, 110, 110, 140, 140, 320; ×6 slower when looping |
| 1 | running-right | 8 | 120 each, last 220 |
| 2 | running-left | 8 | 120 each, last 220 |
| 3 | waving | 4 | 140 each, last 280 |
| 4 | jumping | 5 | 140 each, last 280 |
| 5 | failed | 8 | 140 each, last 240 |
| 6 | waiting | 6 | 150 each, last 260 |
| 7 | running (working at laptop) | 6 | 120 each, last 220 |
| 8 | review (happy/done) | 6 | 150 each, last 280 |

Art is drawn at 48x52 logical px and scaled x4 with nearest-neighbour. Pets load from these places:
- bundled `Sources/Sidekick/Resources/Pets/`
- `~/Library/Application Support/Sidekick/Pets/`
- `~/.codex/pets/` (read-only, user's own custom pets)

## Visual design

The bar is high: native macOS polish that fits macOS 26.
- **Bubbles.** Rounded, radius ~14. Use Liquid Glass via `.glassEffect` on macOS 26, falling back to `.regularMaterial`. Subtle shadow, about 300 pt wide.
  - Title: 13 pt semibold, one line.
  - Subtitle: 11.5 pt secondary, one line.
  - Status chip: colored dot plus label (amber Needs input, red Failed, green Ready, blue animated Running, gray Idle).
  - Platform badge: 18 pt, the app's own icon read at runtime from the installed app (Claude.app; Codex's cloud from ChatGPT.app's `app.icns`), never bundled. Without the app, a drawn circle: Claude orange #D97757 or Codex near-black, with a simple glyph.
  - The bubble nearest the pet has a small speech tail pointing at the pet.
  - Light and dark mode.
- **Chat panel.** About 360x440, same material.
  - Header: badge, title, status chip, close.
  - Subheader: folder · branch · surface.
  - Messages: user messages right-aligned with a tinted background, assistant messages as left-aligned plain markdown.
  - Composer at the bottom with a send button. The Open button sits in the footer.
- **Menu bar icon.** A template pawprint.

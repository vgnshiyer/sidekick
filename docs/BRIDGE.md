# Bridge protocol

HTTP/1.1 over the Unix socket `~/Library/Application Support/Sidekick/bridge.sock`. You can override the directory with `SIDEKICK_HOME`.
- The socket is mode 0600 and its directory is 0700 (created 0700 when missing).
- Every request and response body is JSON (`Content-Type: application/json`). The `Host` header is ignored.
- One request per connection: the server answers with `Connection: close` and closes.
- A body needs `Content-Length` and may be up to 1 MiB. A malformed request, a chunked body, a larger body, or a body without the fields a route needs gets 400 `{"error":"…"}`.
- Unknown routes, including a known path with another method, return 404 `{"error":"not found"}`.
- On start, if the socket file exists and something answers `GET /health`, the server refuses to start (`alreadyRunning`). Otherwise it removes the stale file. Stopping removes the socket.

## Claude bridge mod (`sidekick-bridge`)

| Route | Body | Response |
|---|---|---|
| `POST /claude/hello` | `{"sessionId","pid"?,"cwd"?,"surfaces"?}` | `{"ok":true}`; recorded as the event `session.start` |
| `GET /claude/poll?session=<sessionId>` | — | `204` when nothing is queued; `200 {"id","text"}` for the next item, which counts as taken |
| `POST /claude/ack` | `{"id","ok":bool,"error"?}` | `{"ok":true}` |
| `POST /claude/event` | `{"sessionId","kind":"turn.start"\|"turn.complete"\|"session.end"}` | `{"ok":true}`; any other kind is 400 |

The mod polls once per second. When the socket is unreachable, it backs off to once every 5 s and never shows an error to the user. Each poll marks the session as "bridge live" (see `BridgeHub.isClaudeBridgeLive`).

What the mod does:
- **Socket.** It reads `SIDEKICK_HOME` and `HOME` from the session's environment (`$.env.get`). It uses `$SIDEKICK_HOME/bridge.sock`, or else `$HOME/Library/Application Support/Sidekick/bridge.sock`.
- **Connecting.** It starts at `session.start` with a 1 s `$.clock.every`. Before polling a session id for the first time, and again after the socket was unreachable, it sends `hello`. A `/clear` changes the session id, so the next poll says hello for the new id.
- **Sending.** It submits each item with `$.prompt.submit({text, asUser: true})` and acks when that call settles:
  - `ok: true` when the call resolves;
  - `ok: false` with the reason when a hook drops the prompt or the call rejects. Text starting with `/` is always refused.
- **Events.** It reports `turn.start`, `turn.complete` (main loop only, not subagents) and `session.end` (including for `/clear`). It sends them only while the socket answers.
- **Silence.** It never draws, never logs, and never touches the model's context or tool calls. Every error is swallowed.
- **Network access.** It uses `$.http.fetch` with `socketPath`. Claude Code refuses that when the organisation's policy turns off web fetch (`allow_web_fetch`). The bridge then stays silent, and sends take the clipboard fallback.

### Delivery timing

Measured with Claude Code 2.1.288 in the terminal, and with the Claude.app-bundled 2.1.293 as a stream-json host.

`$.prompt.submit` queues the text as a turn of its own. It resolves only when that turn **starts**, so the ack never comes earlier than that:

| Session state | When the item is taken | When the ack arrives |
|---|---|---|
| Idle | At the next poll (0.3–0.7 s measured) | About 50 ms later, as its turn starts |
| Busy with a turn | At the next poll | When the running turn ends and the queued prompt's turn starts (about 25 ms after `turn.complete`) |
| Waiting on a permission dialog | At the next poll | Only after the user answers and that turn ends. The prompt never answers or dismisses the dialog. |

So a sender waiting up to 15 s sees one of these:
- `submitted`: the prompt is running.
- `taken` still: the prompt is queued behind the current turn and runs when it ends.
- `pending` still: no mod picked it up, so cancel the item.
- `failed`: refused, with the reason.

In the terminal the prompt appears under a dim "› Prompt from the sidekick-bridge plugin" line. The transcript stores it as a `type: "user"` line with string content and `origin: {"kind":"plugin","name":"sidekick-bridge","asUser":true}`. A stream-json host started with `--replay-user-messages` receives it as a `user` message with the same `origin`.

## Codex hooks

| Route | Body | Response |
|---|---|---|
| `POST /codex/hook` | the raw hook stdin JSON from Codex (`session_id`, `hook_event_name`, `cwd`, `tool_name`?, …) | `{"ok":true}` |

The server decodes the body into a `BridgeHub.CodexHookEvent` with these fields: `event` = `hook_event_name`, `threadId` = `session_id`, `toolName` = `tool_name`, `cwd`. A body without `session_id` or `hook_event_name` is 400.

The hook pieces:
- **`bridge/codex-hooks/codex-hook`** is a POSIX sh script, installed as `<Sidekick home>/bin/codex-hook`. It posts its stdin to `<Sidekick home>/bridge.sock`, found relative to its own path, with `curl -m 1`. It prints nothing and always exits 0, so Codex is never slowed or blocked, whether Sidekick runs or not.
- **`bridge/codex-hooks/hooks.json`** is the template (Codex 0.159 schema).
  - `UserPromptSubmit`, `PermissionRequest`, `PostToolUse`, `Stop` and `Interrupt` run with `"async": true`.
  - `SessionEnd` has no `async`, because Codex always runs it synchronously and warns at startup if it is marked async.
  - Every hook has a 3 s timeout, the cap for `SessionEnd` and `Interrupt`.
  - `@CODEX_HOOK@` stands for the installed script's single-quoted path. Codex runs commands through the user's `$SHELL -lc`.
- **`scripts/install-codex-hooks.sh`** copies the script and merges these hooks into `$CODEX_HOME/hooks.json`. It keeps every other hook, backs the file up first, and is safe to rerun. `--uninstall` reverses it. It never touches `config.toml` or `notify`.
- **Trust.** Codex runs new or changed hooks only after the user trusts them once, in Settings > Hooks in the app or `/hooks` in the CLI.

## Local CLI / app API (served only when the app passes a `SidekickAPI`; otherwise 503)

| Route | Body | Response |
|---|---|---|
| `GET /api/threads` | — | `{"threads":[AgentThread…]}` (ISO-8601 dates) |
| `GET /api/messages?thread=<id>&limit=N` | — | `{"messages":[ChatMessage…]}`; `limit` defaults to 20 |
| `POST /api/send` | `{"threadId","text"}` | `{"outcome":<SendOutcome JSON>,"message":"Sent"}` |
| `POST /api/open` | `{"threadId"}` | `{"ok":bool}` |
| `GET /health` | — | `{"ok":true,"app":"Sidekick"}` |

`SendOutcome` uses Swift's synthesized `Codable` form, e.g. `{"delivered":{}}` or `{"queued":{"_0":"Runs after the current turn"}}`. `message` is `SendOutcome.message`.

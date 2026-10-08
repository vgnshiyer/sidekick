import type { EngineInterface, HttpResponse, Register } from 'claude-code'

// The Sidekick bridge: polls the Sidekick app over its Unix socket for text queued for this
// session, submits it as the user's own prompt, and reports turn and session events.
// Protocol: docs/BRIDGE.md. It never draws, logs or touches the model's context, and stays
// silent while Sidekick is not running.

const POLL_MS = 1000
/** While the socket is unreachable, poll every 5 s instead of every second. */
const BACKOFF_POLLS = 5

type Item = { id: string; text: string }

let socketPath: string | undefined
let isReachable = false

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    socketPath = await bridgeSocketPath($)
    if (socketPath === undefined) return started

    let helloFor: string | undefined
    let skipPolls = 0
    let isPolling = false
    $.clock.every(POLL_MS, async () => {
      if (isPolling) return
      if (skipPolls > 0) {
        skipPolls -= 1
        return
      }
      isPolling = true
      try {
        const sessionId = await $.session.id()
        if (helloFor !== sessionId) {
          await hello($, sessionId)
          helloFor = sessionId
        }
        const item = await poll($, sessionId)
        isReachable = true
        if (item) submit($, item)
      } catch {
        isReachable = false
        helloFor = undefined
        skipPolls = BACKOFF_POLLS - 1
      } finally {
        isPolling = false
      }
    })
    return started
  })

  on('turn.start', ($, e, next) => {
    void report($, 'turn.start')
    return next(e)
  })

  on('turn.complete', ($, e, next) => {
    if (e.agentId === undefined) void report($, 'turn.complete')
    return next(e)
  })

  on('session.end', async ($, e, next) => {
    await report($, 'session.end', e.sessionId)
    return next(e)
  })
}

/** `$SIDEKICK_HOME/bridge.sock`, else `~/Library/Application Support/Sidekick/bridge.sock`. */
async function bridgeSocketPath($: EngineInterface): Promise<string | undefined> {
  const sidekickHome = await $.env.get('SIDEKICK_HOME')
  if (sidekickHome) return `${sidekickHome.replace(/\/+$/, '')}/bridge.sock`
  const home = await $.env.get('HOME')
  return home ? `${home.replace(/\/+$/, '')}/Library/Application Support/Sidekick/bridge.sock` : undefined
}

async function request($: EngineInterface, method: string, path: string, body?: object): Promise<HttpResponse> {
  if (socketPath === undefined) throw new Error('no Sidekick socket')
  return $.http.fetch(`http://sidekick${path}`, {
    method,
    socketPath,
    ...(body && { headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }),
  })
}

async function hello($: EngineInterface, sessionId: string) {
  const [cwd, surfaces] = await Promise.all([$.session.cwd(), $.session.surfaces()])
  await request($, 'POST', '/claude/hello', { sessionId, cwd, surfaces })
}

/** The next queued item for the session, which the bridge now counts as taken. */
async function poll($: EngineInterface, sessionId: string): Promise<Item | undefined> {
  const polled = await request($, 'GET', `/claude/poll?session=${encodeURIComponent(sessionId)}`)
  return polled.status === 200 ? parseItem(polled.text) : undefined
}

/** Submit as the user's own words; ack once Claude Code accepted it (its turn started) or refused it. */
function submit($: EngineInterface, item: Item) {
  $.prompt.submit({ text: item.text, asUser: true }).then(
    result => ack($, item.id, result.drop === undefined, result.drop),
    error => ack($, item.id, false, String(error).slice(0, 500)),
  )
}

async function ack($: EngineInterface, id: string, ok: boolean, error?: string) {
  try {
    await request($, 'POST', '/claude/ack', { id, ok, error })
  } catch {
    // Sidekick went away; it times the send out on its side.
  }
}

async function report($: EngineInterface, kind: string, sessionId?: string) {
  if (!isReachable) return
  try {
    await request($, 'POST', '/claude/event', { sessionId: sessionId ?? (await $.session.id()), kind })
  } catch {
    // Sidekick went away; the next poll notices.
  }
}

function parseItem(text: string): Item | undefined {
  try {
    const value: unknown = JSON.parse(text)
    if (typeof value !== 'object' || value === null) return undefined
    const { id, text: prompt } = value as Record<string, unknown>
    return typeof id === 'string' && typeof prompt === 'string' && prompt !== '' ? { id, text: prompt } : undefined
  } catch {
    return undefined
  }
}

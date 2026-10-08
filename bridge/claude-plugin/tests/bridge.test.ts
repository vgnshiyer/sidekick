import type { HttpInit, HttpResponse, On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

const SOCKET = '/Users/me/Library/Application Support/Sidekick/bridge.sock'
const START = { cwd: '/work', surface: 'terminal', isInteractive: true } as const

type Sent = { method: string; path: string; socketPath?: string; body?: Record<string, unknown> }

/** A fake Sidekick beneath the plugin: records requests and hands out `queue` on polls. */
function sidekick(on: On, queue: { id: string; text: string }[], isUp = () => true) {
  const sent: Sent[] = []
  const reply = (status: number, text = ''): { value: HttpResponse } => ({
    value: { status, ok: status < 300, headers: {}, text },
  })
  on('session.start', () => ({ cwd: '/work' }))
  on('session.id', () => ({ value: 'session-1' }))
  on('session.cwd', () => ({ value: '/work' }))
  on('session.surfaces', () => ({ value: ['terminal'] as const }))
  on('http.fetch', ($, e: { url: string; init?: HttpInit }) => {
    if (!isUp()) throw new Error('connect ENOENT')
    const url = new URL(e.url)
    sent.push({
      method: e.init?.method ?? 'GET',
      path: url.pathname + url.search,
      socketPath: e.init?.socketPath,
      body: e.init?.body ? JSON.parse(e.init.body) : undefined,
    })
    if (url.pathname !== '/claude/poll') return reply(200, '{"ok":true}')
    const item = queue.shift()
    return item ? reply(200, JSON.stringify(item)) : reply(204)
  })
  return sent
}

test('polls each second and submits queued text as the user', async ($, on) => {
  const clock = mock.clock(on)
  mock.env(on, { HOME: '/Users/me' })
  const sent = sidekick(on, [{ id: 'm1', text: 'run the tests' }])
  const submitted: { text: string; origin: unknown }[] = []
  on('prompt.submit', ($, e) => {
    submitted.push({ text: e.text, origin: e.origin })
    return { text: e.text }
  })

  await $.session.start(START)
  await clock.advance(1000)
  await clock.settle()

  expect(sent.map(s => `${s.method} ${s.path}`)).toEqual([
    'POST /claude/hello',
    'GET /claude/poll?session=session-1',
    'POST /claude/ack',
  ])
  expect(sent.every(s => s.socketPath === SOCKET)).toBe(true)
  expect(sent[0]?.body).toEqual({ sessionId: 'session-1', cwd: '/work', surfaces: ['terminal'] })
  expect(submitted).toEqual([{ text: 'run the tests', origin: expect.objectContaining({ kind: 'plugin', asUser: true }) }])
  expect(sent[2]?.body).toEqual({ id: 'm1', ok: true })

  await clock.advance(1000)
  expect(sent.map(s => s.path).at(-1)).toBe('/claude/poll?session=session-1')
  expect(sent.filter(s => s.path === '/claude/hello').length).toBe(1)
})

test('acks a refused prompt with the reason', async ($, on) => {
  const clock = mock.clock(on)
  mock.env(on, { HOME: '/Users/me' })
  const sent = sidekick(on, [{ id: 'm2', text: '/compact' }])
  on('prompt.submit', () => {
    throw new Error('would run a command as the user')
  })

  await $.session.start(START)
  await clock.advance(1000)
  await clock.settle()

  const ack = sent.find(s => s.path === '/claude/ack')
  expect(ack?.body?.id).toBe('m2')
  expect(ack?.body?.ok).toBe(false)
  expect(String(ack?.body?.error)).toContain('would run a command as the user')
})

test('backs off to every 5 s while Sidekick is down, and reconnects', async ($, on) => {
  const clock = mock.clock(on)
  mock.env(on, { SIDEKICK_HOME: '/tmp/sk/', HOME: '/Users/me' })
  let isUp = false
  let attempts = 0
  const sent = sidekick(on, [], () => {
    attempts += 1
    return isUp
  })

  await $.session.start(START)
  await clock.advance(11_000)
  expect(attempts).toBe(3) // at 1 s, 6 s and 11 s

  isUp = true
  await clock.advance(5000)
  expect(sent.map(s => s.path)).toEqual(['/claude/hello', '/claude/poll?session=session-1'])
  expect(sent[0]?.socketPath).toBe('/tmp/sk/bridge.sock')
})

test('reports main-loop turns and session end once connected', async ($, on) => {
  const clock = mock.clock(on)
  mock.env(on, { HOME: '/Users/me' })
  const sent = sidekick(on, [])
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('session.end', ($, e) => ({ sessionId: e.sessionId }))
  const turn = { answer: 'done', durationMs: 5, isAborted: false, reason: 'answer' } as const

  await $.turn.start({ text: 'before the bridge connected', turnId: 't0' })
  await $.session.start(START)
  await clock.advance(1000)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  await $.turn.complete({ ...turn, turnId: 't-sub', agentId: 'agent-1' })
  await $.turn.complete({ ...turn, turnId: 't1' })
  await $.session.end({ reason: 'prompt_input_exit', sessionId: 'session-1', resume: { id: 'session-1' } })
  await clock.settle()

  const events = sent.filter(s => s.path === '/claude/event').map(s => s.body)
  expect(events).toEqual([
    { sessionId: 'session-1', kind: 'turn.start' },
    { sessionId: 'session-1', kind: 'turn.complete' },
    { sessionId: 'session-1', kind: 'session.end' },
  ])
})

import { describe, expect, it } from 'vitest'
import { handleRemoteHttpStream } from '../src/http-stream.ts'
import type { TypertGatewayWireStream } from '../src/types.ts'

describe('Remote HTTP stream carrier', () => {
  it('streams item and end frames as NDJSON', async () => {
    const wire: TypertGatewayWireStream = {
      async open(endpoint, payload) {
        expect(endpoint).toBe('feed/sync')
        expect(payload).toEqual({ args: { label: 'native' } })
        return (async function *() {
          yield 'one'
          yield 'two'
        })()
      },
      failure: error => ({ code: 'internal', message: String(error), details: {} }),
    }
    const response = await handleRemoteHttpStream(wire, request({
      type: 'open',
      streamId: 'ios',
      endpoint: 'feed/sync',
      payload: { args: { label: 'native' } },
    }))

    expect(response.status).toBe(200)
    expect(response.headers.get('content-type')).toBe('application/x-ndjson; charset=utf-8')
    expect((await response.text()).trim().split('\n').map(line => JSON.parse(line))).toEqual([
      { type: 'item', streamId: 'ios', value: 'one' },
      { type: 'item', streamId: 'ios', value: 'two' },
      { type: 'end', streamId: 'ios' },
    ])
  })

  it('returns input failures before opening a stream', async () => {
    const wire: TypertGatewayWireStream = {
      open: () => { throw new Error('must not open') },
      failure: error => ({ code: 'internal', message: String(error), details: {} }),
    }
    const wrongType = await handleRemoteHttpStream(wire, new Request('http://dsh.invalid/api/remote.stream', {
      method: 'POST',
      headers: { 'content-type': 'text/plain' },
      body: '{}',
    }))
    expect(wrongType.status).toBe(415)

    const invalidJson = await handleRemoteHttpStream(wire, new Request('http://dsh.invalid/api/remote.stream', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: '{',
    }))
    expect(invalidJson.status).toBe(400)

    const malformed = await handleRemoteHttpStream(wire, request({ type: 'cancel', streamId: 'ios' }))
    expect(malformed.status).toBe(400)
  })

  it('maps stream failures into a terminal frame', async () => {
    const wire: TypertGatewayWireStream = {
      async open() {
        return (async function *(): AsyncIterable<never> {
          throw new Error('broken')
        })()
      },
      failure: () => ({ code: 'fixture/broken', message: 'broken', details: {} }),
    }
    const response = await handleRemoteHttpStream(wire, request({
      type: 'open',
      streamId: 'ios',
      endpoint: 'feed/reject',
      payload: { args: {} },
    }))
    expect(JSON.parse((await response.text()).trim())).toEqual({
      type: 'error',
      streamId: 'ios',
      error: { code: 'fixture/broken', message: 'broken', details: {} },
    })
  })

  it('aborts the logical stream when the HTTP reader cancels', async () => {
    const observed = Promise.withResolvers<undefined>()
    const wire: TypertGatewayWireStream = {
      async open(_endpoint, _payload, signal) {
        return (async function *() {
          try {
            yield 'ready'
            await new Promise<void>((resolve) => {
              if (signal.aborted) resolve()
              else signal.addEventListener('abort', () => { resolve() }, { once: true })
            })
            signal.throwIfAborted()
          } finally {
            expect(signal.aborted).toBe(true)
            observed.resolve(undefined)
          }
        })()
      },
      failure: error => ({ code: 'internal', message: String(error), details: {} }),
    }
    const response = await handleRemoteHttpStream(wire, request({
      type: 'open',
      streamId: 'ios',
      endpoint: 'feed/follow',
      payload: { args: {} },
    }))
    const reader = response.body!.getReader()
    expect((await reader.read()).done).toBe(false)
    await reader.cancel(new Error('native client backgrounded'))
    await observed.promise
  })
})

function request(body: unknown): Request {
  return new Request('http://dsh.invalid/api/remote.stream', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

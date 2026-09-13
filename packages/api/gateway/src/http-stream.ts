/** Authenticated HTTP carrier for one Gateway Remote stream. */

import type { TypertGatewayWireStream } from './types.ts'
import {
  parseRemoteStreamClientMessage,
  type RemoteStreamServerMessage,
} from './stream-protocol.ts'

const MEDIA_TYPE = 'application/x-ndjson; charset=utf-8'

/**
 * Open one Remote stream and encode its frames as newline-delimited JSON.
 * @param wire - carrier-independent Gateway stream dispatcher.
 * @param request - authenticated exact-route request.
 * @returns streaming response whose cancellation aborts the logical stream.
 */
export async function handleRemoteHttpStream(
  wire: TypertGatewayWireStream,
  request: Request,
): Promise<Response> {
  const mediaType = request.headers.get('content-type')?.split(';', 1)[0]?.trim().toLowerCase()
  if (mediaType !== 'application/json') {
    return new Response('content type must be application/json', { status: 415 })
  }
  let message
  try {
    message = parseRemoteStreamClientMessage(await request.text())
  } catch {
    return new Response('invalid Remote stream request', { status: 400 })
  }
  if (message.type !== 'open') {
    return new Response('HTTP Remote stream requires an open request', { status: 400 })
  }

  const lifetime = new AbortController()
  const signal = AbortSignal.any([request.signal, lifetime.signal])
  let done: Promise<void> = Promise.resolve()
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      done = pump(
        wire,
        message.streamId,
        message.endpoint,
        message.payload,
        signal,
        controller,
      )
    },
    async cancel(reason) {
      lifetime.abort(reason)
      await done
    },
  })
  return new Response(body, {
    headers: {
      'cache-control': 'no-store',
      'content-type': MEDIA_TYPE,
      'x-content-type-options': 'nosniff',
    },
  })
}

async function pump(
  wire: TypertGatewayWireStream,
  streamId: string,
  endpoint: string,
  payload: unknown,
  signal: AbortSignal,
  controller: ReadableStreamDefaultController<Uint8Array>,
): Promise<void> {
  const encoder = new TextEncoder()
  const send = (frame: RemoteStreamServerMessage): void => {
    controller.enqueue(encoder.encode(`${JSON.stringify(frame)}\n`))
  }
  try {
    const source = await wire.open(endpoint, payload, signal)
    for await (const value of source) {
      signal.throwIfAborted()
      send({ type: 'item', streamId, value })
    }
    send({ type: 'end', streamId })
  } catch (error) {
    if (!signal.aborted) {
      send({ type: 'error', streamId, error: wire.failure(error) })
    }
  } finally {
    if (!signal.aborted) controller.close()
  }
}

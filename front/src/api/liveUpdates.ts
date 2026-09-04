// Live updates client — wraps @rails/actioncable with a small Vue-friendly
// store-agnostic API. One shared Consumer (WebSocket) is opened at app
// start; each store subscribes to the streams it cares about and gets
// callbacks on every pushed message.
//
// This replaces the previous 5–30s polling. The back-end pushes model
// lifecycle events (created/updated/destroyed) over ActionCable whenever
// a record is written.

import { createConsumer, type Consumer } from '@rails/actioncable'

export type LiveStream = 'system' | 'agent_runs' | 'trades' | 'positions' | 'backtests' | 'config'

export interface LiveEvent<T = Record<string, unknown>> {
  event: 'created' | 'updated' | 'destroyed' | string
  model?: string
  record?: T
  id?: number
  [k: string]: unknown
}

type Listener = (ev: LiveEvent) => void

class LiveUpdatesClient {
  private consumer: Consumer | null = null
  private subscription: ReturnType<Consumer['subscriptions']['create']> | null = null
  private listeners = new Map<LiveStream, Set<Listener>>()
  private wsUrl: string

  constructor() {
    // Match the Vite dev-server proxy: the API is reachable at the same
    // host as the SPA, on the path Vite proxies /api and /cable to the
    // api container. In dev, this is ws://localhost:<vite-port>/cable.
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:'
    const host = window.location.host
    this.wsUrl = `${protocol}//${host}/cable`
  }

  start(): void {
    if (this.consumer) return
    this.consumer = createConsumer(this.wsUrl)

    // Subscribe to all five multiplexed streams. The channel's
    // #subscribed hook (see Rails app/channels/live_updates_channel.rb)
    // fans out to the named `live_updates:<stream>` ActionCable
    // streams. We listen on each.
    this.subscription = this.consumer.subscriptions.create(
      { channel: 'LiveUpdatesChannel' },
      {
        received: (data: LiveEvent | { stream: LiveStream; [k: string]: unknown }) => {
          // The Rails side transmits `{ stream, event, record, ... }` for
          // pushed updates. Filter on the stream field and fan out to
          // matching listeners.
          const stream = (data as { stream?: LiveStream }).stream
          if (!stream) return
          const ev = data as LiveEvent
          const set = this.listeners.get(stream)
          if (!set) return
          for (const fn of set) {
            try {
              fn(ev)
            } catch (e) {
              console.error('[live] listener error', e)
            }
          }
        },
        connected: () => console.log('[live] connected to', this.wsUrl),
        disconnected: () => console.log('[live] disconnected'),
      }
    )
  }

  subscribe(stream: LiveStream, fn: Listener): () => void {
    let set = this.listeners.get(stream)
    if (!set) {
      set = new Set()
      this.listeners.set(stream, set)
    }
    set.add(fn)
    return () => {
      set!.delete(fn)
    }
  }

  stop(): void {
    this.subscription?.unsubscribe()
    this.subscription = null
    this.consumer = null
    this.listeners.clear()
  }
}

export const liveUpdates = new LiveUpdatesClient()

// Global test setup — runs before every test file.
// Mounting naive-ui components needs the ResizeObserver polyfill and
// a few other DOM APIs that happy-dom doesn't fully implement.
import { vi } from 'vitest'

// ResizeObserver is referenced by NDataTable and others.
if (typeof globalThis.ResizeObserver === 'undefined') {
  globalThis.ResizeObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as any
}

// IntersectionObserver is used by some naive-ui lazy-render paths.
if (typeof globalThis.IntersectionObserver === 'undefined') {
  globalThis.IntersectionObserver = class {
    observe() {}
    unobserve() {}
    disconnect() {}
    takeRecords() { return [] }
    root = null
    rootMargin = ''
    thresholds = []
  } as any
}

// matchMedia is referenced by some responsive components.
if (typeof window !== 'undefined' && !window.matchMedia) {
  window.matchMedia = vi.fn().mockImplementation((query: string) => ({
    matches: false,
    media: query,
    onchange: null,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    addListener: vi.fn(),
    removeListener: vi.fn(),
    dispatchEvent: vi.fn()
  }))
}

// Stub global.fetch so any stray store action that triggers a real
// network call (e.g. when onMounted fires fetchAll before the test
// has a chance to stub it) gets a deterministic empty response
// instead of an ECONNREFUSED thrown into the store's error state.
// Per-test overrides should still go through `vi.spyOn(globalThis,
// 'fetch')` to assert specific requests.
const defaultFetchStub = vi.fn().mockImplementation(async (_url: string, _init?: RequestInit) => {
  // If a test wants to assert a real fetch was made it should stub
  // this. The default just returns an empty 200 so onMounted-driven
  // fetches don't error and clobber the test's manual `store.error`
  // assignments.
  return new Response(JSON.stringify([]), {
    status: 200,
    headers: { 'Content-Type': 'application/json' }
  })
})
// Always override — happy-dom defines a real fetch that tries to hit
// the network (and fails). We want our stub to win in tests.
;(globalThis as any).fetch = defaultFetchStub
;(globalThis.fetch as any).__isVitestStub = true
// Also patch the window-level fetch so any code that does
// `window.fetch(...)` gets the stub too.
if (typeof window !== 'undefined') {
  ;(window as any).fetch = defaultFetchStub
}

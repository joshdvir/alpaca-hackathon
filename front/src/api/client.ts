// Thin fetch wrapper for the Rails JSON API.
// Vite dev server proxies /api/* to the api service (see vite.config.ts).

const BASE = '/api'

export class ApiError extends Error {
  constructor(
    public status: number,
    public statusText: string,
    public body: unknown
  ) {
    super(`API ${status}: ${statusText}`)
    this.name = 'ApiError'
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { 'Content-Type': 'application/json' },
    ...init,
  })
  if (!res.ok) {
    const body = await res.text().catch(() => null)
    throw new ApiError(res.status, res.statusText, body)
  }
  // 204 No Content etc. — return undefined as T (callers handle)
  if (res.status === 204) return undefined as unknown as T
  return (await res.json()) as T
}

export const api = {
  get: <T>(path: string) => request<T>(path),
  // post / put / delete unused for this read-only API but kept for future
  post: <T>(path: string, body: unknown) =>
    request<T>(path, { method: 'POST', body: JSON.stringify(body) }),
}

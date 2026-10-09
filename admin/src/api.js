import { useEffect } from 'react'

// Admin PostgREST behind caddy at /api. The JWT comes from admin_api.setup/login and lives in localStorage.
const KEY = 'bc_admin_token'
export const token = {
  get: () => { try { return localStorage.getItem(KEY) } catch { return null } },
  set: (t) => { try { t ? localStorage.setItem(KEY, t) : localStorage.removeItem(KEY) } catch { /* private mode */ } },
}

export async function api(path, { method = 'GET', body, headers = {} } = {}) {
  const t = token.get()
  const r = await fetch(`/api/${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...(t ? { authorization: `Bearer ${t}` } : {}), ...headers },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await r.text()
  const data = text ? JSON.parse(text) : null
  if (!r.ok) {
    const err = new Error(data?.message || `HTTP ${r.status}`)
    err.status = r.status
    throw err
  }
  return data
}

export function usePoll(fn, ms, deps = []) {
  useEffect(() => {
    let alive = true
    const tick = () => { if (alive && document.visibilityState === 'visible') fn() }
    tick()
    const id = setInterval(tick, ms)
    return () => { alive = false; clearInterval(id) }
  }, deps) // eslint-disable-line react-hooks/exhaustive-deps
}

export const fmt = (ts) => (ts ? ts.slice(0, 16).replace('T', ' ') : '–')

import { useEffect, useState } from 'react'
import { api, fmt } from '../api.js'
import { Button, Card, Err, Input } from '../ui.jsx'

// Promo codes: a tester types the code in the app (Settings → Plan) and gets the plan for `days` days.
const EMPTY = { code: '', plan: 'pro', days: 30, max_uses: '', expires: '', note: '' }

function Create({ plans, onCreated, fail }) {
  const [v, setV] = useState(EMPTY)
  const [made, setMade] = useState(null)
  const set = (k) => (e) => setV({ ...v, [k]: e.target.value })
  const create = () => api('rpc/create_promo', { method: 'POST', body: {
    plan: v.plan, days: +v.days, max_uses: v.max_uses === '' ? null : +v.max_uses,
    expires_at: v.expires ? new Date(`${v.expires}T23:59:59`).toISOString() : null,
    note: v.note || null, code: v.code || null } })
    .then((rows) => { setMade(rows[0]); setV(EMPTY); onCreated() }).catch(fail)
  return (
    <Card title="New promo code">
      <div className="grid gap-3 text-sm md:grid-cols-3">
        <label>Plan it gives
          <select className="w-full rounded-md border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm" value={v.plan} onChange={set('plan')}>
            {plans.map((p) => <option key={p.id} value={p.id}>{p.id} ({p.posts_month} options, {p.images_month} pictures)</option>)}
          </select>
        </label>
        <label>For how many days<Input type="number" min="1" max="366" value={v.days} onChange={set('days')} /></label>
        <label>How many accounts may use it<Input type="number" min="1" placeholder="empty = no limit" value={v.max_uses} onChange={set('max_uses')} /></label>
        <label>Can be entered until<Input type="date" value={v.expires} onChange={set('expires')} /></label>
        <label>Your own code<Input placeholder="empty = made up for you" value={v.code} onChange={set('code')} /></label>
        <label>Note (who it is for)<Input value={v.note} onChange={set('note')} /></label>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-3">
        <Button onClick={create}>Create code</Button>
        {made && (
          <span className="text-sm text-zinc-300">Created: <b className="font-mono text-emerald-400">{made.code}</b>
            <Button kind="ghost" className="ml-2" onClick={() => navigator.clipboard?.writeText(made.code)}>Copy</Button>
          </span>
        )}
      </div>
      <p className="mt-2 text-xs text-zinc-500">The tester opens the app, Settings → Plan → "Promo code", types the code and gets the plan at once. When the days are over the account is on the free plan again by itself.</p>
    </Card>
  )
}

export default function Promo({ onUnauthorized, openUser }) {
  const [codes, setCodes] = useState([])
  const [used, setUsed] = useState([])
  const [plans, setPlans] = useState([])
  const [error, setError] = useState(null)
  const fail = (e) => (e.status === 401 ? onUnauthorized() : setError(e))
  const load = () => Promise.all([api('promo_codes?order=created_at.desc'), api('promo_redemptions?order=redeemed_at.desc&limit=200'), api('plans?order=price_cents')])
    .then(([c, r, p]) => { setCodes(c); setUsed(r); setPlans(p); setError(null) }).catch(fail)
  useEffect(() => { load() }, [])
  const toggle = (c) => api('rpc/set_promo_disabled', { method: 'POST', body: { code: c.code, disabled: !c.disabled } }).then(load).catch(fail)
  const state = (c) => (c.disabled ? 'stopped' : c.active ? 'active' : c.max_uses !== null && c.used >= c.max_uses ? 'used up' : 'date passed')
  return (
    <div className="space-y-4">
      <Err error={error} />
      <Create plans={plans} onCreated={load} fail={fail} />
      <Card title={`Codes (${codes.length})`}>
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-left text-xs text-zinc-500"><tr><th className="py-1">code</th><th>plan</th><th>days</th><th>used</th><th>enter until</th><th>note</th><th>state</th><th /></tr></thead>
            <tbody>
              {codes.map((c) => (
                <tr key={c.code} className="border-t border-zinc-800">
                  <td className="py-1.5 font-mono">{c.code}</td><td>{c.plan}</td><td>{c.days}</td>
                  <td>{c.used} / {c.max_uses ?? '∞'}</td><td className="text-zinc-400">{c.expires_at ? fmt(c.expires_at) : 'any time'}</td>
                  <td className="text-zinc-400">{c.note}</td>
                  <td className={c.active ? 'text-emerald-400' : 'text-zinc-500'}>{state(c)}</td>
                  <td className="text-right">
                    <Button kind="ghost" className="mr-2" onClick={() => navigator.clipboard?.writeText(c.code)}>Copy</Button>
                    <Button kind={c.disabled ? 'primary' : 'danger'} onClick={() => toggle(c)}>{c.disabled ? 'Allow again' : 'Stop'}</Button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Card>
      <Card title={`Who used a code (${used.length})`}>
        <table className="w-full text-sm">
          <thead className="text-left text-xs text-zinc-500"><tr><th className="py-1">code</th><th>user</th><th>entered</th><th>plan</th><th>until</th></tr></thead>
          <tbody>
            {used.map((r) => (
              <tr key={r.code + r.account_id} className="cursor-pointer border-t border-zinc-800 hover:bg-zinc-900" onClick={() => openUser(r.account_id)}>
                <td className="py-1.5 font-mono">{r.code}</td><td className="font-mono text-xs">{r.account_id.slice(0, 8)}</td>
                <td className="text-zinc-400">{fmt(r.redeemed_at)}</td><td>{r.plan}</td><td className="text-zinc-400">{fmt(r.plan_until)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>
    </div>
  )
}

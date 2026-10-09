import { useEffect, useState } from 'react'
import { api } from '../api.js'
import { Button, Card, Err, Input } from '../ui.jsx'

function Row({ p, onSaved, fail }) {
  const [v, setV] = useState(p)
  const save = () => api('rpc/update_plan', { method: 'POST', body: {
    id: p.id, images_month: +v.images_month, posts_month: +v.posts_month, images_per_post: +v.images_per_post } })
    .then(onSaved).catch(fail)
  const f = (k) => <Input value={v[k]} onChange={(e) => setV({ ...v, [k]: e.target.value })} />
  return (
    <tr className="border-t border-zinc-800"><td className="py-2 pr-2 font-semibold">{p.id}</td>
      <td className="pr-2">{f('images_month')}</td><td className="pr-2">{f('posts_month')}</td><td className="pr-2">{f('images_per_post')}</td>
      <td><Button onClick={save}>Save</Button></td></tr>
  )
}

export default function Plans({ onUnauthorized }) {
  const [plans, setPlans] = useState([])
  const [error, setError] = useState(null)
  const fail = (e) => (e.status === 401 ? onUnauthorized() : setError(e))
  const load = () => api('plans').then(setPlans).catch(fail)
  useEffect(() => { load() }, [])
  return (
    <Card title="Plans (monthly quota defaults)">
      <Err error={error} />
      <table className="w-full text-sm">
        <thead className="text-left text-xs text-zinc-500"><tr><th>plan</th><th>images / month</th><th>posts / month</th><th>images / post (1–3)</th><th /></tr></thead>
        <tbody>{plans.map((p) => <Row key={p.id} p={p} onSaved={load} fail={fail} />)}</tbody>
      </table>
    </Card>
  )
}

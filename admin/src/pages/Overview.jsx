import { useState } from 'react'
import { api, fmt, usePoll } from '../api.js'
import { Card, Err } from '../ui.jsx'

const Stat = ({ label, value }) => (
  <div className="rounded-lg bg-zinc-950 p-3"><div className="text-xs text-zinc-500">{label}</div><div className="text-xl font-semibold">{value ?? '–'}</div></div>
)

export default function Overview({ onUnauthorized }) {
  const [s, setS] = useState(null)
  const [failed, setFailed] = useState([])
  const [error, setError] = useState(null)
  usePoll(() => Promise.all([api('rpc/stats', { method: 'POST', body: {} }),
    api('jobs?status=eq.failed&order=id.desc&limit=20')])
    .then(([a, b]) => { setS(a); setFailed(b) })
    .catch((e) => (e.status === 401 ? onUnauthorized() : setError(e))), 5000)
  return (
    <div className="space-y-4">
      <Err error={error} />
      {s && (
        <Card title="Now">
          <div className="grid grid-cols-2 gap-2 md:grid-cols-4">
            <Stat label="accounts" value={s.accounts} /><Stat label="active 7 days" value={s.accounts_active_7d} />
            <Stat label="businesses" value={s.businesses} /><Stat label="posts total" value={s.posts_total} />
            <Stat label="posts 24 h" value={s.posts_24h} /><Stat label="images 24 h" value={s.images_24h} />
            <Stat label="jobs queued / running" value={`${s.jobs.queued || 0} / ${s.jobs.running || 0}`} />
            <Stat label="jobs failed 24 h" value={s.jobs_failed_24h} />
          </div>
          <p className="mt-3 text-xs text-zinc-500">avg seconds per step (24 h): {Object.entries(s.avg_job_s_24h).map(([k, v]) => `${k} ${v}`).join(' · ') || '–'}</p>
        </Card>
      )}
      <Card title="Recent failed jobs">
        <table className="w-full text-sm">
          <tbody>
            {failed.map((j) => (
              <tr key={j.id} className="border-t border-zinc-800">
                <td className="py-1.5 text-zinc-400">{fmt(j.finished_at)}</td><td>{j.kind}</td><td>×{j.attempts}</td>
                <td className="text-red-400">{j.error}</td>
              </tr>
            ))}
            {!failed.length && <tr><td className="py-2 text-zinc-500">none</td></tr>}
          </tbody>
        </table>
      </Card>
    </div>
  )
}

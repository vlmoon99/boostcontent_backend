import { useEffect, useState } from 'react'
import { api, fmt } from '../api.js'
import { Bar, Button, Card, Err, Input } from '../ui.jsx'
import PostCard from './PostCard.jsx'

function Quota({ a, onSaved, fail }) {
  const [img, setImg] = useState(a.images_month_override ?? '')
  const [posts, setPosts] = useState(a.posts_month_override ?? '')
  const save = () => api('rpc/set_quota', { method: 'POST', body: {
    account_id: a.id, images_month: img === '' ? null : +img, posts_month: posts === '' ? null : +posts } })
    .then(onSaved).catch(fail)
  return (
    <div className="space-y-2">
      <Bar label="images this month" value={a.images_used_month} max={a.images_month} />
      <Bar label="posts this month" value={a.posts_used_month} max={a.posts_month} />
      <div className="flex items-end gap-2 text-sm">
        <label className="flex-1">images / month override<Input value={img} placeholder={`plan: ${a.plan}`} onChange={(e) => setImg(e.target.value)} /></label>
        <label className="flex-1">posts / month override<Input value={posts} placeholder={`plan: ${a.plan}`} onChange={(e) => setPosts(e.target.value)} /></label>
        <Button onClick={save}>Save</Button>
      </div>
      <p className="text-xs text-zinc-500">Empty = the plan's default.</p>
    </div>
  )
}

function Detail({ id, back, fail }) {
  const [a, setA] = useState(null)
  const [biz, setBiz] = useState([])
  const [posts, setPosts] = useState([])
  const load = () => Promise.all([api(`accounts?id=eq.${id}`), api(`businesses?account_id=eq.${id}&order=created_at.desc`),
    api(`posts?account_id=eq.${id}&order=created_at.desc&limit=60`)])
    .then(([x, b, p]) => { setA(x[0]); setBiz(b); setPosts(p) }).catch(fail)
  useEffect(() => { load() }, [id])
  if (!a) return null
  const block = () => api('rpc/set_blocked', { method: 'POST', body: { account_id: id, blocked: !a.blocked } }).then(load).catch(fail)
  return (
    <div className="space-y-4">
      <Button kind="ghost" onClick={back}>← all users</Button>
      <Card title={<span className="font-mono text-sm">{a.id}</span>}
        right={<Button kind={a.blocked ? 'primary' : 'danger'} onClick={block}>{a.blocked ? 'Unblock' : 'Block'}</Button>}>
        <p className="mb-3 text-sm text-zinc-400">{a.is_anonymous ? 'guest' : 'signed in'} · joined {fmt(a.created_at)} · last seen {fmt(a.last_seen_at)}</p>
        <Quota a={a} onSaved={load} fail={fail} />
      </Card>
      <Card title={`Businesses (${biz.length})`}>
        {biz.map((b) => (
          <details key={b.id} className="border-t border-zinc-800 py-2 text-sm">
            <summary className="cursor-pointer"><b>{b.name}</b> <span className="text-zinc-500">{b.language} · {b.photos} photos · {b.posts} posts · profile {b.profile_status}{b.deleted_at ? ' · deleted' : ''}</span></summary>
            <p className="mt-1 text-zinc-400">{b.description}</p>
            {b.profile && <pre className="mt-2 overflow-x-auto rounded bg-zinc-950 p-2 text-xs text-zinc-300">{JSON.stringify(b.profile, null, 2)}</pre>}
          </details>
        ))}
      </Card>
      <Card title={`Posts (${posts.length})`}>
        <div className="grid gap-3 md:grid-cols-2 lg:grid-cols-3">{posts.map((p) => <PostCard key={p.id} p={p} />)}</div>
      </Card>
    </div>
  )
}

export default function Users({ onUnauthorized, userId, setUserId }) {
  const [rows, setRows] = useState([])
  const [error, setError] = useState(null)
  const fail = (e) => (e.status === 401 ? onUnauthorized() : setError(e))
  useEffect(() => { if (!userId) api('accounts?order=last_seen_at.desc&limit=500').then(setRows).catch(fail) }, [userId])
  if (userId) return <><Err error={error} /><Detail id={userId} back={() => setUserId(null)} fail={fail} /></>
  return (
    <Card title={`Users (${rows.length})`}>
      <Err error={error} />
      <div className="overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="text-left text-xs text-zinc-500"><tr><th className="py-1">user</th><th>last seen</th><th>businesses</th><th>posts</th><th>images (month)</th><th>posts (month)</th><th /></tr></thead>
          <tbody>
            {rows.map((a) => (
              <tr key={a.id} className="cursor-pointer border-t border-zinc-800 hover:bg-zinc-900" onClick={() => setUserId(a.id)}>
                <td className="py-1.5 font-mono text-xs">{a.id.slice(0, 8)}{a.is_anonymous ? ' (guest)' : ''}</td>
                <td className="text-zinc-400">{fmt(a.last_seen_at)}</td><td>{a.businesses}</td><td>{a.posts_total}</td>
                <td>{a.images_used_month} / {a.images_month}</td><td>{a.posts_used_month} / {a.posts_month}</td>
                <td className="text-red-400">{a.blocked ? 'blocked' : ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </Card>
  )
}

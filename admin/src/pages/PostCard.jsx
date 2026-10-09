import { fmt } from '../api.js'

export default function PostCard({ p }) {
  const tone = { ready: 'text-emerald-400', partial: 'text-amber-400', failed: 'text-red-400' }[p.status] || 'text-zinc-400'
  return (
    <div className="rounded-lg bg-zinc-950 p-3 text-sm">
      <div className="mb-2 flex justify-between text-xs"><span className={tone}>{p.status} · {p.language}</span><span className="text-zinc-500">{fmt(p.created_at)}</span></div>
      <div className="mb-2 grid grid-cols-3 gap-1">
        {p.images.map((i) => i.url
          ? <a key={i.position} href={i.url} target="_blank" rel="noreferrer"><img src={i.url} alt="" className="aspect-[4/5] w-full rounded object-cover" /></a>
          : <div key={i.position} className="flex aspect-[4/5] items-center justify-center rounded bg-zinc-900 text-xs text-zinc-500">{i.status}</div>)}
      </div>
      <p className="whitespace-pre-wrap text-zinc-200">{p.caption || <i className="text-zinc-500">no caption yet</i>}</p>
      {p.hashtags?.length > 0 && <p className="mt-1 text-xs text-sky-400">{p.hashtags.map((h) => `#${h}`).join(' ')}</p>}
      {p.error && <p className="mt-1 text-xs text-red-400">{p.error}</p>}
    </div>
  )
}

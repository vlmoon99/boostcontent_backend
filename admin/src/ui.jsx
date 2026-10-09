export const Card = ({ title, right, children }) => (
  <section className="rounded-xl border border-zinc-800 bg-zinc-900/60 p-4">
    {(title || right) && (
      <div className="mb-3 flex items-center justify-between gap-2">
        <h2 className="font-semibold text-zinc-200">{title}</h2>
        {right}
      </div>
    )}
    {children}
  </section>
)

export const Button = ({ kind = 'primary', className = '', ...p }) => {
  const k = {
    primary: 'bg-emerald-600 hover:bg-emerald-500 text-white',
    ghost: 'bg-zinc-800 hover:bg-zinc-700 text-zinc-200',
    danger: 'bg-red-700 hover:bg-red-600 text-white',
  }[kind]
  return <button className={`rounded-md px-3 py-1.5 text-sm disabled:opacity-40 ${k} ${className}`} {...p} />
}

export const Input = (p) => (
  <input className="w-full rounded-md border border-zinc-700 bg-zinc-950 px-3 py-2 text-sm outline-none focus:border-emerald-500" {...p} />
)

export const Bar = ({ value, max, label }) => {
  const pct = max ? Math.min(100, (100 * value) / max) : 0
  const tone = pct > 90 ? 'bg-red-500' : pct > 70 ? 'bg-amber-500' : 'bg-emerald-500'
  return (
    <div>
      <div className="mb-1 flex justify-between text-xs text-zinc-400"><span>{label}</span><span>{value ?? '–'} / {max ?? '–'}</span></div>
      <div className="h-2 rounded bg-zinc-800"><div className={`h-2 rounded ${tone}`} style={{ width: `${pct}%` }} /></div>
    </div>
  )
}

export const Err = ({ error }) => error ? <p className="text-sm text-red-400">{String(error.message || error)}</p> : null

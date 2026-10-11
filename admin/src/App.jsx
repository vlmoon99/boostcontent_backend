import { useEffect, useState } from 'react'
import { api, token } from './api.js'
import Auth from './pages/Auth.jsx'
import Overview from './pages/Overview.jsx'
import Users from './pages/Users.jsx'
import Posts from './pages/Posts.jsx'
import Plans from './pages/Plans.jsx'
import Promo from './pages/Promo.jsx'

const TABS = { Overview, Users, Posts, Plans, Promo }

export default function App() {
  const [state, setState] = useState(null)       // {setup_needed}
  const [authed, setAuthed] = useState(!!token.get())
  const [tab, setTab] = useState('Overview')
  const [userId, setUserId] = useState(null)
  useEffect(() => { api('rpc/state', { method: 'POST', body: {} }).then(setState).catch(() => setState({ setup_needed: false })) }, [])
  const logout = () => { token.set(null); setAuthed(false) }

  if (!state) return null
  if (!authed || state.setup_needed) {
    return <Auth setup={state.setup_needed} onDone={() => { setState({ setup_needed: false }); setAuthed(true) }} />
  }
  const Page = TABS[tab]
  const open = (id) => { setUserId(id); setTab('Users') }
  return (
    <div className="mx-auto max-w-6xl p-4">
      <header className="mb-4 flex flex-wrap items-center gap-2">
        <h1 className="mr-4 text-lg font-bold">BoostContent <span className="text-emerald-400">admin</span></h1>
        {Object.keys(TABS).map((t) => (
          <button key={t} onClick={() => { setTab(t); if (t !== 'Users') setUserId(null) }}
            className={`rounded-md px-3 py-1.5 text-sm ${t === tab ? 'bg-zinc-100 text-zinc-900' : 'text-zinc-300 hover:bg-zinc-800'}`}>{t}</button>
        ))}
        <button className="ml-auto text-sm text-zinc-400 hover:text-zinc-200" onClick={logout}>Log out</button>
      </header>
      <Page onUnauthorized={logout} userId={userId} setUserId={setUserId} openUser={open} />
    </div>
  )
}

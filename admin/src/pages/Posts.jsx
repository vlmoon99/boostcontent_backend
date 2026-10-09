import { useState } from 'react'
import { api, usePoll } from '../api.js'
import { Card, Err } from '../ui.jsx'
import PostCard from './PostCard.jsx'

export default function Posts({ onUnauthorized, openUser }) {
  const [posts, setPosts] = useState([])
  const [error, setError] = useState(null)
  usePoll(() => api('posts?order=created_at.desc&limit=60').then(setPosts)
    .catch((e) => (e.status === 401 ? onUnauthorized() : setError(e))), 10000)
  return (
    <Card title="Latest posts (all users)">
      <Err error={error} />
      <div className="grid gap-3 md:grid-cols-2 lg:grid-cols-3">
        {posts.map((p) => (
          <div key={p.id}>
            <button className="mb-1 font-mono text-xs text-zinc-500 hover:text-zinc-200" onClick={() => openUser(p.account_id)}>user {p.account_id.slice(0, 8)} →</button>
            <PostCard p={p} />
          </div>
        ))}
      </div>
    </Card>
  )
}

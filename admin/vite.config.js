import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// dev: `npm run dev` proxies /api to a running inf-admin (ADMIN_API, default the Spark's tailnet address)
export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: { proxy: { '/api': process.env.ADMIN_API || 'http://100.64.0.1:3200' } },
})

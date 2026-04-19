import { defineConfig } from 'vite'

export default defineConfig({
  base: './', // relative paths so it works from any server base
  server: {
    host: true,
    port: 5173,
  },
})

import { defineConfig } from 'vitest/config'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath } from 'node:url'

// Vitest config — runs in jsdom-like DOM via happy-dom so naive-ui
// components (NPopover, NTag, NDataTable) can mount. The same alias
// resolution as vite.config.ts so `@/` style paths (if added later)
// and relative paths to ../api work without per-test setup.
export default defineConfig({
  plugins: [vue()],
  test: {
    // happy-dom is lighter and faster than jsdom for Vue 3, and
    // supports the same API surface our components need.
    environment: 'happy-dom',
    globals: true,
    setupFiles: ['./src/test-setup.ts'],
    include: ['src/**/*.{test,spec}.{ts,tsx}'],
    // Vue SFCs use the `.vue` extension. Vite's vue plugin handles
    // them in test mode automatically; just make sure the resolve
    // config below is consistent.
    coverage: {
      provider: 'v8',
      reporter: ['text', 'html'],
      include: ['src/**/*.{ts,vue}'],
      exclude: ['src/**/*.spec.ts', 'src/**/*.test.ts', 'src/main.ts']
    }
  },
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url))
    }
  }
})

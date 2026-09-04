// Shared test helper — wraps @vue/test-utils mount with everything
// the views need: a fresh Pinia, a memory router, and naive-ui
// registered as a plugin so NDataTable, NTag, NPopover all resolve
// (without `app.use(naive)` the components fall back to literal
// `<n-data-table>` HTML and the assertions break).

import { mount, type MountingOptions } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'
import naive from 'naive-ui'

export interface TestMountOptions {
  /** Mounting options forwarded to @vue/test-utils (props, slots, etc). */
  props?: Record<string, any>
  /** Extra routes for the memory router. */
  routes?: Array<{ path: string; component: any }>
}

export function mountWithProviders(component: any, options: TestMountOptions = {}) {
  setActivePinia(createPinia())
  const router: Router = createRouter({
    history: createMemoryHistory(),
    routes: options.routes ?? [
      { path: '/', component: { template: '<div/>' } },
      { path: '/positions/:id', component: { template: '<div/>' } }
    ]
  })
  const wrapper = mount(component, {
    props: options.props,
    global: {
      plugins: [router, naive]
    }
  })
  return { wrapper, router }
}

// Pagination component tests — mount with naive-ui plugin, render
// in a known state, simulate Prev/Next/page clicks, verify the
// emitted payload matches the expected {page, per_page}.

import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import naive from 'naive-ui'
import Pagination from './Pagination.vue'

const mountPagination = (props: {
  state: { page: number; per_page: number; total: number; total_pages: number }
  loading?: boolean
}) =>
  mount(Pagination, {
    props,
    global: { plugins: [naive] }
  })

describe('Pagination', () => {
  it('renders the start..end range and total count', () => {
    const wrapper = mountPagination({
      state: { page: 2, per_page: 10, total: 35, total_pages: 4 }
    })
    // page 2, per_page 10 → start=11, end=20, total=35
    expect(wrapper.text()).toContain('11')
    expect(wrapper.text()).toContain('20')
    expect(wrapper.text()).toContain('35')
  })

  it('disables Prev on the first page', () => {
    const wrapper = mountPagination({
      state: { page: 1, per_page: 10, total: 35, total_pages: 4 }
    })
    const prev = wrapper.findAll('button').find((b) => b.text().includes('Prev'))!
    expect(prev.attributes('disabled')).toBeDefined()
  })

  it('disables Next on the last page', () => {
    const wrapper = mountPagination({
      state: { page: 4, per_page: 10, total: 35, total_pages: 4 }
    })
    const next = wrapper.findAll('button').find((b) => b.text().includes('Next'))!
    expect(next.attributes('disabled')).toBeDefined()
  })

  it('emits change with the next page when Next is clicked', async () => {
    const wrapper = mountPagination({
      state: { page: 2, per_page: 10, total: 35, total_pages: 4 }
    })
    const next = wrapper.findAll('button').find((b) => b.text().includes('Next'))!
    await next.trigger('click')
    expect(wrapper.emitted('change')).toBeTruthy()
    expect(wrapper.emitted('change')![0]).toEqual([{ page: 3, per_page: 10 }])
  })

  it('emits change with the previous page when Prev is clicked', async () => {
    const wrapper = mountPagination({
      state: { page: 2, per_page: 10, total: 35, total_pages: 4 }
    })
    const prev = wrapper.findAll('button').find((b) => b.text().includes('Prev'))!
    await prev.trigger('click')
    expect(wrapper.emitted('change')![0]).toEqual([{ page: 1, per_page: 10 }])
  })

  it('does not emit when clicking Prev on the first page', async () => {
    const wrapper = mountPagination({
      state: { page: 1, per_page: 10, total: 35, total_pages: 4 }
    })
    const prev = wrapper.findAll('button').find((b) => b.text().includes('Prev'))!
    expect(prev.attributes('disabled')).toBeDefined()
    await prev.trigger('click')
    expect(wrapper.emitted('change')).toBeFalsy()
  })

  it('hides itself when there are zero items (parent renders the empty state)', () => {
    const wrapper = mountPagination({
      state: { page: 1, per_page: 10, total: 0, total_pages: 0 }
    })
    // The component is hidden via v-if so the view's "No Data" row
    // is the only thing the user sees. We just verify no crash and
    // an empty body.
    expect(wrapper.text()).toBe('')
  })
})

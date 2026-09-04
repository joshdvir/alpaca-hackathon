// Term component tests — mount the component with @vue/test-utils,
// assert the visible label, the help icon, the override prop, and
// the popover's accessible attributes. We don't try to trigger
// hover/click programmatically because naive-ui's NPopover relies
// on a Teleport target that is finicky in happy-dom; instead we
// verify the trigger element exists and the aria-label is correct.

import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import naive from 'naive-ui'
import Term from './Term.vue'

// Use the full naive-ui plugin so NPopover, NIcon, etc. all
// register. Without this naive-ui components fall back to literal
// HTML tags in tests.
const mountTerm = (props: { k: string; label?: string; inline?: boolean }) =>
  mount(Term, {
    props,
    global: {
      plugins: [naive]
    }
  })

describe('Term', () => {
  it('renders the default label from the glossary for a known key', () => {
    const wrapper = mountTerm({ k: 'equity' })
    expect(wrapper.text()).toContain('Equity')
  })

  it('renders the override label when the `label` prop is provided', () => {
    const wrapper = mountTerm({ k: 'symbol', label: 'Stock Ticker' })
    expect(wrapper.text()).toContain('Stock Ticker')
    expect(wrapper.text()).not.toContain('Symbol')
  })

  it('renders the help icon (the ? svg) on every term', () => {
    const wrapper = mountTerm({ k: 'qty' })
    // The svg is inside the trigger and has the term__icon class
    const icon = wrapper.find('.term__icon')
    expect(icon.exists()).toBe(true)
  })

  it('falls back to a generated label for an unknown key', () => {
    const wrapper = mountTerm({ k: 'totally_made_up_key' })
    // The fallback humanizes snake_case to spaces
    expect(wrapper.text()).toContain('totally made up key')
  })

  it('sets an accessible aria-label on the outer term wrapper so the term is announced', () => {
    const wrapper = mountTerm({ k: 'delta' })
    const trigger = wrapper.find('.term')
    const aria = trigger.attributes('aria-label')
    expect(aria).toBeDefined()
    expect(aria).toContain('Delta')
  })

  it('is keyboard-focusable via the `?` icon (not the label) so the popover works without a mouse', () => {
    const wrapper = mountTerm({ k: 'unrealized_pl' })
    // The `?` icon wrap is the focusable / tooltip-trigger element.
    // The label is plain text — focusing the label would fire the
    // popover on every header hover and make the column-header row
    // visually underline the label, both of which the user pushed
    // back on.
    const icon = wrapper.find('.term__icon-wrap')
    expect(icon.exists()).toBe(true)
    expect(icon.attributes('tabindex')).toBe('0')
    expect(icon.attributes('role')).toBe('button')
  })

  it('does not put a cursor or focus on the label (only the `?` icon is the hover target)', () => {
    const wrapper = mountTerm({ k: 'unrealized_pl' })
    const label = wrapper.find('.term__label')
    expect(label.exists()).toBe(true)
    // The label should NOT be the focusable trigger — no tabindex,
    // no role, and definitely no `<a>`/`<button>` element wrapping
    // the text. (If the user later wants the label to be its own
    // clickable thing, that's a separate design choice.)
    expect(label.attributes('tabindex')).toBeUndefined()
    expect(label.attributes('role')).toBeUndefined()
  })

  it('applies the inline modifier when inline=true', () => {
    const wrapper = mountTerm({ k: 'cash', inline: true })
    expect(wrapper.find('.term--inline').exists()).toBe(true)
    expect(wrapper.find('.term--block').exists()).toBe(false)
  })

  it('applies the block modifier by default', () => {
    const wrapper = mountTerm({ k: 'cash' })
    expect(wrapper.find('.term--block').exists()).toBe(true)
  })
})

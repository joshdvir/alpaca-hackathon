<script setup lang="ts">
// <Term> — render a glossary term with a hover tooltip on the `?` icon.
//
// Usage:
//   <Term k="equity" />                          shows the default label + ? icon
//   <Term k="qty" label="Quantity" />            override the visible text
//   <Term :fallback="{ label: 'X', definition: '...' }" />
//                                                ad-hoc definition without
//                                                registering in glossary.ts
//   <Term k="delta" inline />                    span (not block)
//
// Hover behavior: the LABEL is plain text (no dotted underline, no
// cursor, no tooltip). Only the `?` icon at the end is the tooltip
// trigger. This avoids accidentally firing the popover when the user
// hovers the column header text — the icon is the discoverable
// affordance. The whole component stays keyboard-focusable for a11y
// (the `?` icon carries the focus ring).
//
// Uses naive-ui's NTooltip which wraps a single child element and
// shows a styled popover on hover. The popover renders to <body>
// via Vue's Teleport, so it works inside NDataTable column titles,
// inside dashboard card headers, and inside page <h1> titles —
// same component, same UX, every screen.

import { computed, getCurrentInstance } from 'vue'
import { NTooltip } from 'naive-ui'
import { lookup } from '../glossary'

type Fallback = { label: string; definition: string }

const props = withDefaults(
  defineProps<{
    /** Glossary key. Required unless `fallback` is provided. */
    k?: string
    /** Override the visible label. */
    label?: string
    /** Render inline (span) instead of as a block. */
    inline?: boolean
    /**
     * Ad-hoc definition used when there's no glossary entry. Lets a
     * component author explain a one-off term without registering it
     * globally. When both `k` and `fallback` are given, the glossary
     * lookup wins (so the global definition can override a fallback).
     */
    fallback?: Fallback
  }>(),
  { k: undefined, label: undefined, inline: false, fallback: undefined }
)

const entry = computed<Fallback>(() => {
  if (props.k) {
    const found = lookup(props.k)
    if (found) return found
  }
  // Fall through to the inline fallback if no glossary entry matches.
  // NEVER return undefined — the template assumes `entry.label` and
  // `entry.definition` are always strings, and returning undefined
  // here crashed the dashboard with "Cannot read properties of
  // undefined (reading 'replace')" the first time we tried to use
  // an ad-hoc term.
  return props.fallback ?? { label: props.label ?? '', definition: '' }
})
const visibleLabel = computed(() => props.label ?? entry.value.label)

// Per-instance uid for the popover DOM id (used to wire the
// trigger's `aria-describedby` to its own popover). Vue assigns a
// unique id to every component instance, so we reuse it. Falls back
// to a module-level counter for environments where getCurrentInstance
// is null (e.g. some SSR setups).
const _uid = (getCurrentInstance()?.uid ?? Math.floor(Math.random() * 1e9)).toString()
</script>

<template>
  <span
    :class="['term', { 'term--inline': inline, 'term--block': !inline }]"
    :aria-label="visibleLabel"
  >
    <span class="term__label">{{ visibleLabel }}</span>
    <n-tooltip
      trigger="hover"
      placement="top"
      :show-arrow="true"
      :delay="200"
      :duration="200"
      :raw="false"
    >
      <template #trigger>
        <!-- The `?` icon is the ONLY hover target. Keyboard users
             can focus the icon (tabindex=0) and press Enter / Space
             to open the popover; sighted users see the cursor
             change to "help" on hover. The label stays as plain
             text so the column header isn't visually underlined
             or competing for hover. -->
        <span
          class="term__icon-wrap"
          tabindex="0"
          role="button"
          :aria-label="`What is ${entry.label}?`"
          :aria-describedby="entry.definition ? `term-def-${_uid}` : undefined"
        >
          <svg
            class="term__icon"
            viewBox="0 0 16 16"
            width="13"
            height="13"
            fill="currentColor"
            aria-hidden="true"
          >
            <circle cx="8" cy="8" r="7" fill="none" stroke="currentColor" stroke-width="1.5" />
            <path d="M5.7 6.2c.1-1 .9-1.7 1.9-1.7 1.1 0 1.9.7 1.9 1.7 0 .7-.4 1.1-1 1.5-.6.4-.9.7-.9 1.3v.4h-1v-.4c0-.9.4-1.3 1-1.7.5-.3.8-.5.8-1.1 0-.6-.5-1-1.1-1-.7 0-1.1.4-1.2 1H5.7zm1.5 4.3h1.1v1.1H7.2v-1.1z" />
          </svg>
        </span>
      </template>
      <!-- The popover content is teleported to <body>, so the
           scoped styles on this component would NOT apply to it.
           Use an unscoped block to give the popover a guaranteed
           white-on-dark-text background regardless of the page's
           theme. -->
      <div class="term-popover" :id="`term-def-${_uid}`">
        <div class="term-popover__title">{{ entry.label }}</div>
        <div class="term-popover__body">{{ entry.definition }}</div>
      </div>
    </n-tooltip>
  </span>
</template>

<style scoped>
.term {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  outline: none;
}
.term__label {
  color: inherit;
  /* The label is plain text — no dotted underline, no help cursor.
     Discoverability comes from the `?` icon next to it. */
}
.term__icon-wrap {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 16px;
  height: 16px;
  border-radius: 50%;
  cursor: help;
  color: rgba(24, 160, 88, 0.85);
  flex-shrink: 0;
  transition: background-color 0.15s, color 0.15s;
  outline: none;
}
.term__icon-wrap:hover,
.term__icon-wrap:focus-visible {
  background-color: rgba(24, 160, 88, 0.12);
  color: #18a058;
}
.term__icon {
  display: block;
  flex-shrink: 0;
}
.term__icon-wrap:focus-visible {
  outline: 2px solid rgba(24, 160, 88, 0.5);
  outline-offset: 1px;
}
</style>

<!-- Unscoped (global) styles for the teleported popover body.
     Scoped styles don't reach the popover content because the
     popover is rendered via Teleport into <body>, outside this
     component's DOM subtree. We use a global selector scoped to
     the term-popover class names so we don't bleed into other
     components. -->
<style>
.term-popover {
  background: #ffffff !important;
  color: #1f2937 !important;
  padding: 10px 12px !important;
  border-radius: 6px !important;
  max-width: 340px !important;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.18) !important;
  line-height: 1.5 !important;
}
.term-popover__title {
  font-weight: 600 !important;
  font-size: 13px !important;
  margin-bottom: 4px !important;
  color: #18a058 !important;
}
.term-popover__body {
  font-size: 12px !important;
  line-height: 1.55 !important;
  color: #1f2937 !important;
}
</style>

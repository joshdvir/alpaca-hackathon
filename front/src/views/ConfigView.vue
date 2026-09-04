<script setup lang="ts">
// ConfigView — front-end editor for the trading.yml file.
//
// The view shows the current raw YAML in a CodeMirror editor with
// YAML syntax highlighting, lets the user edit and save, and stays
// in sync with the server via the `live_updates:config` ActionCable
// stream. When the file changes on disk (either through this editor
// or a deploy script), the server broadcasts a `reloaded` event and
// the editor refreshes — unless the user has unsaved local edits,
// in which case we show a banner so they can decide whether to keep
// their changes or accept the server's.

import { computed, onMounted, onUnmounted, ref, watch } from 'vue'
import { NButton, NSpace, NTag, NAlert, useMessage } from 'naive-ui'
import { useConfigStore } from '../stores/config'
import { liveUpdates } from '../api/liveUpdates'
import type { ConfigSnapshot } from '../stores/config'

// CodeMirror 6 + the YAML language pack. We import the umbrella
// `codemirror` for the core (state, view, commands, language, lint,
// search, autocomplete) and add `lang-yaml` for YAML syntax. The
// `yaml` package is used for a custom parse-error linter that marks
// invalid YAML in the gutter — without this, the user only learns
// the file is broken when they hit Save and the server 422s.
import { EditorState } from '@codemirror/state'
import { EditorView, keymap, lineNumbers, highlightActiveLine, drawSelection } from '@codemirror/view'
import { defaultKeymap, history, historyKeymap, indentWithTab } from '@codemirror/commands'
import { defaultHighlightStyle, syntaxHighlighting, indentOnInput, bracketMatching, foldGutter, foldKeymap } from '@codemirror/language'
import { lintGutter, linter, lintKeymap, type Diagnostic } from '@codemirror/lint'
import { yaml as yamlLang } from '@codemirror/lang-yaml'
import YAML from 'yaml'

const store = useConfigStore()
const message = useMessage()

const remoteRefreshBanner = ref(false)
const lastRemoteLoadedAt = ref<string | null>(null)

let unsubscribe: (() => void) | null = null
let editor: EditorView | null = null
// Track the last value WE pushed to the editor so a watch on
// `store.draft` can tell incoming-from-store updates apart from
// the editor's own onChange echoes (which would loop forever).
let lastEmitted = ''

async function refresh() {
  await store.fetch()
}

async function save() {
  try {
    await store.save()
    message.success('Config saved and reloaded')
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    // The store has already set `error`; surface it as a notice too
    // so the user sees the parse error inline.
    message.error(`Save failed: ${msg}`, { duration: 8000 })
  }
}

async function discard() {
  await store.discard()
  remoteRefreshBanner.value = false
  message.info('Local edits discarded')
}

async function acceptRemote() {
  // User chose to take the server's version over their local edits.
  if (store.config) {
    store.setDraft(store.config.raw_yaml)
  }
  remoteRefreshBanner.value = false
}

function onConfigEvent(payload: unknown) {
  if (!payload || typeof payload !== 'object') return
  const ev = payload as { event?: string; loaded_at?: string; config?: Record<string, unknown> }
  if (ev.event !== 'reloaded') return
  if (!ev.config) return
  // The server broadcast includes the parsed config + path + loaded_at
  // but NOT the raw yaml (which we may not want to ship over WS for
  // a 100KB file). We re-fetch the snapshot to get the raw yaml too.
  void reloadFromServer()
}

async function reloadFromServer() {
  const before = store.lastSavedAt
  await store.fetch()
  if (store.lastSavedAt && store.lastSavedAt !== before) {
    lastRemoteLoadedAt.value = store.lastSavedAt
    // If the user has unsaved local edits, show a banner.
    if (store.isDirty) {
      remoteRefreshBanner.value = true
    }
  }
}

// Custom linter: parse the document with the `yaml` package and
// report any syntax errors via the CodeMirror lint gutter. The
// server does the authoritative parse on save, but having a live
// underline saves a round trip and is much nicer to edit against.
function yamlLinter(view: EditorView): readonly Diagnostic[] {
  const text = view.state.doc.toString()
  if (text.trim() === '') return []
  try {
    YAML.parse(text)
    return []
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    // The `yaml` package's error messages don't include line/col
    // info in a structured way, so we mark the whole document with
    // a generic message. The server's save-time error has the real
    // position; this is a soft "this looks broken" hint.
    return [{
      from: 0,
      to: view.state.doc.length,
      severity: 'error',
      message: `YAML parse error: ${msg}`,
      source: 'yaml'
    }]
  }
}

onMounted(async () => {
  await refresh()

  const editorEl = document.getElementById('config-editor')
  if (!editorEl) return

  // Build the CodeMirror state. Re-creating the state on every
  // prop change would be wasteful — we mount once and dispatch
  // updates to the existing view.
  editor = new EditorView({
    state: EditorState.create({
      doc: store.draft,
      extensions: [
        lineNumbers(),
        foldGutter(),
        lintGutter(),
        history(),
        drawSelection(),
        indentOnInput(),
        bracketMatching(),
        highlightActiveLine(),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        yamlLang(),
        linter(yamlLinter),
        // Keep the editor's text in sync with the pinia store.
        EditorView.updateListener.of((update) => {
          if (update.docChanged) {
            const value = update.state.doc.toString()
            lastEmitted = value
            store.setDraft(value)
          }
        }),
        // Cmd/Ctrl-S to save (mirrors the Save button).
        keymap.of([
          { key: 'Mod-s', preventDefault: true, run: () => { void save(); return true } },
          indentWithTab,
          ...defaultKeymap,
          ...historyKeymap,
          ...foldKeymap,
          ...lintKeymap
        ]),
        EditorView.theme({
          '&': { fontSize: '12px' },
          '.cm-content': {
            fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, "Courier New", monospace'
          },
          '.cm-gutters': {
            backgroundColor: 'transparent',
            border: 'none'
          }
        })
      ]
    }),
    parent: editorEl
  })
  lastEmitted = store.draft

  // Subscribe to the config stream. The server broadcasts on every
  // reload (PATCH, watcher, or this same browser's save). Re-fetch
  // the full snapshot on every event so we get the raw yaml.
  unsubscribe = liveUpdates.subscribe('config', onConfigEvent)
})

onUnmounted(() => {
  unsubscribe?.()
  editor?.destroy()
  editor = null
})

// When the store's draft changes from OUTSIDE the editor (initial
// fetch, fetch after remote reload, acceptRemote, discard), push
// the new value into the editor. The `lastEmitted` guard skips the
// echoes from the editor's own updateListener.
watch(() => store.draft, (newDraft) => {
  if (!editor) return
  if (newDraft === lastEmitted) return
  if (editor.state.doc.toString() === newDraft) return
  editor.dispatch({
    changes: { from: 0, to: editor.state.doc.length, insert: newDraft }
  })
  lastEmitted = newDraft
})

const lineCount = computed(() => {
  // Cheap line counter for the editor footer; YAML editing tends
  // to be a few hundred lines, so this is fine on every keystroke.
  return store.draft.split('\n').length
})

const charCount = computed(() => store.draft.length)

const isDirty = computed(() => store.isDirty)
const lastSavedDisplay = computed(() => {
  if (!store.lastSavedAt) return 'never'
  try {
    return new Date(store.lastSavedAt).toLocaleString()
  } catch {
    return store.lastSavedAt
  }
})
</script>

<template>
  <div>
    <div style="display: flex; align-items: center; justify-content: space-between; margin-bottom: 16px;">
      <h1 class="page-title">Config</h1>
      <n-space>
        <n-button @click="refresh" :loading="store.loading" size="small" :disabled="store.saving">Refresh</n-button>
        <n-button @click="discard" size="small" :disabled="!isDirty || store.saving">Discard</n-button>
        <n-button
          @click="save"
          type="primary"
          size="small"
          :loading="store.saving"
          :disabled="!isDirty"
        >
          Save
        </n-button>
      </n-space>
    </div>

    <n-alert
      v-if="store.error"
      type="error"
      :title="store.error"
      closable
      style="margin-bottom: 16px;"
    />

    <n-alert
      v-if="remoteRefreshBanner"
      type="warning"
      title="Config reloaded on the server"
      style="margin-bottom: 16px;"
    >
      The file was changed elsewhere (or by the file watcher). You
      have unsaved local edits — keep them or take the server's
      version.
      <n-space style="margin-top: 8px;">
        <n-button size="small" @click="acceptRemote">Take server's version</n-button>
        <n-button size="small" @click="remoteRefreshBanner = false">Keep my edits</n-button>
      </n-space>
    </n-alert>

    <n-card v-if="store.config">
      <n-space style="margin-bottom: 12px;" align="center">
        <n-tag :type="isDirty ? 'warning' : 'success'" size="small" round>
          {{ isDirty ? 'unsaved' : 'clean' }}
        </n-tag>
        <span class="muted">Loaded from:</span>
        <code class="muted">{{ store.config.loaded_from }}</code>
        <span class="muted">·</span>
        <span class="muted">Last saved: {{ lastSavedDisplay }}</span>
      </n-space>

      <!--
        CodeMirror mounts into this div. We don't use a Vue wrapper
        component for it — direct EditorView construction gives us
        full control over the update loop with the pinia store and
        keeps the bundle lean (no extra wrapper package).
      -->
      <div
        id="config-editor"
        class="config-editor"
        :class="{ 'config-editor--disabled': store.saving }"
      />

      <div class="muted" style="margin-top: 8px;">
        {{ lineCount }} lines · {{ charCount }} chars
      </div>
    </n-card>

    <n-card v-else-if="!store.loading" style="margin-top: 16px;">
      <p>No config loaded yet. Click Refresh to fetch the current trading.yml.</p>
    </n-card>
  </div>
</template>

<style scoped>
.config-editor {
  border: 1px solid var(--n-border-color, #e0e0e0);
  border-radius: 4px;
  overflow: hidden;
  background: var(--n-color, #ffffff);
}
.config-editor--disabled {
  opacity: 0.6;
  pointer-events: none;
}
/* CodeMirror's default min-height on the scroller is small; pin it
   to something readable. The auto-size behavior is replaced with
   a fixed min/max so the editor doesn't grow unboundedly for big
   trading.yml files. */
.config-editor :deep(.cm-editor) {
  min-height: 480px;
  max-height: 70vh;
}
.config-editor :deep(.cm-scroller) {
  font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, "Courier New", monospace;
  font-size: 12px;
  line-height: 1.5;
}
</style>

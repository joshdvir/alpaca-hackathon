import { defineStore } from 'pinia'
import { api } from '../api/client'
import type { TradingConfigView } from '../api/types'

// Snapshot returned by GET /api/config. The front-end editor uses
// `raw_yaml` for the textarea and `config` for read-only summaries
// (e.g. "current max_open_positions: 3").
export interface ConfigSnapshot {
  config: Record<string, unknown>
  raw_yaml: string
  loaded_from: string
  loaded_at: string
}

export interface UpdateConfigResponse {
  ok: boolean
  loaded_from: string
  loaded_at: string
  config: Record<string, unknown>
}

export const useConfigStore = defineStore('config', {
  state: () => ({
    config: null as ConfigSnapshot | null,
    loading: false,
    saving: false,
    error: null as string | null,
    // Track the raw_yaml the user is currently editing so we can
    // detect "dirty" state vs the server snapshot.
    draft: '' as string,
    lastSavedAt: null as string | null,
  }),

  getters: {
    isDirty(state): boolean {
      return state.config != null && state.draft !== state.config.raw_yaml
    }
  },

  actions: {
    async fetch() {
      this.loading = true
      this.error = null
      try {
        this.config = await api.get<ConfigSnapshot>('/config')
        // Initialize the draft from the server snapshot the first
        // time we fetch, OR if the user has no unsaved changes.
        if (this.draft === '' || this.draft === this.config.raw_yaml) {
          this.draft = this.config.raw_yaml
        }
        this.lastSavedAt = this.config.loaded_at
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Unknown error'
      } finally {
        this.loading = false
      }
    },

    // Save the current draft. Throws on validation error so the
    // caller can show the server's error message inline.
    async save(): Promise<UpdateConfigResponse> {
      if (!this.config) throw new Error('Config not loaded yet')
      this.saving = true
      this.error = null
      try {
        const res = await api.patch<UpdateConfigResponse>('/config', {
          raw_yaml: this.draft
        })
        // Refresh the snapshot from the server response so the
        // "dirty" flag clears.
        this.config = {
          config: res.config as Record<string, unknown>,
          raw_yaml: this.draft,
          loaded_from: res.loaded_from,
          loaded_at: res.loaded_at
        }
        this.lastSavedAt = res.loaded_at
        return res
      } catch (e) {
        this.error = e instanceof Error ? e.message : 'Save failed'
        throw e
      } finally {
        this.saving = false
      }
    },

    // Replace the draft (called by the editor textarea). Does NOT
    // touch the server.
    setDraft(yaml: string) {
      this.draft = yaml
    },

    // Discard local edits and reload from the server.
    async discard() {
      if (this.config) {
        this.draft = this.config.raw_yaml
      } else {
        await this.fetch()
      }
    },

    // Called by the ActionCable live_updates:config handler when
    // the server-side file changes (reload, watcher, or another
    // editor session). Refreshes the snapshot and resets the draft
    // to the new content (so we don't blow away the user's edits
    // unless they opt in).
    async onRemoteReload(snapshot: ConfigSnapshot) {
      // Capture the previous server snapshot's raw yaml BEFORE we
      // overwrite `config` — that's what we compare the user's
      // draft against to decide if they have unsaved local edits.
      const previousRaw = this.config?.raw_yaml
      this.config = snapshot
      this.lastSavedAt = snapshot.loaded_at
      // If the user has no unsaved local edits (draft equals the
      // previous server snapshot, or draft is empty), mirror the
      // remote change into the draft so the editor reflects the
      // new file. If they DO have unsaved edits, leave the draft
      // alone — the ConfigView shows a banner asking what to do.
      if (this.draft === '' || (previousRaw != null && this.draft === previousRaw)) {
        this.draft = snapshot.raw_yaml
      }
    }
  }
})

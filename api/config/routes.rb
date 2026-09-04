# frozen_string_literal: true

Rails.application.routes.draw do
  # Liveness check (used by Docker healthcheck and load balancers)
  get 'up' => 'rails/health#show', as: :rails_health_check

  # No-op favicon. The api doesn't serve one; the front-end has its own.
  # Browsers auto-request /favicon.ico from any visited origin, so serve an
  # empty 204 to silence the routing error in the dev log.
  get '/favicon.ico', to: ->(_env) { [204, { 'Content-Type' => 'image/x-icon' }, ['']] }

  # ActionCable WebSocket mount. The front-end opens a single connection
  # to /cable and subscribes to one or more live streams via the
  # LiveUpdatesChannel (see app/channels/live_updates_channel.rb).
  mount ActionCable.server => '/cable'

  # JSON API for the Vue front-end
  namespace :api do
    get 'dashboard', to: 'dashboard#show'

    resources :positions, only: %i[index show]
    resources :orders,    only: %i[index show]
    resources :research,  only: [:index]
    resources :agent_runs, only: %i[index show] do
      collection do
        get :distinct, action: :distinct
      end
    end

    get  'system/health',      to: 'system#health'
    get  'rate_limits/stats',  to: 'rate_limits#stats'

    resources :watchlist, only: [:index] do
      collection do
        get :recommendations
      end
    end

    resources :backtests, only: %i[index show create] do
      member do
        get  :trades
        get  :status
        post :cancel
      end
    end

    get   'config',        to: 'config#show'
    patch 'config',        to: 'config#update'
    post  'config/reload', to: 'config#reload'

    # Live mirror of the Alpaca account + positions + open orders.
    # The data here is refreshed every 30s by AlpacaMirrorJob; this
    # endpoint is a read-through cache, not a live broker call.
    get   'account',       to: 'account#show'
    post  'account/refresh', to: 'account#refresh'
  end
end

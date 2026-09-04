import { createRouter, createWebHistory, type RouteRecordRaw } from 'vue-router'

const routes: RouteRecordRaw[] = [
  {
    path: '/',
    name: 'dashboard',
    component: () => import('../views/DashboardView.vue'),
  },
  {
    path: '/positions',
    name: 'positions',
    component: () => import('../views/PositionsView.vue'),
  },
  {
    path: '/positions/:id',
    name: 'position-detail',
    component: () => import('../views/PositionDetailView.vue'),
    props: true,
  },
  {
    path: '/orders',
    name: 'orders',
    component: () => import('../views/OrdersView.vue'),
  },
  {
    path: '/watchlist',
    name: 'watchlist',
    component: () => import('../views/WatchlistView.vue'),
  },
  {
    path: '/research',
    name: 'research',
    component: () => import('../views/ResearchView.vue'),
  },
  {
    path: '/agents',
    name: 'agent-runs',
    component: () => import('../views/AgentRunsView.vue'),
  },
  {
    path: '/system',
    name: 'system',
    component: () => import('../views/SystemView.vue'),
  },
  {
    path: '/config',
    name: 'config',
    component: () => import('../views/ConfigView.vue'),
  },
  {
    path: '/backtests',
    name: 'backtests',
    component: () => import('../views/BacktestsView.vue'),
  },
  {
    path: '/backtests/:id',
    name: 'backtest-detail',
    component: () => import('../views/BacktestDetailView.vue'),
    props: true,
  },
]

const router = createRouter({
  history: createWebHistory(),
  routes,
})

export default router

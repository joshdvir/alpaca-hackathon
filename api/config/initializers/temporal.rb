# frozen_string_literal: true

# Temporal client + workflow + activity shorthands.
# Loaded once at boot; everything else references T_CLIENT / T_WORKFLOW.

require 'temporalio/client'
require 'temporalio/worker'
require 'temporalio/workflow'
require 'temporalio/activity'

TEMPORAL_NAMESPACE  = ENV.fetch('TEMPORAL_NAMESPACE',  'default')
TEMPORAL_ADDRESS    = ENV.fetch('TEMPORAL_ADDRESS',    'temporal:7233')
TEMPORAL_TASK_QUEUE = ENV.fetch('TEMPORAL_TASK_QUEUE', 'trading-queue')

T_CLIENT = Temporalio::Client.connect(
  TEMPORAL_ADDRESS,
  TEMPORAL_NAMESPACE
)

# Shorthands used by workflows, activities, and workers
T_WORKFLOW  = Temporalio::Workflow
T_ACTIVITY  = Temporalio::Activity
T_WORKER    = Temporalio::Worker
T_FUTURE    = Temporalio::Workflow::Future

# Common bases used by ApplicationActivity / ApplicationWorkflow / ApplicationWorker
T_ACTIVITY_DEF = Temporalio::Activity::Definition
T_ACTIVITY_CTX = Temporalio::Activity::Context
T_WORKFLOW_DEF = Temporalio::Workflow::Definition

T_RETRY_POLICY = Temporalio::RetryPolicy.new(
  max_attempts: 3
)

# Search attributes for filtering/list_workflows queries.
# Ticker is set on every per-ticker workflow start so we can do
# `WorkflowType = 'ProcessTickerWorkflow' AND Ticker = 'SPY'`.
TickerKey = Temporalio::SearchAttributes::Key.new(
  'Ticker',
  Temporalio::SearchAttributes::IndexedValueType::KEYWORD
)

WorkflowKindKey = Temporalio::SearchAttributes::Key.new(
  'WorkflowKind',
  Temporalio::SearchAttributes::IndexedValueType::KEYWORD
)

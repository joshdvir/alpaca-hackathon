# frozen_string_literal: true

# ApplicationWorkflow is the base class for all Temporal workflows.
# Subclasses override #execute. The intent is symmetry with ApplicationActivity
# and ApplicationWorker so a developer can spot the conventions at a glance.

class ApplicationWorkflow < T_WORKFLOW_DEF
  def execute(...)
    raise NotImplementedError, "#{self.class} must implement #execute"
  end

  # Workflows use `activity.logger.info(...)` to stay symmetric with
  # ApplicationActivity (where `activity` is the Temporal activity
  # context). In a workflow there's no activity context, so this
  # returns a thin shim whose `.logger` is the workflow-scoped
  # `T_WORKFLOW.logger` — which auto-appends workflow context and
  # skips replay. New code can use `T_WORKFLOW.logger` directly.
  def activity
    @activity ||= WorkflowActivityShim.new
  end
end

# Tiny shim so existing `activity.logger.*` call sites in workflow
# files work without rewrites. `logger` is memoized per-shim (cheap)
# and re-resolves `T_WORKFLOW.logger` lazily so it always reflects the
# current workflow's scoped logger.
class WorkflowActivityShim
  def logger
    T_WORKFLOW.logger
  end
end

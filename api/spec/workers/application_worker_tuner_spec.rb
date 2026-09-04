# frozen_string_literal: true

require "rails_helper"

# Tests for the per-class Tuner configuration API on ApplicationWorker
# and its concrete subclasses. The Tuner caps how many workflows /
# activities / local activities a worker polls in parallel from a task
# queue. The source of truth is the worker class's `tuner_settings`
# method (returns a Hash). bin/worker reads that hash and builds the
# Tuner. Base class provides the default; subclasses override (or
# `super.merge(...)`) to tune.
RSpec.describe "Worker Tuner configuration" do
  describe ApplicationWorker, ".tuner_settings" do
    it "returns a Hash with the three slot keys" do
      defaults = ApplicationWorker.tuner_settings
      expect(defaults).to include(:workflow_slots, :activity_slots, :local_activity_slots)
    end

    it "uses conservative defaults that subclasses can inherit" do
      defaults = ApplicationWorker.tuner_settings
      expect(defaults[:workflow_slots]).to be_a(Integer)
      expect(defaults[:activity_slots]).to be_a(Integer)
      expect(defaults[:local_activity_slots]).to be_a(Integer)
    end
  end

  describe TradingWorkflowsWorker, ".tuner_settings" do
    it "declares explicit Tuner settings for the trading pipeline" do
      expect(TradingWorkflowsWorker.tuner_settings).to eq(
        workflow_slots: 100,
        activity_slots: 5,
        local_activity_slots: 100
      )
    end
  end

  describe TickerSelectorWorker, ".tuner_settings" do
    it "overrides the base defaults to allow more parallel filter fan-out" do
      # TickerSelectorWorker's filter fan-out is MCP-call-heavy, not
      # LLM-heavy, so the LLM-tuned base defaults (5 activity slots)
      # are way too tight. See TickerSelectorWorker for the full
      # rationale; the short version: 20 × 5-filter × 25-ticker fan-out
      # at activity_slots=5 takes 90+ minutes; activity_slots=20 cuts
      # it to ~20.
      expect(TickerSelectorWorker.tuner_settings).to eq(
        workflow_slots: 20,
        activity_slots: 20,
        local_activity_slots: 100
      )
    end

    it "differs from the trading-pipeline Tuner because the workload is different" do
      # Sanity check: TickerSelectorWorker and TradingWorkflowsWorker
      # are NOT sharing the same Tuner — they poll different queues
      # and have very different resource profiles. If this test ever
      # fails, the override was removed by accident.
      expect(TickerSelectorWorker.tuner_settings).not_to eq(TradingWorkflowsWorker.tuner_settings)
    end
  end

  describe BacktestWorkflowsWorker, ".tuner_settings" do
    it "inherits the base defaults" do
      expect(BacktestWorkflowsWorker.tuner_settings).to eq(ApplicationWorker.tuner_settings)
    end
  end

  describe PositionWorkflowsWorker, ".tuner_settings" do
    it "inherits the base defaults" do
      expect(PositionWorkflowsWorker.tuner_settings).to eq(ApplicationWorker.tuner_settings)
    end
  end

  describe "tuner_settings override via super.merge" do
    it "lets a subclass tweak a single slot while keeping the rest" do
      stub_const("CustomWorker", Class.new(ApplicationWorker) do
        def self.tuner_settings
          super.merge(activity_slots: 2)
        end
      end)
      expect(CustomWorker.tuner_settings[:activity_slots]).to eq(2)
      expect(CustomWorker.tuner_settings[:workflow_slots]).to eq(100)
    end
  end
end

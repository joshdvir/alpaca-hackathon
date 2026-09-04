# frozen_string_literal: true

require "rails_helper"

RSpec.describe Positions::Occ do
  describe ".expiry_date" do
    it "parses a 21st-century option symbol" do
      expect(described_class.expiry_date("PLTR260911C00190000")).to eq(Date.new(2026, 9, 11))
    end

    it "parses a short-root option symbol" do
      expect(described_class.expiry_date("SPY260116C00580000")).to eq(Date.new(2026, 1, 16))
    end

    it "parses a long-root option symbol" do
      expect(described_class.expiry_date("AAPL260919P00200000")).to eq(Date.new(2026, 9, 19))
    end

    it "returns nil for a non-OCC string" do
      expect(described_class.expiry_date("AAPL")).to be_nil
      expect(described_class.expiry_date("PLTR260911X00190000")).to be_nil # X is not C/P
      expect(described_class.expiry_date("")).to be_nil
    end

    it "returns nil for an invalid date (Nov 31 doesn't exist)" do
      expect(described_class.expiry_date("PLTR261131C00190000")).to be_nil
    end

    it "treats 2-digit year 00-49 as 21st century" do
      expect(described_class.expiry_date("SPY240315C00500000").year).to eq(2024)
    end
  end

  describe ".days_to_expiry" do
    it "returns positive for symbols expiring in the future" do
      dte = described_class.days_to_expiry("PLTR270911C00190000", as_of: Date.new(2026, 8, 31))
      # 2026-08-31 to 2027-09-11 is 376 days (365 + 11 leap-day-free days).
      expect(dte).to eq(376)
    end

    it "returns 0 for symbols expiring today" do
      dte = described_class.days_to_expiry("PLTR260831C00190000", as_of: Date.new(2026, 8, 31))
      expect(dte).to eq(0)
    end

    it "returns negative for symbols that have already expired" do
      dte = described_class.days_to_expiry("PLTR260101C00190000", as_of: Date.new(2026, 8, 31))
      expect(dte).to be < 0
    end

    it "returns nil for non-OCC strings" do
      expect(described_class.days_to_expiry("not-an-option", as_of: Date.current)).to be_nil
    end
  end

  describe ".valid?" do
    it "returns true for a well-formed OCC symbol" do
      expect(described_class.valid?("PLTR260911C00190000")).to be true
    end

    it "returns false for a malformed symbol" do
      expect(described_class.valid?("garbage")).to be false
    end
  end
end

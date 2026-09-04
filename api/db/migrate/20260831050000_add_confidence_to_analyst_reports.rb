# frozen_string_literal: true

# Add confidence / thesis / summary columns to analyst_reports so
# the PersistResearchActivity can store the LLM analyst's
# top-level metrics without round-tripping through the JSONB payload.
# These were missing from the original migration; the LLM briefs
# always had them but the table didn't, so the UI only saw a JSON
# blob. Now the columns are queryable + sortable.
class AddConfidenceToAnalystReports < ActiveRecord::Migration[8.0]
  def change
    add_column :analyst_reports, :confidence, :integer
    add_column :analyst_reports, :thesis,     :text
    add_column :analyst_reports, :summary,    :text
    add_index  :analyst_reports, [:ticker, :confidence]
  end
end

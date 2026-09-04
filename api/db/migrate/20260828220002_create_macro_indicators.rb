# frozen_string_literal: true

class CreateMacroIndicators < ActiveRecord::Migration[8.0]
  def change
    create_table :macro_indicators do |t|
      t.string  :series_id, null: false # 'VIXCLS', 'DGS10'
      t.decimal :value
      t.date    :observed_on, null: false
      t.timestamps
    end
    add_index :macro_indicators, %i[series_id observed_on], unique: true
  end
end

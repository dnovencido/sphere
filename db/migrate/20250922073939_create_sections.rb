class CreateSections < ActiveRecord::Migration[7.2]
  def change
    create_table :sections do |t|
      t.string :name, null: false # e.g. "BSCS-1A"
      t.integer :year_level, null: false # 1..4
      t.references :term, foreign_key: true, null: false
      t.timestamps
    end
  end
end

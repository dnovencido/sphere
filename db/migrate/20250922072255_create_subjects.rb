class CreateSubjects < ActiveRecord::Migration[7.2]
  def change
    create_table :subjects do |t|
      t.string :code, null: false
      t.string :title
      t.integer :year_level
      t.integer :lecture_duration_minutes, default: 60
      t.integer :lab_duration_minutes, default: 90
      t.boolean :has_lab, default: false
      t.timestamps
    end
  end
end

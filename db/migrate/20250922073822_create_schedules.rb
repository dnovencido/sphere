class CreateSchedules < ActiveRecord::Migration[7.2]
  def change
    create_table :schedules do |t|
      t.references :term, foreign_key: true, null: false
      t.string :name
      t.float :fitness_score
      t.timestamps
    end

    create_table :schedule_entries do |t|
      t.references :schedule, foreign_key: true, null: false
      t.references :subject_offering, foreign_key: true, null: false
      t.references :room, foreign_key: true, null: false
      t.string :day, null: false # e.g. 'Monday'
      t.time :start_time, null: false
      t.integer :duration_minutes, null: false
      t.timestamps
    end
  end
end

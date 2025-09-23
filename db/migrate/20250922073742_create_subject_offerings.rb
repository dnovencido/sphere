class CreateSubjectOfferings < ActiveRecord::Migration[7.2]
  def change
    create_table :subject_offerings do |t|
      t.references :term, foreign_key: true, null: false
      t.references :subject, foreign_key: true, null: false
      t.references :teacher, foreign_key: true, null: false
      t.integer :max_students
      t.timestamps
    end
  end
end

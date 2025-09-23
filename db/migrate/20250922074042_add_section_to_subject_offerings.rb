class AddSectionToSubjectOfferings < ActiveRecord::Migration[7.2]
  def change
    add_reference :subject_offerings, foreign_key: true, null: false
  end
end

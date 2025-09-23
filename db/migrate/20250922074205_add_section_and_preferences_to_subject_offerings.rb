class AddSectionAndPreferencesToSubjectOfferings < ActiveRecord::Migration[7.2]
  def change
    add_column :subject_offerings, :preferred_days, :string, array: true, default: []
    # preferred_days example: ["Monday", "Wednesday"]
  end
end

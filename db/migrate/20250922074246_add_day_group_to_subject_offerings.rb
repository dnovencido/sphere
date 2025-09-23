class AddDayGroupToSubjectOfferings < ActiveRecord::Migration[7.2]
  def change
    add_column :subject_offerings, :day_group, :string, null: false, default: "weekdays"
    # values: "weekdays" (Mon–Fri), "weekends" (Saturday and Sunday only)
  end
end

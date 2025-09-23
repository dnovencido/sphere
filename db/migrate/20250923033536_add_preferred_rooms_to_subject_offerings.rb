class AddPreferredRoomsToSubjectOfferings < ActiveRecord::Migration[7.2]
  def change
    add_column :subject_offerings, :preferred_room_ids, :integer, array: true, default: [], null: false
    add_column :subject_offerings, :preferred_time, :string
  end
end

class CreateRooms < ActiveRecord::Migration[7.2]
  def change
    create_table :rooms do |t|
        t.string :name, null: false
        t.integer :room_type, null: false, default: 0 # enum: lec=0, lab=1
        t.integer :capacity
        t.timestamps
    end
  end
end

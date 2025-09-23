class Room < ApplicationRecord
    validates :name, :room_type, presence: true 
    enum room_type: { lec: 0, lab: 1 }
end
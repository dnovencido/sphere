class Schedule < ApplicationRecord
    belongs_to :term
    has_many :schedule_entries, dependent: :destroy
end
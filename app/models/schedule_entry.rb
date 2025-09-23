class ScheduleEntry < ApplicationRecord
    belongs_to :schedule
    belongs_to :subject_offering
    belongs_to :room
    delegate :section, to: :subject_offering
end
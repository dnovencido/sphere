class Semester < ApplicationRecord
    has_many :subject_offerings
    has_many :schedules
end
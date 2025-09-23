class SubjectOffering < ApplicationRecord
    belongs_to :term
    belongs_to :subject
    belongs_to :teacher
    belongs_to :section

    # Returns preferred days as an array of strings
    def preferred_days_array
        preferred_days || []
    end

    def weekday_group?
        day_group == "weekdays"
    end

    def weekend_group?
        day_group == "weekend"
    end
end
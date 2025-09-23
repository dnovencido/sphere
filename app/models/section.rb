class Section < ApplicationRecord
    belongs_to :term
    has_many :subject_offerings
end
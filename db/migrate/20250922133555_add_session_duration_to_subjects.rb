class AddSessionDurationToSubjects < ActiveRecord::Migration[7.2]
  def change
    add_column :subjects, :session_duration, :string, default: nil
  end
end

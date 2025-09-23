class Admins::SchedulesController < ApplicationController
  def index
    semester = Term.find(13)
    selected_year = 1

    scheduler = GeneticSchedulerService.new(
      semester: semester,
      population_size: 100,
      generations: 500,
      mutation_rate: 0.05,
      crossover_rate: 0.8,
      year_level: selected_year,
      section_id: 54
    )

    best_schedule = scheduler.run

    valid_days = %w[Monday Tuesday Wednesday Thursday Friday Saturday]

    display_schedule = best_schedule.map do |gene|
      subj_off = SubjectOffering.find_by(id: gene[:subject_offering_id])
      next unless subj_off
      next unless subj_off.section.year_level == selected_year
      next unless valid_days.include?(gene[:day]) # ✅ skip Sunday or invalid days

      {
        day: gene[:day], # "Monday".."Saturday"
        start_time: gene[:start_time],
        end_time: gene[:start_time] + gene[:duration_minutes].minutes,
        subject: subj_off.subject.title,
        teacher: subj_off.teacher.name,
        section: subj_off.section.name,
        room: Room.find_by(id: gene[:room_id])&.name
      }
    end.compact


    # @schedule_by_day = display_schedule.group_by { |s| s[:day] }
    # @schedule_by_day = valid_days.index_with { |day| @schedule_by_day[day] || [] }
    display_schedule.each do |s|
      s[:start_time] = s[:start_time].is_a?(String) ? Time.parse(s[:start_time]) : s[:start_time]
      s[:end_time]   = s[:end_time].is_a?(String)   ? Time.parse(s[:end_time])   : s[:end_time]
    end

    @schedule_by_day = valid_days.index_with { |d| display_schedule.select { |s| s[:day] == d }.sort_by { |e| e[:start_time] } }
    @selected_year = selected_year 

    # ensure times are Time objects and group in order Mon-Sat


    # Map to readable format
  #   display_schedule = best_schedule.map do |gene|
  #     subj_off = SubjectOffering.find_by(id: gene[:subject_offering_id])
  #     next unless subj_off
  #     {
  #       day: gene[:day],
  #       start_time: gene[:start_time].strftime("%H:%M"),
  #       end_time: (gene[:start_time] + gene[:duration_minutes].minutes).strftime("%H:%M"),
  #       subject: subj_off.subject.title,
  #       teacher: subj_off.teacher.name,
  #       section: subj_off.section.name,
  #       room: Room.find_by(id: gene[:room_id])&.name
  #     }
  #  end.compact

    # Group by day
    # schedule_by_day = display_schedule.group_by { |s| s[:day] }
    # render json: { year_level: selected_year, schedule: @schedule_by_day }
  end
end
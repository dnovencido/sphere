# app/services/genetic_scheduler_service.rb
require 'set'
require 'parallel'

class GeneticSchedulerService
  attr_reader :semester, :population_size, :generations, :mutation_rate, :crossover_rate,
              :offerings, :rooms, :lec_rooms, :lab_rooms, :offering_lookup, :session_plan_cache,
              :weekday_slots, :weekend_slots

  def initialize(semester:, population_size: 50, generations: 200,
                 mutation_rate: 0.05, crossover_rate: 0.8, year_level: nil, section_id: nil)
    @semester = semester
    @population_size = population_size
    @generations = generations
    @mutation_rate = mutation_rate
    @crossover_rate = crossover_rate

    @offerings = semester.subject_offerings.includes(:subject, :teacher, :section)
    @offerings = @offerings.where(sections: { year_level: year_level }) if year_level.present?
    @offerings = @offerings.where(section_id: section_id) if section_id.present?
    @offerings = @offerings.to_a

    @rooms = Room.all.to_a
    @lec_rooms = rooms.select { |r| r.room_type == 'lec' }
    @lab_rooms = rooms.select { |r| r.room_type == 'lab' }

    @offering_lookup = offerings.index_by(&:id)
    @session_plan_cache = offerings.map { |off| [off.subject_id, build_session_plan(off.subject)] }.to_h

    @weekday_slots = build_time_slots(%w[Monday Tuesday Wednesday Thursday Friday])
    @weekend_slots = build_time_slots(%w[Saturday])
  end

  # -----------------------------
  # Run GA
  # -----------------------------
  def run
    return [] if offerings.empty?

    population = Array.new(population_size) { generate_random_chromosome }

    generations.times do |gen|
      scored = Parallel.map(population, in_threads: 4) { |chrom| [chrom, fitness(chrom)] }
      scored.sort_by! { |_, score| -score }

      best_score = scored.first.last
      @stagnant ||= 0
      if defined?(@prev_best) && (best_score - @prev_best).abs < 1e-6
        @stagnant += 1
      else
        @stagnant = 0
        @prev_best = best_score
      end
      break if @stagnant >= 20

      elite_size = (population_size * 0.2).to_i
      new_population = scored.first(elite_size).map(&:first)

      while new_population.size < population_size
        parent1, parent2 = select_parents(scored)
        child1, child2 = crossover(parent1, parent2)
        new_population << mutate(child1)
        new_population << mutate(child2)
      end

      population = new_population.first(population_size)
    end

    population.max_by { |chrom| fitness(chrom) }
  end

  # -----------------------------
  # Generate chromosome
  # -----------------------------
  def generate_random_chromosome
    chromosome = []
    room_occupancy = Hash.new { |h,k| h[k] = [] }
    teacher_schedule = Hash.new { |h,k| h[k] = [] }
    section_schedule = Hash.new { |h,k| h[k] = [] }
    subject_day_schedule = Hash.new { |h,k| h[k] = [] }
    subject_scheduled_days = Hash.new { |h,k| h[k] = Set.new }
    daily_subject_count = Hash.new { |h, k| h[k] = Hash.new(0) } # New hash for daily subject count per section

    offerings.each do |off|
      session_plan_cache[off.subject_id].each do |duration, type|
        gene = assign_gene(off, duration, type,
                           room_occupancy, teacher_schedule, section_schedule,
                           subject_day_schedule, subject_scheduled_days, daily_subject_count)
        chromosome << gene
      end
    end

    chromosome
  end

  # -----------------------------
  # Build session plan
  # -----------------------------
  def build_session_plan(subj)
    plan = []

    if subj.session_duration.present?
      case subj.session_duration
      when "2x1hr"
        plan += Array.new(2) { [subj.lecture_duration_minutes, "lec"] }
      when "3x1hr"
        plan += Array.new(3) { [subj.lecture_duration_minutes, "lec"] }
      when "1x3hr"
        plan << [subj.lecture_duration_minutes, "lec"]
      when "2x1.5hr"
        type = subj.has_lab ? "lab" : "lec"
        duration = subj.has_lab ? subj.lab_duration_minutes : subj.lecture_duration_minutes
        plan += Array.new(2) { [duration, type] }
      else
        if subj.has_lab && subj.lab_duration_minutes.positive?
          plan << [subj.lab_duration_minutes, "lab"]
        elsif subj.lecture_duration_minutes.positive?
          plan << [subj.lecture_duration_minutes, "lec"]
        end
      end
    else
      if subj.has_lab && subj.lab_duration_minutes.positive?
        plan << [subj.lab_duration_minutes, "lab"]
      elsif subj.lecture_duration_minutes.positive?
        plan << [subj.lecture_duration_minutes, "lec"]
      end
    end

    plan
  end

  # -----------------------------
  # Assign gene (hard room type + AM/PM)
  # -----------------------------
  def assign_gene(off, duration, type, room_occupancy, teacher_schedule, section_schedule, subject_day_schedule, subject_scheduled_days, daily_subject_count)
    slots = off.day_group == "weekdays" ? weekday_slots : weekend_slots
    slots = filter_slots_by_strict_time(slots, off.preferred_time)

    slots = slots.sort_by { |s| s[:start_time] }

    room_candidates = off.preferred_room_ids.any? ? rooms.select { |r| off.preferred_room_ids.include?(r.id) } : (type == 'lec' ? lec_rooms : lab_rooms)

    assigned_gene = nil

    slots.each do |slot|
      # Check daily subject count constraint
      max_subjects_per_day = slot[:day] == "Saturday" ? 1 : 4
      next if daily_subject_count[off.section_id][slot[:day]] >= max_subjects_per_day

      room = room_candidates.find do |r|
        !room_occupancy[[r.id, slot[:day]]].any? { |s,e| overlaps?([s,e],[slot[:start_time], slot[:start_time] + duration.minutes]) }
      end
      next unless room

      next if teacher_schedule[[off.teacher_id, slot[:day]]].any? { |s,e| overlaps?([s,e],[slot[:start_time], slot[:start_time]+duration.minutes]) }
      next if section_schedule[[off.section_id, slot[:day]]].any? { |s,e| overlaps?([s,e],[slot[:start_time], slot[:start_time]+duration.minutes]) }
      next if subject_scheduled_days[off.subject_id].include?(slot[:day])

      prev_end_times = subject_day_schedule[[off.subject_id, slot[:day]]] || []
      next if prev_end_times.any? { |prev_end| (prev_end.to_i - slot[:start_time].to_i).abs <= 60*60 }

      start_time = slot[:start_time]
      end_time = start_time + duration.minutes
      assigned_gene = {
        subject_offering_id: off.id,
        room_id: room.id,
        day: slot[:day],
        start_time: start_time,
        duration_minutes: duration,
        type: type
      }

      room_occupancy[[room.id, slot[:day]]] << [start_time,end_time]
      teacher_schedule[[off.teacher_id, slot[:day]]] << [start_time,end_time]
      section_schedule[[off.section_id, slot[:day]]] << [start_time,end_time]
      subject_day_schedule[[off.subject_id, slot[:day]]] ||= []
      subject_day_schedule[[off.subject_id, slot[:day]]] << end_time
      subject_scheduled_days[off.subject_id] << slot[:day]
      daily_subject_count[off.section_id][slot[:day]] += 1 # Increment subject count for the day

      break
    end

    unless assigned_gene
      room = room_candidates.first
      slot = slots.first
      assigned_gene = {
        subject_offering_id: off.id,
        room_id: room.id,
        day: slot[:day],
        start_time: slot[:start_time],
        duration_minutes: duration,
        type: type
      }
    end

    assigned_gene
  end


  # -----------------------------
  # Mutation (hard room type + AM/PM)
  # -----------------------------
  def mutate(chromosome)
    subject_scheduled_days = Hash.new { |h,k| h[k] = Set.new }
    daily_subject_count = Hash.new { |h, k| h[k] = Hash.new(0) }
    
    chromosome.each do |gene|
      off = offering_lookup[gene[:subject_offering_id]]
      subject_scheduled_days[off.subject_id] << gene[:day]
      daily_subject_count[off.section_id][gene[:day]] += 1
    end

    chromosome.each do |gene|
      next unless rand < mutation_rate
      off = offering_lookup[gene[:subject_offering_id]]

      original_day = gene[:day]
      
      slots = off.day_group == "weekdays" ? weekday_slots : weekend_slots
      slots = filter_slots_by_strict_time(slots, off.preferred_time)

      type_rooms = gene[:type] == 'lec' ? lec_rooms : lab_rooms
      available_rooms = off.preferred_room_ids.any? ? type_rooms.select { |r| off.preferred_room_ids.include?(r.id) } : type_rooms
      available_rooms = type_rooms if available_rooms.empty?

      10.times do
        slot = slots.sample
        room = available_rooms.sample
        
        # Check daily subject count constraint for new day
        max_subjects_per_day = slot[:day] == "Saturday" ? 1 : 4
        next if daily_subject_count[off.section_id][slot[:day]] >= max_subjects_per_day

        start_time = slot[:start_time]
        end_time = start_time + gene[:duration_minutes].minutes
        next if end_time > Time.parse("17:00")
        
        # Check if moving the subject to a new day would violate the "same-subject-same-day" constraint
        next if original_day != slot[:day] && subject_scheduled_days[off.subject_id].include?(slot[:day])

        # Check conflicts
        next if chromosome.any? do |g|
          g_off = offering_lookup[g[:subject_offering_id]]
          g[:day] == slot[:day] &&
            overlaps?([start_time,end_time],[g[:start_time], g[:start_time]+g[:duration_minutes].minutes]) &&
            (g[:room_id]==room.id || g_off.teacher_id==off.teacher_id || g_off.section_id==off.section_id || g_off.subject_id==off.subject_id)
        end

        # Update daily subject count
        daily_subject_count[off.section_id][original_day] -= 1
        daily_subject_count[off.section_id][slot[:day]] += 1
        
        gene[:room_id] = room.id
        gene[:day] = slot[:day]
        gene[:start_time] = start_time
        subject_scheduled_days[off.subject_id] << slot[:day]
        break
      end
    end

    chromosome
  end

  # -----------------------------
  # Build AM/PM slots
  # -----------------------------
  def build_time_slots(days)
    slots = []
    days.each do |day|
      # AM: 8:00 to 12:00
      (8..11).each do |hour|
        [0,30].each do |minute|
          t = Time.parse("#{hour}:#{minute}")
          next if t + 30.minutes > Time.parse("12:00")
          slots << { day: day, start_time: t, period: "AM" }
        end
      end
      # PM: 1:00 to 4:30
      (13..16).each do |hour|
        [0,30].each do |minute|
          t = Time.parse("#{hour}:#{minute}")
          slots << { day: day, start_time: t, period: "PM" }
        end
      end
    end

    slots
  end

  # -----------------------------
  # Fitness
  # -----------------------------
  def fitness(chromosome)
    total_penalty = 0.0
    room_schedule = Hash.new { |h,k| h[k] = [] }
    teacher_schedule = Hash.new { |h,k| h[k] = [] }
    section_schedule = Hash.new { |h,k| h[k] = [] }
    subject_days = Hash.new { |h,k| h[k] = Set.new }
    daily_subject_count = Hash.new { |h, k| h[k] = Hash.new(0) } # New hash for daily subject count per section

    chromosome.each do |gene|
      off = offering_lookup[gene[:subject_offering_id]]
      start = gene[:start_time]
      finish = start + gene[:duration_minutes].minutes

      room_schedule[[gene[:room_id], gene[:day]]] << [start,finish]
      teacher_schedule[[off.teacher_id, gene[:day]]] << [start,finish]
      section_schedule[[off.section_id, gene[:day]]] << [start,finish]
      subject_days[off.subject_id] << gene[:day]
      daily_subject_count[off.section_id][gene[:day]] += 1 # Increment subject count

      # Penalties
      total_penalty += 1.5 if off.preferred_days.any? && !off.preferred_days.include?(gene[:day])
      total_penalty += 1.0 if off.preferred_room_ids.any? && !off.preferred_room_ids.include?(gene[:room_id])
      total_penalty += 1.0 if off.preferred_time == "AM" && !(8..11).include?(start.hour)
      total_penalty += 1.0 if off.preferred_time == "PM" && !(13..16).include?(start.hour)
    end

    # New penalty for daily subject count constraint
    daily_subject_count.each do |section_id, daily_counts|
      daily_counts.each do |day, count|
        if day == "Saturday"
          total_penalty += 1000.0 if count > 1
        else
          total_penalty += 500.0 if count > 4
        end
      end
    end
    
    # Overlaps
    room_schedule.each { |_, intervals| total_penalty += overlap_penalty(intervals) * 100.0 }
    teacher_schedule.each { |_, intervals| total_penalty += overlap_penalty(intervals) * 50.0 }
    section_schedule.each { |_, intervals| total_penalty += overlap_penalty(intervals) * 50.0 }

    # Consecutive lec/lab penalty
    chromosome.group_by { |g| offering_lookup[g[:subject_offering_id]].subject_id }.each do |subject_id, genes|
      genes.group_by { |g| g[:day] }.each do |day, day_genes|
        sorted = day_genes.sort_by { |g| g[:start_time] }
        sorted.each_cons(2) { |g1,g2| total_penalty += 5.0 if (g1[:type] != g2[:type]) }
      end
    end

    # Same-subject same-day penalty
    subject_days.each do |subject_id, days|
      # This penalty needs to be re-evaluated to work with the new subject per day logic.
      # A better approach is to check if all session parts of a subject are scheduled.
      # total_penalty += 10.0 if days.size < offerings.count { |o| o.subject_id == subject_id }
      # A gene's subject offering ID is unique. If a subject has multiple sessions, it's represented by
      # multiple genes with the same subject_offering_id, which is wrong. A subject offering should have a unique ID.
      # The `session_plan_cache` is a better source.
      
      # Let's check if all parts of a subject are scheduled on different days.
      session_parts_count = session_plan_cache[offerings.find { |o| o.subject_id == subject_id }.subject_id].size rescue 0
      total_penalty += 10.0 if days.size < session_parts_count
    end
    
    1.0 / (1.0 + total_penalty)
  end

  # -----------------------------
  # Helpers
  # -----------------------------
  def overlaps?(a,b)
    a_start,a_end = a
    b_start,b_end = b
    (a_start < b_end) && (b_start < a_end)
  end

  def overlap_penalty(intervals)
    penalty = 0
    sorted = intervals.sort_by(&:first)
    sorted.each_cons(2) { |a,b| penalty += 1 if overlaps?(a,b) }
    penalty
  end

  def select_parents(scored)
    weights = scored.map { |_, score| score }
    parent1 = scored[weighted_sample(weights)].first
    parent2 = scored[weighted_sample(weights)].first
    [parent1, parent2]
  end

  def weighted_sample(weights)
    total = weights.sum
    point = rand * total
    weights.each_with_index do |w,i|
      point -= w
      return i if point <= 0
    end
    weights.size - 1
  end

  def crossover(parent1, parent2)
    return [parent1, parent2] if rand > crossover_rate
    point = rand(1...parent1.size)
    child1 = parent1[0...point] + parent2[point..]
    child2 = parent2[0...point] + parent1[point..]
    [child1, child2]
  end

  def filter_slots_by_strict_time(slots, pref)
    case pref
    when "AM" then slots.select { |s| s[:period] == "AM" }
    when "PM" then slots.select { |s| s[:period] == "PM" }
    else slots
    end
  end
end
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
  # Run Genetic Algorithm
  # -----------------------------
  def run
    return [] if offerings.empty?

    population = Array.new(population_size) { generate_random_chromosome }

    generations.times do
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

      # Elitism: retain top 20%
      elite_size = (population_size * 0.2).to_i
      new_population = scored.first(elite_size).map(&:first)

      # Generate offspring
      while new_population.size < population_size
        parent1, parent2 = select_parents(scored)
        child1, child2 = crossover(parent1, parent2)
        new_population << mutate(child1)
        new_population << mutate(child2)
      end

      population = new_population.first(population_size)
    end

    # Return best chromosome
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

    offerings.each do |off|
      session_plan_cache[off.subject_id].each do |duration,type|
        gene = assign_gene(off, duration, type,
                           room_occupancy, teacher_schedule, section_schedule,
                           subject_day_schedule, subject_scheduled_days)
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
      when "2x1hr" then plan += Array.new(2) { [subj.lecture_duration_minutes, "lec"] }
      when "3x1hr" then plan += Array.new(3) { [subj.lecture_duration_minutes, "lec"] }
      when "1x3hr" then plan << [subj.lecture_duration_minutes, "lec"]
      when "2x1.5hr"
        type = subj.has_lab ? "lab" : "lec"
        duration = subj.has_lab ? subj.lab_duration_minutes : subj.lecture_duration_minutes
        plan += Array.new(2) { [duration, type] }
      else
        plan << (subj.has_lab && subj.lab_duration_minutes.positive? ? [subj.lab_duration_minutes, "lab"] : [subj.lecture_duration_minutes, "lec"])
      end
    else
      plan << (subj.has_lab && subj.lab_duration_minutes.positive? ? [subj.lab_duration_minutes, "lab"] : [subj.lecture_duration_minutes, "lec"])
    end

    plan
  end

  # -----------------------------
  # Assign gene
  # -----------------------------
  def assign_gene(off, duration, type, room_occupancy, teacher_schedule, section_schedule, subject_day_schedule, subject_scheduled_days)
    slots = off.day_group == "weekdays" ? weekday_slots : weekend_slots
    slots = filter_slots_by_strict_time(slots, off.preferred_time)
    slots.sort_by! { |s| s[:start_time] }

    room_candidates = off.preferred_room_ids.any? ? rooms.select { |r| off.preferred_room_ids.include?(r.id) } : (type == 'lec' ? lec_rooms : lab_rooms)

    assigned_gene = nil

    slots.each do |slot|
      room = room_candidates.find do |r|
        !room_occupancy[[r.id, slot[:day]]].any? { |s,e| overlaps?([s,e],[slot[:start_time], slot[:start_time] + duration.minutes]) }
      end
      next unless room
      next if teacher_schedule[[off.teacher_id, slot[:day]]].any? { |s,e| overlaps?([s,e],[slot[:start_time], slot[:start_time]+duration.minutes]) }
      next if section_schedule[[off.section_id, slot[:day]]].any? { |s,e| overlaps?([s,e],[slot[:start_time], slot[:start_time]+duration.minutes]) }
      next if subject_scheduled_days[off.subject_id].include?(slot[:day])

      start_time = slot[:start_time]
      end_time = start_time + duration.minutes
      assigned_gene = { subject_offering_id: off.id, room_id: room.id, day: slot[:day], start_time: start_time, duration_minutes: duration, type: type }

      room_occupancy[[room.id, slot[:day]]] << [start_time,end_time]
      teacher_schedule[[off.teacher_id, slot[:day]]] << [start_time,end_time]
      section_schedule[[off.section_id, slot[:day]]] << [start_time,end_time]
      subject_day_schedule[[off.subject_id, slot[:day]]] ||= []
      subject_day_schedule[[off.subject_id, slot[:day]]] << end_time
      subject_scheduled_days[off.subject_id] << slot[:day]

      break
    end

    assigned_gene ||= { subject_offering_id: off.id, room_id: room_candidates.first.id, day: slots.first[:day], start_time: slots.first[:start_time], duration_minutes: duration, type: type }
  end

  # -----------------------------
  # Mutation
  # -----------------------------
  def mutate(chromosome)
    subject_scheduled_days = Hash.new { |h,k| h[k] = Set.new }
    chromosome.each { |gene| subject_scheduled_days[offering_lookup[gene[:subject_offering_id]].subject_id] << gene[:day] }

    chromosome.each do |gene|
      next unless rand < mutation_rate
      off = offering_lookup[gene[:subject_offering_id]]
      slots = (off.day_group == "weekdays" ? weekday_slots : weekend_slots)
      slots = filter_slots_by_strict_time(slots, off.preferred_time)

      type_rooms = gene[:type] == 'lec' ? lec_rooms : lab_rooms
      available_rooms = off.preferred_room_ids.any? ? type_rooms.select { |r| off.preferred_room_ids.include?(r.id) } : type_rooms
      available_rooms = type_rooms if available_rooms.empty?

      5.times do
        slot = slots.sample
        room = available_rooms.sample
        start_time = slot[:start_time]
        end_time = start_time + gene[:duration_minutes].minutes
        next if end_time > Time.parse("17:00")
        next if subject_scheduled_days[off.subject_id].include?(slot[:day])
        next if chromosome.any? do |g|
          g_off = offering_lookup[g[:subject_offering_id]]
          g[:day] == slot[:day] && overlaps?([start_time,end_time],[g[:start_time], g[:start_time]+g[:duration_minutes].minutes]) &&
            (g[:room_id]==room.id || g_off.teacher_id==off.teacher_id || g_off.section_id==off.section_id || g_off.subject_id==off.subject_id)
        end

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
      (8..11).each { |h| [0,30].each { |m| t = Time.parse("#{h}:#{m}"); slots << { day: day, start_time: t, period: "AM" } if t + 30.minutes <= Time.parse("12:00") } }
      (13..16).each { |h| [0,30].each { |m| t = Time.parse("#{h}:#{m}"); slots << { day: day, start_time: t, period: "PM" } } }
    end
    slots
  end

  # -----------------------------
  # Fitness function
  # -----------------------------
  def fitness(chromosome)
    total_penalty = 0.0
    room_schedule = Hash.new { |h,k| h[k] = [] }
    teacher_schedule = Hash.new { |h,k| h[k] = [] }
    section_schedule = Hash.new { |h,k| h[k] = [] }
    subject_days = Hash.new { |h,k| h[k] = Set.new }

    chromosome.each do |gene|
      off = offering_lookup[gene[:subject_offering_id]]
      start = gene[:start_time]
      finish = start + gene[:duration_minutes].minutes

      room_schedule[[gene[:room_id], gene[:day]]] << [start,finish]
      teacher_schedule[[off.teacher_id, gene[:day]]] << [start,finish]
      section_schedule[[off.section_id, gene[:day]]] << [start,finish]
      subject_days[off.subject_id] << gene[:day]

      total_penalty += 1.5 if off.preferred_days.any? && !off.preferred_days.include?(gene[:day])
      total_penalty += 1.0 if off.preferred_room_ids.any? && !off.preferred_room_ids.include?(gene[:room_id])
      total_penalty += 1.0 if off.preferred_time == "AM" && !(8..11).include?(start.hour)
      total_penalty += 1.0 if off.preferred_time == "PM" && !(13..16).include?(start.hour)
    end

    [room_schedule, teacher_schedule, section_schedule].each { |sched| sched.each { |_, intervals| total_penalty += overlap_penalty(intervals) * 50.0 } }

    # Consecutive lec/lab penalty
    chromosome.group_by { |g| offering_lookup[g[:subject_offering_id]].subject_id }.each do |subject_id, genes|
      genes.group_by { |g| g[:day] }.each { |_, day_genes| day_genes.sort_by { |g| g[:start_time] }.each_cons(2) { |g1,g2| total_penalty += 5.0 if g1[:type] != g2[:type] } }
    end

    # Same-subject same-day penalty
    subject_days.each { |_, days| total_penalty += 10.0 if days.size < offerings.count { |o| o.subject_id == _ } }

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
    sorted = intervals.sort_by(&:first)
    sorted.each_cons(2).count { |a,b| overlaps?(a,b) }
  end

  def select_parents(scored)
    weights = scored.map { |_, score| score }
    [scored[weighted_sample(weights)].first, scored[weighted_sample(weights)].first]
  end

  def weighted_sample(weights)
    total = weights.sum
    point = rand * total
    weights.each_with_index { |w,i| point -= w; return i if point <= 0 }
    weights.size - 1
  end

  def crossover(parent1, parent2)
    return [parent1, parent2] if rand > crossover_rate
    point = rand(1...parent1.size)
    [parent1[0...point] + parent2[point..], parent2[0...point] + parent1[point..]]
  end

  def filter_slots_by_strict_time(slots, pref)
    case pref
    when "AM" then slots.select { |s| s[:period] == "AM" }
    when "PM" then slots.select { |s| s[:period] == "PM" }
    else slots
    end
  end
end

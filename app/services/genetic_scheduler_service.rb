# app/services/genetic_scheduler_service.rb
class GeneticSchedulerService
  attr_reader :semester, :population_size, :generations, :mutation_rate, :crossover_rate,
              :weekday_slots, :weekend_slots, :offerings, :rooms

  def initialize(semester:, population_size: 100, generations: 500,
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
    @weekday_slots = build_time_slots(%w[Monday Tuesday Wednesday Thursday Friday])
    @weekend_slots = build_time_slots(%w[Saturday])
  end

  # -----------------------------
  # Run GA
  # -----------------------------
  def run
    return [] if offerings.empty?

    population = Array.new(population_size) { generate_random_chromosome }

    generations.times do
      scored = population.map { |chrom| [chrom, fitness(chrom)] }
      scored.sort_by! { |_, score| -score }

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
  # Generate conflict-free chromosome
  # -----------------------------
  def generate_random_chromosome
    chromosome = []
    room_occupancy = Hash.new { |h, k| h[k] = [] }
    teacher_schedule = Hash.new { |h, k| h[k] = [] }
    section_schedule = Hash.new { |h, k| h[k] = [] }
    subject_day_schedule = Hash.new { |h, k| h[k] = [] }
    subject_scheduled_days = Hash.new { |h, k| h[k] = Set.new }

    offerings.each do |off|
      build_session_plan(off.subject).each do |duration, type|
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

    case subj.session_duration
    when "2x1hr"
      plan += [[60, "lec"], [60, "lec"]]
    when "1x3hr"
      plan << [180, "lec"]
    when "2x1.5hr"
      plan += [[90, "lab"], [90, "lab"]]
    when "3x1hr"
      plan += [[60, "lec"], [60, "lec"], [60, "lec"]]
    else
      if subj.has_lab && subj.lab_duration_minutes > 0
        plan += [[90, "lab"], [90, "lab"]]
      elsif subj.lecture_duration_minutes > 0
        plan += [[60, "lec"], [60, "lec"]]
      end
    end

    plan
  end

  # -----------------------------
  # Assign gene (conflict-free)
  # -----------------------------
  def assign_gene(off, duration, type, room_occupancy, teacher_schedule, section_schedule, subject_day_schedule, subject_scheduled_days)
    slots = off.day_group == "weekdays" ? weekday_slots : weekend_slots
    assigned_gene = nil

    100.times do
      slot = slots.sample
      room = rooms.select { |r| r.room_type == type }.sample
      next unless room

      start_time = slot[:start_time]
      end_time   = start_time + duration.minutes
      next if end_time > Time.parse("17:00")  # End by 5 PM

      # Conflict checks
      next if room_occupancy[[room.id, slot[:day]]].any? { |s,e| overlaps?([start_time, end_time], [s,e]) }
      next if teacher_schedule[[off.teacher_id, slot[:day]]].any? { |s,e| overlaps?([start_time, end_time], [s,e]) }
      next if section_schedule[[off.section_id, slot[:day]]].any? { |s,e| overlaps?([start_time, end_time], [s,e]) }
      next if subject_scheduled_days[off.subject_id].include?(slot[:day])
      prev_end_times = subject_day_schedule[[off.subject_id, slot[:day]]] || []
      next if prev_end_times.any? { |prev_end| (prev_end.to_i - start_time.to_i).abs <= 60*60 }

      assigned_gene = {
        subject_offering_id: off.id,
        room_id: room.id,
        day: slot[:day],
        start_time: start_time,
        duration_minutes: duration,
        type: type
      }

      # Track schedules
      room_occupancy[[room.id, slot[:day]]] << [start_time, end_time]
      teacher_schedule[[off.teacher_id, slot[:day]]] << [start_time, end_time]
      section_schedule[[off.section_id, slot[:day]]] << [start_time, end_time]
      subject_day_schedule[[off.subject_id, slot[:day]]] ||= []
      subject_day_schedule[[off.subject_id, slot[:day]]] << end_time
      subject_scheduled_days[off.subject_id] << slot[:day]

      break
    end

    # fallback
    assigned_gene ||= {
      subject_offering_id: off.id,
      room_id: rooms.select { |r| r.room_type == type }.sample.id,
      day: slots.first[:day],
      start_time: slots.first[:start_time],
      duration_minutes: duration,
      type: type
    }

    assigned_gene
  end

  # -----------------------------
  # Mutation
  # -----------------------------
  def mutate(chromosome)
    subject_scheduled_days = Hash.new { |h, k| h[k] = Set.new }
    chromosome.each do |gene|
      off = offerings.find { |o| o.id == gene[:subject_offering_id] }
      subject_scheduled_days[off.subject_id] << gene[:day]
    end

    chromosome.each do |gene|
      next unless rand < mutation_rate
      off = offerings.find { |o| o.id == gene[:subject_offering_id] }
      slots = off.day_group == "weekdays" ? weekday_slots : weekend_slots
      room_type = gene[:type]

      50.times do
        slot = slots.sample
        room = rooms.select { |r| r.room_type == room_type }.sample
        start_time = slot[:start_time]
        end_time = start_time + gene[:duration_minutes].minutes
        next if end_time > Time.parse("17:00")
        next if subject_scheduled_days[off.subject_id].include?(slot[:day])

        # Check conflicts
        next if chromosome.any? do |g|
          g_off = offerings.find { |o| o.id == g[:subject_offering_id] }
          g[:day] == slot[:day] && overlaps?([start_time, end_time], [g[:start_time], g[:start_time] + g[:duration_minutes].minutes]) &&
            (g[:room_id] == room.id || g_off.teacher_id == off.teacher_id || g_off.section_id == off.section_id || g_off.subject_id == off.subject_id)
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
  # Fitness function
  # -----------------------------
  def fitness(chromosome)
    total_penalty = 0.0
    room_schedule = Hash.new { |h,k| h[k] = [] }
    teacher_schedule = Hash.new { |h,k| h[k] = [] }
    section_schedule = Hash.new { |h,k| h[k] = [] }
    subject_days = Hash.new { |h,k| h[k] = Set.new }

    chromosome.each do |gene|
      off = offerings.find { |o| o.id == gene[:subject_offering_id] }
      start = gene[:start_time]
      finish = start + gene[:duration_minutes].minutes

      room_schedule[[gene[:room_id], gene[:day]]] << [start, finish]
      teacher_schedule[[off.teacher_id, gene[:day]]] << [start, finish]
      section_schedule[[off.section_id, gene[:day]]] << [start, finish]
      subject_days[off.subject_id] << gene[:day]

      total_penalty += 1.5 if off.preferred_days_array.any? && !off.preferred_days_array.include?(gene[:day])
    end

    room_schedule.each    { |_, intervals| total_penalty += overlap_penalty(intervals) * 100.0 }
    teacher_schedule.each { |_, intervals| total_penalty += overlap_penalty(intervals) * 50.0 }
    section_schedule.each { |_, intervals| total_penalty += overlap_penalty(intervals) * 50.0 }

    # Consecutive lec/lab penalty
    chromosome.group_by { |gene| offerings.find { |o| o.id == gene[:subject_offering_id] }.subject_id }.each do |subject_id, genes|
      genes.group_by { |g| g[:day] }.each do |day, day_genes|
        sorted = day_genes.sort_by { |g| g[:start_time] }
        sorted.each_cons(2) do |g1, g2|
          type1 = g1[:type]
          type2 = g2[:type]
          total_penalty += 5.0 if (type1 == "lec" && type2 == "lab") || (type1 == "lab" && type2 == "lec")
        end
      end
    end

    # Penalize same-subject sessions on the same day
    subject_days.each { |_, days| total_penalty += 10.0 if days.size < offerings.count { |o| o.subject_id == _ } }

    1.0 / (1.0 + total_penalty)
  end

  # -----------------------------
  # Helpers
  # -----------------------------
  def build_time_slots(days)
    slots = []
    days.each do |day|
      (8..16).each do |hour|
        [0,30].each do |minute|
          t = Time.parse("#{hour}:#{minute}")
          slots << { day: day, start_time: t } if t + 3.hours <= Time.parse("17:00")
        end
      end
    end
    slots
  end

  def overlap_penalty(intervals)
    penalty = 0
    intervals.combination(2) { |a,b| penalty += 1 if overlaps?(a,b) }
    penalty
  end

  def overlaps?(a,b)
    a_start, a_end = a
    b_start, b_end = b
    (a_start < b_end) && (b_start < a_end)
  end

  # -----------------------------
  # Selection & Crossover
  # -----------------------------
  def select_parents(scored)
    weights = scored.map { |_, score| score }
    parent1 = scored[weighted_sample(weights)].first
    parent2 = scored[weighted_sample(weights)].first
    [parent1, parent2]
  end

  def weighted_sample(weights)
    total = weights.sum
    point = rand * total
    weights.each_with_index do |w, i|
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
end

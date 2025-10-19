# app/services/genetic_scheduler_service.rb
require 'set'
require 'parallel'

class GeneticSchedulerService
  attr_reader :semester, :population_size, :generations, :mutation_rate, :crossover_rate,
              :offerings, :rooms, :lec_rooms, :lab_rooms, :offering_lookup, :session_plan_cache,
              :weekday_slots, :weekend_slots

  def initialize(semester:, population_size: nil, generations: 200,
                 mutation_rate: 0.05, crossover_rate: 0.8, year_level: nil, section_id: nil)
    @semester = semester
    @generations = generations
    @mutation_rate = mutation_rate
    @crossover_rate = crossover_rate

    # Auto-adjust population size based on problem complexity
    offering_count = semester.subject_offerings.count
    @population_size = population_size || 
                      [50, (100 * Math.log(offering_count + 1)).round].min
    
    # Reduce generations for larger problems
    @generations = [generations, (200 * (1.0 / Math.log(offering_count + 2))).round].max

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
  # Run GA with timeout
  # -----------------------------
  def run
    return [] if offerings.empty?

    puts "Starting genetic algorithm with #{offerings.size} offerings"
    start_time = Time.now
    timeout_threshold = 2.75.hours # Stop before 3 hours

    population = Array.new(population_size) { generate_random_chromosome }
    best_score = -Float::INFINITY
    stagnant_generations = 0

    generations.times do |gen|
      # Check timeout
      if Time.now - start_time > timeout_threshold
        puts "Time limit reached after #{gen} generations"
        break
      end

      scored = Parallel.map(population, in_threads: 4) { |chrom| [chrom, fitness(chrom)] }
      scored.sort_by! { |_, score| -score }

      current_best_score = scored.first.last
      
      if current_best_score > best_score
        best_score = current_best_score
        stagnant_generations = 0
        puts "Generation #{gen}: New best score = #{best_score.round(4)}"
      else
        stagnant_generations += 1
      end

      # More aggressive termination for large problems
      break if stagnant_generations >= [15, generations / 10].min

      elite_size = (population_size * 0.2).to_i
      new_population = scored.first(elite_size).map(&:first)

      while new_population.size < population_size
        parent1, parent2 = select_parents(scored)
        child1, child2 = crossover(parent1, parent2)
        new_population << mutate(child1)
        new_population << mutate(child2) if new_population.size < population_size
      end

      population = new_population.first(population_size)
    end

    best_chromosome = population.max_by { |chrom| fitness(chrom) }
    puts "Final fitness: #{fitness(best_chromosome).round(4)}"
    
    # Convert back to Time objects for final output
    convert_chromosome_to_time_objects(best_chromosome)
  end

  # -----------------------------
  # Generate chromosome with optimized ordering
  # -----------------------------
  def generate_random_chromosome
    chromosome = []
    room_occupancy = Hash.new { |h,k| h[k] = [] }
    teacher_schedule = Hash.new { |h,k| h[k] = [] }
    section_schedule = Hash.new { |h,k| h[k] = [] }
    subject_day_schedule = Hash.new { |h,k| h[k] = [] }
    subject_scheduled_days = Hash.new { |h,k| h[k] = Set.new }
    daily_subject_count = Hash.new { |h, k| h[k] = Hash.new(0) }

    # Sort by difficulty (subjects with more sessions first)
    sorted_offerings = offerings.sort_by { |off| -session_plan_cache[off.subject_id].size }

    sorted_offerings.each do |off|
      session_plan_cache[off.subject_id].each do |duration, type|
        gene = assign_gene(off, duration, type,
                           room_occupancy, teacher_schedule, section_schedule,
                           subject_day_schedule, subject_scheduled_days, daily_subject_count)
        chromosome << gene if gene
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
  # NEW: Calculate long gap penalty
  # -----------------------------
  def calculate_long_gap_penalty(day_schedule)
    return 0.0 if day_schedule.nil? || day_schedule.empty?
    
    valid_schedule = day_schedule.select { |interval| interval.is_a?(Array) && interval.size == 2 }
    return 0.0 if valid_schedule.empty?
    
    sorted_schedule = valid_schedule.sort_by(&:first)
    penalty = 0.0
    
    # Check gaps between consecutive classes
    sorted_schedule.each_cons(2) do |class1, class2|
      gap_duration = class2[0] - class1[1] # minutes between classes
      
      # Penalize gaps longer than 2 hours (120 minutes)
      if gap_duration > 120
        # Increase penalty exponentially with gap size
        excess_gap = gap_duration - 120
        penalty += 2.0 * (excess_gap / 30.0) ** 2 # Quadratic penalty for larger gaps
      end
    end
    
    penalty
  end

  # -----------------------------
  # UPDATED: Assign gene with long gap avoidance
  # -----------------------------
  def assign_gene(off, duration, type, room_occupancy, teacher_schedule, section_schedule, subject_day_schedule, subject_scheduled_days, daily_subject_count)
    slots = off.day_group == "weekdays" ? weekday_slots : weekend_slots
    slots = filter_slots_by_strict_time(slots, off.preferred_time)

    # Sort slots by day and time for more systematic assignment
    slots = slots.sort_by { |s| [s[:day], s[:start_minutes]] }

    room_candidates = off.preferred_room_ids.any? ? 
                    rooms.select { |r| off.preferred_room_ids.include?(r.id) } : 
                    (type == 'lec' ? lec_rooms : lab_rooms)

    assigned_gene = nil
    best_slot = nil
    min_long_gap_penalty = Float::INFINITY

    # Try to find a valid slot that respects all constraints
    slots.each do |slot|
      # Enforce daily subject count constraint
      max_subjects_per_day = slot[:day] == "Saturday" ? 1 : 4
      current_count = daily_subject_count[off.section_id][slot[:day]]
      
      # Skip if daily limit reached
      next if current_count >= max_subjects_per_day

      # Check if subject already scheduled on this day
      next if subject_scheduled_days[off.subject_id].include?(slot[:day])

      # Check consecutive subject constraint
      section_day_schedule = section_schedule[[off.section_id, slot[:day]]]
      if section_day_schedule.any?
        temp_schedule = section_day_schedule + [[slot[:start_minutes], slot[:start_minutes] + duration]]
        temp_schedule.sort_by!(&:first)
        
        consecutive_count = calculate_consecutive_subjects_count(temp_schedule)
        next if consecutive_count >= 4
      end

      # Find available room
      room = room_candidates.find do |r|
        !room_occupancy[[r.id, slot[:day]]].any? { |s,e| overlaps?([s,e],[slot[:start_minutes], slot[:start_minutes] + duration]) }
      end
      next unless room

      # Check teacher availability
      next if teacher_schedule[[off.teacher_id, slot[:day]]].any? { |s,e| overlaps?([s,e],[slot[:start_minutes], slot[:start_minutes] + duration]) }
      
      # Check section availability
      next if section_schedule[[off.section_id, slot[:day]]].any? { |s,e| overlaps?([s,e],[slot[:start_minutes], slot[:start_minutes] + duration]) }
      
      # Check minimum gap between sessions of same subject (at least 1 hour)
      prev_end_times = subject_day_schedule[[off.subject_id, slot[:day]]] || []
      next if prev_end_times.any? { |prev_end| (prev_end - slot[:start_minutes]).abs <= 60 }

      start_minutes = slot[:start_minutes]
      end_minutes = start_minutes + duration
      next if end_minutes > 1020

      # NEW: Calculate long gap penalty for this slot
      if section_day_schedule.any?
        temp_schedule = section_day_schedule + [[start_minutes, end_minutes]]
        long_gap_penalty = calculate_long_gap_penalty(temp_schedule)
        
        # Track the slot with minimum long gap penalty
        if long_gap_penalty < min_long_gap_penalty
          min_long_gap_penalty = long_gap_penalty
          best_slot = { slot: slot, room: room, start_minutes: start_minutes, end_minutes: end_minutes }
        end
      else
        # First class of the day - no gap penalty
        best_slot = { slot: slot, room: room, start_minutes: start_minutes, end_minutes: end_minutes }
        break # Take the first available slot if it's the first class
      end
    end

    if best_slot
      assigned_gene = {
        subject_offering_id: off.id,
        room_id: best_slot[:room].id,
        day: best_slot[:slot][:day],
        start_minutes: best_slot[:start_minutes],
        duration_minutes: duration,
        type: type
      }

      # Update all tracking structures
      room_occupancy[[best_slot[:room].id, best_slot[:slot][:day]]] << [best_slot[:start_minutes], best_slot[:end_minutes]]
      teacher_schedule[[off.teacher_id, best_slot[:slot][:day]]] << [best_slot[:start_minutes], best_slot[:end_minutes]]
      section_schedule[[off.section_id, best_slot[:slot][:day]]] << [best_slot[:start_minutes], best_slot[:end_minutes]]
      subject_day_schedule[[off.subject_id, best_slot[:slot][:day]]] ||= []
      subject_day_schedule[[off.subject_id, best_slot[:slot][:day]]] << best_slot[:end_minutes]
      subject_scheduled_days[off.subject_id] << best_slot[:slot][:day]
      daily_subject_count[off.section_id][best_slot[:slot][:day]] += 1
    else
      # Fallback assignment if no valid slot found (with penalty)
      room = room_candidates.first
      slot = slots.first
      assigned_gene = {
        subject_offering_id: off.id,
        room_id: room.id,
        day: slot[:day],
        start_minutes: slot[:start_minutes],
        duration_minutes: duration,
        type: type
      }
      daily_subject_count[off.section_id][slot[:day]] += 1
    end

    assigned_gene
  end

  # -----------------------------
  # Calculate consecutive subjects count
  # -----------------------------
  def calculate_consecutive_subjects_count(day_schedule)
    return 0 if day_schedule.nil? || day_schedule.empty?
    
    valid_schedule = day_schedule.select { |interval| interval.is_a?(Array) && interval.size == 2 }
    return 0 if valid_schedule.empty?
    
    sorted_schedule = valid_schedule.sort_by(&:first)
    max_consecutive = 1
    current_consecutive = 1
    
    sorted_schedule.each_cons(2) do |class1, class2|
      break_duration = class2[0] - class1[1]
      
      # Considered consecutive if break is less than 30 minutes
      if break_duration < 30
        current_consecutive += 1
        max_consecutive = [max_consecutive, current_consecutive].max
      else
        current_consecutive = 1
      end
    end
    
    max_consecutive
  end

  # -----------------------------
  # UPDATED: Fitness with long gap penalties
  # -----------------------------
  def fitness(chromosome)
    total_penalty = 0.0
    room_schedule = Hash.new { |h,k| h[k] = [] }
    teacher_schedule = Hash.new { |h,k| h[k] = [] }
    section_schedule = Hash.new { |h,k| h[k] = [] }
    subject_days = Hash.new { |h,k| h[k] = Set.new }
    daily_subject_count = Hash.new { |h, k| h[k] = Hash.new(0) }

    # First pass: collect schedule data with validation
    chromosome.each do |gene|
      next unless gene && gene[:start_minutes].is_a?(Numeric) && gene[:duration_minutes].is_a?(Numeric) && gene[:day]
      
      off = offering_lookup[gene[:subject_offering_id]]
      next unless off

      start_minutes = gene[:start_minutes]
      end_minutes = start_minutes + gene[:duration_minutes]

      room_schedule[[gene[:room_id], gene[:day]]] << [start_minutes, end_minutes]
      teacher_schedule[[off.teacher_id, gene[:day]]] << [start_minutes, end_minutes]
      section_schedule[[off.section_id, gene[:day]]] << [start_minutes, end_minutes]
      subject_days[off.subject_id] << gene[:day]
      daily_subject_count[off.section_id][gene[:day]] += 1
    end

    # Daily subject count penalty
    daily_subject_count.each do |section_id, daily_counts|
      daily_counts.each do |day, count|
        next unless day && count.is_a?(Numeric)
        
        if day == "Saturday"
          total_penalty += 1000.0 * (count - 1) if count > 1
        else
          total_penalty += 500.0 * (count - 4) if count > 4
        end
      end
    end
    
    # Consecutive subject penalty
    section_schedule.each do |(section_id, day), intervals|
      next unless day && intervals.is_a?(Array)
      
      valid_intervals = intervals.select { |interval| interval.is_a?(Array) && interval.size == 2 }
      next if valid_intervals.empty?
      
      consecutive_count = calculate_consecutive_subjects_count(valid_intervals)
      
      if consecutive_count >= 4
        total_penalty += 2000.0 * (consecutive_count - 3)
      end
    end
    
    # NEW: Long gap penalty
    section_schedule.each do |(section_id, day), intervals|
      next unless day && intervals.is_a?(Array)
      
      valid_intervals = intervals.select { |interval| interval.is_a?(Array) && interval.size == 2 }
      next if valid_intervals.empty?
      
      long_gap_penalty = calculate_long_gap_penalty(valid_intervals)
      total_penalty += long_gap_penalty
    end
    
    # Early return for invalid schedules
    return 0.0 if total_penalty > 10000

    # Overlap detection
    [room_schedule, teacher_schedule, section_schedule].each do |schedule|
      schedule.each_value do |intervals|
        valid_intervals = intervals.select { |interval| interval.is_a?(Array) && interval.size == 2 }
        sorted = valid_intervals.sort_by(&:first)
        
        sorted.each_cons(2) do |a, b|
          total_penalty += 100.0 if a[1] > b[0]
        end
      end
    end

    # Consecutive lec/lab penalty
    chromosome.group_by { |g| g && offering_lookup[g[:subject_offering_id]]&.subject_id }.each do |subject_id, genes|
      next unless subject_id
      
      genes.compact.group_by { |g| g[:day] }.each do |day, day_genes|
        next unless day
        
        sorted = day_genes.select { |g| g[:start_minutes].is_a?(Numeric) }.sort_by { |g| g[:start_minutes] }
        sorted.each_cons(2) { |g1,g2| total_penalty += 5.0 if g1 && g2 && (g1[:type] != g2[:type]) }
      end
    end

    # Same-subject distribution penalty
    subject_days.each do |subject_id, days|
      next unless subject_id && days.is_a?(Set)
      
      session_parts_count = session_plan_cache[subject_id]&.size || 0
      if session_parts_count > 0
        total_penalty += 10.0 if days.size < session_parts_count
      end
    end
    
    1.0 / (1.0 + total_penalty)
  end

  # -----------------------------
  # UPDATED: Mutation with long gap consideration
  # -----------------------------
  def mutate(chromosome)
    return chromosome if rand >= mutation_rate

    subject_scheduled_days = Hash.new { |h,k| h[k] = Set.new }
    daily_subject_count = Hash.new { |h, k| h[k] = Hash.new(0) }
    section_schedule = Hash.new { |h,k| h[k] = [] }
    
    chromosome.each do |gene|
      off = offering_lookup[gene[:subject_offering_id]]
      subject_scheduled_days[off.subject_id] << gene[:day]
      daily_subject_count[off.section_id][gene[:day]] += 1
      section_schedule[[off.section_id, gene[:day]]] << [gene[:start_minutes], gene[:start_minutes] + gene[:duration_minutes]]
    end

    mutation_count = [1, (chromosome.size * 0.15).round].max
    indices_to_mutate = (0...chromosome.size).to_a.sample(mutation_count)
    
    indices_to_mutate.each do |index|
      gene = chromosome[index]
      off = offering_lookup[gene[:subject_offering_id]]
      original_day = gene[:day]
      
      slots = off.day_group == "weekdays" ? weekday_slots : weekend_slots
      slots = filter_slots_by_strict_time(slots, off.preferred_time)

      type_rooms = gene[:type] == 'lec' ? lec_rooms : lab_rooms
      available_rooms = off.preferred_room_ids.any? ? 
                       type_rooms.select { |r| off.preferred_room_ids.include?(r.id) } : 
                       type_rooms
      available_rooms = type_rooms if available_rooms.empty?

      best_slot = nil
      min_long_gap_penalty = Float::INFINITY

      10.times do # Try more times to find a good slot
        slot = slots.sample
        room = available_rooms.sample
        
        max_subjects_per_day = slot[:day] == "Saturday" ? 1 : 4
        current_count = daily_subject_count[off.section_id][slot[:day]]
        next if current_count >= max_subjects_per_day

        # Check consecutive subject constraint
        section_day_schedule = section_schedule[[off.section_id, slot[:day]]]
        if section_day_schedule.any?
          temp_schedule = section_day_schedule + [[slot[:start_minutes], slot[:start_minutes] + gene[:duration_minutes]]]
          next if calculate_consecutive_subjects_count(temp_schedule) >= 4
        end

        start_minutes = slot[:start_minutes]
        end_minutes = start_minutes + gene[:duration_minutes]
        next if end_minutes > 1020
        
        next if original_day != slot[:day] && subject_scheduled_days[off.subject_id].include?(slot[:day])

        conflict = chromosome.any? do |g|
          next if g == gene
          
          g_off = offering_lookup[g[:subject_offering_id]]
          g[:day] == slot[:day] &&
            overlaps?([start_minutes, end_minutes], 
                     [g[:start_minutes], g[:start_minutes] + g[:duration_minutes]]) &&
            (g[:room_id] == room.id || g_off.teacher_id == off.teacher_id || 
             g_off.section_id == off.section_id || g_off.subject_id == off.subject_id)
        end
        next if conflict

        # NEW: Calculate long gap penalty for this mutation
        if section_day_schedule.any?
          temp_schedule = section_day_schedule + [[start_minutes, end_minutes]]
          long_gap_penalty = calculate_long_gap_penalty(temp_schedule)
          
          if long_gap_penalty < min_long_gap_penalty
            min_long_gap_penalty = long_gap_penalty
            best_slot = { slot: slot, room: room, start_minutes: start_minutes }
          end
        else
          best_slot = { slot: slot, room: room, start_minutes: start_minutes }
          break
        end
      end

      if best_slot
        # Update tracking structures
        daily_subject_count[off.section_id][original_day] -= 1
        daily_subject_count[off.section_id][best_slot[:slot][:day]] += 1
        
        if original_day != best_slot[:slot][:day]
          subject_scheduled_days[off.subject_id].delete(original_day)
          subject_scheduled_days[off.subject_id] << best_slot[:slot][:day]
          section_schedule[[off.section_id, original_day]].delete([gene[:start_minutes], gene[:start_minutes] + gene[:duration_minutes]])
          section_schedule[[off.section_id, best_slot[:slot][:day]]] << [best_slot[:start_minutes], best_slot[:start_minutes] + gene[:duration_minutes]]
        end
        
        # Apply mutation
        gene[:room_id] = best_slot[:room].id
        gene[:day] = best_slot[:slot][:day]
        gene[:start_minutes] = best_slot[:start_minutes]
      end
    end

    chromosome
  end

  # -----------------------------
  # Build time slots with minute-based optimization
  # -----------------------------
  def build_time_slots(days)
    slots = []
    days.each do |day|
      # AM: 8:00 to 12:00 (480 to 720 minutes)
      [480, 510, 540, 570, 600, 630, 660, 690].each do |start_minutes|
        next if start_minutes + 30 > 720
        slots << { day: day, start_minutes: start_minutes, period: "AM" }
      end
      # PM: 1:00 to 4:30 (780 to 1020 minutes)
      [780, 810, 840, 870, 900, 930, 960].each do |start_minutes|
        slots << { day: day, start_minutes: start_minutes, period: "PM" }
      end
    end

    slots
  end

  # -----------------------------
  # Helper methods
  # -----------------------------
  def overlaps?(a, b)
    a_start, a_end = a
    b_start, b_end = b
    (a_start < b_end) && (b_start < a_end)
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

  def convert_chromosome_to_time_objects(chromosome)
    return [] unless chromosome
    
    chromosome.map do |gene|
      next unless gene && gene[:start_minutes]
      
      hours = gene[:start_minutes] / 60
      minutes = gene[:start_minutes] % 60
      start_time = Time.parse("#{hours}:#{minutes.to_s.rjust(2, '0')}")
      
      {
        subject_offering_id: gene[:subject_offering_id],
        room_id: gene[:room_id],
        day: gene[:day],
        start_time: start_time,
        duration_minutes: gene[:duration_minutes],
        type: gene[:type]
      }
    end.compact
  end
end
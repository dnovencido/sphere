# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

# db/seeds.rb

Term.destroy_all
Section.destroy_all
Teacher.destroy_all
Subject.destroy_all
Room.destroy_all
SubjectOffering.destroy_all

# Term
current_term = Term.create!(name: "1st Semester 2025")

# === Section Setup ===
section = Section.find_or_create_by!(name: "BSInfoTech-1A", year_level: 1, term: current_term)

# === Teachers ===
teachers = {
  "B. Valmonte"  => Teacher.find_or_create_by!(name: "B. Valmonte"),
  "R. Cadelina"  => Teacher.find_or_create_by!(name: "R. Cadelina"),
  "R. Catbagan"  => Teacher.find_or_create_by!(name: "R. Catbagan"),
  "L. Maquiling" => Teacher.find_or_create_by!(name: "L. Maquiling"),
  "R. Flores"    => Teacher.find_or_create_by!(name: "R. Flores"),
  "C. Bangug"    => Teacher.find_or_create_by!(name: "C. Bangug"),
  "D. Torres"    => Teacher.find_or_create_by!(name: "D. Torres"),
  "J. Dela Cruz" => Teacher.find_or_create_by!(name: "J. Dela Cruz")
}

# === Subjects & Offerings ===
subjects = [
  { code: "GEEC 101", title: "GEEC 101", session_duration: "3x1hr", year_level: 1,  day_group: "weekdays", teacher: "B. Valmonte" },
  { code: "GECC 101", title: "GECC 101", session_duration: "3x1hr",  year_level: 1,  day_group: "weekdays", teacher: "R. Cadelina" },
  { code: "GECC 102", title: "GECC 102", session_duration: "2x1.5hr", year_level: 1, day_group: "weekdays", teacher: "R. Catbagan" },
  { code: "ITCC 102 LAB", title: "ITCC 102 (Lab)", session_duration: "2x1.5hr", year_level: 1, has_lab: true, day_group: "weekdays", teacher: "L. Maquiling" },
  { code: "ITCC 102 LEC", title: "ITCC 102 (Lecture)", session_duration: "2x1hr", year_level: 1, day_group: "weekdays", teacher: "L. Maquiling" },
  { code: "PATHFIT 101", title: "Pathfit 101)", session_duration: "1x3hr", year_level: 1, day_group: "weekdays", teacher: "R. Flores" },
  { code: "ITCC 101 LAB", title: "ITCC 101 (Lab)", session_duration: "2x1.5hr", year_level: 1, has_lab: true, day_group: "weekdays", teacher: "C. Bangug" },
  { code: "ITCC 101 LEC", title: "ITCC 101 (Lecture)", session_duration: "2x1hr", year_level: 1, day_group: "weekdays", teacher: "C. Bangug" },
  { code: "GECC 103", title: "GECC 103", session_duration: "1x3hr", year_level: 1, day_group: "weekdays", teacher: "D. Torres" },
  { code: "NSTP 101", title: "NSTP 101", session_duration: "1x3hr", year_level: 1, day_group: "weekends", teacher: "J. Dela Cruz" }
]

subjects.each do |s|
  subj = Subject.find_or_create_by!(code: s[:code]) do |sub|
    sub.title = s[:title]
    sub.year_level = s[:year_level]
    sub.has_lab = s[:has_lab]
    sub.session_duration = s[:session_duration]
  end

  SubjectOffering.find_or_create_by!(
    term: current_term,
    subject: subj,
    teacher: teachers[s[:teacher]],
    section: section,
    day_group: s[:day_group] 
  )
end

# === Rooms ===
rooms = [
  { name: "RM 202",   room_type: "lec" },
  { name: "RM 207",   room_type: "lec" },
  { name: "RM 203",   room_type: "lec" },
  { name: "LAB 206",  room_type: "lab" },
  { name: "LAB 201",  room_type: "lab" },
  { name: "CIT GRND", room_type: "lec" }
]

rooms.each do |r|
  Room.find_or_create_by!(name: r[:name]) do |room|
    room.room_type = r[:room_type]
  end
end

puts "✅ Seeded #{Room.count} rooms."

puts "✅ Seeded 1st Year Schedule (#{SubjectOffering.count} offerings)."

# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2025_09_23_033536) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "admins", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_admins_on_email", unique: true
    t.index ["reset_password_token"], name: "index_admins_on_reset_password_token", unique: true
  end

  create_table "rooms", force: :cascade do |t|
    t.string "name", null: false
    t.integer "room_type", default: 0, null: false
    t.integer "capacity"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "schedule_entries", force: :cascade do |t|
    t.bigint "schedule_id", null: false
    t.bigint "subject_offering_id", null: false
    t.bigint "room_id", null: false
    t.string "day", null: false
    t.time "start_time", null: false
    t.integer "duration_minutes", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["room_id"], name: "index_schedule_entries_on_room_id"
    t.index ["schedule_id"], name: "index_schedule_entries_on_schedule_id"
    t.index ["subject_offering_id"], name: "index_schedule_entries_on_subject_offering_id"
  end

  create_table "schedules", force: :cascade do |t|
    t.bigint "term_id", null: false
    t.string "name"
    t.float "fitness_score"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["term_id"], name: "index_schedules_on_term_id"
  end

  create_table "sections", force: :cascade do |t|
    t.string "name", null: false
    t.integer "year_level", null: false
    t.bigint "term_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["term_id"], name: "index_sections_on_term_id"
  end

  create_table "subject_offerings", force: :cascade do |t|
    t.bigint "term_id", null: false
    t.bigint "subject_id", null: false
    t.bigint "teacher_id", null: false
    t.integer "max_students"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "section_id", null: false
    t.string "preferred_days", default: [], array: true
    t.string "day_group", default: "weekdays", null: false
    t.integer "preferred_room_ids", default: [], null: false, array: true
    t.string "preferred_time"
    t.index ["section_id"], name: "index_subject_offerings_on_section_id"
    t.index ["subject_id"], name: "index_subject_offerings_on_subject_id"
    t.index ["teacher_id"], name: "index_subject_offerings_on_teacher_id"
    t.index ["term_id"], name: "index_subject_offerings_on_term_id"
  end

  create_table "subjects", force: :cascade do |t|
    t.string "code", null: false
    t.string "title"
    t.integer "year_level"
    t.integer "lecture_duration_minutes", default: 60
    t.integer "lab_duration_minutes", default: 90
    t.boolean "has_lab", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "session_duration"
  end

  create_table "teachers", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "terms", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "schedule_entries", "rooms"
  add_foreign_key "schedule_entries", "schedules"
  add_foreign_key "schedule_entries", "subject_offerings"
  add_foreign_key "schedules", "terms"
  add_foreign_key "sections", "terms"
  add_foreign_key "subject_offerings", "sections"
  add_foreign_key "subject_offerings", "subjects"
  add_foreign_key "subject_offerings", "teachers"
  add_foreign_key "subject_offerings", "terms"
end

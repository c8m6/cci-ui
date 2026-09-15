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

ActiveRecord::Schema[8.1].define(version: 2026_09_15_000100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.string "actor", null: false
    t.string "area", null: false
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.jsonb "references", default: [], null: false
    t.string "store_event_id"
    t.datetime "updated_at", null: false
    t.index ["area", "occurred_at", "id"], name: "index_audit_events_on_area_and_occurred_at_and_id"
    t.index ["store_event_id"], name: "index_audit_events_on_store_event_id", unique: true
  end

  create_table "certificates", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "algorithm"
    t.string "area", null: false
    t.string "client"
    t.string "common_name", null: false
    t.datetime "created_at", null: false
    t.string "created_by"
    t.string "entry_id"
    t.string "fingerprint", null: false
    t.boolean "has_key", default: false, null: false
    t.datetime "indexed_at", null: false
    t.text "issuer", null: false
    t.string "lookup"
    t.datetime "not_after", null: false
    t.datetime "not_before", null: false
    t.string "rollout_status", default: "active", null: false
    t.jsonb "sans", default: [], null: false
    t.text "search_text", null: false
    t.string "serial", null: false
    t.string "source", null: false
    t.string "source_id", null: false
    t.text "subject", null: false
    t.jsonb "tags", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["area", "active", "not_after"], name: "index_certificates_on_area_and_active_and_not_after"
    t.index ["area", "rollout_status"], name: "index_certificates_on_area_and_rollout_status"
    t.index ["area", "source", "source_id"], name: "index_certificates_on_area_and_source_and_source_id", unique: true
    t.index ["entry_id"], name: "index_certificates_on_entry_id"
    t.index ["fingerprint"], name: "index_certificates_on_fingerprint"
    t.index ["search_text"], name: "index_certificates_on_search_text", opclass: :gin_trgm_ops, using: :gin
    t.check_constraint "rollout_status::text = ANY (ARRAY['active'::character varying::text, 'norollout'::character varying::text, 'delete'::character varying::text])", name: "certificates_rollout_status"
  end

  create_table "import_drafts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "owner", null: false
    t.text "payload", null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_import_drafts_on_expires_at"
    t.index ["token"], name: "index_import_drafts_on_token", unique: true
  end
end

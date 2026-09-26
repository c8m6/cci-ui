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

ActiveRecord::Schema[8.1].define(version: 2026_09_26_000200) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "audit_events", force: :cascade do |t|
    t.string "action", null: false
    t.string "actor", null: false
    t.text "actor_display_name"
    t.string "area", null: false
    t.datetime "created_at", null: false
    t.jsonb "details", default: {}, null: false
    t.datetime "occurred_at", null: false
    t.jsonb "references", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["area", "occurred_at", "id"], name: "index_audit_events_on_area_and_occurred_at_and_id"
  end

  create_table "ca_inventories", force: :cascade do |t|
    t.string "area", null: false
    t.jsonb "authorities", default: [], null: false
    t.datetime "checked_at"
    t.datetime "created_at", null: false
    t.datetime "error_at"
    t.jsonb "issues", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["area"], name: "index_ca_inventories_on_area", unique: true
  end

  create_table "certificate_requests", force: :cascade do |t|
    t.string "area", null: false
    t.string "certid", null: false
    t.text "comment", default: "", null: false
    t.string "common_name", null: false
    t.datetime "created_at", null: false
    t.string "created_by", null: false
    t.text "csr_pem", null: false
    t.string "digest", null: false
    t.text "encrypted_private_key", null: false
    t.text "encrypted_revoke_password", null: false
    t.string "key_algorithm", null: false
    t.integer "key_size", null: false
    t.jsonb "sans", default: [], null: false
    t.string "secret_id", null: false
    t.jsonb "subject_fields", default: {}, null: false
    t.jsonb "target_areas", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["area", "created_at"], name: "index_certificate_requests_on_area_and_created_at"
    t.index ["target_areas"], name: "index_certificate_requests_on_target_areas", using: :gin
    t.index ["secret_id"], name: "index_certificate_requests_on_secret_id", unique: true
  end

  create_table "certificates", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "algorithm"
    t.boolean "archived", default: false, null: false
    t.string "area", null: false
    t.string "certid"
    t.integer "certificate_version"
    t.string "client"
    t.string "common_name", null: false
    t.datetime "created_at", null: false
    t.string "created_by"
    t.datetime "deleted_at"
    t.string "fingerprint", null: false
    t.boolean "has_key", default: false, null: false
    t.datetime "imported_at"
    t.datetime "indexed_at", null: false
    t.text "issuer", null: false
    t.datetime "not_after", null: false
    t.datetime "not_before", null: false
    t.datetime "puppetdb_checked_at"
    t.datetime "puppetdb_error_at"
    t.jsonb "puppetdb_hosts", default: [], null: false
    t.string "rollout_status", default: "active", null: false
    t.jsonb "sans", default: [], null: false
    t.text "search_text", null: false
    t.string "serial", null: false
    t.string "sha1_fingerprint"
    t.string "source", null: false
    t.string "source_id", null: false
    t.text "subject", null: false
    t.jsonb "tags", default: [], null: false
    t.datetime "updated_at", null: false
    t.index ["area", "active", "not_after"], name: "index_certificates_on_area_and_active_and_not_after"
    t.index ["area", "archived", "active"], name: "index_certificates_on_area_and_archived_and_active"
    t.index ["area", "rollout_status"], name: "index_certificates_on_area_and_rollout_status"
    t.index ["area", "source", "source_id", "fingerprint"], name: "index_certificates_on_source_identity_and_fingerprint", unique: true
    t.index ["deleted_at"], name: "index_certificates_on_deleted_at"
    t.index ["fingerprint"], name: "index_certificates_on_fingerprint"
    t.index ["search_text"], name: "index_certificates_on_search_text", opclass: :gin_trgm_ops, using: :gin
    t.index ["sha1_fingerprint"], name: "index_certificates_on_sha1_fingerprint"
    t.check_constraint "NOT archived OR rollout_status::text = 'delete'::text", name: "archived_certificates_request_deletion"
    t.check_constraint "jsonb_typeof(puppetdb_hosts) = 'array'::text", name: "certificate_puppetdb_hosts_are_array"
    t.check_constraint "rollout_status::text = ANY (ARRAY['active'::character varying::text, 'norollout'::character varying::text, 'delete'::character varying::text])", name: "certificates_rollout_status"
    t.check_constraint "source::text <> 'filesystem'::text OR NOT archived AND rollout_status::text = 'active'::text", name: "filesystem_certificates_have_no_control_state"
  end

  create_table "csr_certificates", force: :cascade do |t|
    t.bigint "certificate_request_id", null: false
    t.integer "consul_version"
    t.jsonb "consul_versions", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "error_code"
    t.string "fingerprint", null: false
    t.text "issuer", null: false
    t.jsonb "issuer_pems", default: [], null: false
    t.datetime "not_after", null: false
    t.datetime "not_before", null: false
    t.text "pem", null: false
    t.jsonb "prepared", default: {}, null: false
    t.datetime "published_at"
    t.jsonb "sans", default: [], null: false
    t.string "state", default: "awaiting_issuer", null: false
    t.text "subject", null: false
    t.datetime "updated_at", null: false
    t.string "uploaded_by", null: false
    t.datetime "verified_at"
    t.index ["certificate_request_id", "fingerprint"], name: "idx_on_certificate_request_id_fingerprint_19fcbe4096", unique: true
    t.index ["certificate_request_id"], name: "index_csr_certificates_on_certificate_request_id"
    t.check_constraint "state::text <> 'published'::text OR consul_version > 0 AND published_at IS NOT NULL", name: "csr_published_version"
    t.check_constraint "state::text = ANY (ARRAY['awaiting_issuer'::character varying, 'pending'::character varying, 'publishing'::character varying, 'published'::character varying, 'failed'::character varying]::text[])", name: "csr_certificate_state"
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

  add_foreign_key "csr_certificates", "certificate_requests"
end

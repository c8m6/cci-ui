# frozen_string_literal: true

# Abstract base for the PostgreSQL catalogue, draft and audit models.
class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class
end

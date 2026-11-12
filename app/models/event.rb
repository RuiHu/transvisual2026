class Event < ApplicationRecord
  VALID_STATUSES = %w[created picked_up in_transit delivered failed].freeze
  UTC_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/

  # Optional because the controller creates the shipment in the same
  # transaction; the association is still declared explicitly (plan §2.2).
  belongs_to :shipment, foreign_key: :shipment_reference, primary_key: :reference,
                        optional: true, inverse_of: :events

  validates :event_id, presence: true, uniqueness: true
  validates :shipment_reference, presence: true
  validates :status, presence: true, inclusion: { in: VALID_STATUSES }
  validates :event_timestamp, presence: true,
            format: { with: UTC_TIMESTAMP, message: "must be ISO 8601 with Z suffix" }
end

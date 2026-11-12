class Shipment < ApplicationRecord
  # String reference join (plan §2.2): no integer FK column, so the association
  # must name its foreign key explicitly.
  has_many :events, foreign_key: :shipment_reference, primary_key: :reference,
                    dependent: :destroy, inverse_of: :shipment

  validates :reference, presence: true, uniqueness: true

  # FR-6: derived at query time from all recorded events. event_id is the
  # deterministic tie-break required by FR-7 when timestamps are identical.
  def current_status
    events.order(event_timestamp: :desc, event_id: :desc).pick(:status)
  end

  def latest_event_at
    events.order(event_timestamp: :desc, event_id: :desc).pick(:event_timestamp)
  end
end

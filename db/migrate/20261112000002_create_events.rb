class CreateEvents < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      CREATE TABLE events (
        id                  bigserial PRIMARY KEY,
        event_id            varchar(50) NOT NULL,
        shipment_reference  varchar(50) NOT NULL,
        status              varchar(20) NOT NULL,
        event_timestamp     varchar(25) NOT NULL,
        created_at          timestamp   NOT NULL DEFAULT now(),
        updated_at          timestamp   NOT NULL DEFAULT now()
      );
    SQL

    # INDEX 1 (idempotency authority): every POST checks event_id.
    # The unique constraint is the atomic arbiter under concurrent duplicates.
    execute "CREATE UNIQUE INDEX idx_events_event_id ON events (event_id);"

    # INDEX 2 (timeline + derivation): equality on shipment_reference, sort on
    # event_timestamp. Serves both the ordered timeline and the max-timestamp
    # current_status derivation without a second index on event_timestamp.
    execute "CREATE INDEX idx_events_ship_ts ON events (shipment_reference, event_timestamp);"
  end

  def down
    execute "DROP TABLE IF EXISTS events;"
  end
end

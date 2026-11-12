class CreateShipments < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL
      CREATE TABLE shipments (
        id          bigserial PRIMARY KEY,
        reference   varchar(50) NOT NULL,
        created_at  timestamp   NOT NULL DEFAULT now(),
        updated_at  timestamp   NOT NULL DEFAULT now()
      );
    SQL

    # Natural key lookup on every ingestion (find_or_create_by!(reference:)).
    # UNIQUE also serialises concurrent first-event creation for one shipment.
    execute "CREATE UNIQUE INDEX idx_shipments_reference ON shipments (reference);"
  end

  def down
    execute "DROP TABLE IF EXISTS shipments;"
  end
end

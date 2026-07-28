-- Align notifications/shipments with service migrate() schemas.
-- 0001 originally captured a stale shape; CREATE IF NOT EXISTS cannot reshape
-- existing tables, so replace the empty first-boot tables.

DROP TABLE IF EXISTS tracking_events;
DROP TABLE IF EXISTS shipments;
DROP TABLE IF EXISTS notifications;
DROP TABLE IF EXISTS notification_templates;

CREATE TABLE notifications (
  id SERIAL PRIMARY KEY,
  recipient VARCHAR(255) NOT NULL,
  channel VARCHAR(20) NOT NULL,
  template VARCHAR(100) NOT NULL,
  subject TEXT,
  body TEXT NOT NULL,
  metadata JSONB,
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  sent_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX idx_notifications_recipient ON notifications(recipient);
CREATE INDEX idx_notifications_status ON notifications(status);

CREATE TABLE notification_templates (
  id VARCHAR(100) PRIMARY KEY,
  channel VARCHAR(20) NOT NULL,
  subject TEXT,
  body TEXT NOT NULL,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);

CREATE TABLE shipments (
  id SERIAL PRIMARY KEY,
  order_id INTEGER NOT NULL,
  carrier VARCHAR(50) NOT NULL,
  tracking_number VARCHAR(100) UNIQUE,
  status VARCHAR(30) NOT NULL DEFAULT 'label_created',
  recipient_name VARCHAR(255),
  address_line1 TEXT,
  address_line2 TEXT,
  city VARCHAR(100),
  postcode VARCHAR(20),
  country VARCHAR(2) DEFAULT 'GB',
  weight_kg DECIMAL(8,2),
  estimated_delivery DATE,
  shipped_at TIMESTAMP,
  delivered_at TIMESTAMP,
  created_at TIMESTAMP DEFAULT NOW(),
  updated_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX idx_shipments_order ON shipments(order_id);
CREATE INDEX idx_shipments_tracking ON shipments(tracking_number);

CREATE TABLE tracking_events (
  id SERIAL PRIMARY KEY,
  shipment_id INTEGER NOT NULL REFERENCES shipments(id),
  status VARCHAR(30) NOT NULL,
  location VARCHAR(255),
  description TEXT,
  occurred_at TIMESTAMP NOT NULL,
  created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX idx_tracking_shipment ON tracking_events(shipment_id);

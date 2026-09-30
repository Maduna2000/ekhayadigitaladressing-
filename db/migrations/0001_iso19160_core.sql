-- Ekhaya Addressing System: ISO 19160-1 style core schema (Cloudflare D1 / SQLite)
--
-- Mapping to the ISO 19160-1:2015 conceptual model:
--   profile             -> a country profile (here: the Eswatini SZNS ISO 19160 profile)
--   address_class       -> AddressClass (addresses sharing the same components and rules)
--   component_type      -> AddressComponent kinds (region, inkhundla, street, unit ...)
--   class_component     -> AddressReferenceSystem (which components a class uses, in what order)
--   address             -> Address (with lifecycle, position and metadata)
--   address_component   -> the component values that make up one address
--   address_alias       -> AddressAlias (local names, landmarks, former addresses)
--   address_event       -> Ekhaya verification evidence, aggregated into a confidence score
--                          (the on-the-ground counterpart of ISO 19160-3 data quality)
--
-- The profile, classes and components are DATA, not code. When the real SZNS
-- profile is obtained, update the rows in 0002/next seed; the API does not change.

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------- profile ---

CREATE TABLE profile (
  id          INTEGER PRIMARY KEY,
  code        TEXT NOT NULL UNIQUE,            -- e.g. 'SZNS-ISO19160'
  name        TEXT NOT NULL,
  version     TEXT NOT NULL,
  confirmed   INTEGER NOT NULL DEFAULT 0 CHECK (confirmed IN (0, 1)),
                                               -- 0 = placeholder, 1 = matches published standard
  source      TEXT                             -- where the definition came from
);

CREATE TABLE address_class (
  id          INTEGER PRIMARY KEY,
  profile_id  INTEGER NOT NULL REFERENCES profile(id),
  code        TEXT NOT NULL,                   -- 'street', 'rural', 'informal_settlement', ...
  name        TEXT NOT NULL,
  description TEXT,
  confirmed   INTEGER NOT NULL DEFAULT 0 CHECK (confirmed IN (0, 1)),
  UNIQUE (profile_id, code)
);

CREATE TABLE component_type (
  id          INTEGER PRIMARY KEY,
  profile_id  INTEGER NOT NULL REFERENCES profile(id),
  code        TEXT NOT NULL,                   -- 'region', 'inkhundla', 'street_name', 'unit' ...
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL CHECK (kind IN
                ('admin', 'locality', 'thoroughfare', 'number', 'building', 'unit', 'postal')),
  admin_level INTEGER,                         -- position in the admin tree, when kind = 'admin'
  UNIQUE (profile_id, code)
);

-- The address reference system: which components a class uses and in what order.
CREATE TABLE class_component (
  class_id          INTEGER NOT NULL REFERENCES address_class(id),
  component_type_id INTEGER NOT NULL REFERENCES component_type(id),
  position          INTEGER NOT NULL,          -- display order, most general first
  required          INTEGER NOT NULL DEFAULT 1 CHECK (required IN (0, 1)),
  PRIMARY KEY (class_id, component_type_id),
  UNIQUE (class_id, position)
);

-- ------------------------------------------------- administrative reference ---

-- Region, Inkhundla, Umphakatsi, Sigodzi (and urban localities) as a tree.
-- Address forms use these for dropdowns and the app keeps names official.
CREATE TABLE admin_unit (
  id                INTEGER PRIMARY KEY,
  parent_id         INTEGER REFERENCES admin_unit(id),
  component_type_id INTEGER NOT NULL REFERENCES component_type(id),
  name              TEXT NOT NULL,
  official_code     TEXT,                      -- government code, when one exists
  UNIQUE (parent_id, component_type_id, name)
);
CREATE INDEX idx_admin_unit_parent ON admin_unit(parent_id);

CREATE TABLE postcode (
  code        TEXT PRIMARY KEY CHECK (code GLOB '[A-Z][0-9][0-9][0-9]'),  -- A999
  place_name  TEXT NOT NULL,
  region_id   INTEGER REFERENCES admin_unit(id)
);

-- ---------------------------------------------------------------- address ---

CREATE TABLE address (
  id            TEXT PRIMARY KEY,              -- opaque internal ID (UUID); NOT a public address
  class_id      INTEGER NOT NULL REFERENCES address_class(id),
  official_id   TEXT UNIQUE,                   -- identifier issued by the national addressing authority
  formatted     TEXT,                          -- rendered address line(s), built from components
  postcode      TEXT REFERENCES postcode(code),

  -- Position (WGS84). Accuracy in metres is required for proximity scoring.
  lat           REAL CHECK (lat BETWEEN -27.5 AND -25.5),   -- Eswatini bounding range
  lng           REAL CHECK (lng BETWEEN 30.5 AND 32.5),
  accuracy_m    REAL,
  geohash       TEXT,                          -- prefix search for "near me" lookups

  -- ISO 19160 lifecycle
  lifecycle     TEXT NOT NULL DEFAULT 'proposed'
                CHECK (lifecycle IN ('proposed', 'current', 'retired')),
  valid_from    TEXT,
  valid_to      TEXT,

  -- Metadata
  source        TEXT NOT NULL DEFAULT 'ekhaya_capture'
                CHECK (source IN ('national', 'ekhaya_capture', 'import')),

  -- Ekhaya verification layer
  confidence    REAL NOT NULL DEFAULT 0 CHECK (confidence BETWEEN 0 AND 1),
  verification  TEXT NOT NULL DEFAULT 'provisional'
                CHECK (verification IN ('provisional', 'probable', 'verified', 'disputed', 'stale')),
  verified_at   TEXT,

  created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  updated_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX idx_address_geohash      ON address(geohash);
CREATE INDEX idx_address_postcode     ON address(postcode);
CREATE INDEX idx_address_class        ON address(class_id);
CREATE INDEX idx_address_verification ON address(verification, confidence);

-- One row per component of an address. The class decides which are allowed/required.
CREATE TABLE address_component (
  address_id        TEXT    NOT NULL REFERENCES address(id) ON DELETE CASCADE,
  component_type_id INTEGER NOT NULL REFERENCES component_type(id),
  value             TEXT    NOT NULL,          -- text as written, e.g. 'Sigodzi Ndlovu' or '12B'
  admin_unit_id     INTEGER REFERENCES admin_unit(id),  -- set when the value is a reference unit
  PRIMARY KEY (address_id, component_type_id)
);
CREATE INDEX idx_address_component_unit ON address_component(admin_unit_id);

-- Local names, landmarks, former or alternative addresses (ISO 19160 address alias).
CREATE TABLE address_alias (
  id          INTEGER PRIMARY KEY,
  address_id  TEXT NOT NULL REFERENCES address(id) ON DELETE CASCADE,
  alias       TEXT NOT NULL,
  alias_type  TEXT NOT NULL CHECK (alias_type IN ('landmark', 'local_name', 'former', 'alternate')),
  language    TEXT NOT NULL DEFAULT 'en' CHECK (language IN ('en', 'ss')),  -- English, siSwati
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX idx_alias_address ON address_alias(address_id);

-- ------------------------------------------------------ verification layer ---

-- Signal weights live in data so they can be tuned without a deploy.
CREATE TABLE signal_weight (
  signal  TEXT PRIMARY KEY,
  weight  REAL NOT NULL CHECK (weight >= 0)
);

-- Append-only evidence. Confidence is derived from these rows.
CREATE TABLE address_event (
  id          INTEGER PRIMARY KEY,
  address_id  TEXT NOT NULL REFERENCES address(id) ON DELETE CASCADE,
  signal      TEXT NOT NULL REFERENCES signal_weight(signal),
  score       REAL NOT NULL CHECK (score BETWEEN 0 AND 1),   -- strength of this piece of evidence
  actor_id    TEXT,                            -- resident, courier or agent that produced it
  lat         REAL,
  lng         REAL,
  accuracy_m  REAL,
  detail      TEXT,                            -- JSON: landmark text, delivery reference, etc.
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX idx_event_address ON address_event(address_id, signal);

-- Confidence = sum over signals of (weight * best score for that signal), over the total weight.
-- The Worker recomputes and writes address.confidence; this view is the reference definition.
CREATE VIEW v_address_confidence AS
SELECT
  a.id AS address_id,
  COALESCE(SUM(w.weight * s.best), 0) / (SELECT SUM(weight) FROM signal_weight) AS confidence
FROM address a
JOIN signal_weight w
LEFT JOIN (
  SELECT address_id, signal, MAX(score) AS best
  FROM address_event
  GROUP BY address_id, signal
) s ON s.address_id = a.id AND s.signal = w.signal
GROUP BY a.id;

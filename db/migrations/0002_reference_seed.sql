-- Reference data. Only facts from the project context are seeded.
-- The profile is a PLACEHOLDER (confirmed = 0) until the SZNS text (ESWASA E437 / E813.37) is obtained.
-- Not seeded on purpose: the 59 inkhundla, umphakatsi, sigodzi and the full postcode list.
-- Load those from an official/verified source (GeoPostcodes sample, ESCCOM) with a separate migration.

INSERT INTO profile (id, code, name, version, confirmed, source) VALUES
  (1, 'SZNS-ISO19160', 'Eswatini National Addressing Standard (SZNS ISO 19160)',
   'placeholder-0', 0, 'Project CONTEXT.md; replace with published standard');

-- Classes named in the context. The standard defines six; the rest are added when known.
INSERT INTO address_class (id, profile_id, code, name, description, confirmed) VALUES
  (1, 1, 'street',              'Street address',              'Urban address on a named street', 0),
  (2, 1, 'rural',               'Rural address',               'Region > Inkhundla > Umphakatsi > Sigodzi > Homestead', 0),
  (3, 1, 'informal_settlement', 'Informal settlement address', 'Address within an informal settlement', 0);

INSERT INTO component_type (id, profile_id, code, name, kind, admin_level) VALUES
  (1,  1, 'region',       'Region',              'admin',        1),
  (2,  1, 'inkhundla',    'Inkhundla',           'admin',        2),
  (3,  1, 'umphakatsi',   'Umphakatsi',          'admin',        3),
  (4,  1, 'sigodzi',      'Sigodzi',             'admin',        4),
  (5,  1, 'homestead',    'Homestead',           'building',     NULL),
  (6,  1, 'locality',     'Town / locality',     'locality',     NULL),
  (7,  1, 'street_name',  'Street name',         'thoroughfare', NULL),
  (8,  1, 'plot_number',  'Plot / building no.', 'number',       NULL),
  (9,  1, 'block',        'Block',               'unit',         NULL),
  (10, 1, 'floor',        'Floor',               'unit',         NULL),
  (11, 1, 'wing',         'Wing',                'unit',         NULL),
  (12, 1, 'unit',         'Unit',                'unit',         NULL),
  (13, 1, 'room',         'Room',                'unit',         NULL);

-- Address reference systems (component order per class).
INSERT INTO class_component (class_id, component_type_id, position, required) VALUES
  -- rural
  (2, 1, 1, 1), (2, 2, 2, 1), (2, 3, 3, 1), (2, 4, 4, 1), (2, 5, 5, 1),
  -- street
  (1, 6, 1, 1), (1, 7, 2, 1), (1, 8, 3, 1),
  (1, 9, 4, 0), (1, 10, 5, 0), (1, 11, 6, 0), (1, 12, 7, 0), (1, 13, 8, 0),
  -- informal settlement (placeholder: locality + plot)
  (3, 6, 1, 1), (3, 8, 2, 1);

-- The four regions and their postcode letters (H, M, L, S).
INSERT INTO admin_unit (id, parent_id, component_type_id, name, official_code) VALUES
  (1, NULL, 1, 'Hhohho',    'H'),
  (2, NULL, 1, 'Manzini',   'M'),
  (3, NULL, 1, 'Lubombo',   'L'),
  (4, NULL, 1, 'Shiselweni','S');

-- Postcodes listed in the project context (A999 format).
INSERT INTO postcode (code, place_name, region_id) VALUES
  ('H100', 'Mbabane',      1),
  ('H101', 'Swazi Plaza',  1),
  ('M200', 'Manzini',      2),
  ('M202', 'Matsapha',     2),
  ('L300', 'Siteki',       3),
  ('S400', 'Nhlangano',    4);

-- Verification signals and starting weights (adjustable data, from the context).
INSERT INTO signal_weight (signal, weight) VALUES
  ('gps_proximity', 0.40),
  ('gps_dwell',     0.30),
  ('landmark_match',0.20),
  ('attestation',   0.10),
  ('delivery',      0.00);   -- courier delivery confirmation; set a weight when the signal goes live

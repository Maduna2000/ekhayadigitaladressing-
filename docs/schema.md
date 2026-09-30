# Ekhaya schema (ISO 19160-1 style)

The address is the **official national address**, structured as ISO 19160-1 defines it. Ekhaya adds a
verification layer on top; it does not invent a competing address format.

| ISO 19160 concept | Table | Notes |
|---|---|---|
| Profile | `profile` | SZNS ISO 19160. `confirmed = 0` until the real standard text is loaded. |
| Address class | `address_class` | street, rural, informal settlement (more when the standard is known). |
| Address component | `component_type`, `address_component` | Region, inkhundla, umphakatsi, sigodzi, homestead, street, plot, block, floor, wing, unit, room. |
| Address reference system | `class_component` | Which components a class uses, in order, required or optional. |
| Address | `address` | Internal UUID, optional `official_id`, position with accuracy, lifecycle, source. |
| Address alias | `address_alias` | Landmarks, local names, former names. |
| Data quality (Part 3) | `address_event`, `signal_weight`, `v_address_confidence` | Evidence rows roll up into a 0-1 confidence. |

## Key decisions

- `address.id` is an opaque internal key. The public address is `formatted` plus `official_id` once issued.
- Profile, classes, components and signal weights are **rows**, so adopting the real SZNS profile is a data change.
- Lifecycle (`proposed`, `current`, `retired`) follows ISO; verification (`provisional` ... `stale`) is Ekhaya's.
- Confidence = sum(weight x best score per signal) / total weight. Weights: proximity 0.40, dwell 0.30, landmark 0.20, attestation 0.10; `delivery` is 0 until enabled.
- Coordinates are constrained to Eswatini's bounding range to catch swapped or bad GPS values.

## Not yet loaded

The 59 inkhundla, umphakatsi, sigodzi and the full postcode list need a verified source. The seed contains only
the four regions and the postcodes named in the project context.

Check: `python3 db/test_schema.py`

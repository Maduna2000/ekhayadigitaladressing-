# Schema

The current schema is in `supabase/migrations/` (Postgres). See `docs/architecture.md` for the structure and rules.

The earlier ISO 19160-style SQLite/D1 schema is archived in `legacy-d1/` (run `python3 legacy-d1/test_schema.py`).
Its reference tables were ported to `0002_reference_data.sql`. Its GPS "confidence score" was dropped as a headline
signal: provenance and evidence are recorded instead, and GPS alone is never treated as proof of residence.

Test the current schema: `supabase/tests/run.sh`

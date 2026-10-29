"""Loads the migrations into an in-memory SQLite database and checks the schema.

Run: python3 db/test_schema.py
"""
import glob
import os
import sqlite3

here = os.path.dirname(os.path.abspath(__file__))
db = sqlite3.connect(":memory:")
db.execute("PRAGMA foreign_keys = ON")
for path in sorted(glob.glob(os.path.join(here, "migrations", "*.sql"))):
    db.executescript(open(path).read())


def add_address(addr_id, class_code, components, lat, lng, postcode, formatted):
    class_id = db.execute("SELECT id FROM address_class WHERE code = ?", (class_code,)).fetchone()[0]
    db.execute(
        "INSERT INTO address (id, class_id, formatted, postcode, lat, lng, accuracy_m) VALUES (?,?,?,?,?,?,8)",
        (addr_id, class_id, formatted, postcode, lat, lng),
    )
    for code, value in components:
        ct = db.execute("SELECT id FROM component_type WHERE code = ?", (code,)).fetchone()[0]
        db.execute("INSERT INTO address_component VALUES (?,?,?,NULL)", (addr_id, ct, value))
    return class_id


def missing_required(addr_id, class_id):
    """Required components of the class that the address does not have."""
    return [r[0] for r in db.execute(
        """SELECT ct.code FROM class_component cc
           JOIN component_type ct ON ct.id = cc.component_type_id
           WHERE cc.class_id = ? AND cc.required = 1
             AND cc.component_type_id NOT IN
                 (SELECT component_type_id FROM address_component WHERE address_id = ?)""",
        (class_id, addr_id))]


# Urban: a Matsapha street address with unit detail
c1 = add_address("a-urban", "street",
                 [("locality", "Matsapha"), ("street_name", "Example Street"),
                  ("plot_number", "12"), ("block", "B"), ("unit", "4")],
                 -26.51, 31.30, "M202", "Unit 4, Block B, 12 Example Street, Matsapha M202")
# Rural: full chain
c2 = add_address("a-rural", "rural",
                 [("region", "Hhohho"), ("inkhundla", "Example Inkhundla"), ("umphakatsi", "Example Umphakatsi"),
                  ("sigodzi", "Example Sigodzi"), ("homestead", "H-001")],
                 -26.30, 31.10, "H100", "Homestead H-001, Example Sigodzi, Example Umphakatsi, Hhohho")
assert missing_required("a-urban", c1) == [], missing_required("a-urban", c1)
assert missing_required("a-rural", c2) == []

# An incomplete rural address is detected
c3 = add_address("a-bad", "rural", [("region", "Manzini")], -26.4, 31.2, "M200", "incomplete")
assert set(missing_required("a-bad", c3)) == {"inkhundla", "umphakatsi", "sigodzi", "homestead"}

# Aliases (landmarks)
db.execute("INSERT INTO address_alias (address_id, alias, alias_type) VALUES ('a-rural','near the big tree','landmark')")

# Confidence from evidence: proximity 1.0 (0.40) + dwell 0.5 (0.15) = 0.55
db.execute("INSERT INTO address_event (address_id, signal, score) VALUES ('a-rural','gps_proximity',1.0)")
db.execute("INSERT INTO address_event (address_id, signal, score) VALUES ('a-rural','gps_dwell',0.3)")
db.execute("INSERT INTO address_event (address_id, signal, score) VALUES ('a-rural','gps_dwell',0.5)")
conf = dict(db.execute("SELECT address_id, confidence FROM v_address_confidence").fetchall())
assert abs(conf["a-rural"] - 0.55) < 1e-9, conf
assert conf["a-urban"] == 0

# Constraints
for bad_sql in (
    "INSERT INTO postcode VALUES ('MATS','x',2)",                          # not A999
    "UPDATE address SET lat = 10 WHERE id = 'a-urban'",                     # outside Eswatini
    "UPDATE address SET confidence = 1.5 WHERE id = 'a-urban'",             # out of range
    "INSERT INTO address_event (address_id, signal, score) VALUES ('a-urban','nope',0.5)",  # unknown signal
):
    try:
        db.execute(bad_sql)
    except sqlite3.IntegrityError:
        continue
    raise AssertionError("constraint not enforced: " + bad_sql)

print("schema OK:", db.execute("SELECT COUNT(*) FROM sqlite_master WHERE type='table'").fetchone()[0], "tables; confidence", round(conf["a-rural"], 2))

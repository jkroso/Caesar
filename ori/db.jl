@use SQLite

function init_db(path::AbstractString)
  db = SQLite.DB(path)
  for sql in [
    """CREATE TABLE IF NOT EXISTS vitality (
         note_id TEXT PRIMARY KEY,
         access_times TEXT DEFAULT '[]',
         decay_rate REAL DEFAULT 0.5)""",
    """CREATE TABLE IF NOT EXISTS qvalues (
         note_id TEXT PRIMARY KEY,
         value REAL DEFAULT 0.0,
         count INTEGER DEFAULT 0,
         exposure_count INTEGER DEFAULT 0)""",
    """CREATE TABLE IF NOT EXISTS cooccurrence (
         source_id TEXT,
         target_id TEXT,
         weight REAL DEFAULT 0.0,
         count INTEGER DEFAULT 0,
         last_seen TEXT,
         PRIMARY KEY (source_id, target_id))""",
    """CREATE TABLE IF NOT EXISTS query_log (
         id INTEGER PRIMARY KEY AUTOINCREMENT,
         query TEXT,
         intent TEXT,
         result_ids TEXT,
         timestamp TEXT)""",
    """CREATE TABLE IF NOT EXISTS metadata (
         key TEXT PRIMARY KEY,
         value TEXT)""",
  ]
    SQLite.execute(db, sql)
  end
  db
end

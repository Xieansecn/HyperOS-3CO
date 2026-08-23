import sqlite3, sys, os, json

def dump_db(path):
    print("="*120)
    print("DB:", path)
    try:
        con = sqlite3.connect('file:'+path+'?mode=ro', uri=True, timeout=5)
    except Exception as e:
        print("ERROR opening:", e)
        return
    cur = con.cursor()
    cur.execute("SELECT name, type, sql FROM sqlite_master WHERE type IN ('table','view') ORDER BY name")
    objects = cur.fetchall()
    print("OBJECTS:")
    for name, typ, sql in objects:
        print(f"  [{typ}] {name}\n    SQL: {sql}")
    print("-"*100)
    for name, typ, sql in objects:
        try:
            count = cur.execute('SELECT COUNT(*) FROM "%s"' % name).fetchone()[0]
        except Exception as e:
            count = -1
        print(f"TABLE {name} rows={count}")
        if typ == 'table' and count >= 0 and count <= 50:
            cols = [d[0] for d in cur.execute('PRAGMA table_info("%s")' % name).fetchall()]
            print("  columns:", cols)
            rows = cur.execute('SELECT * FROM "%s" LIMIT 50' % name).fetchall()
            for r in rows:
                # Truncate long values for readability
                vals = []
                for v in r:
                    s = repr(v)
                    if len(s) > 500:
                        s = s[:500] + f"...<len={len(repr(v))}>"
                    vals.append(s)
                print("  ", vals)
        elif typ == 'table' and count > 50:
            # print first few sample rows
            cols = [d[0] for d in cur.execute('PRAGMA table_info("%s")' % name).fetchall()]
            print("  columns:", cols)
            rows = cur.execute('SELECT * FROM "%s" LIMIT 3' % name).fetchall()
            for r in rows:
                vals = []
                for v in r:
                    s = repr(v)
                    if len(s) > 500:
                        s = s[:500] + f"...<len={len(repr(v))}>"
                    vals.append(s)
                print("  sample:", vals)
    con.close()

for p in sys.argv[1:]:
    dump_db(p)

#!/usr/bin/env python3
"""
Expo Village Tracker loader.

Loads lookups, rooms and staff into Supabase from the CSV files in this folder.
Runs on your own laptop only. It needs the SECRET key, which must never go into
the web page, the repo, an email or a chat.

  python load.py lookups              departments.csv, priorities.csv, categories.csv
  python load.py rooms                rooms.csv (add --deactivate-missing to hide rooms not in the file)
  python load.py staff                staff.csv (creates sign-ins, sets or generates PINs)
                                      pin column: blank keeps the current PIN (new people get one generated),
                                      6 digits sets that PIN, "new" generates a fresh one
  python load.py all                  lookups, then rooms, then staff
  add --dry-run to any command to check the CSVs without touching Supabase.

Settings come from loader/.env (copy .env.example). Needs: pip install requests
"""
import csv, os, re, sys, secrets, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROLES = {"cleaner", "reception", "supervisor"}
ID_RE = re.compile(r"^[A-Z0-9][A-Z0-9-]{0,19}$")
CAT_RE = re.compile(r"^[a-z0-9_]+$")
WEAK_PINS = {"123456", "654321", "123123", "112233", "121212", "000000", "111111", "222222", "333333",
             "444444", "555555", "666666", "777777", "888888", "999999", "012345", "543210", "696969"}


def die(msg):
    print("ERROR: " + msg)
    sys.exit(1)


def read_env():
    env = {}
    p = os.path.join(HERE, ".env")
    if os.path.exists(p):
        for line in open(p, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    for k in ("SUPABASE_URL", "SUPABASE_SECRET_KEY", "STAFF_EMAIL_DOMAIN"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


def read_csv(name):
    p = os.path.join(HERE, name)
    if not os.path.exists(p):
        die(f"{name} not found in {HERE}")
    with open(p, encoding="utf-8-sig", newline="") as f:
        rows = [{(k or "").strip().lower(): (v or "").strip() for k, v in r.items()} for r in csv.DictReader(f)]
    return [r for r in rows if any(r.values())]


def as_bool(v, default=True):
    if v == "":
        return default
    v = v.lower()
    if v in ("1", "true", "yes", "y"):
        return True
    if v in ("0", "false", "no", "n"):
        return False
    raise ValueError(f"'{v}' is not yes or no")


def as_int(v, field):
    try:
        return int(v)
    except ValueError:
        raise ValueError(f"{field} '{v}' is not a whole number")


class Api:
    def __init__(self, env):
        try:
            import requests  # noqa
        except ImportError:
            die("Install requests first: pip install requests")
        import requests
        self.r = requests
        self.url = env.get("SUPABASE_URL", "").rstrip("/")
        key = env.get("SUPABASE_SECRET_KEY", "")
        if not re.match(r"^https://[a-z0-9-]+\.supabase\.co$", self.url):
            die("SUPABASE_URL in .env looks wrong. Expected https://<project-ref>.supabase.co")
        if not key or "REPLACE" in key:
            die("SUPABASE_SECRET_KEY missing in .env")
        if key.startswith("sb_publishable_"):
            die("That is the publishable key. The loader needs the secret key (sb_secret_...).")
        self.h = {"apikey": key, "Content-Type": "application/json"}
        if key.startswith("eyJ"):  # legacy service_role JWT
            self.h["Authorization"] = "Bearer " + key

    def call(self, method, path, json=None, params=None, prefer=None, ok=(200, 201, 204)):
        h = dict(self.h)
        if prefer:
            h["Prefer"] = prefer
        resp = self.r.request(method, self.url + path, headers=h, json=json, params=params, timeout=30)
        if resp.status_code not in ok:
            raise RuntimeError(f"{method} {path} failed ({resp.status_code}): {resp.text[:400]}")
        return resp.json() if resp.content else None

    def upsert(self, table, rows, conflict):
        if rows:
            self.call("POST", f"/rest/v1/{table}", json=rows, params={"on_conflict": conflict},
                      prefer="resolution=merge-duplicates,return=minimal")

    def select(self, table, cols="*"):
        out, start = [], 0
        while True:
            h = dict(self.h)
            h["Range"] = f"{start}-{start + 999}"
            resp = self.r.get(f"{self.url}/rest/v1/{table}", headers=h, params={"select": cols}, timeout=30)
            if resp.status_code not in (200, 206):
                raise RuntimeError(f"read {table} failed ({resp.status_code}): {resp.text[:400]}")
            page = resp.json()
            out += page
            if len(page) < 1000:
                return out
            start += 1000


# ---------------------------------------------------------------- lookups
def check_lookups():
    deps, pris, cats, errs = [], [], [], []
    for i, r in enumerate(read_csv("departments.csv"), 2):
        try:
            if not r.get("id"):
                raise ValueError("id is empty")
            deps.append({"id": r["id"], "sort": as_int(r.get("sort") or "0", "sort"), "active": as_bool(r.get("active", ""))})
        except ValueError as e:
            errs.append(f"departments.csv line {i}: {e}")
    for i, r in enumerate(read_csv("priorities.csv"), 2):
        try:
            lv = as_int(r.get("level", ""), "level")
            am = as_int(r.get("alert_minutes", ""), "alert_minutes")
            if not 1 <= lv <= 9 or am <= 0 or not r.get("label"):
                raise ValueError("level 1 to 9, label required, alert_minutes above 0")
            pris.append({"level": lv, "label": r["label"], "alert_minutes": am})
        except ValueError as e:
            errs.append(f"priorities.csv line {i}: {e}")
    dep_ids = {d["id"] for d in deps}
    pri_ids = {p["level"] for p in pris}
    for i, r in enumerate(read_csv("categories.csv"), 2):
        try:
            if not CAT_RE.match(r.get("id", "")):
                raise ValueError("id must be lower case letters, digits or _")
            if r.get("default_department") not in dep_ids:
                raise ValueError(f"default_department '{r.get('default_department')}' is not in departments.csv")
            dp = as_int(r.get("default_priority", ""), "default_priority")
            if dp not in pri_ids:
                raise ValueError(f"default_priority {dp} is not in priorities.csv")
            if not r.get("label_en"):
                raise ValueError("label_en is empty")
            cats.append({"id": r["id"], "icon": r.get("icon") or "💬", "label_en": r["label_en"], "label_sr": r.get("label_sr", ""),
                         "default_department": r["default_department"], "default_priority": dp,
                         "sort": as_int(r.get("sort") or "0", "sort"), "active": as_bool(r.get("active", ""))})
        except ValueError as e:
            errs.append(f"categories.csv line {i}: {e}")
    return deps, pris, cats, errs


def load_lookups(api, dry):
    deps, pris, cats, errs = check_lookups()
    if errs:
        die("\n  ".join(["fix these first:"] + errs))
    print(f"lookups OK: {len(deps)} departments, {len(pris)} priorities, {len(cats)} categories")
    if dry:
        return
    api.upsert("departments", deps, "id")
    api.upsert("priorities", pris, "level")
    api.upsert("categories", cats, "id")
    print("lookups loaded. Missing entries are not deleted; set active = no to hide a department or category.")


# ---------------------------------------------------------------- rooms
def check_rooms():
    rooms, errs, seen = [], [], set()
    for i, r in enumerate(read_csv("rooms.csv"), 2):
        rid = r.get("room_id", "").upper()
        if not rid or not re.match(r"^[A-Z0-9][A-Z0-9-]{0,19}$", rid):
            errs.append(f"rooms.csv line {i}: room_id '{r.get('room_id')}' must be letters, digits and -")
            continue
        if rid in seen:
            errs.append(f"rooms.csv line {i}: room_id {rid} appears twice")
            continue
        seen.add(rid)
        if not r.get("building") or not r.get("floor") or not r.get("label"):
            errs.append(f"rooms.csv line {i}: building, floor and label are required")
            continue
        try:
            rooms.append({"id": rid, "building": r["building"], "floor": r["floor"], "label": r["label"].upper(),
                          "sort": as_int(r.get("sort") or "0", "sort"), "active": True})
        except ValueError as e:
            errs.append(f"rooms.csv line {i}: {e}")
    return rooms, errs


def load_rooms(api, dry, deactivate_missing):
    rooms, errs = check_rooms()
    if errs:
        die("\n  ".join(["fix these first:"] + errs))
    print(f"rooms OK: {len(rooms)} rooms in {len({r['building'] for r in rooms})} buildings")
    if dry:
        return
    for i in range(0, len(rooms), 500):
        api.upsert("rooms", rooms[i:i + 500], "id")
    print("rooms loaded. New rooms start as Dirty; existing rooms keep their current status.")
    if deactivate_missing:
        keep = {r["id"] for r in rooms}
        gone = [r["id"] for r in api.select("rooms", "id,active") if r["active"] and r["id"] not in keep]
        for rid in gone:
            api.call("PATCH", "/rest/v1/rooms", json={"active": False}, params={"id": f"eq.{rid}"}, prefer="return=minimal")
        print(f"deactivated {len(gone)} rooms not in rooms.csv" + (f": {', '.join(gone[:20])}" if gone else ""))


# ---------------------------------------------------------------- staff
def gen_pin():
    while True:
        p = f"{secrets.randbelow(10**6):06d}"
        if p not in WEAK_PINS and len(set(p)) > 2:
            return p


def check_staff():
    staff, errs, seen = [], [], set()
    for i, r in enumerate(read_csv("staff.csv"), 2):
        sid = r.get("staff_id", "").upper().replace(" ", "")
        role = r.get("role", "").lower()
        pin = r.get("pin", "")
        if pin.lower() == "new":
            pin = gen_pin()
        try:
            if not ID_RE.match(sid):
                raise ValueError(f"staff_id '{r.get('staff_id')}' must be letters, digits and -, up to 20 characters")
            if sid in seen:
                raise ValueError(f"staff_id {sid} appears twice")
            if role not in ROLES:
                raise ValueError(f"role '{r.get('role')}' must be cleaner, reception or supervisor")
            if pin and (not re.match(r"^\d{6}$", pin) or pin in WEAK_PINS or len(set(pin)) <= 2):
                raise ValueError("pin must be 6 digits and not an easy pattern, 'new' to generate one, or blank to keep the current PIN")
            staff.append({"id": sid, "role": role, "label": r.get("label", ""), "pin": pin, "active": as_bool(r.get("active", ""))})
            seen.add(sid)
        except ValueError as e:
            errs.append(f"staff.csv line {i}: {e}")
    return staff, errs


def find_auth_user(api, email):
    page = 1
    while True:
        res = api.call("GET", "/auth/v1/admin/users", params={"page": page, "per_page": 1000})
        users = res.get("users", []) if isinstance(res, dict) else res
        for u in users:
            if (u.get("email") or "").lower() == email:
                return u["id"]
        if len(users) < 1000:
            return None
        page += 1


def load_staff(api, dry, domain):
    staff, errs = check_staff()
    if errs:
        die("\n  ".join(["fix these first:"] + errs))
    if not domain or "." not in domain:
        die("STAFF_EMAIL_DOMAIN missing in .env (must match the web page CONFIG)")
    print(f"staff OK: {len(staff)} people, " + ", ".join(f"{sum(1 for s in staff if s['role'] == r)} {r}" for r in sorted(ROLES)))
    if dry:
        return
    existing = {s["id"]: s for s in api.select("staff", "id,user_id,active")}
    issued = []
    for s in staff:
        email = f"exv-{s['id'].lower()}@{domain}"
        uid = (existing.get(s["id"]) or {}).get("user_id")
        pin = s["pin"]
        if not uid:
            pin = pin or gen_pin()
            res = api.r.post(f"{api.url}/auth/v1/admin/users", headers=api.h, timeout=30,
                             json={"email": email, "password": pin, "email_confirm": True,
                                   "user_metadata": {"staff_id": s["id"]}})
            if res.status_code in (200, 201):
                uid = res.json()["id"]
            elif res.status_code == 422 and ("already" in res.text or "exists" in res.text):
                uid = find_auth_user(api, email)
                if not uid:
                    die(f"{s['id']}: sign-in exists but could not be found")
                api.call("PUT", f"/auth/v1/admin/users/{uid}", json={"password": pin})
            else:
                die(f"{s['id']}: could not create sign-in ({res.status_code}): {res.text[:300]}")
            issued.append((s["id"], s["label"], s["role"], pin))
            action = "created"
        elif pin:
            api.call("PUT", f"/auth/v1/admin/users/{uid}", json={"password": pin})
            issued.append((s["id"], s["label"], s["role"], pin))
            action = "PIN changed"
        else:
            action = "kept"
        api.call("PUT", f"/auth/v1/admin/users/{uid}", json={"ban_duration": "none" if s["active"] else "876000h"})
        api.upsert("staff", [{"id": s["id"], "user_id": uid, "role": s["role"], "label": s["label"], "active": s["active"]}], "id")
        print(f"  {s['id']:<12} {s['role']:<11} {'active' if s['active'] else 'DEACTIVATED':<12} {action}")
    missing = [k for k, v in existing.items() if v["active"] and k not in {s['id'] for s in staff}]
    if missing:
        print(f"note: {len(missing)} active staff are not in staff.csv and were left unchanged: {', '.join(missing)}")
    if issued:
        name = os.path.join(HERE, f"pins_issued_{datetime.datetime.now():%Y%m%d_%H%M}.csv")
        with open(name, "w", encoding="utf-8-sig", newline="") as f:
            w = csv.writer(f)
            w.writerow(["staff_id", "label", "role", "pin"])
            w.writerows(issued)
        print(f"\n{len(issued)} PINs written to {os.path.basename(name)}. Hand them out, then delete the file.")
    if any(s["pin"] for s in staff):
        print("Remove the pin values from staff.csv now so PINs are not stored in two places.")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    if not args or args[0] not in ("lookups", "rooms", "staff", "all"):
        print(__doc__)
        sys.exit(1)
    dry = "--dry-run" in flags
    env = read_env()
    api = None if dry else Api(env)
    what = args[0]
    try:
        if what in ("lookups", "all"):
            load_lookups(api, dry)
        if what in ("rooms", "all"):
            load_rooms(api, dry, "--deactivate-missing" in flags)
        if what in ("staff", "all"):
            load_staff(api, dry, env.get("STAFF_EMAIL_DOMAIN", "") if not dry else env.get("STAFF_EMAIL_DOMAIN", "x.y"))
    except RuntimeError as e:
        die(str(e))
    if dry:
        print("dry run only, nothing was sent")


if __name__ == "__main__":
    main()

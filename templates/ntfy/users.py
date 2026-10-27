#!/usr/bin/env python3
"""
ntfy user management.

Accounts, grants and tokens are declarative: they live in auth.env, which docker compose
loads into the container via env_file. The `ntfy user` / `ntfy access` CLI cannot edit
provisioned accounts, so everything here edits auth.env instead -- which also means it
works before the service has ever been started. Nothing takes effect until a `up`.

  ./service.sh users                 interactive console
  ./service.sh users help            command list
"""

import curses
import locale
import os
import re
import secrets
import shutil
import subprocess
import sys

SERVICE_DIR = os.path.dirname(os.path.abspath(__file__))
AUTH_ENV = os.path.join(SERVICE_DIR, "auth.env")
VERSION_FILE = os.path.join(SERVICE_DIR, ".version")
FALLBACK_IMAGE = "binwiederhier/ntfy"
VARS = ("NTFY_AUTH_USERS", "NTFY_AUTH_ACCESS", "NTFY_AUTH_TOKENS")

RE_USER = re.compile(r"^[-_.+@a-zA-Z0-9]+$")
RE_PATTERN = re.compile(r"^[-_*A-Za-z0-9]{1,64}$")
RE_HASH = re.compile(r"\$2[aby]\$[0-9]{2}\$[A-Za-z0-9./]{53}")
PERMS = ("rw", "ro", "wo", "deny")
ROLES = ("user", "admin")
EVERYONE = "everyone"

HEADER = """\
# ntfy declarative accounts -- managed by ./service.sh users
#
# Loaded into the container by docker-compose.yml via `env_file`, so a variable that is
# absent here is simply unset. (An EMPTY value would abort ntfy at startup.)
# This file is NOT sourced by bash and NOT used for compose interpolation.
#
#   NTFY_AUTH_USERS   <user>:<bcrypt-hash>:<role>        role = admin | user
#   NTFY_AUTH_ACCESS  <user>:<topic-pattern>:<access>    rw | ro | wo | deny, '*' allowed
#   NTFY_AUTH_TOKENS  <user>:<token>[:<label>]           token = tk_ + 29 chars
#
# Entries are comma-separated. After any change run ./service.sh up -- NOT restart,
# which would reuse the container's old environment.
"""


class Problem(Exception):
    """A message for the operator, not a crash."""


# ----------------------------------------------------------------- store


class Store:
    def __init__(self):
        self.users = []    # {name, hash, role}
        self.access = []   # {name, pattern, perm}
        self.tokens = []   # {name, token, label}
        self.broken = {}   # var -> [raw entry] kept verbatim, never silently dropped
        self.dirty = False      # unsaved edits in the buffer
        self.saved_any = False  # something was written during this session
        self.load()

    # -- io

    def load(self):
        raw = {"NTFY_AUTH_USERS": "", "NTFY_AUTH_ACCESS": "", "NTFY_AUTH_TOKENS": ""}
        if os.path.exists(AUTH_ENV):
            with open(AUTH_ENV) as fh:
                for line in fh:
                    line = line.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    key, _, val = line.partition("=")
                    key = key.strip()
                    if key in raw:
                        raw[key] = val.strip().strip("'").strip('"')

        self.users, self.access, self.tokens = [], [], []
        self.broken = {k: [] for k in raw}
        self.dirty = False

        for e in self._split(raw["NTFY_AUTH_USERS"]):
            parts = e.split(":")
            if len(parts) == 3 and RE_USER.match(parts[0]) and parts[2] in ROLES:
                self.users.append({"name": parts[0], "hash": parts[1], "role": parts[2]})
            else:
                self.broken["NTFY_AUTH_USERS"].append(e)
        for e in self._split(raw["NTFY_AUTH_ACCESS"]):
            parts = e.split(":")
            if len(parts) == 3 and parts[2] in PERMS:
                self.access.append({"name": parts[0], "pattern": parts[1], "perm": parts[2]})
            else:
                self.broken["NTFY_AUTH_ACCESS"].append(e)
        for e in self._split(raw["NTFY_AUTH_TOKENS"]):
            parts = e.split(":", 2)
            if len(parts) >= 2 and parts[1].startswith("tk_"):
                self.tokens.append({
                    "name": parts[0], "token": parts[1],
                    "label": parts[2] if len(parts) == 3 else "",
                })
            else:
                self.broken["NTFY_AUTH_TOKENS"].append(e)

    def reload(self):
        """Throw the buffer away and re-read the file."""
        self.load()
        self.dirty = False

    @staticmethod
    def _split(value):
        return [e.strip() for e in value.split(",") if e.strip()]

    def save(self):
        lines = [HEADER]
        groups = (
            ("NTFY_AUTH_USERS", [f"{u['name']}:{u['hash']}:{u['role']}" for u in self.users]),
            ("NTFY_AUTH_ACCESS", [f"{a['name']}:{a['pattern']}:{a['perm']}" for a in self.access]),
            ("NTFY_AUTH_TOKENS", [
                f"{t['name']}:{t['token']}" + (f":{t['label']}" if t["label"] else "")
                for t in self.tokens]),
        )
        for var, entries in groups:
            entries = entries + self.broken.get(var, [])
            # an empty value is fatal for ntfy, so the variable is omitted entirely
            if entries:
                lines.append(f"{var}='{','.join(entries)}'\n")
        # keep the previous version one copy away, nothing here is committed to git yet
        if os.path.exists(AUTH_ENV):
            shutil.copy2(AUTH_ENV, AUTH_ENV + ".bak")
        tmp = AUTH_ENV + ".tmp"
        with open(tmp, "w") as fh:
            fh.write("".join(lines))
        os.replace(tmp, AUTH_ENV)  # atomic, so a crash never leaves a half-written file
        self.dirty = False
        self.saved_any = True

    # -- queries

    def user(self, name):
        for u in self.users:
            if u["name"] == name:
                return u
        return None

    def grants_of(self, name):
        return [a for a in self.access if a["name"] == name]

    def tokens_of(self, name):
        return [t for t in self.tokens if t["name"] == name]

    def orphans(self):
        names = {u["name"] for u in self.users} | {EVERYONE}
        out = []
        for a in self.access:
            if a["name"] not in names:
                out.append(f"grant {a['name']}:{a['pattern']}:{a['perm']}")
        for t in self.tokens:
            if t["name"] not in names:
                out.append(f"token {t['name']}:{t['token']}")
        for var, entries in self.broken.items():
            for e in entries:
                out.append(f"malformed {var}: {e}")
        return out

    # -- mutations (each validates, saves, and returns a message)

    def add_user(self, name, role, pwhash):
        if not RE_USER.match(name):
            raise Problem("invalid username (allowed: a-z A-Z 0-9 - _ . + @)")
        if self.user(name):
            raise Problem(f"user already exists: {name}")
        if role not in ROLES:
            raise Problem("role must be 'user' or 'admin'")
        if not RE_HASH.fullmatch(pwhash):
            raise Problem("not a valid bcrypt hash")
        self.users.append({"name": name, "hash": pwhash, "role": role})
        self.dirty = True
        return f"user {name} added ({role})"

    def set_hash(self, name, pwhash):
        u = self.require(name)
        if not RE_HASH.fullmatch(pwhash):
            raise Problem("not a valid bcrypt hash")
        u["hash"] = pwhash
        self.dirty = True
        return f"password of {name} changed"

    def set_role(self, name, role):
        if role not in ROLES:
            raise Problem("role must be 'user' or 'admin'")
        u = self.require(name)
        u["role"] = role
        self.dirty = True
        return f"{name} is now {role}"

    def del_user(self, name):
        u = self.require(name)
        self.users.remove(u)
        self.access = [a for a in self.access if a["name"] != name]
        self.tokens = [t for t in self.tokens if t["name"] != name]
        self.dirty = True
        return f"user {name} removed (incl. grants and tokens)"

    def grant(self, name, pattern, perm):
        if name == "*":
            raise Problem("use 'everyone' instead of '*' for anonymous access")
        if name != EVERYONE:
            self.require(name)
        if not RE_PATTERN.match(pattern):
            raise Problem("invalid topic pattern (allowed: a-z A-Z 0-9 - _ * , max 64)")
        if perm not in PERMS:
            raise Problem("permission must be rw, ro, wo or deny")
        self.access = [a for a in self.access
                       if not (a["name"] == name and a["pattern"] == pattern)]
        self.access.append({"name": name, "pattern": pattern, "perm": perm})
        self.dirty = True
        return f"{name}: {perm} on {pattern}"

    def revoke(self, name, pattern=None):
        before = len(self.access)
        self.access = [a for a in self.access if not (
            a["name"] == name and (pattern is None or a["pattern"] == pattern))]
        if len(self.access) == before:
            raise Problem("no matching grant")
        self.dirty = True
        return f"revoked {pattern or 'all grants'} from {name}"

    def add_token(self, name, label=""):
        self.require(name)
        for bad in (",", ":", "'", "#"):
            if bad in label:
                raise Problem("label must not contain , : ' or #")
        token = "tk_" + "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz0123456789")
                                for _ in range(29))
        self.tokens.append({"name": name, "token": token, "label": label})
        self.dirty = True
        return token

    def del_token(self, token):
        hit = [t for t in self.tokens if t["token"] == token]
        if not hit:
            raise Problem("no such token")
        self.tokens.remove(hit[0])
        self.dirty = True
        return "token removed"

    def require(self, name):
        u = self.user(name)
        if not u:
            raise Problem(f"no such user: {name}")
        return u


# ----------------------------------------------------------------- docker helpers


def image():
    repo = cur = ""
    if os.path.exists(VERSION_FILE):
        with open(VERSION_FILE) as fh:
            for line in fh:
                k, _, v = line.strip().partition("=")
                if k == "NTFY_REPO":
                    repo = v
                elif k == "NTFY_CURRENT":
                    cur = v
    return f"{repo}@{cur}" if repo and cur else FALLBACK_IMAGE


def bcrypt_hash(password):
    """Hash via the ntfy binary itself, so the cost and format always match."""
    try:
        res = subprocess.run(
            ["docker", "run", "--rm", "-i", image(), "user", "hash"],
            input=f"{password}\n{password}\n", capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise Problem(f"could not run the ntfy image: {exc}")
    m = RE_HASH.search(res.stdout + res.stderr)
    if not m:
        raise Problem("could not generate a hash (is the image available?)")
    return m.group(0)


# Native validation. ntfy applies these rules at startup (user/util.go, cmd/serve.go);
# checking them here keeps it instant -- `ntfy serve` never exits when the config is good,
# so asking the binary meant waiting out a timeout on every valid config.
RE_TOKEN = re.compile(r"^tk_[a-z0-9]{29}$")
RE_BCRYPT = re.compile(r"^\$2[aby]\$([0-9]{2})\$[A-Za-z0-9./]{53}$")
MIN_BCRYPT_COST = 10


def validate(store):
    """Return a list of problems with the buffer. Empty list means it will start."""
    out = []

    # entries auth.env held that could not be parsed at all
    for var, entries in store.broken.items():
        for e in entries:
            out.append(f"malformed {var} entry: {e}")

    # an auth variable present but empty aborts ntfy at startup, so look at the raw file
    if os.path.exists(AUTH_ENV):
        with open(AUTH_ENV) as fh:
            for num, line in enumerate(fh, 1):
                key, sep, val = line.strip().partition("=")
                if sep and key.strip() in VARS and not val.strip().strip("'\""):
                    out.append(f"{AUTH_ENV.rsplit('/', 1)[-1]}:{num}: {key.strip()} is set but "
                               f"empty -- ntfy refuses to start; remove the line instead")

    names = set()
    for u in store.users:
        if not RE_USER.match(u["name"]):
            out.append(f"invalid username: {u['name']}")
        if u["name"] in names:
            out.append(f"duplicate user: {u['name']}")
        names.add(u["name"])
        if u["role"] not in ROLES:
            out.append(f"{u['name']}: role must be user or admin, not {u['role']}")
        m = RE_BCRYPT.match(u["hash"])
        if not m:
            out.append(f"{u['name']}: password hash is not a bcrypt hash")
        elif int(m.group(1)) < MIN_BCRYPT_COST:
            out.append(f"{u['name']}: bcrypt cost {m.group(1)} is below {MIN_BCRYPT_COST}")

    known = names | {EVERYONE}
    seen = set()
    for a in store.access:
        if a["name"] not in known:
            out.append(f"grant for unknown user: {a['name']}:{a['pattern']}:{a['perm']}")
        if not RE_PATTERN.match(a["pattern"]):
            out.append(f"invalid topic pattern: {a['pattern']}")
        if a["perm"] not in PERMS:
            out.append(f"invalid permission: {a['perm']}")
        if (a["name"], a["pattern"]) in seen:
            out.append(f"duplicate grant: {a['name']} on {a['pattern']}")
        seen.add((a["name"], a["pattern"]))

    tokens = set()
    for t in store.tokens:
        if t["name"] not in names:
            out.append(f"token for unknown user: {t['name']}")
        if not RE_TOKEN.match(t["token"]):
            out.append(f"{t['name']}: not a valid token (tk_ + 29 lowercase chars): {t['token']}")
        if t["token"] in tokens:
            out.append(f"duplicate token: {t['token']}")
        tokens.add(t["token"])
        for bad in (",", ":", "'", "#"):
            if bad in t["label"]:
                out.append(f"{t['name']}: token label must not contain {bad}")

    # a value containing a quote or comma would break the file's own encoding
    for group in (store.users, store.access, store.tokens):
        for item in group:
            for field, value in item.items():
                if isinstance(value, str) and ("'" in value or "\n" in value):
                    out.append(f"{item.get('name')}: {field} contains a quote or newline")

    return out


def summary(store):
    return (f"{len(store.users)} user(s), {len(store.access)} grant(s), "
            f"{len(store.tokens)} token(s)")


DEFAULT_COMMIT_MSG = "update users"


def request(apply=False, commit=False, message=""):
    """Hand `up` / `git commit` back to service.sh, which has those functions."""
    path = os.environ.get("UA_ACTION_FILE")
    if not path:
        print("[USERS] (not started through ./service.sh -- run './service.sh up' yourself)")
        return
    with open(path, "w") as fh:
        fh.write(f"apply={int(apply)}\ncommit={int(commit)}\nmessage={message}\n")


# ----------------------------------------------------------------- plain CLI


USAGE = """\
Usage: ./service.sh users [<command>]        (no command => interactive console)

  list                                  users, grants and tokens
  add <name> [--admin] [--token]        create a user (prompts for the password)
  passwd <name>                         change a password
  role <name> <user|admin>              change a role
  del <name> [-y]                       delete a user, its grants and tokens
  grant <name> <topic-pattern> <perm>   perm = rw | ro | wo | deny, '*' allowed in pattern
  revoke <name> [topic-pattern]         drop one grant, or all of the user's grants
  token add <name> [label]              create an access token
  token list [name]                     show tokens in full
  token del <tk_...>                    delete a token
  check                                 validate auth.env against ntfy, changes nothing
  apply                                 check, then ./service.sh up

Everything edits auth.env and takes effect on `up` -- not on `restart`, which reuses the
container's old environment. Admins need no grant. 'everyone' is ntfy's anonymous user:
granting it makes a topic public.
"""


def gen_password(length=24):
    alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(length))


def ask_password():
    """Empty input generates one and prints it once."""
    import getpass
    p1 = getpass.getpass("  password (empty = generate): ")
    if not p1:
        p1 = gen_password()
        print(f"  generated password: {p1}")
        print("  ^ store it now, only the hash is kept")
        return p1
    if p1 != getpass.getpass("  confirm:  "):
        raise Problem("passwords do not match")
    return p1


def cli_list(store):
    if not store.users:
        print("[USERS] no users defined -- './service.sh users add <name> --admin'")
        return
    for u in store.users:
        print(f"\n  {u['name']}  ({u['role']})")
        if u["role"] == "admin":
            print(f"      {'rw':<5} * -- all topics (admin role, no grant needed)")
        for a in store.grants_of(u["name"]):
            print(f"      {a['perm']:<5} {a['pattern']}")
        for t in store.tokens_of(u["name"]):
            print(f"      {'token':<5} {t['token'][:7]}…{t['token'][-4:]}  {t['label']}")
    for a in store.access:
        if a["name"] == EVERYONE:
            print(f"\n  everyone  (anonymous)\n      {a['perm']:<5} {a['pattern']}")
    orph = store.orphans()
    if orph:
        print()
        for o in orph:
            print(f"  [!] {o}")
        print("[USERS] ntfy will refuse to start -- fix auth.env before 'apply'")
    print()


def cli(argv):
    store = Store()
    cmd = argv[0] if argv else "help"
    rest = argv[1:]

    if cmd in ("list", "ls"):
        cli_list(store)
    elif cmd == "add":
        if not rest:
            raise Problem("usage: users add <name> [--admin] [--token]")
        name = rest[0]
        role = "admin" if "--admin" in rest[1:] else "user"
        want_token = "--token" in rest[1:]
        for opt in rest[1:]:
            if opt not in ("--admin", "--token"):
                raise Problem(f"unknown option: {opt}")
        print(f"[USERS] adding {name} (role: {role})")
        msg = store.add_user(name, role, bcrypt_hash(ask_password()))
        print(f"[USERS] {msg}")
        if want_token:
            print(f"[USERS] token for {name}: {store.add_token(name, 'created with user')}")
        if role == "user":
            print(f"[USERS] no access yet -- './service.sh users grant {name} <topic> rw'")
        print("[USERS] auth.env updated -- run './service.sh users apply' to activate")
    elif cmd in ("passwd", "password"):
        if not rest:
            raise Problem("usage: users passwd <name>")
        store.require(rest[0])
        print(f"[USERS] new password for {rest[0]}")
        print(f"[USERS] {store.set_hash(rest[0], bcrypt_hash(ask_password()))}")
        print("[USERS] auth.env updated -- run './service.sh users apply' to activate")
    elif cmd == "role":
        if len(rest) < 2:
            raise Problem("usage: users role <name> <user|admin>")
        print(f"[USERS] {store.set_role(rest[0], rest[1])}")
    elif cmd in ("del", "rm", "delete"):
        if not rest:
            raise Problem("usage: users del <name> [-y]")
        store.require(rest[0])
        if "-y" not in rest[1:]:
            print(f"[USERS] deleting {rest[0]} also deletes it from user.db on the next 'up',")
            print("        together with its grants and tokens. This cannot be undone.")
            if input("        type the username to confirm: ").strip() != rest[0]:
                raise Problem("aborted")
        print(f"[USERS] {store.del_user(rest[0])}")
    elif cmd == "grant":
        if len(rest) < 3:
            raise Problem("usage: users grant <name> <topic-pattern> <rw|ro|wo|deny>")
        if rest[0] == EVERYONE:
            print(f"[USERS] WARNING: 'everyone' is the anonymous user -- this makes "
                  f"'{rest[1]}' PUBLIC,")
            print("        bypassing auth-default-access: deny-all.")
            if input("        continue? [y/N] ").strip().lower() != "y":
                raise Problem("aborted")
        print(f"[USERS] {store.grant(rest[0], rest[1], rest[2])}")
    elif cmd == "revoke":
        if not rest:
            raise Problem("usage: users revoke <name> [topic-pattern]")
        print(f"[USERS] {store.revoke(rest[0], rest[1] if len(rest) > 1 else None)}")
    elif cmd in ("token", "tokens"):
        sub = rest[0] if rest else "list"
        args = rest[1:]
        if sub == "add":
            if not args:
                raise Problem("usage: users token add <name> [label]")
            tok = store.add_token(args[0], " ".join(args[1:]))
            print(f"[USERS] token for {args[0]}: {tok}")
            print(f'[USERS] curl -H "Authorization: Bearer {tok}" -d "hi" '
                  f'https://$DOMAIN/<topic>')
        elif sub in ("del", "rm"):
            if not args:
                raise Problem("usage: users token del <tk_...>")
            print(f"[USERS] {store.del_token(args[0])}")
        elif sub == "list":
            for t in store.tokens:
                if args and t["name"] != args[0]:
                    continue
                print(f"  {t['name']:<20} {t['token']}  {t['label']}")
        else:
            raise Problem("usage: users token <add|del|list> ...")
    elif cmd == "check":
        problems = validate(store)
        if problems:
            print(f"[USERS] {len(problems)} problem(s) -- ntfy would refuse to start:")
            for pr in problems:
                print(f"        {pr}")
            return 1
        print(f"[USERS] config valid ({summary(store)})")
    elif cmd == "apply":
        problems = validate(store)
        if problems:
            print(f"[USERS] {len(problems)} problem(s) -- not applying:")
            for pr in problems:
                print(f"        {pr}")
            return 1
        print(f"[USERS] config valid ({summary(store)}).")
        print("[USERS] 'up' recreates the container so the new auth.env is read.")
        print("        ('restart' would NOT -- it reuses the old environment.)")
        if input("        run 'up' now? [y/N] ").strip().lower() == "y":
            request(apply=True)
        else:
            print("[USERS] not applied -- run './service.sh up' when ready")
    elif cmd in ("help", "-h", "--help"):
        print(USAGE)
    else:
        print(f"[USERS] unknown command: {cmd}\n")
        print(USAGE)
        return 1
    if store.dirty:
        store.save()
    return 0


# ----------------------------------------------------------------- console


class Console:
    """Two-pane master/detail console. Edits are buffered; `s` writes auth.env."""

    LEFT_W = 26

    def __init__(self, stdscr, store):
        self.scr = stdscr
        self.st = store
        self.sel = 0          # index into self.rows()
        self.item = 0         # index into detail items of the selected user
        self.focus = "left"
        self.reveal = False   # show tokens in full
        self.msg = "↑↓ select · → details · ? keys"

    # -- data shaping

    def rows(self):
        """Users, plus a pseudo-row for anonymous grants."""
        out = [u["name"] for u in self.st.users]
        if any(a["name"] == EVERYONE for a in self.st.access):
            out.append(EVERYONE)
        return out

    def current(self):
        rows = self.rows()
        if not rows:
            return None
        self.sel = max(0, min(self.sel, len(rows) - 1))
        return rows[self.sel]

    def items(self, name):
        """Flat list of actionable detail rows: ('grant'|'token', object)."""
        return ([("grant", a) for a in self.st.grants_of(name)]
                + [("token", t) for t in self.st.tokens_of(name)])

    # -- drawing

    def draw(self):
        self.scr.erase()
        h, w = self.scr.getmaxyx()
        if h < 10 or w < 60:
            self.scr.addnstr(0, 0, "terminal too small (need 60x10)", w - 1)
            self.scr.refresh()
            return
        lw = min(self.LEFT_W, w // 2)

        flag = " ·modified" if self.st.dirty else ""
        head = f" ntfy users · auth.env{flag}"
        stats = (f"{len(self.st.users)} user(s)  {len(self.st.access)} grant(s)  "
                 f"{len(self.st.tokens)} token(s) ")
        self.scr.addnstr(0, 0, head.ljust(w - 1), w - 1,
                         curses.A_BOLD | (curses.A_REVERSE if self.st.dirty else 0))
        if w > len(head) + len(stats) + 2:
            self.scr.addnstr(0, w - 1 - len(stats), stats, len(stats), curses.A_BOLD)

        body_h = h - 4
        for y in range(body_h):
            self.scr.addnstr(1 + y, lw, "│", 1)

        rows = self.rows()
        if not rows:
            self.scr.addnstr(2, 2, "(no users)", lw - 3, curses.A_NORMAL)
        for i, name in enumerate(rows[:body_h]):
            role = "anon" if name == EVERYONE else self.st.user(name)["role"]
            attr = curses.A_NORMAL
            if i == self.sel:
                attr = curses.A_REVERSE if self.focus == "left" else curses.A_BOLD
            self.scr.addnstr(1 + i, 0, f" {name:<{lw - 8}}{role:>6} ", lw, attr)

        self.draw_detail(1, lw + 2, w - lw - 3, body_h)

        self.scr.addnstr(h - 3, 0, "─" * (w - 1), w - 1)
        keys = ("  ↑↓ move   → details   a add   d delete   p passwd   r role   "
                "g grant   t token   s save   q quit"
                if self.focus == "left" else
                "  ↑↓ item   ← back   x delete item   g grant   t token   "
                "T reveal   s save   q quit")
        self.scr.addnstr(h - 2, 0, keys[:w - 1], w - 1, curses.A_NORMAL)
        self.scr.addnstr(h - 1, 0, f" {self.msg}"[:w - 1], w - 1)
        self.scr.refresh()

    def draw_detail(self, y0, x0, width, height):
        name = self.current()
        if not name:
            return
        lines = []
        if name == EVERYONE:
            lines.append(("everyone  (anonymous)", curses.A_BOLD))
            lines.append(("PUBLIC — bypasses deny-all", curses.A_NORMAL))
        else:
            u = self.st.user(name)
            lines.append((f"{u['name']}  ({u['role']})", curses.A_BOLD))
            if u["role"] == "admin":
                lines.append(("rw    *  all topics (admin role)", curses.A_NORMAL))
        lines.append(("", 0))

        items = self.items(name)
        grants = [i for i in items if i[0] == "grant"]
        tokens = [i for i in items if i[0] == "token"]

        lines.append(("Grants", curses.A_BOLD))
        if not grants:
            lines.append(("  (none)", curses.A_NORMAL))
        for idx, (_, a) in enumerate(grants):
            mark = ">" if (self.focus == "right" and items.index(("grant", a)) == self.item) else " "
            attr = curses.A_REVERSE if mark == ">" else curses.A_NORMAL
            lines.append((f"{mark} {a['perm']:<5} {a['pattern']}", attr))
        lines.append(("", 0))
        lines.append(("Tokens", curses.A_BOLD))
        if not tokens:
            lines.append(("  (none)", curses.A_NORMAL))
        for _, t in tokens:
            shown = t["token"] if self.reveal else f"{t['token'][:7]}…{t['token'][-4:]}"
            mark = ">" if (self.focus == "right" and items.index(("token", t)) == self.item) else " "
            attr = curses.A_REVERSE if mark == ">" else curses.A_NORMAL
            lines.append((f"{mark} {shown}  {t['label']}", attr))

        for i, (text, attr) in enumerate(lines[:height]):
            self.scr.addnstr(y0 + i, x0, text, width, attr)

    # -- input helpers

    def read_key(self):
        """get_wch, but also decode a raw ESC[A..D from a terminal that never switched
        to application mode -- otherwise the bare ESC would be taken as 'back'."""
        ch = self.scr.get_wch()
        if ch != "\x1b":
            return ch
        self.scr.nodelay(True)
        try:
            nxt = self.scr.get_wch()
        except curses.error:
            nxt = None
        finally:
            self.scr.nodelay(False)
        if nxt is None:
            return "\x1b"
        if nxt not in ("[", "O"):
            return nxt
        self.scr.nodelay(True)
        try:
            third = self.scr.get_wch()
        except curses.error:
            third = None
        finally:
            self.scr.nodelay(False)
        return {"A": curses.KEY_UP, "B": curses.KEY_DOWN,
                "C": curses.KEY_RIGHT, "D": curses.KEY_LEFT}.get(third, "\x1b")

    def prompt(self, label, secret=False):
        h, w = self.scr.getmaxyx()
        buf = []
        curses.curs_set(1)
        try:
            while True:
                shown = "*" * len(buf) if secret else "".join(buf)
                self.scr.move(h - 1, 0)
                self.scr.clrtoeol()
                self.scr.addnstr(h - 1, 0, f" {label}{shown}", w - 1, curses.A_BOLD)
                self.scr.refresh()
                ch = self.read_key()
                if ch in ("\n", "\r"):
                    return "".join(buf)
                if ch == "\x1b":
                    return None
                if ch in ("\x7f", "\b") or ch == curses.KEY_BACKSPACE:
                    if buf:
                        buf.pop()
                elif isinstance(ch, str) and ch.isprintable():
                    buf.append(ch)
        finally:
            curses.curs_set(0)

    def confirm(self, label):
        a = self.prompt(f"{label} [y/N] ")
        return bool(a) and a.strip().lower() == "y"

    def popup(self, lines):
        """Blocking message box -- used for a generated password or a token."""
        h, w = self.scr.getmaxyx()
        bw = min(max(len(l) for l in lines) + 4, w - 4)
        bh = len(lines) + 4
        y0, x0 = max(0, (h - bh) // 2), max(0, (w - bw) // 2)
        win = curses.newwin(bh, bw, y0, x0)
        win.border("|", "|", "-", "-", "+", "+", "+", "+")
        for i, l in enumerate(lines):
            win.addnstr(1 + i, 2, l, bw - 4, curses.A_BOLD if i == 0 else curses.A_NORMAL)
        win.addnstr(bh - 2, 2, "press any key", bw - 4, curses.A_NORMAL)
        win.refresh()
        win.getch()
        self.scr.touchwin()
        self.scr.refresh()

    def ask_password(self):
        """Empty = generate. Returns the hash, or None if cancelled."""
        p1 = self.prompt("password (empty = generate): ", secret=True)
        if p1 is None:
            return None
        if not p1:
            p1 = gen_password()
            self.popup([f"generated password: {p1}",
                        "", "store it now -- only the hash is kept"])
        else:
            p2 = self.prompt("confirm: ", secret=True)
            if p2 is None:
                return None
            if p1 != p2:
                self.msg = "passwords do not match"
                return None
        self.msg = "hashing (ntfy image)..."
        self.draw()
        return bcrypt_hash(p1)

    # -- actions

    def act(self, fn, *a):
        try:
            self.msg = fn(*a) or ""
        except Problem as exc:
            self.msg = f"! {exc}"

    def add_user(self):
        name = self.prompt("new username: ")
        if not name:
            return
        role = self.prompt("role [user/admin] (user): ") or "user"
        if role not in ROLES:
            self.msg = "! role must be 'user' or 'admin'"
            return
        pwhash = self.ask_password()
        if not pwhash:
            return
        self.act(self.st.add_user, name, role, pwhash)
        rows = self.rows()
        if name in rows:
            self.sel = rows.index(name)

    def passwd(self, name):
        pwhash = self.ask_password()
        if pwhash:
            self.act(self.st.set_hash, name, pwhash)

    def role(self, name):
        u = self.st.user(name)
        new = "user" if u["role"] == "admin" else "admin"
        if self.confirm(f"make {name} {new}?"):
            self.act(self.st.set_role, name, new)

    def del_user(self, name):
        a = self.prompt(f"delete {name}? type the name to confirm: ")
        if a == name:
            self.act(self.st.del_user, name)
            self.sel = max(0, self.sel - 1)
        else:
            self.msg = "aborted"

    def grant(self, name):
        pat = self.prompt(f"topic pattern for {name} (e.g. alerts-*): ")
        if not pat:
            return
        perm = self.prompt("permission [rw/ro/wo/deny]: ")
        if not perm:
            return
        if name == EVERYONE and not self.confirm(f"'{pat}' becomes PUBLIC -- continue?"):
            self.msg = "aborted"
            return
        self.act(self.st.grant, name, pat, perm)

    def token(self, name):
        if name == EVERYONE:
            self.msg = "! anonymous has no tokens"
            return
        label = self.prompt("label (optional): ") or ""
        try:
            tok = self.st.add_token(name, label)
        except Problem as exc:
            self.msg = f"! {exc}"
            return
        self.popup([f"token for {name}:", "", tok, "", "shown again with T (reveal)"])
        self.msg = "token added"

    def del_item(self, name):
        items = self.items(name)
        if not items:
            return
        kind, obj = items[min(self.item, len(items) - 1)]
        if kind == "grant":
            if self.confirm(f"revoke {obj['perm']} on {obj['pattern']} from {name}?"):
                self.act(self.st.revoke, name, obj["pattern"])
        else:
            if self.confirm(f"delete token {obj['token'][:10]}...?"):
                self.act(self.st.del_token, obj["token"])
        self.item = max(0, self.item - 1)

    def check(self):
        """Validates the buffer, so unsaved edits are checked too."""
        problems = validate(self.st)
        if not problems:
            self.msg = f"config valid \u00b7 {summary(self.st)}"
            return
        self.popup([f"{len(problems)} problem(s) \u2014 ntfy would refuse to start", ""]
                   + [pr[:70] for pr in problems[:12]])
        self.msg = f"! {len(problems)} problem(s) \u00b7 c to review"

    def help(self):
        self.popup([
            "keys",
            "",
            "↑↓        move          →/⏎  detail pane",
            "←/esc     back          ?    this help",
            "a add user              d    delete user",
            "p password              r    toggle role",
            "g grant                 t    new token",
            "x delete grant/token (detail pane)",
            "T reveal tokens         c    check config",
            "s save                  u    discard changes",
            "q quit",
        ])

    # -- loop

    def run(self):
        curses.curs_set(0)
        # curses.wrapper calls start_color(), which leaves colour pair 0 as white-on-black.
        # Everything curses then paints gets an explicit ESC[40m while untouched cells keep
        # the terminal's own background -- which is the patchwork look. This makes the
        # default pair mean "whatever the terminal uses".
        try:
            curses.use_default_colors()
        except curses.error:
            pass
        while True:
            self.draw()
            try:
                key = self.read_key()
            except curses.error:
                continue
            except KeyboardInterrupt:
                key = "q"
            name = self.current()
            rows = self.rows()

            if key in (curses.KEY_DOWN, "j"):
                if self.focus == "left":
                    self.sel = min(len(rows) - 1, self.sel + 1) if rows else 0
                    self.item = 0
                else:
                    self.item = min(max(0, len(self.items(name)) - 1), self.item + 1)
            elif key in (curses.KEY_UP, "k"):
                if self.focus == "left":
                    self.sel = max(0, self.sel - 1)
                    self.item = 0
                else:
                    self.item = max(0, self.item - 1)
            elif key in (curses.KEY_RIGHT, "\n", "\r", "l"):
                if name and self.items(name):
                    self.focus, self.item = "right", 0
                else:
                    self.msg = "nothing to step into — g adds a grant, t a token"
            elif key in (curses.KEY_LEFT, "\x1b", "h"):
                self.focus = "left"
            elif key == "a":
                self.add_user()
            elif key == "d" and name and name != EVERYONE:
                self.del_user(name)
            elif key == "p" and name and name != EVERYONE:
                self.passwd(name)
            elif key == "r" and name and name != EVERYONE:
                self.role(name)
            elif key == "g" and name:
                self.grant(name)
            elif key == "t" and name:
                self.token(name)
            elif key == "x" and self.focus == "right" and name:
                self.del_item(name)
            elif key == "T":
                self.reveal = not self.reveal
                self.msg = "tokens revealed" if self.reveal else "tokens masked"
            elif key == "c":
                self.check()
            elif key == "s":
                if self.st.dirty:
                    self.st.save()
                    self.msg = "saved · previous version in auth.env.bak"
                else:
                    self.msg = "nothing to save"
            elif key == "u":
                if self.st.dirty and self.confirm("discard unsaved changes?"):
                    self.st.reload()
                    self.msg = "reloaded from auth.env"
            elif key == "?":
                self.help()
            elif key == "q":
                if self.st.dirty:
                    a = self.prompt("unsaved changes -- save? [y/n/esc] ")
                    if a is None:
                        continue
                    if a.strip().lower() == "y":
                        self.st.save()
                    elif a.strip().lower() != "n":
                        continue
                return


def after_console(store):
    """Asked once, after the console closed and something was actually written."""
    if not store.saved_any:
        return
    print(f"[USERS] auth.env written ({summary(store)}).")
    problems = validate(store)
    if problems:
        print(f"[USERS] {len(problems)} problem(s) -- ntfy would refuse to start:")
        for pr in problems:
            print(f"        {pr}")
        print("[USERS] fix auth.env before applying")
        return
    print("[USERS] 'up' recreates the container so the new auth.env is read")
    print("        ('restart' would not -- it reuses the old environment).")
    apply = input("        apply now (up)? [y/N] ").strip().lower() == "y"
    print("[USERS] a commit also creates a borg backup (needs 'borg init' once).")
    commit = input("        commit the change? [y/N] ").strip().lower() == "y"
    message = DEFAULT_COMMIT_MSG
    if commit:
        custom = input(f'        message ["{DEFAULT_COMMIT_MSG}"]: ').strip()
        if custom:
            message = custom
    if apply or commit:
        request(apply=apply, commit=commit, message=message)
    else:
        print("[USERS] nothing applied -- run './service.sh up' when ready")


def main():
    locale.setlocale(locale.LC_ALL, "")  # curses needs this for UTF-8
    argv = sys.argv[1:]
    try:
        if argv:
            return cli(argv)
        if not sys.stdin.isatty() or not sys.stdout.isatty():
            print("[USERS] no terminal for the console -- showing the command list\n")
            print(USAGE)
            return 1
        store = Store()
        curses.wrapper(lambda scr: Console(scr, store).run())
        after_console(store)
        return 0
    except Problem as exc:
        print(f"[USERS] {exc}")
        return 1
    except KeyboardInterrupt:
        print()
        return 130


if __name__ == "__main__":
    sys.exit(main())

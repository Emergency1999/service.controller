# ntfy

## Links

- Official docs: <https://docs.ntfy.sh/>
- Docker install guide (source of this stack): <https://docs.ntfy.sh/install/#docker>
- Full config reference: <https://docs.ntfy.sh/config/>
- Users & access control: <https://docs.ntfy.sh/config/#access-control>
- Unmodified upstream reference: [docs/upstream-compose.yml](docs/upstream-compose.yml)
  (retrieved 2026-10-14; deviations: config via `NTFY_*` env vars instead of a mounted
  `/etc/ntfy/server.yml`, no published ports, data under `./volumes/`)

## First run

1. Fill `DOMAIN` in `.env`, generate the web-push keypair
   (`docker run --rm binwiederhier/ntfy webpush keys`) into `NTFY_WEB_PUSH_PUBLIC_KEY` /
   `NTFY_WEB_PUSH_PRIVATE_KEY`, and fill `NTFY_WEB_PUSH_EMAIL_ADDRESS` — ntfy **refuses to
   start** with web push configured but no contact address.
2. `./service.sh users add admin --admin` — creates the admin account in `auth.env` (return
   at the password prompt generates one and shows it once). There is no setup wizard.
3. `./service.sh up:logs` — wait for `Listening on :80[http]`.
4. Log in at `https://ntfy.example.com` as **`admin`**.

## Accounts and access

Accounts, grants and tokens are **declarative**: they live in `auth.env`, which
`docker-compose.yml` loads into the container with `env_file`. That keeps them in git next to
the stack and makes them survive a `borg restore-fresh` without anyone remembering to
recreate them. `env_file` rather than `environment:` on purpose — a variable *absent* from the
file is then simply unset, where an empty value would abort ntfy at startup.

[`./service.sh users`](users.py) manages all of it. It edits `auth.env`, generates bcrypt
hashes (through the pinned ntfy image, so cost and format always match) and tokens, and never
talks to a running container — so it works before the service has ever been started.

### Console

`./service.sh users` with no argument opens a two-pane console: users on the left, the
selected user's role, grants and tokens on the right.

```
 ↑↓ move   → details   a add   d delete   p passwd   r role
 g grant   t token      s save   u discard   c check   ? keys   q quit
```

In the detail pane `↑↓` picks a grant or token, `x` deletes it, `←` goes back, and `T` reveals
tokens in full for copying (masked by default). `j/k/h/l` work as well as the arrows.

Edits are **buffered** — the header shows `·modified` until `s` writes the file, `u` throws the
buffer away and re-reads from disk, and `q` asks before discarding anything unsaved. Each
write keeps the previous version as `auth.env.bak` (gitignored).

After the console closes, *if* something was written, it validates the result and then asks
whether to `up` and whether to commit. Both are executed by `service.sh` itself, so `up` is the
real `docker_up` with its attachment hooks and autobackup handling, and the commit is the
regular `git commit` (which also makes a borg backup — that needs `borg init` once).

### Arguments

```
./service.sh users list                       # users, grants, tokens
./service.sh users add <name> [--admin] [--token]
./service.sh users passwd <name>
./service.sh users role <name> <user|admin>
./service.sh users del <name> [-y]
./service.sh users grant <name> <topic-pattern> <rw|ro|wo|deny>
./service.sh users revoke <name> [topic-pattern]
./service.sh users token add <name> [label]
./service.sh users token list [name]          # tokens in full
./service.sh users token del <tk_...>
./service.sh users check                      # validate auth.env against ntfy, changes nothing
./service.sh users apply                      # check, then up
```

At a password prompt, pressing return alone **generates** a strong password and shows it once;
typing one asks for confirmation instead. Only the hash is ever stored.

A device that may publish to its own topics and nothing else:

```bash
./service.sh users add printer --token
./service.sh users grant printer 'printer-*' wo
./service.sh users apply
```

```bash
curl -H "Authorization: Bearer tk_..." -d "Print finished" \
     https://ntfy.example.com/printer-alerts
```

`users check` validates natively, in about 50 ms, and needs no container. It mirrors the rules
ntfy applies at startup (`user/util.go`, `cmd/serve.go`): field counts, username / topic-pattern
/ permission / role syntax, bcrypt format and minimum cost, orphan grants and tokens whose user
is not provisioned, duplicates, and the variable-set-but-empty case that aborts ntfy. In the
console `c` checks the *buffer*, so unsaved edits are covered too.

Asking the ntfy binary itself would be stricter in principle but costs 25 s every time: `ntfy
serve` never exits when the config is good, so a valid config could only be confirmed by
waiting out a timeout. If a future ntfy adds a provisioning rule, this validator has to learn
it — `./service.sh up` is still the real arbiter, and it will say so in the logs.

### What the file looks like

Three variables in `auth.env`, comma-separated entries:

| Variable | Entry format | Notes |
|---|---|---|
| `NTFY_AUTH_USERS` | `<user>:<bcrypt-hash>:<role>` | role = `admin` \| `user` |
| `NTFY_AUTH_ACCESS` | `<user>:<topic-pattern>:<access>` | `rw` \| `ro` \| `wo` \| `deny`, `*` wildcard allowed |
| `NTFY_AUTH_TOKENS` | `<user>:<token>[:<label>]` | token = `tk_` + 29 chars, 32 total |

A variable with no entries is left out of the file entirely, never written as `''`.

Verify what the server actually applied — provisioned entries are marked `server config`:

```bash
./service.sh ntfy access
./service.sh ntfy user list
```

### Roles

- `admin` — read-write on **all** topics; the ACL check is short-circuited, so an admin needs
  no grant and automatically covers topics that do not exist yet.
- `user` — no permissions at all until a grant is added (`auth-default-access` is `deny-all`).
- Neither role can manage users or the ACL remotely: there is no admin UI and no user API in
  self-hosted ntfy. The role is purely about topic authorization.
- Rate limits are *tier*-based, not role-based — admins get the same limits as everyone else.
- Prefer `user` + a narrow grant + its own token for devices and scripts. An admin token is an
  unrestricted key to every present and future topic.
- `everyone` as the username grants **anonymous** access and punches straight through
  `deny-all`. Both the console and `users grant` ask for confirmation before writing one.

### The ntfy CLI (the other way)

`./service.sh ntfy user add …`, `ntfy access …` and `ntfy token add …` write to `user.db`
directly and take effect immediately, no restart. Use them to inspect state or for a throwaway
account — but they do **not** mix with a provisioned account of the same name, and anything
created that way exists only in the volume, i.e. only in borg, not in git.

## Quirks

- **Provisioned accounts are owned by the config, not by the CLI.** `ntfy user` / `ntfy access`
  cannot edit them, and **deleting an entry from `auth.env` deletes that user on the next
  start**, along with its grants. Changing a password means regenerating the hash, not
  `change-pass` — `./service.sh users passwd` does that for you.
- **`./service.sh restart` does not apply account changes.** It is `docker compose restart`,
  which restarts the container with its existing environment. Use `./service.sh up` — compose
  then recreates the container and the new `.env` is read.
- **Never leave an auth variable set to an empty value.** ntfy aborts at startup with
  `invalid auth-access: , expected format: 'user:topic:permission'`. This is why `auth.env` is
  loaded with `env_file` and why an unused variable is omitted from the file rather than
  written empty — `./service.sh users` handles that, a hand-edit has to respect it.
- **`auth.env` is not `.env`.** It is read only by docker compose (via `env_file`), never
  sourced by bash and never used for compose interpolation, so a bcrypt hash's `$` survives
  as-is. Values are single-quoted anyway, and no inline `#` comments after a value — compose
  would keep the comment text as part of the value. If a hash is ever mangled, login fails
  with no server-side error; verify what the container actually receives with
  `docker compose run --rm --no-deps --entrypoint sh ntfy -c 'printenv NTFY_AUTH_USERS'`.
- **Topics are flat, with no wildcards for subscribers.** Names are `[-_A-Za-z0-9]{1,64}` — no
  `/`, no MQTT-style `topic/#`. Subscribers enumerate topics comma-separated
  (`/alerts-disk,alerts-cpu/json`); `*` works only in ACL patterns. So use prefixes as a
  pseudo-hierarchy (`alerts-disk`, `alerts-cpu`) and grant them as `alerts-*`, and keep the
  separator consistent — `alerts-*` and `alerts_*` are different patterns.
- **No OIDC/SAML/LDAP, and no header auth.** ntfy's auth is self-contained (local accounts,
  Basic auth, `tk_` tokens); the OIDC request is open upstream with no maintainer commitment.
  Authentik forwardAuth is deliberately *not* in front of this service: topics live at the
  root path, so there is no way to protect the web app without also locking out every mobile
  client, `curl` publisher and webhook, none of which carry an authentik session cookie.
- **Config lives in `docker-compose.yml`, not in a `server.yml`.** Every setting from the
  config reference maps to an env var: `base-url` → `NTFY_BASE_URL`, `auth-file` →
  `NTFY_AUTH_FILE`. The image ships no default `server.yml` and none is mounted, so the
  documented YAML keys have to be translated when adopting a new option.
- **`NTFY_BEHIND_PROXY: "true"` is mandatory** behind traefik. Without it ntfy sees only
  traefik's container IP and rate-limits *all* visitors as if they were one client.
- **The web-push VAPID keypair in `.env` is sticky.** Replacing it silently invalidates every
  existing browser subscription; users then have to re-subscribe. Web push also only works
  over valid HTTPS — which traefik provides.
- **Messages are not a mailbox.** `NTFY_CACHE_DURATION: 12h` means the server drops cached
  messages after 12 hours; subscribers offline longer never see them. Raise it for a longer
  catch-up window (`0` disables caching entirely).
- **No iOS push.** Instant notifications in the official iOS app would need
  `NTFY_UPSTREAM_BASE_URL: https://ntfy.sh`, which forwards poll requests (topic names, not
  message contents) to the public ntfy.sh. Deliberately left off — Android, the web app and
  the CLI are unaffected.
- **The container runs as root** (upstream's `user:` line is dropped). That keeps `cache.db`,
  `user.db` and the attachments directory writable without host-side `chown`; the trade-off is
  root-owned files under `./volumes/`.
- Two databases, two volumes: `./volumes/cache` holds the disposable message cache, web-push
  subscriptions and attachments — `./volumes/lib` holds `user.db`. With declarative accounts
  the authoritative copy of who-may-what is `auth.env` in git; `user.db` is derived state.

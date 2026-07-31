# Migration Checklist

Follow top to bottom. Each step says **who runs it**. Re-read [SKILL.md](SKILL.md) for the
rules behind these steps — especially "old system is read-only" and "do not stop the old
stack".

## 0. Pre-flight (Claude)

- [ ] Confirm SSH access to the old host: `ssh root@OLD 'echo ok'`.
- [ ] Confirm disk space on this host: `df -h "$BASE_DIR"` — must comfortably fit the copy.
- [ ] Identify the service type and pick a template:
      `ls "$BASE_DIR"/.controller/templates/`. If nothing fits, fall back to `default` and apply
      [standardize-service](../standardize-service/SKILL.md).

## 1. Read-only inventory of the old deployment (Claude)

- [ ] `ssh root@OLD 'docker ps'` — list running containers (if dockerized).
- [ ] Locate the service directory and its env file. The env file may live in a parent dir
      (e.g. compose `env_file: ../foo.env`).
- [ ] `cat` the compose file and env file. Note image versions, ports, volumes, env vars.
- [ ] `du -sh <service>/volumes/*` — total size you're about to transfer.
- [ ] `docker exec <c> env` for each container — captures runtime env vars not in compose.
- [ ] For each persistent DB: identify engine, version, root password (from env), DB name(s),
      and whether anything else mounts the data dir.
- [ ] Read the application's own config (e.g. `config.php`, `settings.json`) for embedded
      hostnames, reverse-proxy IPs, signaling URLs — these are common fix-up targets later.
- [ ] **Stop and ask the user** anything ambiguous. Cheap to ask, expensive to redo.

## 2. Plan (Claude, in plan mode)

- [ ] Draft plan with: context, source inventory table, proposed new files (compose, .env,
      service.sh), exact user-run migration commands, verification checklist.
- [ ] Surface any open questions via `AskUserQuestion` before exiting plan mode (e.g. which
      bits of optional infrastructure to keep, whether to route extra subdomains through
      traefik vs leave on host ports, whether to init borg now or later).
- [ ] `ExitPlanMode` for approval.

## 3. Scaffold (Claude)

- [ ] `cd $BASE_DIR && printf 'n\n' | ./controller.sh create <name> <template>` — the piped
      answer handles the interactive Borg prompt; pipe `y` instead if the plan decided to init
      borg now.

## 4. Adapt scaffolded files (Claude)

- [ ] Edit `$BASE_DIR/<name>/docker-compose.yml` to match the plan (services not in the
      template, traefik labels including any custom middlewares, network membership, etc.).
- [ ] Rewrite `$BASE_DIR/<name>/.env` per the plan — rename vars to template conventions, drop
      `BORG_*`, add `TIME_ZONE` if used, carry secrets across verbatim.
- [ ] Append any service-specific commands to `service.sh` if the template doesn't already
      ship them.
- [ ] `cd $BASE_DIR/<name> && docker compose config` — validates the compose syntax without
      starting anything. Inspect the rendered output for typos / unintended interpolation.
- [ ] **Do not run `service.sh git commit` yet.** That triggers a borg backup, and the volumes
      may still be receiving rsync writes.

## 5. Data migration (User)

- [ ] User runs `scp` for env / config files (overwrites template stubs with real values).
- [ ] User runs `rsync -aHAX --numeric-ids --info=progress2` for each volume directory.
      Required flags: `-aHAX` (perms, hardlinks, ACLs, xattrs), `--numeric-ids` (preserve uid/gid
      across host user-namespace differences), `--info=progress2` (single-line progress).
- [ ] For any **running database** on the old side: user runs a logical dump piped into the
      new container. Do **not** rsync DB data files of a running DB.
- [ ] User pings Claude when the copy finishes.

## 6. Verify the copy (Claude)

- [ ] `du -sh $BASE_DIR/<name>/volumes/*` — sizes match expectations.
- [ ] `ls -la $BASE_DIR/<name>/volumes/<critical-dir>` — numeric uid/gid preserved.
- [ ] Spot-check a few files / DB tables exist and look right.

## 7. Start + finalize (Claude)

- [ ] `cd $BASE_DIR/<name> && ./service.sh up`.
- [ ] `./service.sh logs` — tail briefly, watch for fatal errors after the main service starts.
- [ ] `./service.sh status` — all containers up; healthchecks healthy where defined.
- [ ] Apply post-start fix-ups (trusted_proxies, hostname config, internal URLs, etc. — list
      these in the plan).
- [ ] `curl -ksI https://<domain>` and any service-specific endpoint(s) — should return
      expected status from the application, not from traefik's default backend.
- [ ] Hand the verification checklist back to the user with what they need to do (admin-UI
      changes, DNS flip, etc.).

## 8. Cutover (User)

- [ ] User flips DNS to point the new host (or, if DNS already pointed here during the rsync,
      acknowledge that the new stack is already authoritative).
- [ ] Optional brief re-sync if writes happened on the old side between data-copy and DNS flip
      (rsync is idempotent and will only transfer deltas).
- [ ] When the user gives the go-ahead: stop the old stack on the old host (their hand on the
      keyboard, not Claude's).

## 9. Commit + first backup (Claude, on user request)

- [ ] When the user asks to commit:
      ```bash
      cd $BASE_DIR/<name>
      ./service.sh git commit "<concrete description, drafted from the diff>"
      ```
      No separate backup command — `git commit` automatically creates a borg backup named
      `commit: <message>`.
- [ ] Confirm commit and backup both succeeded.

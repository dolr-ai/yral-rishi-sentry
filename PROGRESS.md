# Rollout progress

A living checklist of the 11 phases from the plan (`~/.claude/plans/splendid-spinning-mccarthy.md`). Update this at the end of every session so the next session has a clean pickup point.

Legend: `[x]` done · `[~]` in progress · `[ ]` not started · `[-]` skipped / deferred.

---

## Phase 1 — Pre-flight on rishi-3 · `[x]` DONE 2026-04-21

- [x] SSH to rishi-3 as `deploy`
- [x] Capture baseline (`free -h`, `df -h`, `nproc`, `uptime`, `docker ps`)
- [x] Compare to acceptance gates (≥ 20 GB RAM free, ≥ 120 GB disk free, load < 2.0)
- [x] Write `PRE-FLIGHT.md`
- [ ] Deferred: add 8 GB swap file (rishi's call — revisit when RAM pressure appears)

**Outcome:** all gates passed with massive margin (3× on RAM, 7× on disk). Proceed to Phase 2.

---

## Phase 2 — Install Sentry on rishi-3 · `[~]` IN PROGRESS

**Local scaffolding — DONE**
- [x] Create local repo at `~/Claude Projects/yral-rishi-sentry/`
- [x] Pin `SENTRY_VERSION=26.4.0` in `project.config`
- [x] Create GitHub repo `dolr-ai/yral-rishi-sentry` (live at https://github.com/dolr-ai/yral-rishi-sentry, public)
- [x] `docker-compose.override.yml` — loopback bind, resource limits on 9 heaviest services
- [x] `sentry/config.yml` — URL prefix, `auth.allow-registration: false`, Google OAuth env-var placeholders, mail=dummy
- [x] `sentry/sentry.conf.override.py` — `GOOGLE_DOMAIN_WHITELIST = ['gobazzinga.io']` + session hardening
- [x] `scripts/install.sh` — idempotent bootstrap; places our overrides, runs upstream install.sh, verifies `/_health/`
- [x] `scripts/upgrade.sh` — changelog-gated, dry-run-first upgrade with pre-upgrade backup hook

**On-rishi-3 steps**
- [x] `git clone` of yral-rishi-sentry to rishi-3 `~/yral-rishi-sentry` — DONE 2026-04-21
- [x] `scripts/install.sh` run — DONE 2026-04-21 (7 attempts; 5 bugs fixed along the way, all now committed)
- [x] Verify `curl http://127.0.0.1:9000/_health/` returns `ok` on rishi-3 — **PASSED**
- [x] All 30+ Sentry containers healthy (web, nginx, relay, snuba-api, clickhouse, kafka, postgres, consumers) — CONFIRMED
- [ ] **Gate C — Rishi creates superuser** (manually, so password never touches Claude):
      `cd ~/sentry-upstream && docker compose run --rm web createuser --email rishi@gobazzinga.io --password '<strong-pw>' --superuser`
- [ ] Set GitHub Secrets `SENTRY_HOST_IP`, `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` (deferred; placeholder values currently in `.env.custom`)
- [ ] Google Cloud Console: create OAuth 2.0 Client ID (Phase 4)

## Install-time bugs encountered on first Phase 2 attempts (all fixed)

For future reference — each of these is now baked into the install.sh in a way that prevents recurrence:

1. `--skip-user-prompt` was deprecated at upstream 26.4.0 → replaced with `--skip-user-creation`, plus added `--no-report-self-hosted-issues` and `--apply-automatic-config-updates` to silence two other interactive prompts.
2. `docker-compose.override.yml` named `worker` and `cron` — upstream renamed to `taskworker` and `taskscheduler` → updated our override with verified service names. Added a warning comment that names MUST be re-verified on every SENTRY_VERSION bump.
3. Empty `SENTRY_SYSTEM_SECRET_KEY` broke Django boot → install.sh now generates + persists a key in `.env.custom`.
4. Secret generation used `tr | head` which SIGPIPE'd under `pipefail` → switched to `python3 -c` with the `secrets` module.
5. Generated secrets contained `&(*^#)` which broke bash `source` of `.env.custom` → switched to shell-safe alphabet (`a-zA-Z0-9-_`) AND defensively single-quote every value in the written file.
6. Initial containers born without `SENTRY_SYSTEM_SECRET_KEY` because our shell didn't export it → install.sh now sources `.env.custom` into its own shell AND passes `--force-recreate` to compose.

**Gate to Phase 3:** `/_health/` = ok from inside rishi-3.

---

## Phase 3 — Caddy reverse proxy + TLS · `[ ]`

- [ ] Write `/home/deploy/caddy/conf.d/sentry.caddy` on rishi-1
- [ ] Mirror on rishi-2
- [ ] Confirm rishi-1 Caddy can reach `rishi-3:9000` (network path decision)
- [ ] Confirm Cloudflare DNS covers `sentry.rishi.yral.com` via the `*.rishi.yral.com` wildcard; add explicit record if not
- [ ] `systemctl reload caddy` on both hosts
- [ ] Browser test: `https://sentry.rishi.yral.com` shows Sentry login page

---

## Phase 4 — Google Workspace SSO · `[ ]`

- [ ] Verify `gobazzinga.io` is on Google Workspace (ask Saikat if unsure)
- [ ] Create Google OAuth 2.0 Client ID (Web application, redirect `https://sentry.rishi.yral.com/auth/sso/`)
- [ ] Save `GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET` to this repo's GitHub Secrets
- [ ] Add `auth-google.*` to `sentry/config.yml`
- [ ] Add `GOOGLE_DOMAIN_WHITELIST = ['gobazzinga.io']` to `sentry/sentry.config.py`
- [ ] `docker compose restart web worker`
- [ ] Configure in UI: Organization Settings → Auth → Google, enable "Require SSO"
- [ ] Test: @gobazzinga.io Google account → allowed; other Google account → rejected

---

## Phase 5 — Sentry projects + DSNs · `[ ]`

- [ ] Create org (`gobazzinga` or `dolr-ai` — confirm with Saikat)
- [ ] Create team `rishi-services`
- [ ] Create 4 projects: `yral-chat-ai`, `yral-rishi-hetzner-infra-template`, `yral-hello-world-rishi`, `yral-hello-world-counter`
- [ ] Copy each DSN; store in the corresponding repo's GitHub Secrets as `SENTRY_DSN`
- [ ] Configure alert rule per project (email to rishi@gobazzinga.io on new unresolved issue)

---

## Phase 6 — chat-ai cutover + drift fix · `[ ]`

- [ ] Update `yral-chat-ai/app/main.py` — remove inline `sentry_sdk.init()`, call `init_sentry()` from `infra/sentry.py`
- [ ] Verify `infra/sentry.py` matches the template's version byte-for-byte
- [ ] Remove `/sentry-debug` endpoint
- [ ] `gh secret set SENTRY_DSN` to the new DSN
- [ ] Push, wait for canary deploy to complete
- [ ] Force an error, verify event + performance transactions arrive in new Sentry

---

## Phase 7 — Cut over template demo + hello-world × 2 · `[ ]`

- [ ] `gh secret set SENTRY_DSN` in `yral-rishi-hetzner-infra-template`, redeploy, verify
- [ ] `gh secret set SENTRY_DSN` in `yral-hello-world-rishi`, redeploy, verify
- [ ] `gh secret set SENTRY_DSN` in `yral-hello-world-counter`, redeploy, verify
- [ ] Confirm apm.yral.com is no longer receiving new events from any of these four

---

## Phase 8 — Bake into the template · `[ ]`

- [ ] Update `TEMPLATE.md` — replace `apm.yral.com` with `sentry.rishi.yral.com`; add numbered "create Sentry project" step
- [ ] Update `scripts/new-service.sh` — end-of-run message pointing at the new Sentry UI
- [ ] Update `INTEGRATIONS.md` — new Sentry endpoint, pointer to `yral-rishi-sentry` RUNBOOK
- [ ] Update `SECURITY.md` — SENTRY_DSN source column
- [ ] Update `infra/sentry.py` header comment
- [ ] PR, self-review, merge

---

## Phase 9 — Runbook + backups + watchdog · `[ ]`

- [ ] Write `RUNBOOK.md` (Sentry down, Clickhouse disk, Kafka lag, upgrades, OAuth rotation)
- [ ] Write `SECURITY.md` (threat model, secrets inventory, recovery procedures)
- [ ] `.github/workflows/health-check.yml` — curl `/_health/` every 5 min, fail on non-200
- [ ] `.github/workflows/backup.yml` — daily pg_dump of Sentry Postgres → S3
- [ ] Write + install `systemd/sentry.service` on rishi-3
- [ ] Verify: stop compose manually, confirm systemd restarts it; reboot rishi-3 (in maintenance window), confirm Sentry comes back

---

## Phase 10 — Scaling escape hatch · `[ ]`

- [ ] Write `SCALING.md` (monitoring thresholds, rishi-3 → rishi-4 migration, component-level scale-out)
- [ ] Add threshold alerts to health-check workflow
- [ ] Full end-to-end retest (induce errors in all 4 services within one minute, verify all arrive correctly)

---

## Open questions (for Saikat, carry forward until resolved)

1. Sentry org name: `gobazzinga` or `dolr-ai`? (Phase 5 blocker)
2. Is `gobazzinga.io` on Google Workspace? (Phase 4 blocker)
3. SMTP relay for Sentry email alerts, or UI-only? (Phase 9, non-blocking)
4. Delete old Sentry projects on apm.yral.com after cutover, or keep indefinitely? (Phase 7, non-blocking)

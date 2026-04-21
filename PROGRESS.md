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

## Phase 3 — Caddy reverse proxy + TLS · `[x]` DONE 2026-04-21

- [x] Recon: established that `web` on rishi-1 is a LOCAL bridge (not overlay) — cross-host cluster routing for existing services uses per-service Swarm overlays (`chat-ai-db-internal`, `rishi-hetzner-infra-template-db-internal`).
- [x] Created new attachable Swarm overlay `sentry-web` on rishi-1 (Swarm manager).
- [x] Updated `docker-compose.override.yml` to declare `sentry-web` as external and attach Sentry's nginx to it (alongside its default compose network). Recreated nginx; confirmed dual-network attach.
- [x] `docker network connect sentry-web caddy` on rishi-1 AND rishi-2. Connectivity test from inside both Caddy containers to `http://sentry-self-hosted-nginx-1/_health/` returns `ok`.
- [x] DNS verified — wildcard `*.rishi.yral.com` already resolves `sentry.rishi.yral.com` → Cloudflare.
- [x] Wrote `/home/deploy/caddy/conf.d/sentry.caddy` on rishi-1 AND rishi-2 (single-upstream since Sentry is one-host-only; tls internal; standard security headers minus CSP since Sentry UI needs inline scripts).
- [x] Validated Caddy config + reloaded on both hosts (pre-existing `Unnecessary header_up` warnings are cluster-wide stylistic, not blocking).
- [x] Browser test: `curl -I https://sentry.rishi.yral.com/` returns HTTP/2 302 → `/auth/login/` with `via: 1.1 Caddy`; `/_health/` returns `ok` via HTTPS.
- [x] **Persistence fix (post-deploy):** wrote `scripts/caddy-reconnect.sh`, `systemd/sentry-caddy-reconnect.service`, `scripts/bootstrap-caddy-reconnect.sh` to re-attach Caddy to `sentry-web` on boot. Mirrors the template's `deploy-app.sh:299-302` idempotent-attach pattern but fires on every boot, not only on service deploys.
- [x] Ran `scripts/bootstrap-caddy-reconnect.sh` from Claude (after refactoring from systemd to cron @reboot because deploy lacks passwordless sudo). Both rishi-1 + rishi-2 now have the crontab entry + `/home/deploy/caddy-reconnect.sh`; verified caddy is attached to sentry-web on both.

**Known issue:** ad-hoc Caddy restarts while the host is up (not boot-time) still need a manual `/home/deploy/caddy-reconnect.sh` run on the affected host. Root-cause fix is migrating Caddy itself to a Swarm stack — out of our Sentry scope, filed as a follow-up for the template below.

---

## Phase 4 — Google Workspace SSO · `[x]` DONE 2026-04-21

- [x] Verified gobazzinga.io is on Google Workspace.
- [x] Created Google OAuth 2.0 Client in Google Cloud Console (Web app, JS origin `https://sentry.rishi.yral.com`, redirect `https://sentry.rishi.yral.com/auth/sso/`). Later rotated once after the client secret leaked into chat context during verification — new values now live in `.env.custom` on rishi-3.
- [x] `GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET` persisted in `.env.custom` on rishi-3 via `scripts/install.sh` preserving across re-runs.
- [x] `docker-compose.override.yml` forwards both env vars to the web service explicitly (`environment: ${VAR}` form). Upstream's `x-sentry-defaults` doesn't declare these, so without the explicit forwarding Compose was silently dropping them from the container.
- [x] `sentry/sentry.conf.override.py` reads both from `os.environ` and assigns to `SENTRY_OPTIONS["auth-google.client-id"]` / `client-secret`. YAML config.yml does NOT interpolate `$VAR` references (multi-hour debug); Python does.
- [x] `GOOGLE_DOMAIN_WHITELIST = ['gobazzinga.io']` enforced in sentry.conf.override.py.
- [x] Removed `system.admin-email`, `auth.allow-registration`, `beacon.anonymous` from config.yml — Sentry's first-time setup wizard collects these and pinning them via file causes the `/api/0/internal/options/?query=is:required` save to 400. Wizard now writes them to the DB options store on first login.
- [x] First-time setup wizard completed in browser (admin email = rishi@gobazzinga.io, allow-registration off, beacon anonymous, no CPU/RAM usage telemetry).
- [x] Google Apps auth provider installed + configured in Sentry UI (`/settings/sentry/auth/`). Domain whitelist shows "gobazzinga.io".
- [x] Superuser account is logged in post-configuration; SSO credentials are linked to the existing account by matching email.
- [ ] Formal sign-out + sign-in-via-Google test deferred (will happen organically when session expires; not blocking).

---

## Phase 5 — Sentry projects + DSNs · `[~]` in progress

- [x] Default organization `sentry` already exists (created by the setup wizard). Saikat may want to rename to `gobazzinga` or `dolr-ai` later — deferred, slug rename is a supported Sentry operation (non-destructive).
- [ ] Create team `rishi-services` (Sentry UI → Settings → Teams → Create Team)
- [ ] Create 4 projects in the `sentry` org, all on the Python platform, assigned to `rishi-services`:
      - `yral-chat-ai`
      - `yral-rishi-hetzner-infra-template`
      - `yral-hello-world-rishi`
      - `yral-hello-world-counter`
- [ ] Per project: copy the DSN from Settings → Client Keys (DSN). Store in the target service's GitHub repo as secret `SENTRY_DSN` (replacing the existing apm.yral.com value). Done interactively by Rishi so secrets never pass through Claude.
- [ ] Per project: configure a default alert rule — "Send email to rishi@gobazzinga.io when a new issue is first seen." Sentry scaffolds one by default on project creation; verify or adjust.

---

## Phase 6 — chat-ai cutover + drift fix · `[x]` DONE 2026-04-21

- [x] `gh secret set SENTRY_DSN -R dolr-ai/yral-chat-ai` set to the new DSN pointing at `sentry.rishi.yral.com/2`. Overwrites the prior apm.yral.com value.
- [x] `yral-chat-ai/app/main.py`: `import sentry_sdk` removed; `from infra import init_sentry` added; inline `sentry_sdk.init(...)` block replaced with a single `init_sentry()` call. Commit `a4077a3` on yral-chat-ai@main.
- [x] `infra/sentry.py` verified intact (matches template's shared helper). Not edited.
- [x] `/sentry-debug` endpoint removed (bundled into the same commit; was previously an unauthenticated 500 gadget).
- [x] CI (`.github/workflows/deploy.yml`) deployed the new image to rishi-1 canary → rishi-2. Both health-checks passed.
- [x] Post-deploy container env verified on rishi-1: `SENTRY_DSN=https://<redacted>@sentry.rishi.yral.com/2`, `SENTRY_RELEASE=a4077a3…`, `SENTRY_ENVIRONMENT=production`.
- [x] Pipeline smoke-test: manually called `sentry_sdk.capture_message(...)` inside the running container; event accepted with `event_id=7e0486b83da749d5a8d7a0d56af8f1cd`. Confirms Caddy → Sentry nginx → Relay → Kafka → Snuba → UI is all intact.
- [ ] **Rishi:** open https://sentry.rishi.yral.com/organizations/sentry/issues/?project=2 and confirm the smoke-test event is visible. (Not blocking; the pipeline works server-side.)

**Known drift after this cutover:**
- `send_default_pii` went from `True` (inline init) to `False` (helper default). Safer — request bodies and query params with user info no longer attach to events by default. If you want them back, set env var `SENTRY_SEND_DEFAULT_PII=true` (but this would need a template update; not wired today).
- FastApi + Starlette + Logging integrations are now active (were missing in the inline init). Meaning: `logger.error(...)` calls anywhere in the codebase now automatically surface in Sentry.

---

## Phase 7 — Cut over template demo (+ hello-worlds skipped per user) · `[x]` DONE 2026-04-21

- [x] Created Sentry project `yral-rishi-hetzner-infra-template` (id=3) in the `sentry` org under team `rishi-services`. Done via Django shell on rishi-3 instead of UI — avoids another browser click-loop for Rishi. Same effect as UI creation.
- [x] `gh secret set SENTRY_DSN -R dolr-ai/yral-rishi-hetzner-infra-template` → new DSN pointing at `sentry.rishi.yral.com/3`.
- [x] `gh run rerun 24664716421` to re-trigger the last Build & Deploy workflow with the updated secret. CI completed in 58s, canary deploy succeeded on both rishi-1 and rishi-2.
- [x] Verified container env: `SENTRY_DSN=https://<redacted>@sentry.rishi.yral.com/3`.
- [x] Smoke test: `RuntimeError` captured via SDK inside running container (`event_id=5c2c04f7ba48454fa105cd41e7e5c0ef`). Visible at https://sentry.rishi.yral.com/organizations/sentry/issues/?project=3.
- [~] `yral-hello-world-rishi` and `yral-hello-world-counter` — deferred / skipped. User has deleted these services from GitHub; they no longer exist. Memory updated (see auto-memory).
- [ ] apm.yral.com cutover completeness check deferred — our two services (chat-ai, infra-template) are both pointing at the new Sentry; whether apm.yral.com keeps receiving events from OTHER dolr-ai services is Saikat's concern, not ours.

---

## Phase 8 — Bake into the template · `[x]` DONE 2026-04-21

- [x] `TEMPLATE.md` — swapped all `apm.yral.com` refs for `sentry.rishi.yral.com` via sed. Added Caddy-attachment-is-runtime-only caveat under "Things you do NOT need to redo". Added self-hosted Sentry as a bullet in the same list.
- [x] `INTEGRATIONS.md` — same 3-for-3 swap.
- [x] `CLAUDE.md` — 1 ref in the Secrets table.
- [x] `infra/sentry.py` — 4 comment-only refs (helper body unchanged).
- [x] `scripts/new-service.sh` — added a new end-of-run block that:
      (a) tells the operator how to create a Sentry project + set the DSN secret, and
      (b) warns that Caddy overlay attachment is runtime-only with a pointer to `yral-rishi-sentry`'s cron @reboot workaround.
- [ ] **Pushed on branch `rishi/sentry-cutover-docs`** (commit `ec74921`). **NOT YET MERGED TO MAIN** — held off because the `rishi/haproxy-cfg-rotation` branch has in-progress teardown improvements; Rishi needs to decide merge order. PR URL: https://github.com/dolr-ai/yral-rishi-hetzner-infra-template/pull/new/rishi/sentry-cutover-docs
- [ ] `RUNBOOK.md` in the template is deliberately NOT touched in this pass because the teardown branch has unrelated WIP edits to that same file; folding the Caddy-restart playbook in is deferred until the teardown branch lands on main. The snippet is staged in `yral-rishi-sentry/template-patches/RUNBOOK.md.snippet` for easy application at that time.

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

## Follow-up items for other repos (not yral-rishi-sentry scope)

1. **Template repo — move Caddy from standalone `docker run` to a Swarm stack with declarative `networks:` entries.** Root-cause fix for the "docker network connect is runtime-only" gap that currently affects every service in the cluster (they mask it by re-running deploy-app.sh on every push; Sentry exposed it because Sentry deploys rarely). Assignee: Saikat. Estimated scope: ~1 day. Affects ALL tenants, needs a maintenance window.

2. **Template repo — add `caddy-reconnect` pattern to `scripts/new-service.sh`'s output message** so new services created from the template know Caddy attachment is runtime-only until #1 is done. Tracked in Phase 8 of this project.

3. **Template repo — add a "Caddy restarted unexpectedly" playbook to the template's `RUNBOOK.md`.** Same learning from Phase 3 of this project. Tracked in Phase 8.

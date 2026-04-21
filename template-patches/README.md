# Template patches from the Sentry rollout

## Why this directory exists

Deploying `yral-rishi-sentry` surfaced a behaviour that affects every service in the cluster: `docker network connect <overlay> caddy` is a **runtime** attachment that does not persist across Caddy container restarts. The existing template (`yral-rishi-hetzner-infra-template`) hides this gap because its `scripts/ci/deploy-app.sh` re-runs the attach on every push-to-main deploy, and services push frequently. Sentry exposed the gap because it deploys rarely (monthly upgrades at best) so a Caddy reboot between deploys orphans its overlay.

These three snippets fold the Sentry learnings back into the template so new services created from the template are aware of the pattern and of the recovery steps — without waiting for the root-cause fix (move Caddy to a Swarm stack, out of scope for this project).

## How to apply

When your in-progress teardown branch (`rishi/haproxy-cfg-rotation` today) lands on `main`, come back here and:

1. Switch the template repo to `main`, pull latest.
2. `git checkout -b rishi/caddy-attachment-docs`
3. Apply the three snippets below in the locations indicated.
4. Commit with a message starting `docs:` (three small doc commits, or one bundled — your call).
5. Push + open PR for Saikat.

Each snippet is a plain copy-paste block, not a unified diff, so it's robust against unrelated template edits.

## The three snippets

| # | Snippet file | Where it goes in the template |
|---|---|---|
| 1 | `TEMPLATE.md.snippet` | Replace the single line `- ✅ Caddy running on rishi-1 and rishi-2` in the "Things you do NOT need to redo" section (~line 143) with the block in the snippet file. |
| 2 | `RUNBOOK.md.snippet` | Append as a new subsection under `## 3. Caddy Down`, OR as a standalone top-level section `## Caddy lost overlay attachment`. Either works — the snippet includes its own `##` heading so pick the level that fits. |
| 3 | `new-service.sh.snippet` | Insert into `scripts/new-service.sh` inside the final summary block, between the "Next steps" section and the closing ========= border (~line 452). |

## What these snippets DO NOT do

- They don't fix the root cause. The permanent fix is converting Caddy from a standalone `docker run` to a Swarm stack with `networks:` declarations — that's in `PROGRESS.md` of this project as "Follow-up item #1" for Saikat.
- They don't add a `caddy-reconnect.sh` helper to the template itself. The template doesn't know about specific overlays (each service picks its own), so a generic helper would be a lifecycle hook — larger change than these docs warrant. If the root-cause fix is deferred for > 3 months, revisit and add a generic helper.

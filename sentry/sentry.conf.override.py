# =============================================================================
# yral-rishi-sentry — Python-level config overrides
# =============================================================================
#
# This file is APPENDED to upstream's `sentry/sentry.conf.py` on rishi-3 by
# `scripts/install.sh` — we do NOT overwrite the whole upstream file (534
# lines we'd then have to resync on every Sentry release).
#
# Appending is idempotent: install.sh wraps this block in the marker
# comments `# --- BEGIN yral-rishi-sentry overrides ---` and
# `# --- END yral-rishi-sentry overrides ---`. On re-run, install.sh
# deletes everything between the markers and re-inserts this file's
# contents verbatim. So editing this file is the supported way to change
# Python-level Sentry behaviour on rishi-3.
#
# WHY Python and not YAML? Sentry's YAML config (sentry/config.yml) is a
# flat key→value map. It cannot express things like "allow SSO sign-in only
# for users whose email ends in @gobazzinga.io" because that is a
# Python-level configuration (a list assigned to GOOGLE_DOMAIN_WHITELIST).
# Anything that needs Python lives here.
#
# SAFETY: this file is committed to git. No secrets — Google OAuth
# client secret lives in .env.custom on rishi-3, NOT here.
# =============================================================================


# -----------------------------------------------------------------------------
# Google Workspace SSO domain restriction
# -----------------------------------------------------------------------------
#
# Sentry's built-in Google OAuth provider (configured via auth-google.*
# in config.yml) checks every signing-in user's verified email address
# against this whitelist. If the domain part (everything after the @)
# is NOT in this list, the login is refused.
#
# Multiple domains are supported — add them to the list. For now, only
# gobazzinga.io is allowed, matching Saikat's ask.
#
# WHY not a wildcard / regex? Google's OAuth ID tokens include a verified
# email claim; Sentry compares the literal domain string. A misconfigured
# regex would widen access unexpectedly. An explicit allowlist is safer.
GOOGLE_DOMAIN_WHITELIST = [
    "gobazzinga.io",
]


# -----------------------------------------------------------------------------
# Default organization access for SSO sign-ins
# -----------------------------------------------------------------------------
#
# When a @gobazzinga.io user signs in with Google for the FIRST time,
# Sentry needs to know what to do with them. Without this, they land on
# a "pick an organization to join" page which is confusing.
#
# We set this so first-time SSO users auto-join the single org we create
# in Phase 5 as members (NOT admins). Elevation to admin is a manual step
# done by an existing admin in the UI.
#
# The actual org slug ("gobazzinga" vs "dolr-ai") is TBD in Phase 5 —
# once decided, update this string and re-run install.sh to re-apply.

SENTRY_SINGLE_ORGANIZATION = True
# When SSO users join without an explicit invite, give them the default
# member role. They get read access to everything in the org; no admin
# rights until explicitly granted.
SENTRY_SIGNUP_URL = None  # Disable the "create account" UI link entirely.


# -----------------------------------------------------------------------------
# Request size limits (Caddy is the real enforcer, this is a safety net)
# -----------------------------------------------------------------------------
#
# Sentry's default event size cap is 1 MB. That's too small for
# Python stack traces with long strings, and especially for minidump
# crash reports if we ever add native crash reporting.
#
# Caddy's snippet caps at 100 MB (see `caddy/sentry.caddy` from Phase 3),
# so we set this to match. If a 100 MB event actually arrives, something
# is wrong and Sentry should reject cleanly rather than silently truncate.
SENTRY_MAX_EVENT_PAYLOAD_SIZE_MB = 100


# -----------------------------------------------------------------------------
# Time zone + locale
# -----------------------------------------------------------------------------
#
# All timestamps in Sentry's UI are presented in UTC (Sentry displays the
# viewer's local timezone in the browser — this just sets the storage
# timezone). UTC is the right default for an international team.
TIME_ZONE = "UTC"

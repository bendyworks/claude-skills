---
name: app-wind-down
description: Wind down a hosted app safely and reversibly -- Phase 1 cuts running costs to a bare-minimum caretaker mode (site stays warm and demo-able), Phase 2 hibernates it to ~$0 with full restore assets. Use when an app is being shut down, paused, sold, or cost-reduced to the bone -- triggers on "wind down", "shut down the app", "caretaker mode", "hibernate the app", "bare minimum hosting", "the app is closing down". Covers the vendor-account audit that prevents orphaned-subscription outages.
---

# App Wind-Down

Two phases. Phase 1 keeps the app live and instantly demo-able at minimum
cost (the owner is shopping it, pausing, or deciding). Phase 2 (only on
explicit trigger) shuts it down reversibly: assets safeguarded, restore
runbook written, cost ~$0. Never start Phase 2 work on the assumption it is
coming.

Everything here was learned on a real wind-down. The gotchas are the point;
the checklists exist to force them into view.

## Rule zero: reversibility and evidence

- **Record verbatim before deleting.** Scheduler jobs, cron entries, config
  values, plan names -- capture the exact definitions into the runbook or
  plan file BEFORE removing them. Deletion without a record is the only
  truly irreversible mistake in Phase 1.
- **Capture restore assets before destroying anything**: `heroku config -s`
  snapshot (or equivalent) and a final DB backup, stored in the project's
  password vault. Mark which config vars are add-on-managed
  (DATABASE_URL, REDIS_URL, ...) and must NOT be restored verbatim -- a
  naive snapshot restore points at destroyed resources.
- **Bake before destroy.** Prorated billing means keeping a demoted
  database/Redis attached for 24-48h costs pennies and converts the two
  riskiest steps into trivially reversible ones. Destroys are a day-2 task.
- **Take a production safety backup before any datastore migration**, not
  just the thing being shut down.

## Phase 0: audit the app's vendor accounts FIRST

The biggest outage risk in a wind-down is not your changes -- it is the
project's neglected vendor accounts. Staff departures orphan subscriptions,
payment cards, 2FA phones, and recovery emails. Audit early, before caches
and grace periods hide the damage:

- Enumerate every vendor: DNS/registrar, email delivery, file storage,
  error tracking, background-check APIs, code host. For each: who owns the
  account, what email does recovery route through, whose card pays, when
  does it renew?
- **Check DNS health explicitly**: `dig SOA <domain> @<their-ns>` --
  REFUSED from the authoritative NS means the DNS account is
  suspended/lapsed (this took down a real app's domains when a departing
  employee's subscription-minding stopped).
- **Beware circular lockouts**: a recovery email hosted ON the domain being
  wound down is unreachable the moment DNS dies. Identify these loops
  before you need them.
- Domain registration and TLS cert expiry dates go on a dated list. A
  lapsed registrar account silently fails the domain renewal -- the brand
  is the owner's most sellable asset.
- API tokens in the password vault often outlive web logins; `whoami`-style
  endpoints diagnose account state (suspended vs healthy) without any
  login. Try the token before escalating to account-recovery ceremonies.
- Google Workspace login quirk: after an admin password reset, Google
  throws a login challenge at the RECOVERY PHONE even with 2FA disabled.
  Fix: admin console -> user -> Security -> "Turn off login challenge for
  10 minutes", or relay the code live. Then move recovery contacts to
  whoever is actually operating.

## Phase 1: bare-minimum caretaker mode

Goal: lowest recurring spend while the site stays warm and snappy for a
single demo user. State the warmth constraint explicitly (on Heroku: no Eco
dynos -- they sleep; Basic and Standard stay warm).

- **Stop the labor first.** The retainer/maintenance contract usually dwarfs
  hosting. That decision is the client's; get it in writing.
- **Kill cost-driving scheduled jobs** (anything that calls paid APIs or
  sends bulk email). Check for jobs that are added manually on a calendar
  ritual (annual reruns) -- "not scheduled right now" does not mean "won't
  fire"; note the ritual so nobody performs it.
- **Downsize with these gotchas in mind:**
  - Platform tier-mixing rules: Heroku forbids Basic dynos alongside
    Standard in one app. Verify the target formation is legal before
    promising its price.
  - Grandfathered legacy plans can be CHEAPER than every current plan
    (SendGrid bronze < today's cheapest). Check the current catalog before
    "downgrading" -- some downgrades are one-way doors to pricier tiers.
  - Free-tier eligibility must count STORED assets, not just monthly
    usage (existing uploads count against Cloudinary credits).
  - Never destroy-and-reprovision an email add-on: a fresh account loses
    SPF/DKIM/domain auth and mail fails silently. In-place plan changes
    only, then prove delivery with a real password-reset to a real inbox.
  - Datastore downgrades are re-provision-and-promote migrations:
    maintenance mode does NOT stop workers (scale worker=0 during the
    copy), and `redis:promote` migrates zero data (verify queues/retry/
    scheduled sets are empty; dump the dead set for the record).
  - Budget-tier databases usually lose continuous protection -- schedule
    nightly logical backups explicitly.
- **Add monitoring, because nobody is watching anymore.** A free uptime
  ping (an existing APM's synthetic check works, or any free uptime
  pinger) alerting the responsible human. Point it at the platform URL (herokuapp.com), not the custom
  domain, so a DNS incident doesn't blind the app check.
- **Verify end to end**: key pages, images from the CDN, a DB read, and a
  real delivered email. Then compute the new run-rate from live plan data.
- **Report honestly to the client**: contingencies (what stayed paid and
  why), the single-dyno restart blip, exactly when prepaid hours run out,
  and before/after numbers in a plain-text aligned table.

## Phase 2: reversible shutdown (~$0 hibernation, explicit trigger only)

Safeguard before teardown, in this order:

1. Code custody: the client gets a complete, independent copy (repo
   transfer or bundle) AND the agency keeps a custodial copy.
2. Final DB dump + ALL uploaded files (CDN originals, S3 docs) to durable
   cold storage -- large binaries belong in Drive/S3-class storage, not the
   password vault (vault gets the config/secrets snapshots).
3. `config -s` for every app into the vault.
4. KEEP the domain registered and auto-renewing -- it protects the brand.
   Point it at a holding page.
5. Write RESURRECTION.md: re-provision, restore, re-key, repoint DNS,
   deploy tagged release, smoke test. Restoration labor bills when it
   happens; the runbook is what makes that possible.
6. Only then tear down. Note that a torn-down app's free shell (config,
   domains, cert endpoints, pipeline slot) costs nothing to keep and makes
   restore dramatically easier -- destroy add-ons and scale to zero rather
   than deleting the app.

## Working practices that made this go well

- Small numbered task lists with permanent numbers; plan file updated as
  each lands.
- A challenge/red-team pass on the plan before executing caught: the bake
  period, the worker-during-pg:copy hole, the production backup gap, the
  mail-silent-failure trap, and the cost-target contingencies.
- Client emails in the operator's voice with real dollar figures, drafted
  to `tmp/` for the human to send.
- Rotate any credential that passed through a chat session once the
  emergency is over.

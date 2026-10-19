# Deploying the custom Sure image (fork runbook)

How this fork is validated, built, deployed to the homelab and rolled back.
What the custom code does is in [custom-wise-integration.md](custom-wise-integration.md)
and [custom-binance-integration.md](custom-binance-integration.md).

**Never run builds, the test suite or migration tests on the production Docker
daemon.** It is a single 12-CPU / 8 GB VM shared with the whole homelab; a
parallel test run once made `sure-web` and `sure-worker` restart.

## CI (GitHub Actions)

`.github/workflows/fork-release.yml` runs on every push to `feature/**` and on
manual dispatch, on GitHub-hosted runners only:

| Job | What it does |
|---|---|
| `ci` | Calls the upstream `ci.yml` unchanged: Brakeman, importmap audit, Rubocop, Biome, full Rails suite, system tests |
| `wise` | Wise, provider-ledger, Binance futures, derivative and Kraken tests alone (fast signal) |
| `migrations` | Loads the schema of the release production runs (`baseline_ref`, default `v0.7.5-hotfix.2`), records exactly that release's migrations, applies every newer one, compares the result with `db/schema.rb`, reverses and reapplies this fork's two migrations, and boots the baseline release's code against the migrated database |
| `image` | After the three jobs pass: builds the production `Dockerfile` for linux/amd64, tags it `ghcr.io/<owner>/sure:<commit sha>`, smoke-tests it. Pushes **only** on a manual run with `publish: true` |

No Wise, Binance, Sure or other credentials are used; publishing uses the workflow's
own `GITHUB_TOKEN`. Actions must be enabled for the fork (Settings → Actions).
Upstream's `publish.yml` only runs for `main`, version tags and its schedule
(schedules are disabled in forks by default); it is left untouched. Opening a
PR inside the fork also runs `pr.yml` (the same `ci.yml`), so avoid PRs there
if the duplicate run matters.

## Image

| | |
|---|---|
| Registry / name | `ghcr.io/savytskyi/sure` |
| Tag | the full 40-character commit SHA (never `latest`/`stable`) |
| Pin | deploy by digest: `ghcr.io/savytskyi/sure:<sha>@sha256:<digest>` (printed by the publish step) |
| Architecture | `linux/amd64` (production runs on an x86_64 Docker VM) |
| Dockerfile | upstream `Dockerfile`, unchanged; `BUILD_COMMIT_SHA` build arg and OCI revision label set to the commit |
| Containers | one image for both `sure-web` (default command) and `sure-worker` (`bundle exec sidekiq`), exactly as today |

Configuration is unchanged: the same environment (`SECRET_KEY_BASE`, the three
`ACTIVE_RECORD_ENCRYPTION_*` keys, `DB_*`, `POSTGRES_*`, `REDIS_URL`, …), the
same `${APPDATA}/sure/storage` volume and the same `timescaledb` database.
Optional: `WISE_SYNC_OVERLAP_DAYS`, `WISE_SYNC_REFRESH_DAYS`,
`WISE_SYNC_REFRESH_INTERVAL_DAYS`, `WISE_DETAIL_REQUESTS_PER_SYNC`,
`WISE_LINK_OWN_PROFILE_TRANSFERS`.

A GHCR package created by a workflow can be private. If it is, log the
homelab in once with a token that has only `read:packages`:
`echo "$TOKEN" | docker login ghcr.io -u savytskyi --password-stdin`.

`bin/build-custom-image` builds the same image locally (tag `sure-custom:<sha>`)
— only on a machine other than the production Docker host.

## Database migrations from v0.7.5-hotfix.2

Production's schema is at `2026_09_29_120000`. This branch adds 17 migrations.
Three upstream ones are dated *before* that version but are not part of the
release, so `db:migrate` runs them too.

| Migration | Kind | Reversible | Effect |
|---|---|---|---|
| 20260927142423 FixKrakenTradeEntrySigns | **data** | **no** | flips the sign of Kraken trade entries recorded inverted (not user-modified) |
| 20260927200000 ResetKindsOfPendingTransferMatches | **data** | no-op down | sets `kind = standard` on transactions of *pending* (unconfirmed) transfer matches |
| 20260928100000 CreateSecuritySplits | schema | yes | new table |
| 20261003100000 …TreatBalanceAsAvailableCredit… (Lunchflow) | schema | yes | column, default false |
| 20261004120000 AddCategoriesLockedToFamilies | schema | yes | column, default false |
| 20261005120000 AddExtraContentToToolCalls | schema | yes | nullable column |
| 20261006140000 AddPositionAndStopProcessingToRules | schema + **data** | yes (drops columns) | columns + numbers existing rules by name |
| 20261006210000 AddPositiveRateCheckToExchangeRates | **data** + constraint | constraint only | **deletes** exchange rates ≤ 0, NaN or Infinity, then adds a CHECK |
| 20261006210001 ValidatePositiveRateCheck… | constraint | no-op down | validates the CHECK |
| 20261008090000 RescaleTradeRepublicBondHoldingPrices | **data** | **no** | divides Trade Republic bond holding prices quoted in percent by 100 |
| 20261008120000 AddTimelineCursorsToTradeRepublicItems | schema | yes | column, default `{}` |
| 20261011090000 AddChimnieSupportToProperties | schema + constraint | yes | column; widens a CHECK |
| 20261011151000 AddBalanceSignOverrideToSophtronAccounts | schema + constraint | yes | nullable column + CHECK |
| 20261013180000 AddDeviceIdToTradeRepublicItems | schema | yes | NOT NULL column with generated default |
| 20261015090000 AddSessionExpiresAtToTradeRepublicItems | schema | yes | nullable column |
| 20261019120000 AddWiseLedgerProvenance (this fork) | schema | yes | new table + nullable/defaulted columns |
| 20261019150000 CreateDerivativePositionsAndLedgerEvents (this fork) | schema | yes | two new tables (`derivative_positions`, `derivative_ledger_events`); touches no existing table |

**Old image against the migrated schema:** validated (in CI and locally):
every one of the v0.7.5-hotfix.2 release's 164 models loads against the
migrated database, no column the old code uses is removed or renamed, and
new NOT NULL columns all have defaults. So the previous image *runs* after
these migrations. Whether a rollback also needs the database depends on the
data migrations above; check on the restored copy (below) whether they touch
any rows:

```sql
SELECT 'kraken trades inverted', count(*) FROM entries e JOIN trades t ON t.id = e.entryable_id
  WHERE e.source = 'kraken' AND e.external_id LIKE 'kraken\_trade\_%' AND e.entryable_type = 'Trade'
    AND NOT e.user_modified AND e.amount <> 0 AND t.qty <> 0 AND sign(t.qty) <> sign(e.amount)
UNION ALL SELECT 'pending transfer kinds', count(*) FROM transactions
  WHERE kind IN ('funds_movement','cc_payment','loan_payment','investment_contribution')
    AND id IN (SELECT inflow_transaction_id FROM transfers WHERE status = 'pending'
               UNION SELECT outflow_transaction_id FROM transfers WHERE status = 'pending')
UNION ALL SELECT 'invalid exchange rates', count(*) FROM exchange_rates
  WHERE NOT (rate > 0 AND rate <> 'NaN'::numeric AND rate::text <> 'Infinity')
UNION ALL SELECT 'trade republic accounts', count(*) FROM trade_republic_accounts
UNION ALL SELECT 'rules', count(*) FROM rules;
```

All zero except rules → rolling back the image alone is enough (rule
ordering columns are simply ignored by the old code). Any Kraken or Trade
Republic rows → a faithful rollback needs the database backup.

### Testing the migrations on a restored copy

Never against production. On a machine other than the production Docker host
(or with a native Postgres, as used for this branch's validation):

1. Take a fresh backup: `~/homelab/backup-sure.sh` (pg_dump custom format +
   uploads) and copy `sure_production.dump` to the test machine.
2. Start an isolated Postgres 17 (production runs TimescaleDB on pg17) on a
   private port, and restore:
   `createdb -p 55432 sure_restore && pg_restore -p 55432 --no-owner --no-acl -d sure_restore sure_production.dump`.
3. Run the counts query above and record table row counts
   (`SELECT relname, n_live_tup FROM pg_stat_user_tables ORDER BY 1`).
4. With this branch checked out, the production encryption keys in the
   environment (from the homelab `.env`, never committed) and
   `DATABASE_URL=postgres://…:55432/sure_restore RAILS_ENV=production`:
   `bin/rails db:migrate:status` (expect the 17 pending above), then
   `bin/rails db:migrate`.
5. Re-run step 3 and compare; then `bin/rails runner 'puts Account.count, Entry.count'`.
6. Boot the old release against the migrated copy: `git worktree add ../sure-0.7.5 v0.7.5-hotfix.2`,
   then in it the model-loading check from the `migrations` CI job.
7. Optional: start the new image against the copy with
   `-e DATABASE_URL=…` and no Redis/worker, and open it on a private port.
8. Drop the copy (`dropdb -p 55432 sure_restore`) and delete the dump.

### Restored-copy validation (2026-10-19)

Backup `20261019-122758` (taken manually: the 03:30 launchd run failed with
`docker: command not found`, see below), restored into an isolated
PostgreSQL 17.11 on a private port on the Mac — not the Docker daemon:

* Checksums OK. `pg_restore` reports 30 errors, all TimescaleDB extension
  metadata (`_timescaledb_catalog`, `timescaledb`, `timescaledb_toolkit`),
  which Sure does not use; `pg_dump` warns about circular keys in
  `continuous_agg`, also TimescaleDB's own catalog.
* All 152 tables: row counts identical to live production.
* Counts query: all zero (no Kraken, Trade Republic, pending transfers,
  invalid rates, rules, or Binance futures fills). Production has **no**
  provider connections; 6 manual accounts, 284 entries.
* 17 pending migrations applied in under a second. Afterwards: only the
  four new empty tables and 17 `schema_migrations` rows differ; account
  balances (13,676.86 over 6 accounts), entries (284, sum 26,302.86) and
  net worth (−18,735.06 EUR) unchanged.
* `db:schema:dump` of the migrated copy equals `db/schema.rb` except the
  PostgreSQL-version formatting of one upstream Sophtron CHECK constraint.
* Both fork migrations reversed and reapplied cleanly.

### Backup job

`~/Library/LaunchAgents/com.ky.sure-backup.plist` runs `backup-sure.sh` with
launchd's minimal `PATH`, which does not contain `docker`
(`/usr/local/bin`), so the scheduled run fails and the last automatic
backup is 2026-10-18 11:08. Fix (not applied): add
`export PATH="/usr/local/bin:$HOME/.docker/bin:$PATH"` near the top of the
script, or an `EnvironmentVariables` → `PATH` key in the plist, then
`launchctl kickstart -k gui/$(id -u)/com.ky.sure-backup` and check
`~/homelab/sure-backup.log`.

## Deployment (not yet performed)

1. **Back up**: `~/homelab/backup-sure.sh`. Note the backup directory.
2. **Verify the backup restores**: steps 2–3 of the procedure above on the
   new dump (`pg_restore --list` alone only checks the archive).
3. **Stop Sure**: `docker compose -f ~/homelab/compose.yml stop sure-worker sure-web`.
4. **Pin the image**: in `~/homelab/compose.yml` set, for both `sure-web` and
   `sure-worker`, `image: ghcr.io/savytskyi/sure:<sha>@sha256:<digest>`
   (keep the old line commented for rollback). `docker compose pull sure-web`.
5. **Migrate**: `docker compose run --rm sure-web ./bin/rails db:migrate`
   (the web entrypoint would also run `db:prepare` on start; running it
   explicitly shows the output and stops on error).
6. **Start**: `docker compose up -d sure-web`, then `sure-worker`.
7. **Health**: `docker compose ps` (both healthy), `curl -fsS http://127.0.0.1:3030/up`,
   `docker logs --since 5m sure-web | grep -i -E "error|fatal"`,
   `docker exec sure-web bin/rails runner 'puts Account.count, Entry.count, Account.sum(:balance)'`
   (expect the values recorded before step 3).
8. **First Wise sync, manually**: pause automatic syncing (Settings → turn
   off auto-sync, or keep the worker stopped until step 9 is done and run
   the sync from a console), then trigger it per Wise connection and watch
   `docker exec sure-web bin/rails wise:coverage`. A full backfill takes
   several syncs (`WISE_DETAIL_REQUESTS_PER_SYNC`); repeat until coverage
   shows activities checkpoints for every profile.
9. **Validate and clean up**: `wise:coverage`, `wise:review`,
   `wise:reconcile` (Wise balance vs imported ledger per account),
   `wise:closed_balances`, and
   `wise:legacy_report OUT=/rails/storage/wise-legacy.csv`. Until the legacy
   entries are reviewed, spending is **double counted** (on the live data:
   696 batch members and 157 duplicates on top of the reconstructed legs,
   plus 151 cancelled transfers the old connector booked). Review the CSV,
   run `wise:legacy_exclude FAMILY_ID=<id>` (dry run), then with
   `CONFIRM=yes`, and check `wise:reconcile` again. Resolve or dismiss what
   `wise:review` lists (mainly jar moves into closed jars).
10. **Binance (only when a connection is added or exists)**: create the key
    with Enable Reading only, after the futures accounts were opened. Connect
    it with auto-sync still off, run one sync, then
    `docker exec sure-web bin/rails binance:futures`: every futures market
    should be read (not STALE), the key flags should show no permission
    beyond reading, and Binance's wallet valuation should match the
    imported sources. `binance:legacy_futures_trades` reports fills an older
    version recorded as spot trades (none today). Income backfill completes
    over a few syncs (`backfill_complete=true` per market).
11. **Enable automatic syncing** again.

## Rollback

* **Application only** (no Kraken/Trade Republic data affected, see the
  counts query): stop both containers, restore the previous `image:` lines
  (`ghcr.io/we-promise/sure:stable` pinned to its digest
  `sha256:aa46be2d8e3f…`, see `docker image inspect`), `up -d`. The old
  code runs on the migrated schema and finds every entry it created under
  its original id; entries the new sync added (card payments, incoming
  payments, …) stay as they are, and excluded legacy entries stay
  excluded. For Binance, the old code ignores the two derivative tables
  and the `binance_derivatives_*` entries (zero-amount trades) stay; it
  would resume reading only USDⓈ-M, recording new futures fills as spot
  trades and writing one holding per wallet.
* **Application and database** (data migrations touched rows, or a clean
  state is wanted): stop both containers, then
  `docker exec -i timescaledb pg_restore -U postgres --clean --if-exists -d sure_production < <backup>/sure_production.dump`,
  restore uploads if needed (`tar -xzf <backup>/sure_uploads.tar.gz -C ~/homelab`),
  restore the previous `image:` lines and start. Everything synced after the
  backup is lost and re-synced by the old connector.
* Keep the custom image and the backup until the new version has run
  cleanly for at least a week.

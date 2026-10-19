# Custom Wise integration (fork notes)

This fork improves Sure's native Wise sync for profiles whose personal API
token cannot read balance statements (Wise allows statements to personal
tokens only for US/CA/AU/NZ/SG/MY profiles). The approach and its rules are
ported to Ruby from the homelab `financial-data` project
(`providers/wise/provisional.py`, `provisional_transfers.py`,
`services/merchants.py`). No Python runtime or new gem is involved.

Branch: `feature/wise-sync-improvements` (based on upstream `main`).

## What was wrong before

| Problem | Effect |
|---|---|
| The activity feed was paged with a `cursor` query parameter; Wise expects `nextCursor`. A repeated cursor stopped the loop after the first page. | Only the newest ~100 activities were ever read. |
| Only jar activity types (`INTERBALANCE`, `BALANCE_CASHBACK`, `BALANCE_ASSET_FEE`) were kept. | Card payments, ATM withdrawals, incoming payments, deposits and batch payments were dropped when statements were unavailable. |
| The statement fallback was `GET /v1/transfers`, routed to balances by currency alone (`sourceCurrency` or `targetCurrency` equal to the balance currency). | Card payments and third-party incoming payments never appear there; a cross-currency transfer could be booked on two balances; direction relied on the deprecated borderless-accounts recipient id. |
| Every `INTERBALANCE` activity was booked as an outflow on **every** STANDARD balance. | A EUR→USD conversion appeared as an outflow on the GBP balance too, and conversions were never linked as transfers. |
| No merchants were created. | Card spending had no merchant. |
| The Wise balance only updated the cached `accounts.balance`. | No current-balance anchor; history was back-calculated from a cached value. |
| `DataEnrichment` had no `wise` source. | Any Wise sync that changed the name, category or merchant of an existing entry raised `'wise' is not a valid source`. |

## Endpoints

All requests are `GET` (`Provider::Wise#get` is the only request method).

| Endpoint | Before | Now |
|---|---|---|
| `GET /v1/profiles`, `/v1/me` | ✓ | ✓ (connection setup) |
| `GET /v4/profiles/{pid}/balances?types=STANDARD` / `SAVINGS` | ✓ | ✓, plus `creationTime` (opened date) and `cashAmount` |
| `GET /v1/borderless-accounts` | ✓ | ✓ (legacy only) |
| `GET /v1/profiles/{pid}/balance-statements/{bid}/statement.json` (SCA) | ✓ | ✓, per-balance checkpoint; a refusal is recorded once and retried weekly |
| `GET /v1/profiles/{pid}/activities` | first page, jar types only | all pages (`nextCursor`), `since`/`until` window, all types |
| `GET /v1/transfers` | fallback, all history, currency-routed | `createdDateStart`/`End` window, reference data only |
| `GET /v3/profiles/{pid}/quotes/{quoteUuid}` | – | fee per pay-in method, `payInId` (funding balance); once per transfer |
| `GET /v2/accounts/{id}` | – | recipient name, `ownedByCustomer`, Wise-balance `targetProfile` / `balanceId`; once per recipient |
| Card / card-transaction endpoints | – | not used: user-token (OAuth) only, 90 days |

## How it works

```
WiseItem::Importer (per profile, per sync)
  balances ──────────────▶ WiseAccount (active / closed / discovered, opened_at, closed_at)
  statements ────────────▶ wise_accounts.raw_transactions_payload ──▶ WiseStatement::Processor (verified)
  activities ─┬─ jar moves, jar interest/fees ──▶ payload ──▶ WiseActivity::Processor
              └─ everything else ─▶ WiseItem::LedgerCollector
                                     transfers + quotes + recipients (cached, read once)
                                     WiseItem::LedgerReconstructor (rules, provenance)
                                     ▶ provider_ledger_records
WiseItem#process_ledger_records
  WiseItem::LedgerLinker#annotate!     relationships across all family Wise profiles
  WiseItem::LedgerProcessor            ▶ ProviderLedgerRecord::Importer ▶ Account::ProviderImportAdapter
  WiseItem::LedgerLinker#link_transfers! ▶ Transfer::ProviderLinker
```

Generic, provider-independent pieces (reusable for Kraken, Binance, IBKR):
`ProviderLedgerRecord` (+ `::Importer`), `Transfer::ProviderLinker`,
`Merchant::NameNormalizer` (+ `config/merchant_aliases.yml`),
`Merchant::FamilyResolver`. Wise-specific parsing stays in `WiseItem::*`,
`WiseActivity::Text` and `Provider::Wise`.

### Provenance

Every reconstructed leg is a `provider_ledger_records` row with an overall
provenance and field-level provenance (`amount`, `currency`,
`source_balance` / `destination_balance`, `fee`):

| Provenance | Meaning | Imported? |
|---|---|---|
| `provider_explicit` | Wise states the balance impact **and** the balance (quote `payInId`, recipient `balanceId`) | yes |
| `inferred` | amounts stated; balance = the single STANDARD balance of that currency that existed at the time, or a batch total summed from members | yes |
| `unresolved` | missing or contradictory data | **no**, `needs_review` |

The overall provenance is never stronger than its weakest essential field.
Statement lines are `provider_explicit`; jar activities are `inferred`. The
provenance is copied to `transactions.extra["wise"]` (`provenance`,
`field_provenance`, `provenance_reason`).

Record statuses: `ready`, `imported`, `needs_review`, `excluded` (pending,
declined, card checks, transfer orders, non-balance pay-ins), `superseded`
(a verified statement line covers it), `withdrawn` (reversed after import:
the entry is excluded, not deleted), `dismissed` (the user deleted the
entry; never recreated).

### Rules (from financial-data)

* **Card payments / ATM**: `secondaryAmount` is the actual debit when the
  charged currency differs (amount `provider_explicit`); otherwise the
  purchase amount is the debit (amount `inferred`). The balance is the single
  eligible STANDARD balance of that currency **at the activity time**
  (`opened_at ≤ t ≤ closed_at`; discovered balances within their observed
  usage window). Jars are never eligible. Zero or several → unresolved. A
  currency list (`"EUR, USD"`, split-balance payment) → unresolved. No FX
  rate is ever guessed. Pending (`IN_PROGRESS`) and declined/cancelled
  payments are never imported; pending ones are re-read until they complete.
* **Incoming payments / deposits**: credited amount from the activity,
  checked against the transfer order's `targetValue` when known. Balance from
  the recipient's `balanceId` when stated, else inferred. Sender name and
  payment reference are kept. Nothing is categorized as salary.
* **Outgoing payments**: funding balance from the quote's `payInId`
  (never overridden by inference). Total from the activity; fee confirmed by
  the quote, or derived and marked inferred; a contradiction → unresolved.
  Transfers funded outside Wise (`payInMethod` ≠ `BALANCE`) are excluded.
  A known fee is imported as its own "Wise fee" entry.
* **Conversions**: one activity → source and target legs with the stated
  amounts, linked as a confirmed Sure transfer (`funds_movement`, so neither
  income nor expense). The effective rate is recorded; no fee is invented.
* **Batch payments**: the batch activity is the single debit. Member
  transfers (matched by creation time ±15 min; Wise exposes no batch id) are
  reference records and never ledger legs. A refunded member makes the batch
  unresolved. Multi-currency batches get one inferred leg per currency.
* **Own-profile payments**: the same Wise transfer id debited in one own
  profile and credited in another is `business_to_personal` /
  `personal_to_business` (confirmed), including salary paid from batch
  members. These stay income and expense by default; set
  `WISE_LINK_OWN_PROFILE_TRANSFERS=true` to link them as transfers. Same-
  profile movements are linked. Payments to accounts Wise marks as the
  customer's own are flagged `own_account_transfer` (unmatched); no
  destination leg is invented.
* **Refunds**: a card refund is related to the latest earlier purchase at the
  same merchant within 180 days (full/partial; ambiguous when several).

### Merchants

Card merchants are normalized with `config/merchant_aliases.yml` (exact
aliases, then regex rules, then cleanup of processor prefixes, store numbers
and ALL CAPS): `LIDL 1234 MARIBOR` → Lidl, `SPOTIFY AB STOCKHOLM` → Spotify,
`AMZN MKTP DE` → Amazon. Existing family merchants are matched first by a
key that ignores case, accents, punctuation and whitespace; only then is a
`FamilyMerchant` created. The merchant a raw name resolved to is remembered,
so renaming the merchant does not create a new one. The entry name keeps the
original Wise description; `extra.wise.merchant_raw` keeps it too. A
merchant, category, name or note the user changed is never overwritten
(`Account::ProviderImportAdapter` locks).

### Deduplication

Before importing a leg, in order:
1. the leg's own external id (`wise_activity_<id>[_source|_target|_<CCY>]`);
2. entries earlier Wise code created for the same movement are claimed
   (`wise_transfer_<id>`, `wise_fee_<id>`, `wise_interbalance_<id>_outflow`);
3. a verified statement line (`wise_statement_<CARD|TRANSFER|BALANCE>-<id>`)
   wins: the leg is `superseded`;
4. manual, CSV or YNAB entries (no external id) on the same account with the
   same amount and currency within ±3 days: exactly one on the same day is
   claimed; anything else → `needs_review` (`possible_duplicate`, candidate
   entry ids recorded).

An entry the user deleted is remembered (`dismissed`) and not recreated.

### Balances and reconciliation

The Wise balance snapshot (`cashAmount`, falling back to `amount`; jars use
`totalWorth`) is recorded with `Account#set_current_balance`: a
`current_anchor` valuation for the snapshot date. Previous days' anchors
become reconciliation points. Valuations are not income or expense, so a gap
between reconstructed history and the reported balance is never filled with
invented transactions. Closed balances keep their last balance and history.

**Limitations**: without statements there is no verified running balance,
so historical balances before the first anchor are back-calculated from
reconstructed (and partly unresolved) legs and can be wrong. Historical
reconciliation is `UNKNOWN`, not complete: `bin/rails wise:reconcile` shows
the Wise balance against the net imported transactions per account.

### Incremental sync

* Checkpoints in `wise_items.sync_checkpoints`: `activities`
  (`covered_from`, `covered_to`), `statements` per balance id
  (`ok`/`unavailable`, coverage), `transfer_details`.
* First sync: `sync_start_date`, or full history when "import all history"
  is on, else 365 days. Later syncs start at `covered_to −
  WISE_SYNC_OVERLAP_DAYS` (default 14). A manual sync with a window start
  re-reads from that date.
* The activity checkpoint advances only after every activity page, the
  transfer list and the transfer details were read. A failed statement for
  one balance does not affect others.
* All writes are upserts by stable key; re-running a window changes nothing.

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `WISE_SYNC_OVERLAP_DAYS` | `14` | days re-read before the last checkpoint |
| `WISE_LINK_OWN_PROFILE_TRANSFERS` | `false` | link business ↔ personal payments as transfers |
| `WISE_BASE_URL` | `https://api.wise.com` | unchanged |

## Operator tasks

```sh
bin/rails wise:coverage                 # exact / inferred / unresolved legs per balance, checkpoints
bin/rails wise:review LIMIT=100         # legs waiting for review
bin/rails wise:dismiss RECORD_ID=<uuid> # never import one leg
bin/rails wise:reconcile                # Wise balance vs imported ledger, per account
bin/rails wise:legacy_entries           # old fallback/conversion entries no leg claimed
```

In Docker: `docker exec sure-web bin/rails wise:coverage`.

### Existing data from the old sync

Entries the old code created stay. Reconstructed legs claim the ones that
describe the same movement. Entries the old code booked on the wrong balance
(a conversion as an outflow on every balance, a transfer on both currency
balances) are not deleted automatically; `wise:legacy_entries` lists the
candidates for manual cleanup.

## Files

New (low conflict risk):
`app/models/provider_ledger_record.rb`, `app/models/provider_ledger_record/importer.rb`,
`app/models/transfer/provider_linker.rb`, `app/models/merchant/name_normalizer.rb`,
`app/models/merchant/family_resolver.rb`, `app/models/wise_activity/text.rb`,
`app/models/wise_item/{balance_registry,ledger_reconstructor,ledger_collector,ledger_processor,ledger_linker}.rb`,
`config/merchant_aliases.yml`, `db/migrate/20261019120000_add_wise_ledger_provenance.rb`,
`lib/tasks/wise.rake`, `bin/build-custom-image`, this document, and tests.

Changed upstream files (where merge conflicts can occur):
`app/models/provider/wise.rb`, `app/models/wise_item.rb`,
`app/models/wise_item/importer.rb` (largest change), `app/models/wise_item/syncer.rb`,
`app/models/wise_account.rb`, `app/models/wise_account/processor.rb`,
`app/models/wise_account/transactions/processor.rb`,
`app/models/wise_statement/processor.rb`, `app/models/wise_activity/processor.rb`,
`app/models/data_enrichment.rb` (one line), `config/initializers/wise.rb`,
`config/locales/views/wise_items/en.yml`, `db/schema.rb`,
`test/models/wise_item/importer_test.rb`, `test/models/provider/wise_test.rb`.

## Pulling upstream

`origin` is the fork (`savytskyi/sure`), `upstream` is `we-promise/sure`.

```sh
git fetch upstream
git switch main && git merge --ff-only upstream/main && git push origin main
git switch feature/wise-sync-improvements
git merge main            # merge, not rebase: no history rewrite, no force-push
bin/rails test test/models/wise* test/models/wise*/ test/models/provider_ledger_record test/models/merchant
```

Likely conflicts and how to resolve them:

* `db/schema.rb`: take upstream's version, then regenerate by running
  migrations on a scratch database (never production) and dumping; or keep
  upstream's file and re-add the `provider_ledger_records` table and the new
  `wise_items` / `wise_accounts` columns by hand. The schema version is the
  newest migration timestamp.
* `wise_item/importer.rb`: upstream Wise fixes usually touch the statement or
  balance paths, which are kept nearly verbatim here; apply them to the same
  methods. The transfer fallback (`fetch_transfers`,
  `legacy_transfer_import_needed?`) is intentionally gone.
* `data_enrichment.rb`, `provider/wise.rb`, locale files: additive; keep both
  sides.
* If upstream adds a migration with a later timestamp touching the same
  tables, keep both; ours is additive only.

## Build, deploy, roll back

Production (`~/homelab/compose.yml`) runs `ghcr.io/we-promise/sure:stable`
for `sure-web` and `sure-worker`, with PostgreSQL in `timescaledb` and
uploads in `${APPDATA}/sure/storage`. The custom image keeps the same
entrypoint, environment variables, volumes and database.

**Version jump.** Production is `v0.7.5-hotfix.2`. This branch is based on
upstream `main` (0.7.6 pre-release), which adds 15 upstream migrations,
some of them data migrations (Kraken trade signs, pending transfer kinds,
invalid exchange rates, Trade Republic bond prices). Either accept that
upgrade, or build from a branch created at the release tag with these
commits cherry-picked (`git switch -c wise-on-release v0.7.5-hotfix.2 && git cherry-pick <commits>`).

1. **Back up** (database + uploads): `~/homelab/backup-sure.sh`.
2. **Build**: `bin/build-custom-image` → `sure-custom:<sha>` (refuses a dirty tree).
3. **Deploy**: in `~/homelab/compose.yml` set `image: sure-custom:<sha>` for
   both `sure-web` and `sure-worker`, then
   `docker compose -f ~/homelab/compose.yml up -d sure-web sure-worker`.
   `sure-web` runs `bin/rails db:prepare` on start, which applies pending
   migrations (ours is additive: one new table, new nullable/defaulted columns).
4. **Verify**: `docker logs sure-web`, `curl -fsS http://127.0.0.1:3030/up`,
   then run a Wise sync and `docker exec sure-web bin/rails wise:coverage`.
5. **Roll back**: set the previous image tag again and `up -d`. Our
   migration is additive, so the old image starts against the new schema.
   But once a Wise sync has run on the new version, the old code would
   re-import its legacy transfer rows under their old ids (the new legs
   renamed those entries), creating duplicates. So for a clean rollback,
   stop `sure-web`/`sure-worker` and restore the backup from step 1
   (`pg_restore --clean --if-exists -d sure_production`) before starting
   the old image; the same applies if upstream data migrations ran. Keep
   previous `sure-custom:*` images until a deploy has proven itself.

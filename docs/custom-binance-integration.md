# Custom Binance futures integration (fork notes)

This fork extends Sure's native Binance sync from Spot, Margin, Simple Earn
and part of USDⓈ-M futures to complete **USDⓈ-M and COIN-M futures**:
balances by meaning, positions, and wallet income history. It uses only
Binance's official read-only (`USER_DATA` GET) and public endpoints, places
no orders and needs no new gem. Kraken and the spot/P2P import are unchanged.

Branch: `feature/wise-sync-improvements` (same fork branch as the Wise work).

## What was wrong before

| Problem | Effect |
|---|---|
| COIN-M futures (`dapi.binance.com`) were never read. | BTC (or any coin) posted as COIN-M collateral was missing from the account and from net worth. |
| USDⓈ-M fills (`/fapi/v1/userTrades`) were imported as spot **buys and sells of the base coin**, with the fill's notional as the cash amount. | A BTCUSDT perpetual long added BTC to every earlier holding in the reverse walk and moved cash by money that never left the account. History and cost basis were wrong; the current balance was not (it comes from the wallet). |
| A coin held in two wallets (Spot BTC and COIN-M BTC, Spot and Earn) was imported as two holdings of the same security and day. Sure keeps one, so the second overwrote the first. | Holdings showed only part of the coin; the difference appeared as "cash". |
| Wallet, equity, available margin, unrealized P&L and notional were not kept apart; positions, funding, realized P&L and fees were not recorded. | Only one number per futures asset was visible. |
| 418 (IP ban) was a generic error; `-2015` was not recognised as a permission problem. | No `Retry-After`, no actionable message. |

## Endpoints

All signed requests are GETs that need only **Enable Reading**.

| Endpoint | Host | Weight | Used for |
|---|---|---|---|
| `/fapi/v3/account` (fallback `/fapi/v2/account`) | fapi | 5 | USDⓈ-M wallet per asset |
| `/fapi/v3/positionRisk` | fapi | 5 | USDⓈ-M positions: entry, break-even, mark, liquidation, notional |
| `/fapi/v1/income` | fapi | 30 | USDⓈ-M income; Binance keeps **3 months** |
| `/dapi/v1/account` | dapi | 5 | COIN-M wallet per margin coin |
| `/dapi/v1/positionRisk` | dapi | 1 | COIN-M positions (contracts, coin notional) |
| `/dapi/v1/income` | dapi | 20 | COIN-M income incl. `DELIVERED_SETTELMENT` (sic); one request ≤ 1 year |
| `/dapi/v1/exchangeInfo` (public) | dapi | 1 | contract size (multiplier), contract type, margin asset |
| `/sapi/v1/account/apiRestrictions` | api | 1 | what the key may do (checked, reported) |
| `/sapi/v1/asset/wallet/balance` | api | 60 | Binance's own per-wallet valuation, for reconciliation only |

Fills (`userTrades`) are no longer requested: their effect on the wallet
arrives as `REALIZED_PNL` and `COMMISSION` income.

### API key permissions

Create the key with **Enable Reading only** — no trading, futures trading
("Enable Futures"), margin, withdrawals, internal or universal transfer.
Binance documents `enableFutures` only as a flag of
`apiRestrictions`, not what it gates; it is not needed for the reads above.
Two Binance behaviours to know:

* A key created **before** the futures account was opened cannot read
  futures; Binance answers `-2015 Invalid API-key, IP, or permissions for
  action`. Create the key after opening USDⓈ-M/COIN-M futures.
* `-2015` is also the answer for an IP missing from the key's allow list.
* Portfolio Margin accounts are served by `papi`, not `fapi`/`dapi`, and are
  not supported (see Limitations).

`bin/rails binance:futures` prints the key's flags and warns when the key can
do more than read.

## How it works

### Balances: four figures, one quantity

For every futures margin asset (USDT, USDC, BNB, … on USDⓈ-M; BTC, ETH, … on
COIN-M) the sync keeps, in `binance_accounts.raw_payload["futures_summary"]`:

| Figure | Meaning |
|---|---|
| `wallet_balance` | transfers in/out + realized P&L + funding + fees |
| `margin_balance` (equity) | `wallet_balance + unrealized P&L` |
| `available_balance` | usable for new margin or to move out |
| `unrealized_pnl` | the open positions' paper result, in the margin asset |
| `notional` per currency | exposure of the open positions |

The **quantity** of the asset on the combined Sure account is the **equity**.
COIN-M figures stay in the coin: 0.86512097 BTC of equity is valued as BTC,
never as dollars. A position's notional is **never** added: everything a
position is worth to its owner is its unrealized P&L, which equity already
contains. So collateral and exposure are not double counted, and a BTC
holder with a short COIN-M hedge sees the hedge's effect through the BTC
equity.

Holdings are one per coin, summed across wallets; the external id lists the
wallets (`binance_BTC_spot+coin_futures_<date>`; a coin in one wallet keeps
its old id).

### Positions

`derivative_positions` (provider-independent) holds one row per **episode**:

* updated while Binance keeps reporting it (size, mark, P&L, …);
* `closed` the first time a **complete** position report no longer has it;
* a reopen, or a one-way position flipping long↔short, is a new row;
* hedge-mode LONG and SHORT are separate episodes;
* a failed position read is unknown, not empty — nothing is closed.

USDⓈ-M quantity is in the base asset (`quantity_unit = base`); COIN-M is in
contracts with `contract_size` (100 USD for BTC, 10 for most others) from
exchangeInfo. Prices are in the quote (USDT/USDC or USD), notional and P&L
in the margin asset.

### Income → ledger

`/fapi/v1/income` and `/dapi/v1/income` rows become
`derivative_ledger_events` (provider-independent, 18-decimal amounts):

| incomeType | category | ledger |
|---|---|---|
| `REALIZED_PNL` | realized_pnl | imported (label Other) |
| `FUNDING_FEE` | funding | imported (Interest) |
| `COMMISSION`, `OPTIONS_PREMIUM_FEE`, `POSITION_LIMIT_INCREASE_FEE` | commission | imported (Fee) |
| `COMMISSION_REBATE`, `API_REBATE`, `REFERRAL_KICKBACK`, `FEE_RETURN` | rebate | imported (Fee, positive) |
| `DELIVERED_SETTELMENT`, `OPTIONS_SETTLE_PROFIT` | settlement | imported (Other) |
| `INSURANCE_CLEAR` | liquidation | imported (Fee) |
| `AUTO_EXCHANGE` | conversion | imported (Exchange), both assets |
| `WELCOME_BONUS`, `CONTEST_REWARD`, `BFUSD_REWARD` | bonus | imported (Other) |
| `TRANSFER`, `INTERNAL_TRANSFER`, `CROSS_COLLATERAL_TRANSFER`, `STRATEGY_UMFUTURES_TRANSFER` | transfer | **excluded** |
| anything else | unknown | **needs review**, not imported |

Transfers are excluded because both wallets (Spot/Funding and futures) belong
to the same Sure account: the move changes nothing there. Unrealized P&L is
never an event.

`DerivativeLedgerEvent::EntryWriter` sums a day's events per market,
category and asset into **one entry**: a Trade with **amount 0** and the
summed quantity of the asset (`COIN-M funding +0.00000119 BTC on
BTCUSD_PERP`), priced at the day's close for reference. This is the shape
Kraken uses for coin movements: futures change how many coins the wallet
holds, not cash. `Holding::ReverseCalculator` undoes the quantities, so the
coin's history reflects P&L, funding and fees; `Balance::BaseCalculator`,
the income statement and contribution figures see zero cash, so nothing is
reported as cash income. Days are recomputed in place on every sync; an
entry the user edited keeps their edits, a deleted day is never recreated
(also when more events for it arrive), a day that nets to zero has no entry.
Only days with a new event are touched, plus days saved without a price:
the price is the cost basis of the coins received, so those are re-priced
as soon as a price is found.

### Identity and idempotency

* Event key: `market:incomeType:tranId:symbol:asset`. Binance states tranId
  is unique per incomeType; a realized P&L and its commission share one, and
  both are kept. Unique index per connection.
* Entry key: `binance_derivatives_<market>_<category>_<asset>_<date>`
  (never matches the legacy `binance_futures_<pair>_<id>`).
* Position episode: one open row per (connection, market, symbol, side),
  enforced by a partial unique index.

### Incremental sync and backfill

Per market, in `binance_accounts.extra["binance"]["futures_income"]`:
`started_from_ms`, `covered_to_ms`, `backfill_complete`, `stopped`, `error`,
`retry_after`.

* First sync: from `sync_start_date`, clamped to what Binance serves
  (USDⓈ-M 90 days, COIN-M 365 days), in 30-day windows.
* Later syncs: from `covered_to − 1 day` (late rows), deduplicated by key.
* A window returning a full page (1000) is split in half and both halves are
  read — no reliance on sort order or millisecond uniqueness.
* The checkpoint only advances past windows read in full.
* A run stops after 40 requests per market, when `X-MBX-USED-WEIGHT-1M`
  passes 1800 (of 2400), on 429/418 (keeping `Retry-After`), on a permission
  error or any API error; a `DebugLogEntry` records it and the next sync
  resumes from the checkpoint. Spot history is never blocked by futures.
* After a 429/418 the market is not asked again until `Retry-After` (60 s
  when Binance gives none) has passed, so an IP ban is not extended.
* Any failure in one market (Binance error, timeout, reset connection) stops
  only that market; the other market and the ledger writer still run.
* A window older than 90 days that Binance refuses (COIN-M retention is not
  documented) is skipped and listed in `unavailable_windows` instead of
  pinning the backfill to it forever; a refusal of a recent window stops the
  read and is retried next sync.
* A market is only asked for income when its wallet answered in the same
  sync.

## Limitations

* **History depth**: USDⓈ-M income is 3 months at Binance; COIN-M is not
  stated (requests are capped at a year). Older history needs Binance's
  asynchronous export (`/fapi/v1/income/asyn`), not implemented.
* **Funding wallet** and other wallets (Options, Trading Bots, Copy Trading)
  are not imported; `binance:futures` prints Binance's valuation of every
  wallet next to what was imported so a gap is visible.
* **Portfolio Margin** (`papi`) accounts are not supported.
* **Spot deposits/withdrawals** are still not imported (unchanged), so the
  reverse walk carries today's coins back past them.
* Positions are not shown in the UI yet (data is in `derivative_positions`;
  `binance:positions` lists them). No API endpoint yet for Hermes.
* Historical unrealized P&L cannot be reconstructed; history reflects
  realized events only.

## Operator tasks

```sh
bin/rails binance:futures                 # balances, positions, coverage, key flags, wallet valuation
bin/rails binance:positions [ALL=1]       # open (or all) position episodes
bin/rails binance:legacy_futures_trades   # fills earlier versions recorded as spot trades (dry run)
bin/rails binance:legacy_futures_trades FAMILY_ID=<id> OUT=/rails/storage/binance-legacy.csv CONFIRM=yes
```

The legacy task deletes (excluded trades would still count in holdings),
skips rows the user edited, requires `OUT` and writes every row first.
Production had no Binance connection at the time of writing, so it has
nothing to clean up.

## Files

| File | Role |
|---|---|
| `app/models/provider/binance.rb` | endpoints, rate limits, permission errors, used weight |
| `app/models/binance_item/futures_wallet.rb` | shared wallet/position normalization |
| `app/models/binance_item/futures_importer.rb` | USDⓈ-M balances + positions |
| `app/models/binance_item/coin_futures_importer.rb` | COIN-M balances + positions + contract size |
| `app/models/binance_item/importer.rb` | orchestration, futures summary, position reconciliation |
| `app/models/binance_account/holdings_processor.rb` | one holding per coin across wallets |
| `app/models/binance_account/futures_income_importer.rb` | incremental income read |
| `app/models/binance_account/processor.rb` | no fills; income → entries |
| `app/models/derivative_position.rb` | provider-independent position episodes |
| `app/models/derivative_ledger_event.rb`, `…/entry_writer.rb` | provider-independent events and their ledger entries |
| `db/migrate/20261019150000_create_derivative_positions_and_ledger_events.rb` | the two tables |
| `lib/tasks/binance.rake` | operator tasks |

## Validation

Targeted suites (437 tests: all Binance, Kraken, derivatives, provider
panels, sync events, investment statement) pass on an isolated PostgreSQL;
the full suite, system tests and image build run in CI (see
[custom-deployment.md](custom-deployment.md)). Fixtures under
`test/fixtures/files/binance_futures/` are anonymized and self-consistent
(300 BTCUSD_PERP contracts × 100 USD, 64,000 → 62,000: notional 0.48387097
BTC, unrealized P&L 0.01512097 BTC). The migration was applied to a restored
copy of production, compared with `db/schema.rb`, reversed and reapplied.
Not yet validated against a live Binance account.

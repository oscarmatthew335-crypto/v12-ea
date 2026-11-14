# V12 Expert Advisor (MQL5 Port of `V12_STRAT.pine`)

Exact MQL5 port of `V12_STRAT.pine` (Dickey-Fuller climax breakout/retest + reversal strategy) for trading Gold (`XAUUSD` / `XAUUSDm`) on H1 in MetaTrader 5 (tested on Exness MT5).

---

## 1. Repository Files & Architecture

| File | Purpose |
| --- | --- |
| [`V12_Indicators.mqh`](V12_Indicators.mqh) | Pure Pine-equivalent indicator math (`ATR` via Wilder's RMA with SMA seed, `EMA` with SMA seed, `Highest`/`Lowest`, non-drifting rolling Dickey-Fuller `t_stat`, strictly-greater percentile rank `t_pct`, `df_hook`), shared 9-step closed-bar state machine `V12_StepBar`, and intrabar exit simulator `V12_SimulateIntrabarExit`. |
| [`V12_EA.mq5`](V12_EA.mq5) | Live/Strategy Tester Expert Advisor: replays `V12_REPLAY_BARS = 3200` closed H1 bars in `OnInit`, reconciles active broker positions (`L`, `S`, `RL`, `RS` via `magic`), executes strictly once per closed H1 bar with session-open/market-closed retry handling, rebuilds state from history when disconnected across missed H1 bars (`iBarShift > 1`) with Telegram alerts, enforces `max_loss_usd` and the persistent `halt_dd_R` kill switch, sends Telegram `WebRequest` alerts, and exports deals to `Common\Files\V12_Tester_Trades.csv` in Strategy Tester `OnDeinit`. |
| [`V12_Debug.mq5`](V12_Debug.mq5) | Self-contained indicator unit tests + CSV bar-by-bar exporter (`time,open,high,low,close,atr,ema,range_hi,range_lo,t_stat,t_pct,df_hook,lvl_up,lvl_dn,signal`), supporting both live chart H1 history (`inp_use_csv_input=false`) and deterministic CSV OHLC input (`inp_use_csv_input=true`). |
| [`V12_STRAT.pine`](V12_STRAT.pine) | Pine Script v5 strategy source of truth. |
| [`V12_EA_cline_brief.md`](V12_EA_cline_brief.md) | Port specification and acceptance criteria. |

### Explicit Scope Exclusions
Per `V12_EA_cline_brief.md`, the following Pine options are intentionally omitted:
- Fixed R trend target (Trend trades trail stop-only via `stop_px` and close on stop).
- One-step lock (`once_per_bar` / step lock flags).
- Break entry mode (`Retest` only).
- Trading Sessions filter (trade whenever broker session is open).
- Reversal Target keeps `Trend EMA` with Fixed R (`rev_rr = 1.5`) fallback when EMA is not on the profit side of close.

---

## 2. Installation & Compilation

1. Copy [`V12_Indicators.mqh`](V12_Indicators.mqh) and [`V12_EA.mq5`](V12_EA.mq5) to `<MT5_Data_Folder>\MQL5\Experts\`.
2. Copy [`V12_Indicators.mqh`](V12_Indicators.mqh) and [`V12_Debug.mq5`](V12_Debug.mq5) to `<MT5_Data_Folder>\MQL5\Scripts\`.
3. Open MetaEditor (or use CLI `MetaEditor64.exe /compile:... /log`) and compile both `V12_EA.mq5` and `V12_Debug.mq5`.
   - Verified result: **0 errors, 0 warnings** for both files.

---

## 3. Input Parameters

### Strategy Inputs (`V12_EA.mq5`, matching `V12_STRAT.pine`)

| Group | Input Name | Type | Default | Description |
| --- | --- | --- | --- | --- |
| Stop loss (trend trades) | `trail_len` | `int` | `10` | Trailing stop: lowest low / highest high of last N closed bars |
| Stop loss (trend trades) | `sl_atr` | `double` | `2.0` | Initial trend stop distance (`x ATR`) |
| Stop loss (trend trades) | `atr_len` | `int` | `14` | Wilder RMA ATR length (SMA-seeded, not `iATR`) |
| Breakout | `bo_len` | `int` | `20` | Breakout channel lookback (`range_hi[1]` / `range_lo[1]`) |
| Breakout | `retest_win` | `int` | `10` | Maximum bars after breakout to trigger a retest |
| Breakout | `retest_tol` | `double` | `0.25` | Retest proximity tolerance & failure threshold (`x ATR`) |
| Trend filter | `use_trend` | `bool` | `true` | Require `close > ema` for longs and `close < ema` for shorts |
| Trend filter | `ema_len` | `int` | `200` | EMA length (SMA-seeded) |
| DF climax filter | `df_mode` | `ENUM_DF_MODE` | `DF_BOTH` | `DF_OFF` (0), `DF_SKIP` (1), `DF_EXIT` (2), `DF_BOTH` (3) |
| DF climax filter | `hook_lb` | `int` | `10` | Cooldown bars after a DF hook during which new trend entries are skipped |
| DF climax filter | `df_len` | `int` | `100` | Rolling Dickey-Fuller OLS regression window |
| DF climax filter | `df_tol` | `double` | `0.07` | Flatness / negative step threshold (`t_stat - t_stat[1] < -df_tol`) |
| DF climax filter | `norm_len` | `int` | `200` | Percentile rank lookback |
| DF climax filter | `pct_cut` | `double` | `85.0` | Percentile cutoff (%) for climax detection |
| DF reversal trades | `rev_mode` | `ENUM_REV_MODE` | `REV_AFTER_HOOK_EXIT` | `REV_OFF` (0), `REV_AFTER_HOOK_EXIT` (1), `REV_EVERY_HOOK` (2) |
| DF reversal trades | `rev_sbars` | `int` | `5` | Reversal stop beyond extreme of last N closed bars |
| DF reversal trades | `rev_buf` | `double` | `0.25` | Reversal stop buffer (`x ATR`) |
| DF reversal trades | `rev_rr` | `double` | `1.5` | Fixed R fallback target multiplier when EMA is not on profit side |
| DF reversal trades | `rev_max` | `int` | `24` | Max bars to hold a reversal before time exit |

### EA Money Management, Risk & Execution Inputs

| Group | Input Name | Type | Default | Description |
| --- | --- | --- | --- | --- |
| EA Money Management & Execution | `lot_mode` | `ENUM_LOT_MODE` | `LOT_FIXED` | `LOT_FIXED` (0) or `LOT_RISK_USD` (1) |
| EA Money Management & Execution | `fixed_lot` | `double` | `0.01` | Lot size used when `lot_mode = LOT_FIXED` |
| EA Money Management & Execution | `risk_usd` | `double` | `30.0` | Target stop-loss risk per trade in USD (rounded down to broker lot step) |
| EA Money Management & Execution | `max_loss_usd` | `double` | `100.0` | Hard loss cap per trade in USD; skips entry if minimum lot (`SYMBOL_VOLUME_MIN`) exceeds cap |
| EA Money Management & Execution | `magic` | `ulong` | `1212` | EA magic number used to isolate positions and deals |
| EA Money Management & Execution | `slippage_points` | `int` | `50` | Maximum allowed order deviation in points |
| EA Money Management & Execution | `halt_dd_R` | `double` | `20.0` | Kill switch: halts new entries if peak-to-trough realized `R` drawdown `>= halt_dd_R` (`<= 0` disables) |
| Telegram Notifications | `tg_enable` | `bool` | `false` | Enable Telegram Bot API notifications (disabled automatically in Strategy Tester) |
| Telegram Notifications | `tg_token` | `string` | `""` | Telegram Bot token (enter only in MT5 chart inputs/local `.set`; never commit tokens to git) |
| Telegram Notifications | `tg_chat_id` | `string` | `""` | Target Telegram chat or channel ID |

### Resetting the Kill Switch (`halt_dd_R`)
When `g_peak_R - g_cum_R >= halt_dd_R`, `g_halted` flips to `true` and is persisted in MT5 `GlobalVariable`s keyed by `V12_<magic>_<symbol>_<account>_*`. New entries remain blocked across restarts until you reset the kill switch in MT5 EA Inputs by either:
1. Changing `halt_dd_R` to a new positive value (or `0` to disable), OR
2. Deleting the `V12_*_HALTED` global variable (`F3` in MT5).

---

## 4. Exness VPS & Telegram Setup

### Exness MT5 Attachment
1. Open the `XAUUSDm` **H1** chart in MT5 (EA explicitly queries `PERIOD_H1` closed bars regardless of chart timeframe, though attaching to H1 is recommended).
2. Ensure Exness server history has sufficient H1 bars loaded (`>= 3,650+` bars; EA replays up to `3,200` closed bars plus indicator warmup on `OnInit`).
3. Attach `V12_EA` from **Navigator -> Expert Advisors** and enable **Algo Trading**.
4. **Daily/Weekend Market-Open Handling**: Exness `XAUUSDm` frequently delivers quote ticks during daily/Sunday market-break transitions slightly before trading opens (`TRADE_RETCODE_MARKET_CLOSED` / `retcode 10018`). `V12_EA` evaluates `V12_StepBar` strictly once per newly closed H1 bar, queues pending open/close/SL-modify actions across ticks of that same H1 bar, checks `IsTradeSessionOpen()`, and retries once trading opens (expiring unexecuted entries if a subsequent H1 bar closes first).
5. **VPS Restart Reconciliation**: On `OnInit`, after replaying `3,200` closed bars, any live open broker position matching `magic` and `_Symbol` overrides simulated position state (`pos_dir`, `eid` from `"L"`/`"S"`/`"RL"`/`"RS"` comment or TP presence, `stop_px`/`r_stop`/`r_tgt`, and `rev_bar` derived from `POSITION_TIME`).
   - Note: `V12_Indicators.mqh` / `V12_EA.mq5` assumes a single active position per `magic` + symbol at any time (`no pyramiding`, matching `V12_STRAT.pine`). Do not run two instances on the same account/symbol with the same `magic`.
6. **Missed-Bar Disconnect Recovery**: In `OnTick`, when a new H1 bar opens (`cur_bar_time != g_last_bar_time`), if `iBarShift(_Symbol, PERIOD_H1, g_last_bar_time) > 1` (bars were missed while disconnected), `V12_EA` calls `RebuildStateFromHistory()` across the recent bar history and sends a Telegram `"state rebuilt after N missed bars"` alert instead of stepping only bar `0`. Because `iBarShift` counts H1 bars rather than wall-clock hours, weekend gaps and daily market breaks return `1` and continue normal bar stepping without false rebuilds.

### Telegram Alerts (`WebRequest`)
1. Create a bot with `@BotFather` and obtain your Bot Token and Chat ID.
2. In MetaTrader 5: **Tools -> Options -> Expert Advisors**:
   - Check **Allow WebRequest for listed URL**.
   - Add `https://api.telegram.org`.
3. Set `tg_enable = true`, `tg_token`, and `tg_chat_id` in EA Inputs.
   - **Security**: Never commit `tg_token`, `tg_chat_id`, or exported `.set` files containing credentials (`*.set` is ignored in `.gitignore`). `SendTelegram` never logs tokens.

---

## 5. Parity & Strategy Tester Verification Results

### A. Indicator & Signal Math Parity (`V12_Debug.mq5`)
Running `V12_Debug` executes built-in unit tests (`V12_Debug: ALL indicator unit tests PASSED.`) and exports 8-decimal precision indicator values:
- **Chart mode** (`inp_use_csv_input=false`, `XAUUSDm` H1, `2025.01.01` to `2026.11.13`): exported `11,070` bars to `MQL5\Files\V12_Debug_Output.csv` (`total bars=14271, start_b=13868`).
- **CSV input mode** (`inp_use_csv_input=true` reading identical OHLC from `V12_Input_OHLC.csv`): exported `10,668` post-warmup bars to `MQL5\Files\V12_Debug_CSVMode.csv`.
- **Cross-check vs independent Python reference of `V12_STRAT.pine`** across all `10,668` bars:
  - `atr`: max relative diff `1.18e-09` (max abs `5.00e-09`)
  - `ema`: max relative diff `1.81e-12` (max abs `5.00e-09`)
  - `range_hi` / `range_lo`: `0.00e+00`
  - `t_stat`: max abs diff `5.04e-09`, max relative diff `8.63e-06` overall (`4.01e-07` where `|t_stat| >= 0.01`)
  - `t_pct`: max relative diff `1.30e-16` (max abs `7.11e-15`)
  - `df_hook` mismatches: **`0 / 10,668`**
  - `lvl_up` / `lvl_dn` mismatches: **`0 / 10,668`**
  - `signal` mismatches: **`0 / 10,668`**

### B. Strategy Tester vs `V12_Debug` (Same Exness `XAUUSDm` Feed)
Ran MT5 Strategy Tester (`XAUUSDm`, `H1`, `Model=4` "Every tick based on real ticks", `2025.01.01`–`2026.11.11`, `$10,000` deposit, `1:500` leverage) with updated defaults (`lot_mode = LOT_FIXED`, `fixed_lot = 0.01`, `halt_dd_R = 20.0`):
- **Performance & Drawdown**: final balance **$12,550.23 USD** (`Total Net Profit: $2,550.23`, `Gross Profit: $5,202.95`, `Gross Loss: -$2,652.72`, `Profit Factor: 1.96`, `Recovery Factor: 7.94`), `Balance Drawdown Maximal: $281.36 (2.76%)`, `Equity Drawdown Maximal: $321.00 (3.14%)`, realized **`MaxDD_R = 8.06 R`**, **`CumR = 88.97 R`**, `Halted = NO`.
- **Trades & Execution**: `239` Total Trades (`478` report deals including end-of-test open position close; `477` closed-bar deals exported to `Common\Files\V12_Tester_Trades.csv`), **0** missed-bar rebuild triggers across weekends and daily market breaks.
- **Parity on identical feed**: **`239 / 239 (100.0%)`** Strategy Tester entries match `V12_Debug` exact bar open timestamp, direction (`BUY`/`SELL`), and entry ID (`L`/`S`/`RL`/`RS`).
- **7 `V12_Debug` signals not executed in Strategy Tester**:
  - `4` (`2026.01.30 20:00`, `2026.02.04 02:00`, `2026.02.06 00:00`, `2026.03.03 13:00`): Intentionally skipped by `max_loss_usd = $100.00` during `$4,700–$5,500` gold volatility where minimum lot (`0.01`) stop risk was `$101.70–$216.01`.
  - `1` (`2025.11.17 21:00`): Blocked because MT5 Strategy Tester applies the symbol's static current session-break schedule across historical dates (`21:00` bar outside session on `2025.11.17`), after which the stale signal expired on the `23:00` bar.
  - `2` (`2026.11.11 17:00`, `2026.11.12 16:00`): Occur after Strategy Tester `ToDate = 2026.11.11`.

### C. Strategy Tester (Exness `XAUUSDm`) vs TradingView Export (`IC Markets XAUUSD`)
Compared against `V12_STRAT_IC_XAUUSD_2026-11-10_de175.csv` (`263` trades, `2025-01-15 01:02` to `2026-11-09 10:02`):
- **Chart Timezone & Warmup**: All `263` TV entries fall at `HH:02` under a **fixed `UTC+2` offset** relative to Exness `UTC+0` (`147` exact bar matches under fixed `UTC+2` vs `50` under DST-shifting `UTC+2/+3`). TV starts trading on `2025-01-15` (~208 H1 bars after `2025-01-01` indicator warmup), whereas MT5 replayed `3,250` bars from 2024 in `OnInit` and executed `6` trades between `2025-01-02` and `2025-01-14`.
- **Categorized Breakdown of All 263 TV Trades**:
  - `147 (55.9%)`: Exact entry bar (`TV - 2h == MT5 UTC+0`) & direction match.
  - `31 (11.8%)`: Shifted `1–2` H1 bars (`26` Trend, `5` Rev) due to cross-broker OHLC / spread differences shifting retest or DF hook confirmation by 1–2 bars.
  - `21 (8.0%)`: Shifted `3–6` H1 bars (`15` Trend, `6` Rev) due to cross-feed cascades / prior exit timing differences.
  - `31 (11.8%)`: Skipped in MT5 because an earlier Exness position was still open (`23` same direction, `8` opposite direction) — expected no-pyramiding rule behavior when feeds exit slightly differently.
  - `26 (9.9%)`: Unmatched Trend entries while MT5 was flat: `4` skipped intentionally by EA's `max_loss_usd = $100.00` cap (`TV#152, #154, #155, #168`), `1` (`TV#124` at `2025.11.17 21:00`) outside MT5 Tester's static session schedule, and `21` feed divergences where Exness OHLC slightly missed the breakout/retest/EMA/hook-cooldown condition (e.g., `4` blocked by Exness `DF hook` cooldown `Skip L`/`Skip S`, `1` on a `Rev exit` bar).
  - `7 (2.7%)`: Unmatched Reversal entries (`Rev L`/`Rev S`) while MT5 was flat (`TV#009, #024, #035, #043, #100, #153, #238`) because no active V12 trend trade was open on Exness when the hook printed.
- **Note on Historical Ticks**: On the Exness `XAUUSDm` server tested, real historical tick archives began `2026.09.16 00:00:00`; earlier dates (`2025.01.01`–`2026.09.15`) use MT5's M1-based tick synthesis under Model 4.

### D. IC Markets Strategy Tester (`XAUUSD`, `2025.01.01`–`2026.11.11`, `max_loss_usd = 0`)
Ran MT5 Strategy Tester on the IC Markets `XAUUSD` feed (`ICMarketsSC-Demo`, `H1`, `Model=4` "Every tick based on real ticks", `2025.01.01`–`2026.11.11`, `$10,000.00` deposit, `trail_len = 10`, `lot_mode = LOT_FIXED`, `fixed_lot = 0.01`, `halt_dd_R = 20.0`), setting `max_loss_usd = 0.0` **for this parity test only** so no signals are filtered by dollar stop risk (the repository default in `V12_EA.mq5` remains `max_loss_usd = 100.0`):

| Metric | IC Markets (`XAUUSD`, `max_loss_usd=0`) | Exness (`XAUUSDm`, `max_loss_usd=100`) |
| --- | --- | --- |
| Final Balance | **$13,175.39** | $12,550.23 |
| Total Net Profit | **$3,175.39** | $2,550.23 |
| Gross Profit / Gross Loss | $5,892.13 / -$2,716.74 | $5,202.95 / -$2,652.72 |
| Profit Factor / Expected Payoff | 2.17 / $13.07 | 1.96 / $10.67 |
| Recovery Factor / Sharpe Ratio | 5.10 / 26.09 | 7.94 / 19.82 |
| Balance Drawdown Maximal | **$223.02 (1.92%)** | $281.36 (2.76%) |
| Equity Drawdown Maximal | **$622.92 (5.19%)** | $321.00 (3.14%) |
| Realized Drawdown / Return (`R`) | **`MaxDD_R = 5.81 R`**, `CumR = 103.41 R` | `MaxDD_R = 8.06 R`, `CumR = 88.97 R` |
| Halted (`halt_dd_R = 20.0`) | `NO` | `NO` |
| Total Trades / Report Deals | **`243`** (`486` deals; `485` in `V12_Tester_Trades.csv`) | `239` (`478` deals; `477` in `V12_Tester_Trades.csv`) |
| Long / Short Win Rate | Long `130` (`50.00%`) / Short `113` (`40.71%`) | — |
| Same-Feed `V12_Debug` Entry Parity | **`243 / 243 (100.0%)`** | `239 / 239 (100.0%)` |

- **Note on Historical Ticks**: On `ICMarketsSC-Demo`, `XAUUSD` Strategy Tester processed `11,002` H1 bars and `164,728,451` ticks with `History Quality: 0% real ticks` (`Ticks XAUUSD : real ticks begin from 2026.11.05 00:00:00`), so `2025.01.01`–`2026.11.04` uses MT5's M1-based tick synthesis under Model 4.

### E. Same-Feed Parity Analysis: IC Markets MT5 vs TradingView (`V12_STRAT.pine`)
Compared the IC Markets MT5 feed against both user TradingView exports (chart fixed at **`UTC+2`** vs IC Markets server **`GMT+2` winter / `GMT+3` US DST**, both converted to UTC before matching):
- `V12_STRAT_IC_XAUUSD_2026-11-14_985f8.csv`: `244` trades (`2025-01-15 01:02` to `2026-11-12 12:02`, **`trail_len = 10`** matching EA default)
- `V12_STRAT_IC_XAUUSD_2026-11-10_de175.csv`: `263` trades (`2025-01-15 01:02` to `2026-11-09 10:02`, **`trail_len = 8`**)

#### 1. Root Cause of `:00` vs TradingView Mismatches (`:02` Session-Aligned 1H Boundaries, Zero Logic Bugs)
- **Every TradingView timestamp ends in `:02`** (`488/488` rows in `985f8.csv` and `526/526` rows in `de175.csv`). Because IC Markets' daily XAUUSD session opens at `01:02` server time after rollover, TradingView constructs `1H` candles on **`[HH:02, (HH+1):02)`** windows, whereas MT5 `PERIOD_H1` builds candles on **`[HH:00, (HH+1):00)`** windows.
- **Full-Period Entry Open Price Parity**: Rebuilding `[HH:02, (HH+1):02)` 1H bars from IC Markets' exported M1 history (`717,521` M1 bars, `2024.11.01 01:00`–`2026.11.11 23:58`) gives a full-period entry price error **`|TV Entry - M1[:02].Open|` median `$0.050` (`p90 = $0.180`, `max = $1.120`, `n = 243/244`)**, compared to **median `$1.180` (`p90 = $4.500`, `max = $33.070`, `n = 244/244`)** on standard `H1[:00].Open`. Duration in H1 bars matches **`244 / 244 (100.0%)`** (`0` duration mismatches).
- **Exact MQL5 vs Pine Parity**: Running compiled MQL5 `V12_Debug` (CSV mode) on the exact same OHLC bars against the Python reference translation of `V12_STRAT.pine` yields **`0` `df_hook`, `0` `lvl_up`/`lvl_dn`, and `0` `signal` mismatches** across both `10,668` `:00` bars and `11,582` `:02` bars.
- **Why Exness `:00` Previously Matched `55.9%`**: Across `11,069` common UTC `:00` bars between Exness `XAUUSDm` and IC Markets `XAUUSD`, signals matched on `11,013 / 11,069 (99.49%)` (`233 / 245 = 95.1%` on IC entry bars). The earlier `55.9%` mismatch vs TradingView was almost entirely the `:02` vs `:00` bar-boundary alignment difference plus `trail_len = 8` vs `10`.

#### 2. Parity Summary & Category Breakdowns
| Comparison | Bar Boundary & `trail_len` | Exact Match | Result |
| --- | --- | --- | --- |
| **IC `:02` Session-Aligned 1H (`V12_Debug` MQL5) vs `985f8.csv`** | `:02`, `trail_len = 10` | **`238 / 243 (97.94%)`** | **PASS (`>= 85%`)** |
| **IC `:02` Session-Aligned 1H (`trail_len=8`) vs `de175.csv`** | `:02`, `trail_len = 8` | **`258 / 263 (98.10%)`** | **PASS (`>= 85%`)** |
| Standard MT5 `PERIOD_H1` (`:00`) Tester vs `985f8.csv` | `:00`, `trail_len = 10` | `150 / 244 (61.48%)` | `91 / 94` resolved on `:02` |
| Standard MT5 `PERIOD_H1` (`:00`) Tester vs `de175.csv` | `:00`, `trail_len = 8` | `151 / 263 (57.41%)` | `110 / 112` resolved on `:02` (`trail_len=8`) |

- **`IC :02 Session-Aligned 1H (trail_len=10)` vs `985f8.csv`** (`243` in-range trades; `#244` at `2026-11-12 10:00 UTC` is after `2026-11-11` M1 cutoff):
  - `EXACT_MATCH`: **`238 (97.9%)`**
  - `SHIFTED_1_2_BARS` (Trend): `3 (1.2%)` (`#156`, `#179`, `#225`)
  - `BLOCKED_OPEN_SAME_DIR`: `1 (0.4%)` (`#169`)
  - `UNMATCHED_TREND_FLAT`: `1 (0.4%)` (`#233`)
- **`IC :02 Session-Aligned 1H (trail_len=8)` vs `de175.csv`** (`263` trades; `2` extra SIM trades at `2026-11-10 19:00` and `2026-11-11 16:00` occur after `de175`'s `2026-11-10` export cutoff):
  - `EXACT_MATCH`: **`258 (98.1%)`**
  - `SHIFTED_1_2_BARS` (Trend): `3 (1.1%)` (`#169`, `#193`, `#245`)
  - `UNMATCHED_TREND_FLAT`: `2 (0.8%)` (`#038`, `#255`)
- **Standard MT5 `PERIOD_H1` (`:00`) Tester vs `985f8.csv`** (`244` trades) vs **`de175.csv`** (`263` trades):
  - `EXACT_MATCH`: `150 (61.5%)` / `151 (57.4%)`
  - `SHIFTED_1_2_BARS` (Trend): `29 (11.9%)` / `30 (11.4%)`
  - `UNMATCHED_TREND_FLAT`: `22 (9.0%)` / `22 (8.4%)`
  - `SHIFTED_3_6_BARS` (Trend): `12 (4.9%)` / `12 (4.6%)`
  - `BLOCKED_OPEN_OPP_DIR`: `9 (3.7%)` / `9 (3.4%)`
  - `BLOCKED_OPEN_SAME_DIR`: `6 (2.5%)` / `23 (8.7%)`
  - `UNMATCHED_REV_FLAT`: `6 (2.5%)` / `6 (2.3%)`
  - `SHIFTED_3_6_BARS` (Rev): `5 (2.0%)` / `5 (1.9%)`
  - `SHIFTED_1_2_BARS` (Rev): `5 (2.0%)` / `5 (1.9%)`

#### 3. Remaining `:02` Tick-Boundary Mismatches (Zero Logic Bugs)
All `5` remaining `:02` mismatches in `985f8.csv` (and `de175 #038`) occur where M1 `:02` bucketed OHLC differs from TradingView tick/sub-minute aggregation by `$0.00–$0.37` right on an inequality boundary:

| TV `#` (`985f8` / `de175`) | UTC Bar (`TV`) | Dir / Type | `:02` Category | Exact Tick/OHLC Boundary Difference |
| --- | --- | --- | --- | --- |
| `#156` / `de175 #169` | `2026-03-10 02:00` | `BUY` `Trend L` | `SHIFTED -1h` | `02:00` M1 `:02` low `5163.85` touched `lu + 0.25*atr` (`5156.04 + 0.25*31.31 = 5163.8675`) by **`-$0.0175`**, triggering 1 bar earlier (`03:00` vs `04:00` UTC+2). |
| `#169` / — | `2026-04-14 15:00` | `BUY` `Trend L` | `BLOCKED_SAME_DIR` | Prior long stayed open because `10:00` low (`4751.94`) missed `trail_lo` stop (`4751.57` TV exit) by **`$0.37`**. |
| `#179` / `de175 #193` | `2026-05-26 00:00` | `SELL` `Trend S` | `SHIFTED -1h` | `2026-05-25 23:00` close (`4550.27`) crossed below `rL` (`4550.52`) by **`-$0.25`**, triggering `fresh_dn` 1 bar earlier. |
| `#225` / `de175 #245` | `2026-09-14 10:00` | `SELL` `Trend S` | `SHIFTED +2h` | `10:00` close (`4295.09`) exceeded `failed_dn` (`4290.05 + 0.25*19.47 = 4294.92`) by **`+$0.17`**, invalidating `ld` and delaying entry `+2h`. |
| `#233` / `de175 #255` | `2026-10-14 11:00` | `SELL` `Trend S` | `UNMATCHED_FLAT` | `09:00` close (`4141.50`) missed `rL` (`4141.42`) by **`+$0.08`**, skipping `fresh_dn`. |
| — / `de175 #038` | `2025-04-07 17:00` | `SELL` `Trend S` | `UNMATCHED_FLAT` (`trail_len=8`) | `17:00` close (`2970.27`) tied `rL` (`2970.27`) exactly (**`$0.00`**), failing strict `<`. |

#### 4. Complete `94`-Entry Standard MT5 `PERIOD_H1` (`:00`) Tester vs `985f8.csv` (`:02`) Mismatch Log
`91` of these `94` mismatches become exact matches under `:02` bucketing (`2` are tick-boundary cases `#169` and `#233`, and `1` is post-cutoff `#244` on `2026-11-12`):

<details>
<summary>Expand all 94 mismatch entries with MT5 :00 vs M1-bucketed :02 signal-bar OHLC</summary>

| TV# | TV Time (`UTC+2`) | UTC Bar | Signal | TV Price | MT5 `:00` Status | Cause | Signal-Bar OHLC Diff (`sigbar`) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `#002` | `2025-01-16 14:02` | `2025-01-16 12:00` | `BUY` `Trend L` | `2704.77` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=2706.40, L=2706.24, H=2711.26, sig='')` vs :02 `(C=2704.75, L=2704.56, H=2711.26, sig='Trend L')` |
| `#003` | `2025-01-21 20:02` | `2025-01-21 18:00` | `BUY` `Trend L` | `2740.99` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=2740.28, L=2740.10, H=2745.66, sig='')` vs :02 `(C=2740.94, L=2740.02, H=2745.66, sig='Trend L')` |
| `#005` | `2025-01-28 22:02` | `2025-01-28 20:00` | `BUY` `Trend L` | `2764.95` | `SHIFTED_1_2 (Trend, -2h)` | Bar `:02` vs `:00` | :00 `(C=2764.89, L=2761.35, H=2764.99, sig='')` vs :02 `(C=2764.91, L=2761.35, H=2764.99, sig='Trend L')` |
| `#007` | `2025-01-31 15:02` | `2025-01-31 13:00` | `BUY` `Trend L` | `2804.44` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=2805.43, L=2800.11, H=2807.89, sig='')` vs :02 `(C=2804.42, L=2800.82, H=2807.89, sig='Trend L')` |
| `#008` | `2025-01-31 18:02` | `2025-01-31 16:00` | `SELL` `Rev S` | `2808.32` | `UNMATCHED_REV_FLAT` | Bar `:02` vs `:00` | :00 `(C=2809.31, L=2808.33, H=2817.11, sig='Skip L')` vs :02 `(C=2808.41, L=2808.24, H=2817.11, sig='Rev S')` |
| `#015` | `2025-02-24 16:02` | `2025-02-24 14:00` | `BUY` `Trend L` | `2955.45` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=2954.40, L=2946.33, H=2954.55, sig='')` vs :02 `(C=2955.41, L=2946.92, H=2955.89, sig='Trend L')` |
| `#017` | `2025-02-27 18:02` | `2025-02-27 16:00` | `SELL` `Trend S` | `2874.12` | `SHIFTED_3_6 (Trend, -6h)` | Bar `:02` vs `:00` | :00 `(C=2872.28, L=2870.49, H=2882.60, sig='')` vs :02 `(C=2874.16, L=2871.04, H=2882.60, sig='Trend S')` |
| `#019` | `2025-03-10 20:02` | `2025-03-10 18:00` | `SELL` `Trend S` | `2882.93` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=2886.09, L=2882.84, H=2896.23, sig='')` vs :02 `(C=2883.01, L=2882.77, H=2896.23, sig='Trend S')` |
| `#021` | `2025-03-13 14:02` | `2025-03-13 12:00` | `BUY` `Trend L` | `2947.77` | `SHIFTED_3_6 (Trend, +3h)` | Bar `:02` vs `:00` | :00 `(C=2946.28, L=2944.12, H=2948.76, sig='')` vs :02 `(C=2947.70, L=2944.47, H=2948.76, sig='Trend L')` |
| `#022` | `2025-03-14 04:02` | `2025-03-14 02:00` | `SELL` `Rev S` | `2987.22` | `UNMATCHED_REV_FLAT` | Bar `:02` vs `:00` | :00 `(C=2987.84, L=2981.77, H=2990.19, sig='Skip L')` vs :02 `(C=2987.26, L=2981.77, H=2990.19, sig='Rev S')` |
| `#026` | `2025-03-25 17:02` | `2025-03-25 15:00` | `BUY` `Trend L` | `3027.89` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=3025.11, L=3025.11, H=3035.94, sig='')` vs :02 `(C=3027.82, L=3024.53, H=3035.94, sig='Trend L')` |
| `#028` | `2025-03-28 10:02` | `2025-03-28 08:00` | `SELL` `Rev S` | `3080.43` | `SHIFTED_3_6 (Rev, -3h)` | Bar `:02` vs `:00` | :00 `(C=3079.39, L=3077.65, H=3085.97, sig='Skip L')` vs :02 `(C=3080.47, L=3077.65, H=3085.97, sig='Rev S')` |
| `#030` | `2025-03-31 06:02` | `2025-03-31 04:00` | `SELL` `Rev S` | `3107.15` | `SHIFTED_3_6 (Rev, +5h)` | Bar `:02` vs `:00` | :00 `(C=3107.19, L=3105.25, H=3111.67, sig='')` vs :02 `(C=3107.02, L=3105.25, H=3111.67, sig='Rev S')` |
| `#031` | `2025-04-01 04:02` | `2025-04-01 02:00` | `BUY` `Trend L` | `3134.59` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=3135.42, L=3126.56, H=3138.30, sig='Rev exit')` vs :02 `(C=3134.48, L=3126.56, H=3138.30, sig='Trend L')` |
| `#032` | `2025-04-01 06:02` | `2025-04-01 04:00` | `SELL` `Rev S` | `3146.43` | `UNMATCHED_REV_FLAT` | Bar `:02` vs `:00` | :00 `(C=3146.06, L=3142.62, H=3147.37, sig='')` vs :02 `(C=3146.45, L=3142.62, H=3147.37, sig='Rev S')` |
| `#033` | `2025-04-03 03:02` | `2025-04-03 01:00` | `BUY` `Trend L` | `3151.89` | `SHIFTED_1_2 (Trend, -1h)` | Bar `:02` vs `:00` | :00 `(C=3151.36, L=3140.64, H=3164.88, sig='')` vs :02 `(C=3152.10, L=3140.64, H=3164.88, sig='Trend L')` |
| `#035` | `2025-04-09 16:02` | `2025-04-09 14:00` | `BUY` `Trend L` | `3075.79` | `SHIFTED_1_2 (Trend, +2h)` | Bar `:02` vs `:00` | :00 `(C=3075.18, L=3047.42, H=3077.98, sig='')` vs :02 `(C=3075.77, L=3047.57, H=3077.98, sig='Trend L')` |
| `#036` | `2025-04-11 06:02` | `2025-04-11 04:00` | `SELL` `Rev S` | `3217.78` | `SHIFTED_1_2 (Rev, +1h)` | Bar `:02` vs `:00` | :00 `(C=3217.80, L=3214.15, H=3220.14, sig='')` vs :02 `(C=3217.81, L=3214.15, H=3220.14, sig='Rev S')` |
| `#038` | `2025-04-22 05:02` | `2025-04-22 03:00` | `BUY` `Trend L` | `3474.75` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=3473.15, L=3442.45, H=3476.00, sig='Skip L')` vs :02 `(C=3474.70, L=3442.45, H=3476.00, sig='Trend L')` |
| `#039` | `2025-04-22 07:02` | `2025-04-22 05:00` | `SELL` `Rev S` | `3484.85` | `UNMATCHED_REV_FLAT` | Bar `:02` vs `:00` | :00 `(C=3484.46, L=3479.70, H=3488.47, sig='')` vs :02 `(C=3484.94, L=3479.70, H=3487.22, sig='Rev S')` |
| `#042` | `2025-04-28 21:02` | `2025-04-28 19:00` | `BUY` `Trend L` | `3349.26` | `SHIFTED_1_2 (Trend, +2h)` | Bar `:02` vs `:00` | :00 `(C=3349.02, L=3334.01, H=3350.03, sig='')` vs :02 `(C=3349.18, L=3334.01, H=3350.03, sig='Trend L')` |
| `#043` | `2025-05-01 07:02` | `2025-05-01 05:00` | `SELL` `Trend S` | `3227.23` | `BLOCKED_SAME_DIR` | Bar `:02` vs `:00` | :00 `(C=3226.63, L=3221.32, H=3231.98, sig='')` vs :02 `(C=3227.29, L=3221.32, H=3231.98, sig='Trend S')` |
| `#044` | `2025-05-06 00:02` | `2025-05-05 22:00` | `BUY` `Trend L` | `3337.16` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=3333.96, L=3328.81, H=3334.56, sig='')` vs :02 `(C=3333.96, L=3329.28, H=3334.56, sig='Trend L')` |
| `#045` | `2025-05-06 17:02` | `2025-05-06 15:00` | `SELL` `Rev S` | `3387.92` | `BLOCKED_OPP_DIR` | Bar `:02` vs `:00` | :00 `(C=3386.39, L=3378.25, H=3398.08, sig='')` vs :02 `(C=3388.01, L=3378.25, H=3398.08, sig='Rev S')` |
| `#046` | `2025-05-09 01:02` | `2025-05-08 23:00` | `SELL` `Trend S` | `3319.30` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=3323.80, L=3304.54, H=3324.00, sig='')` vs :02 `(C=3319.34, L=3306.46, H=3324.00, sig='Trend S')` |
| `#047` | `2025-05-12 10:02` | `2025-05-12 08:00` | `SELL` `Trend S` | `3224.70` | `SHIFTED_3_6 (Trend, +3h)` | Bar `:02` vs `:00` | :00 `(C=3222.77, L=3216.19, H=3277.91, sig='')` vs :02 `(C=3225.01, L=3216.19, H=3259.50, sig='Trend S')` |
| `#051` | `2025-05-20 22:02` | `2025-05-20 20:00` | `BUY` `Trend L` | `3294.58` | `SHIFTED_1_2 (Trend, -1h)` | Bar `:02` vs `:00` | :00 `(C=3294.15, L=3287.32, H=3295.12, sig='')` vs :02 `(C=3294.55, L=3287.32, H=3295.12, sig='Trend L')` |
| `#052` | `2025-05-23 14:02` | `2025-05-23 12:00` | `BUY` `Trend L` | `3354.14` | `SHIFTED_3_6 (Trend, -4h)` | Bar `:02` vs `:00` | :00 `(C=3348.05, L=3324.44, H=3349.76, sig='')` vs :02 `(C=3354.05, L=3324.44, H=3354.41, sig='Trend L')` |
| `#056` | `2025-05-30 17:02` | `2025-05-30 15:00` | `SELL` `Trend S` | `3279.98` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=3282.75, L=3271.52, H=3287.34, sig='')` vs :02 `(C=3279.98, L=3271.52, H=3287.34, sig='Trend S')` |
| `#057` | `2025-06-02 22:02` | `2025-06-02 20:00` | `BUY` `Trend L` | `3380.65` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=3381.54, L=3377.95, H=3382.38, sig='')` vs :02 `(C=3380.37, L=3377.95, H=3382.38, sig='Trend L')` |
| `#058` | `2025-06-04 18:02` | `2025-06-04 16:00` | `BUY` `Trend L` | `3373.52` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=3371.78, L=3369.82, H=3378.99, sig='')` vs :02 `(C=3373.48, L=3369.82, H=3377.69, sig='Trend L')` |
| `#059` | `2025-06-06 18:02` | `2025-06-06 16:00` | `SELL` `Trend S` | `3331.83` | `SHIFTED_3_6 (Trend, +5h)` | Bar `:02` vs `:00` | :00 `(C=3332.17, L=3323.39, H=3336.80, sig='')` vs :02 `(C=3331.87, L=3323.39, H=3336.80, sig='Trend S')` |
| `#060` | `2025-06-09 20:02` | `2025-06-09 18:00` | `BUY` `Trend L` | `3333.87` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=3333.69, L=3332.95, H=3338.25, sig='')` vs :02 `(C=3333.79, L=3332.95, H=3336.80, sig='Trend L')` |
| `#061` | `2025-06-10 05:02` | `2025-06-10 03:00` | `SELL` `Trend S` | `3309.13` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=3309.39, L=3301.94, H=3310.31, sig='')` vs :02 `(C=3309.15, L=3301.94, H=3310.31, sig='Trend S')` |
| `#067` | `2025-06-27 06:02` | `2025-06-27 04:00` | `SELL` `Trend S` | `3291.29` | `BLOCKED_SAME_DIR` | Bar `:02` vs `:00` | :00 `(C=3294.37, L=3292.61, H=3311.06, sig='')` vs :02 `(C=3291.31, L=3291.18, H=3311.06, sig='Trend S')` |
| `#068` | `2025-07-01 16:02` | `2025-07-01 14:00` | `BUY` `Trend L` | `3349.06` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=3351.88, L=3344.46, H=3355.66, sig='')` vs :02 `(C=3349.01, L=3344.46, H=3354.56, sig='Trend L')` |
| `#070` | `2025-07-07 04:02` | `2025-07-07 02:00` | `SELL` `Trend S` | `3316.71` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=3316.64, L=3306.72, H=3327.66, sig='')` vs :02 `(C=3316.58, L=3306.72, H=3324.88, sig='Trend S')` |
| `#072` | `2025-07-11 14:02` | `2025-07-11 12:00` | `BUY` `Trend L` | `3349.18` | `BLOCKED_SAME_DIR` | Bar `:02` vs `:00` | :00 `(C=3347.50, L=3342.13, H=3350.29, sig='')` vs :02 `(C=3349.07, L=3342.13, H=3350.29, sig='Trend L')` |
| `#079` | `2025-08-04 02:02` | `2025-08-04 00:00` | `BUY` `Trend L` | `3360.33` | `SHIFTED_1_2 (Trend, -2h)` | Bar `:02` vs `:00` | :00 `(C=3362.05, L=3354.63, H=3362.10, sig='')` vs :02 `(C=3360.36, L=3354.63, H=3362.34, sig='Trend L')` |
| `#088` | `2025-09-01 05:02` | `2025-09-01 03:00` | `BUY` `Trend L` | `3485.83` | `SHIFTED_3_6 (Trend, -4h)` | Bar `:02` vs `:00` | :00 `(C=3483.77, L=3455.24, H=3484.84, sig='')` vs :02 `(C=3485.76, L=3455.98, H=3486.04, sig='Trend L')` |
| `#090` | `2025-09-02 18:02` | `2025-09-02 16:00` | `BUY` `Trend L` | `3519.27` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=3520.49, L=3509.65, H=3520.49, sig='Skip L')` vs :02 `(C=3519.39, L=3509.65, H=3521.82, sig='Trend L')` |
| `#091` | `2025-09-03 00:02` | `2025-09-02 22:00` | `SELL` `Rev S` | `3531.89` | `UNMATCHED_REV_FLAT` | Bar `:02` vs `:00` | :00 `(C=3533.52, L=3533.47, H=3537.79, sig='Skip L')` vs :02 `(C=3533.52, L=3533.47, H=3537.79, sig='Rev S')` |
| `#098` | `2025-09-23 03:02` | `2025-09-23 01:00` | `SELL` `Rev S` | `3746.05` | `BLOCKED_OPP_DIR` | Bar `:02` vs `:00` | :00 `(C=3747.23, L=3744.97, H=3750.68, sig='')` vs :02 `(C=3746.14, L=3744.97, H=3750.68, sig='Rev S')` |
| `#100` | `2025-09-30 05:02` | `2025-09-30 03:00` | `SELL` `Rev S` | `3847.26` | `SHIFTED_3_6 (Rev, +4h)` | Bar `:02` vs `:00` | :00 `(C=3848.06, L=3842.65, H=3851.98, sig='')` vs :02 `(C=3847.34, L=3842.65, H=3851.73, sig='Rev S')` |
| `#104` | `2025-10-07 17:02` | `2025-10-07 15:00` | `BUY` `Trend L` | `3985.95` | `SHIFTED_1_2 (Trend, -1h)` | Bar `:02` vs `:00` | :00 `(C=3985.58, L=3969.08, H=3986.74, sig='')` vs :02 `(C=3986.03, L=3969.08, H=3987.34, sig='Trend L')` |
| `#110` | `2025-10-27 20:02` | `2025-10-27 18:00` | `SELL` `Trend S` | `4005.96` | `BLOCKED_SAME_DIR` | Bar `:02` vs `:00` | :00 `(C=4006.51, L=3990.93, H=4009.04, sig='')` vs :02 `(C=4006.13, L=3990.93, H=4009.04, sig='Trend S')` |
| `#111` | `2025-10-28 12:02` | `2025-10-28 10:00` | `BUY` `Rev L` | `3905.05` | `BLOCKED_OPP_DIR` | Bar `:02` vs `:00` | :00 `(C=3904.83, L=3886.62, H=3911.16, sig='')` vs :02 `(C=3905.01, L=3886.62, H=3911.16, sig='Rev L')` |
| `#113` | `2025-11-13 11:02` | `2025-11-13 09:00` | `BUY` `Trend L` | `4232.41` | `SHIFTED_1_2 (Trend, -1h)` | Bar `:02` vs `:00` | :00 `(C=4232.93, L=4219.16, H=4239.50, sig='')` vs :02 `(C=4232.59, L=4221.93, H=4239.50, sig='Trend L')` |
| `#119` | `2025-11-28 11:02` | `2025-11-28 09:00` | `BUY` `Trend L` | `4167.45` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=4166.55, L=4154.67, H=4175.08, sig='')` vs :02 `(C=4167.32, L=4154.67, H=4174.91, sig='Trend L')` |
| `#127` | `2025-12-31 11:02` | `2025-12-31 09:00` | `SELL` `Trend S` | `4308.49` | `SHIFTED_1_2 (Trend, -2h)` | Bar `:02` vs `:00` | :00 `(C=4307.36, L=4303.48, H=4332.88, sig='')` vs :02 `(C=4308.58, L=4303.48, H=4331.30, sig='Trend S')` |
| `#129` | `2026-01-05 18:02` | `2026-01-05 16:00` | `BUY` `Trend L` | `4448.98` | `SHIFTED_1_2 (Trend, +2h)` | Bar `:02` vs `:00` | :00 `(C=4448.59, L=4435.76, H=4455.78, sig='')` vs :02 `(C=4448.94, L=4435.76, H=4455.78, sig='Trend L')` |
| `#130` | `2026-01-09 17:02` | `2026-01-09 15:00` | `BUY` `Trend L` | `4493.94` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=4494.53, L=4479.13, H=4498.04, sig='')` vs :02 `(C=4493.51, L=4479.13, H=4498.04, sig='Trend L')` |
| `#131` | `2026-01-12 19:02` | `2026-01-12 17:00` | `SELL` `Rev S` | `4617.57` | `SHIFTED_1_2 (Rev, -2h)` | Bar `:02` vs `:00` | :00 `(C=4616.91, L=4608.02, H=4630.22, sig='')` vs :02 `(C=4617.61, L=4608.02, H=4630.22, sig='Rev S')` |
| `#132` | `2026-01-20 07:02` | `2026-01-20 05:00` | `BUY` `Trend L` | `4696.75` | `SHIFTED_3_6 (Trend, +5h)` | Bar `:02` vs `:00` | :00 `(C=4695.30, L=4679.70, H=4697.08, sig='')` vs :02 `(C=4696.78, L=4679.70, H=4697.63, sig='Trend L')` |
| `#133` | `2026-01-21 09:02` | `2026-01-21 07:00` | `SELL` `Rev S` | `4847.37` | `SHIFTED_3_6 (Rev, -4h)` | Bar `:02` vs `:00` | :00 `(C=4847.56, L=4845.33, H=4888.35, sig='Skip L')` vs :02 `(C=4847.44, L=4842.82, H=4888.35, sig='Rev S')` |
| `#135` | `2026-01-23 20:02` | `2026-01-23 18:00` | `BUY` `Trend L` | `4971.60` | `SHIFTED_1_2 (Trend, +2h)` | Bar `:02` vs `:00` | :00 `(C=4966.00, L=4962.20, H=4988.19, sig='')` vs :02 `(C=4971.57, L=4962.20, H=4988.19, sig='Trend L')` |
| `#136` | `2026-01-26 06:02` | `2026-01-26 04:00` | `SELL` `Rev S` | `5076.11` | `BLOCKED_OPP_DIR` | Bar `:02` vs `:00` | :00 `(C=5076.67, L=5070.03, H=5087.88, sig='')` vs :02 `(C=5076.18, L=5070.03, H=5087.88, sig='Rev S')` |
| `#138` | `2026-01-29 06:02` | `2026-01-29 04:00` | `SELL` `Rev S` | `5546.92` | `SHIFTED_1_2 (Rev, -1h)` | Bar `:02` vs `:00` | :00 `(C=5545.77, L=5508.51, H=5549.07, sig='')` vs :02 `(C=5546.90, L=5508.51, H=5550.95, sig='Rev S')` |
| `#140` | `2026-02-02 10:02` | `2026-02-02 08:00` | `BUY` `Rev L` | `4576.85` | `BLOCKED_OPP_DIR` | Bar `:02` vs `:00` | :00 `(C=4587.24, L=4486.14, H=4619.00, sig='')` vs :02 `(C=4576.38, L=4509.64, H=4619.00, sig='Rev L')` |
| `#145` | `2026-02-16 01:02` | `2026-02-15 23:00` | `BUY` `Trend L` | `5019.13` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=5042.46, L=5029.74, H=5045.84, sig='')` vs :02 `(C=5042.46, L=5029.74, H=5045.84, sig='Trend L')` |
| `#152` | `2026-02-23 20:02` | `2026-02-23 18:00` | `SELL` `Rev S` | `5208.05` | `SHIFTED_1_2 (Rev, +1h)` | Bar `:02` vs `:00` | :00 `(C=5208.03, L=5191.21, H=5213.61, sig='')` vs :02 `(C=5208.09, L=5191.21, H=5213.61, sig='Rev S')` |
| `#158` | `2026-03-13 02:02` | `2026-03-13 00:00` | `SELL` `Trend S` | `5101.36` | `SHIFTED_3_6 (Trend, -4h)` | Bar `:02` vs `:00` | :00 `(C=5098.14, L=5089.26, H=5101.39, sig='')` vs :02 `(C=5101.78, L=5089.26, H=5103.84, sig='Trend S')` |
| `#166` | `2026-04-09 17:02` | `2026-04-09 15:00` | `BUY` `Trend L` | `4767.93` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=4768.67, L=4747.40, H=4776.32, sig='')` vs :02 `(C=4767.95, L=4747.40, H=4776.32, sig='Trend L')` |
| `#169` | `2026-04-14 17:02` | `2026-04-14 15:00` | `BUY` `Trend L` | `4802.69` | `BLOCKED_SAME_DIR` | Tick boundary (also shifted/missed in `:02`) | :00 `(C=4803.97, L=4793.17, H=4818.13, sig='')` vs :02 `(C=4802.48, L=4793.17, H=4818.13, sig='')` |
| `#171` | `2026-04-28 06:02` | `2026-04-28 04:00` | `SELL` `Trend S` | `4667.05` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=4671.01, L=4668.44, H=4675.84, sig='')` vs :02 `(C=4667.06, L=4667.01, H=4675.84, sig='Trend S')` |
| `#174` | `2026-05-04 13:02` | `2026-05-04 11:00` | `SELL` `Trend S` | `4566.80` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=4562.69, L=4526.04, H=4575.77, sig='')` vs :02 `(C=4566.85, L=4526.04, H=4571.14, sig='Trend S')` |
| `#178` | `2026-05-15 09:02` | `2026-05-15 07:00` | `BUY` `Rev L` | `4569.65` | `BLOCKED_OPP_DIR` | Bar `:02` vs `:00` | :00 `(C=4570.09, L=4556.41, H=4580.62, sig='')` vs :02 `(C=4569.54, L=4559.40, H=4580.62, sig='Rev L')` |
| `#180` | `2026-05-28 07:02` | `2026-05-28 05:00` | `BUY` `Rev L` | `4371.90` | `BLOCKED_OPP_DIR` | Bar `:02` vs `:00` | :00 `(C=4373.07, L=4366.55, H=4382.06, sig='')` vs :02 `(C=4371.85, L=4366.55, H=4382.06, sig='Rev L')` |
| `#181` | `2026-05-29 13:02` | `2026-05-29 11:00` | `BUY` `Trend L` | `4539.04` | `SHIFTED_3_6 (Trend, -3h)` | Bar `:02` vs `:00` | :00 `(C=4538.57, L=4525.59, H=4543.32, sig='')` vs :02 `(C=4538.93, L=4525.59, H=4543.32, sig='Trend L')` |
| `#184` | `2026-06-03 09:02` | `2026-06-03 07:00` | `SELL` `Trend S` | `4460.92` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=4463.10, L=4455.37, H=4470.97, sig='')` vs :02 `(C=4460.98, L=4455.37, H=4470.97, sig='Trend S')` |
| `#186` | `2026-06-05 19:02` | `2026-06-05 17:00` | `SELL` `Trend S` | `4340.66` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=4344.59, L=4323.34, H=4344.98, sig='')` vs :02 `(C=4340.61, L=4323.34, H=4347.04, sig='Trend S')` |
| `#188` | `2026-06-09 22:02` | `2026-06-09 20:00` | `SELL` `Trend S` | `4256.95` | `SHIFTED_3_6 (Trend, +4h)` | Bar `:02` vs `:00` | :00 `(C=4258.74, L=4250.02, H=4271.73, sig='')` vs :02 `(C=4256.67, L=4250.02, H=4271.73, sig='Trend S')` |
| `#191` | `2026-06-18 05:02` | `2026-06-18 03:00` | `SELL` `Trend S` | `4309.88` | `SHIFTED_1_2 (Trend, -2h)` | Bar `:02` vs `:00` | :00 `(C=4311.02, L=4310.57, H=4329.97, sig='')` vs :02 `(C=4309.90, L=4309.20, H=4329.97, sig='Trend S')` |
| `#192` | `2026-06-19 10:02` | `2026-06-19 08:00` | `BUY` `Rev L` | `4158.77` | `BLOCKED_OPP_DIR` | Bar `:02` vs `:00` | :00 `(C=4158.05, L=4147.59, H=4163.17, sig='')` vs :02 `(C=4158.98, L=4148.19, H=4163.17, sig='Rev L')` |
| `#193` | `2026-06-23 08:02` | `2026-06-23 06:00` | `SELL` `Trend S` | `4125.56` | `SHIFTED_1_2 (Trend, +2h)` | Bar `:02` vs `:00` | :00 `(C=4121.22, L=4115.48, H=4137.38, sig='')` vs :02 `(C=4125.78, L=4116.84, H=4137.38, sig='Trend S')` |
| `#194` | `2026-06-29 13:02` | `2026-06-29 11:00` | `SELL` `Trend S` | `4035.83` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=4036.86, L=4027.54, H=4039.71, sig='')` vs :02 `(C=4035.76, L=4027.54, H=4039.71, sig='Trend S')` |
| `#195` | `2026-07-02 01:02` | `2026-07-01 23:00` | `BUY` `Trend L` | `4043.84` | `SHIFTED_1_2 (Trend, -2h)` | Bar `:02` vs `:00` | :00 `(C=4045.03, L=4033.02, H=4045.18, sig='')` vs :02 `(C=4043.80, L=4035.19, H=4045.18, sig='Trend L')` |
| `#197` | `2026-07-09 10:02` | `2026-07-09 08:00` | `BUY` `Trend L` | `4106.22` | `SHIFTED_3_6 (Trend, +3h)` | Bar `:02` vs `:00` | :00 `(C=4108.07, L=4101.69, H=4111.25, sig='')` vs :02 `(C=4106.18, L=4101.69, H=4111.25, sig='Trend L')` |
| `#201` | `2026-07-24 09:02` | `2026-07-24 07:00` | `SELL` `Trend S` | `4037.68` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=4035.73, L=4023.04, H=4039.08, sig='')` vs :02 `(C=4037.82, L=4023.69, H=4039.08, sig='Trend S')` |
| `#202` | `2026-07-24 17:02` | `2026-07-24 15:00` | `BUY` `Trend L` | `4065.96` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=4063.38, L=4055.96, H=4070.15, sig='')` vs :02 `(C=4065.89, L=4055.96, H=4069.43, sig='Trend L')` |
| `#205` | `2026-07-29 21:02` | `2026-07-29 19:00` | `BUY` `Trend L` | `4113.87` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=4106.76, L=4042.87, H=4109.99, sig='')` vs :02 `(C=4114.40, L=4052.21, H=4116.05, sig='Trend L')` |
| `#208` | `2026-08-04 18:02` | `2026-08-04 16:00` | `BUY` `Trend L` | `4086.72` | `SHIFTED_1_2 (Trend, -2h)` | Bar `:02` vs `:00` | :00 `(C=4087.37, L=4074.60, H=4088.86, sig='')` vs :02 `(C=4086.66, L=4074.60, H=4088.86, sig='Trend L')` |
| `#209` | `2026-08-05 15:02` | `2026-08-05 13:00` | `SELL` `Rev S` | `4188.86` | `SHIFTED_3_6 (Rev, +3h)` | Bar `:02` vs `:00` | :00 `(C=4183.92, L=4183.27, H=4213.51, sig='')` vs :02 `(C=4188.97, L=4183.27, H=4213.51, sig='Rev S')` |
| `#214` | `2026-08-14 18:02` | `2026-08-14 16:00` | `BUY` `Trend L` | `4394.58` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=4391.63, L=4379.13, H=4394.84, sig='')` vs :02 `(C=4394.55, L=4379.13, H=4396.82, sig='Trend L')` |
| `#218` | `2026-08-21 20:02` | `2026-08-21 18:00` | `SELL` `Rev S` | `4622.06` | `UNMATCHED_REV_FLAT` | Bar `:02` vs `:00` | :00 `(C=4620.61, L=4615.31, H=4632.18, sig='')` vs :02 `(C=4622.14, L=4615.31, H=4632.18, sig='Rev S')` |
| `#221` | `2026-09-01 16:02` | `2026-09-01 14:00` | `SELL` `Trend S` | `4362.05` | `SHIFTED_1_2 (Trend, +1h)` | Bar `:02` vs `:00` | :00 `(C=4365.24, L=4326.20, H=4367.28, sig='')` vs :02 `(C=4361.96, L=4326.20, H=4371.03, sig='Trend S')` |
| `#227` | `2026-09-18 09:02` | `2026-09-18 07:00` | `BUY` `Trend L` | `4393.37` | `SHIFTED_1_2 (Trend, +2h)` | Bar `:02` vs `:00` | :00 `(C=4393.56, L=4377.23, H=4397.38, sig='')` vs :02 `(C=4393.46, L=4379.70, H=4397.38, sig='Trend L')` |
| `#228` | `2026-09-22 09:02` | `2026-09-22 07:00` | `SELL` `Trend S` | `4318.62` | `UNMATCHED_TREND_FLAT` | Bar `:02` vs `:00` | :00 `(C=4318.44, L=4314.87, H=4324.28, sig='')` vs :02 `(C=4318.66, L=4314.87, H=4323.34, sig='Trend S')` |
| `#233` | `2026-10-14 13:02` | `2026-10-14 11:00` | `SELL` `Trend S` | `4140.75` | `SHIFTED_1_2 (Trend, +1h)` | Tick boundary (also shifted/missed in `:02`) | :00 `(C=4140.84, L=4138.49, H=4145.58, sig='')` vs :02 `(C=4140.82, L=4138.49, H=4145.58, sig='')` |
| `#235` | `2026-10-19 19:02` | `2026-10-19 17:00` | `SELL` `Trend S` | `4138.32` | `SHIFTED_1_2 (Trend, -2h)` | Bar `:02` vs `:00` | :00 `(C=4141.02, L=4136.98, H=4144.83, sig='')` vs :02 `(C=4138.29, L=4136.98, H=4144.83, sig='Trend S')` |
| `#239` | `2026-11-04 15:02` | `2026-11-04 13:00` | `BUY` `Trend L` | `4047.36` | `SHIFTED_3_6 (Trend, -3h)` | Bar `:02` vs `:00` | :00 `(C=4043.59, L=4031.98, H=4051.54, sig='')` vs :02 `(C=4047.26, L=4031.98, H=4051.54, sig='Trend L')` |
| `#240` | `2026-11-05 08:02` | `2026-11-05 06:00` | `SELL` `Rev S` | `4115.18` | `SHIFTED_1_2 (Rev, -1h)` | Bar `:02` vs `:00` | :00 `(C=4114.63, L=4109.04, H=4140.84, sig='')` vs :02 `(C=4115.24, L=4109.04, H=4140.40, sig='Rev S')` |
| `#243` | `2026-11-11 18:02` | `2026-11-11 16:00` | `SELL` `Trend S` | `4003.34` | `BLOCKED_SAME_DIR` | Bar `:02` vs `:00` | :00 `(C=4005.09, L=4000.73, H=4018.68, sig='')` vs :02 `(C=4003.41, L=4000.73, H=4018.68, sig='Trend S')` |
| `#244` | `2026-11-12 12:02` | `2026-11-12 10:00` | `BUY` `Rev L` | `3944.13` | `BLOCKED_OPP_DIR` | Post-cutoff `2026-11-12` | :00 `(C=3943.83, sig='')`; after M1 range |

</details>

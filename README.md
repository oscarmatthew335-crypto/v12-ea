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

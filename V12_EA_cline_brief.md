# Cline brief: V12 gold Expert Advisor for MT5 (exact port of V12_STRAT.pine)

## Goal
Port the TradingView strategy `V12_STRAT.pine` (attached, the source of truth) to an MQL5 Expert Advisor, `V12_EA.mq5`, that trades XAUUSD 1h on an Exness MT5 account running on a VPS.

**The maths must match the Pine script exactly.** Do not "improve", simplify or re-interpret any rule. If something in the Pine code is ambiguous, stop and ask; don't guess.

Work on a branch `feature/v12-ea`, commit as you go, push, and stop for review. Do not merge.

## Files to produce
- `V12_EA.mq5`: the EA.
- `V12_Indicators.mqh`: the indicator maths (ATR, EMA, DF gauge, percentile rank, highest/lowest), as pure functions over price arrays, so they can be unit-checked.
- `V12_Debug.mq5`: a script that writes a per-bar CSV (see "Parity checks").
- `README.md`: install, inputs, VPS setup, Telegram setup, parity-test steps.

## Execution model (must replicate Pine's)
- All logic runs **once per closed H1 bar**, on the first tick of the new bar. Bar `t` = the bar that just closed. Use closed-bar data only. Never act on the forming bar.
- Pine fills orders at the **open of the next bar**. So the EA sends market orders on the first tick of bar `t+1`, using levels calculated from bar `t`.
- Stops and targets calculated on bar `t` apply from bar `t+1` onward. Set them as **broker-side SL/TP on the position** (so a VPS outage doesn't leave a trade unprotected), and modify them once per bar.
- One position at a time for this EA (identify it by its magic number). Pyramiding is off.

## Inputs (defaults = Pine defaults; keep the same names)
| Input | Default |
|---|---|
| trail_len | 10 |
| sl_atr | 2.0 |
| atr_len | 14 |
| bo_len | 20 |
| retest_win | 10 |
| retest_tol | 0.25 |
| use_trend | true |
| ema_len | 200 |
| df_mode | Both (enum: Off / Skip / Exit / Both) |
| hook_lb | 10 |
| df_len | 100 |
| df_tol | 0.07 |
| norm_len | 200 |
| pct_cut | 85.0 |
| rev_mode | Only after a V12 hook exit (enum: Off / AfterHookExit / EveryHook) |
| rev_sbars | 5 |
| rev_buf | 0.25 |
| rev_max | 24 |

Only the "Trailing channel" exit and "Retest" entry need porting; leave out Fixed R, One-step lock, Break mode and sessions. The reversal target is "Trend EMA" with the Fixed R fallback (`rev_rr` = 1.5), which is still needed inside `f_open_rev`.

EA-only inputs:
- `lot_mode`: Fixed / RiskUSD. `fixed_lot` = 0.01. `risk_usd` = 30. Risk lot = risk_usd ÷ (stop distance × contract size), rounded **down** to the volume step, minimum = the symbol's minimum volume.
- `max_loss_usd`: hard cap per trade. If the calculated loss at the stop exceeds it, reduce the lot. If the minimum lot still exceeds it, skip the trade and send a Telegram message.
- `magic` = 1212. `slippage_points` input.
- `halt_dd_R` = 15: the kill switch (see below).
- Telegram: `tg_enable`, `tg_token`, `tg_chat_id`.

## Indicator maths (exact formulas)
Arrays are indexed so that `[0]` = the bar that just closed, `[1]` = the one before, and so on. Use the chart's own OHLC (bid).

1. **ATR = Wilder's RMA of True Range**, as Pine's `ta.atr`. **Do NOT use `iATR`**: MT5's iATR is a simple average and won't match.
   TR = max(high − low, |high − prev close|, |low − prev close|). RMA: alpha = 1/len, seeded with the SMA of the first `len` values.
2. **EMA(close, 200)**: alpha = 2/(len+1), seeded with the SMA of the first `len` values. Use at least 3,000 bars of warm-up history so the seed doesn't matter.
3. **Range levels:** `range_hi = highest(high, 20)` over bars [1]..[20] (i.e. excluding bar [0]). `range_lo` likewise with lows.
4. **fresh_up** = close[0] > range_hi[0] AND close[1] <= range_hi[1], where range_hi[1] is the same calculation one bar earlier (bars [2]..[21]). **fresh_dn** mirrors it.
5. **Trail levels:** `trail_lo = lowest(low, trail_len)` over bars [1]..[trail_len]; `trail_hi` likewise. (Pine: `ta.lowest(low, trail_len)[1]`.)
6. **Reversal extremes:** `rev_hi = highest(high, 5)` over bars [0]..[4], **including** bar [0]. `rev_lo` likewise.
7. **DF gauge** (over `df_len` = 100 bars; every `sma` is the plain mean of the last 100 values ending at bar [0]):
   ```
   y      = close
   dy     = y[0] - y[1]
   y_lag  = y[1]
   mean_dy   = sma(dy, 100)
   mean_ylag = sma(y_lag, 100)
   covar     = sma(dy*y_lag, 100) - mean_dy*mean_ylag
   var_y     = sma(y_lag*y_lag, 100) - mean_ylag*mean_ylag
   beta      = var_y == 0 ? 0 : covar / var_y
   alpha     = mean_dy - beta*mean_ylag
   res       = dy - (alpha + beta*y_lag)          // a per-bar series
   mse       = sma(res*res, 100)                  // mean of the last 100 res^2, each res computed with ITS OWN bar's alpha/beta
   se_beta   = (100*var_y) <= 0 ? 0.0001 : sqrt(mse / (100*var_y))
   t_stat    = beta / se_beta
   ```
   Note: `res` on each bar uses that bar's own alpha and beta, so it's a series that has to be stored per bar. Don't recompute old residuals with the current beta. Use doubles throughout; the `sma(y_lag*y_lag)` terms are large numbers, so watch precision.
8. **Percentile rank:** `t_pct` = (count of i in 0..199 where t_stat[0] > t_stat[i]) ÷ 200 × 100. Strictly greater than; i = 0 is itself and never counts.
9. **Hook:** `df_hook = t_stat[0] > 0 AND t_pct >= 85 AND (t_stat[0] - t_stat[1]) < -0.07`.
10. **skip_now** = (df_mode is Skip or Both) AND bars since the last hook <= 10. A hook on bar [0] counts as 0 bars since. No hook in history = 9999.

## State machine (replicate the order in the Pine script exactly)
Persisted state: `lvl_up, bar_up, lvl_dn, bar_dn, stop_px, init_risk, r_stop, r_tgt, rev_bar`, plus the position type (none / trend long "L" / trend short "S" / reversal long "RL" / reversal short "RS").

Per closed bar, in this order:
1. Compute the retest conditions using the **existing** levels (before any update this bar):
   - `retest_long = lvl_up set AND t > bar_up AND low <= lvl_up + 0.25*ATR AND close > lvl_up`
   - `retest_short` mirrors it.
   - `failed_up = lvl_up set AND close < lvl_up − 0.25*ATR`. `expired_up = lvl_up set AND t − bar_up > 10`. Mirror these for the down side.
2. **Hook handling.** If `df_hook`:
   - If in a trend trade and the exit is on (Exit/Both): if rev_mode != Off, `rev_dir` = the opposite of the trend trade; otherwise close the trend trade (comment "DF hook").
   - Else if flat and rev_mode == EveryHook: `rev_dir = close > close[bo_len] ? -1 : 1`.
3. If `rev_dir != 0`, open the reversal (this closes the trend trade on the same fill, i.e. reverse the position):
   ```
   raw  = dir==1 ? rev_lo - 0.25*ATR : rev_hi + 0.25*ATR
   risk = max(|close - raw|, 0.5*ATR)
   r_stop = dir==1 ? close - risk : close + risk
   ema_ok = dir==1 ? EMA > close : EMA < close
   r_tgt  = ema_ok ? EMA : (dir==1 ? close + 1.5*risk : close - 1.5*risk)
   rev_bar = t ; did_rev = true
   ```
   All of these use bar [0]'s close. The stop and target are absolute prices, not distances from the fill.
4. **Trend entries:** `flat = no position AND NOT did_rev`. `go_long = flat AND retest_long AND NOT skip_now`. `go_short = flat AND retest_short AND NOT go_long AND NOT skip_now`. The EMA filter has already been applied when the level was set (step 6).
   On entry: `init_risk = 2*ATR`, `stop_px = close ∓ init_risk` (from bar [0]'s close, as an absolute price).
5. **Level resets:** if go_long OR failed_up OR expired_up, clear lvl_up. Mirror for dn.
6. **New levels:** if `fresh_up AND (NOT use_trend OR close > EMA)`, set `lvl_up = range_hi`, `bar_up = t`, clear lvl_dn. If `fresh_dn AND (NOT use_trend OR close < EMA)`, set `lvl_dn = range_lo`, `bar_dn = t`, clear lvl_up. (This runs after step 5, in this order.)
7. **Trailing:** if in a trend trade AND NOT did_rev: long `stop_px = max(stop_px, trail_lo)`; short `stop_px = min(stop_px, trail_hi)`.
   Careful: "in a trend trade" means the position that was open **at the start of this bar's processing**, as in Pine. A trade entered this bar (step 4) is not yet open, so it isn't trailed this bar.
8. **Reversal target follows the EMA:** if in a reversal trade AND the EMA is on the profit side of close, `r_tgt = EMA`.
9. **Reversal time exit:** if in a reversal trade AND t − rev_bar >= 24, close it at market ("Rev time").
10. Apply: send any entry or close orders at the next bar's open, and set or modify the broker SL (and the TP for reversals) to the new values.

## Restart safety (critical)
The retest levels and the bars-since-hook count depend on history. **On `OnInit`, rebuild state by replaying the last 3,000+ closed bars through the same per-bar function in simulation mode** (no orders). Then reconcile with the actual open position (found by magic number; read its type from the order comment "L"/"S"/"RL"/"RS"), and restore `stop_px`, `r_stop`, `r_tgt` and `rev_bar` from the position's SL/TP and open time. Use the same function for live and replay, so there is only one copy of the logic.

## Kill switch
Track closed-trade R (profit ÷ initial risk in $). If the drawdown from the peak cumulative R reaches `halt_dd_R` (15), stop opening new trades (still manage any open trade), send a Telegram alert, and stay halted until the input is reset.

## Telegram
Send a message on: entry (type, price, SL, lot, risk $), every SL modification, every exit (reason, R, $), skip events, the kill switch, and EA start/restart (with the reconciled state). Use `WebRequest`. The README must explain adding `https://api.telegram.org` to MT5's allowed URLs. **Never commit the token to git**; it's an input only.

## Parity checks (acceptance criteria)
1. `V12_Debug.mq5` writes a CSV for 2025-01-01 to now: time, OHLC, ATR, EMA, range_hi, range_lo, t_stat, t_pct, df_hook, lvl_up, lvl_dn, and the signal for each bar.
2. I'll export the same values from TradingView. The ATR, EMA and t_stat values must match to 4 significant figures **when calculated on the same price data**. (Feed differences between Exness and TradingView's IC feed are expected; the maths must match on identical input. To check this, add an option to the debug script that reads OHLC from a CSV instead of the chart.)
3. Strategy Tester (H1, "Every tick based on real ticks", 2025-01-01 to now): export the trade list. It should match the TradingView V12_STRAT trade list on direction and entry bar for at least 90% of trades. List every mismatch with the reason (feed difference vs logic bug).

## Out of scope
No AI layers, no webhooks, no TradingView connection. Don't change any trading rule. Don't add filters.

//+------------------------------------------------------------------+
//|                                                       V12_EA.mq5 |
//|   Exact MQL5 port of V12_STRAT.pine for XAUUSD H1 (Exness MT5)   |
//+------------------------------------------------------------------+
#property copyright "V12 EA"
#property version   "1.00"
#property strict

#include "V12_Indicators.mqh"

//+------------------------------------------------------------------+
//| Strategy Inputs (names & defaults match V12_STRAT.pine)          |
//+------------------------------------------------------------------+
input group "Stop loss (trend trades)"
input int           trail_len  = 10;     // Trailing stop: lowest low / highest high of last N bars
input double        sl_atr     = 2.0;    // Initial stop (x ATR)
input int           atr_len    = 14;     // ATR length

input group "Breakout"
input int           bo_len     = 20;     // Breakout range (bars)
input int           retest_win = 10;     // Retest must happen within (bars)
input double        retest_tol = 0.25;   // Retest tolerance (x ATR)

input group "Trend filter"
input bool          use_trend  = true;   // Trade only with the EMA trend
input int           ema_len    = 200;    // EMA length

input group "DF climax filter (TVR_TENSION hook)"
input ENUM_DF_MODE  df_mode    = DF_BOTH; // Use DF hook
input int           hook_lb    = 10;     // Skip entries for (bars after a hook)
input int           df_len     = 100;    // DF window
input double        df_tol     = 0.07;   // Flatness tolerance
input int           norm_len   = 200;    // Percentile lookback
input double        pct_cut    = 85.0;   // Percentile cutoff (%)

input group "DF reversal trades"
input ENUM_REV_MODE rev_mode   = REV_AFTER_HOOK_EXIT; // Reversal trade on a DF hook
input int           rev_sbars  = 5;      // Reversal stop beyond extreme of last N bars
input double        rev_buf    = 0.25;   // Reversal stop buffer (x ATR)
input double        rev_rr     = 1.5;    // Reversal Fixed R fallback target
input int           rev_max    = 24;     // Close a reversal after (bars) if still open

input group "EA Money Management & Execution"
input ENUM_LOT_MODE lot_mode        = LOT_RISK_USD; // Position sizing mode
input double        fixed_lot       = 0.01;         // Fixed lot size
input double        risk_usd        = 30.0;         // Risk per trade (USD)
input double        max_loss_usd    = 100.0;        // Hard max loss cap per trade (USD)
input ulong         magic           = 1212;         // EA Magic Number
input int           slippage_points = 50;           // Max slippage (points)
input double        halt_dd_R       = 15.0;         // Kill switch max R drawdown from peak

input group "Telegram Notifications"
input bool          tg_enable  = false;  // Enable Telegram alerts
input string        tg_token   = "";     // Telegram Bot Token (keep secret)
input string        tg_chat_id = "";     // Telegram Chat ID

//+------------------------------------------------------------------+
//| Global State                                                     |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING g_filling_mode = ORDER_FILLING_IOC;
V12_Params     g_params;
V12_State      g_state;
datetime       g_last_bar_time      = 0;
int            g_bar_t              = 0;

ulong          g_active_ticket      = 0;
long           g_active_pos_id      = 0;
double         g_active_init_risk   = 0.0;

double         g_cum_R              = 0.0;
double         g_peak_R             = 0.0;
bool           g_halted             = false;

const int      V12_REPLAY_BARS      = 3200; // Replayed closed bars (> 3,000 required)

//+------------------------------------------------------------------+
//| GlobalVariable key helper (scoped per magic + symbol + account)  |
//+------------------------------------------------------------------+
string GVKey(const string suffix)
{
   return StringFormat("V12_%I64u_%s_%I64d_%s",
                       magic, _Symbol, AccountInfoInteger(ACCOUNT_LOGIN), suffix);
}

bool ShouldPersistGlobals()
{
   return (!MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_OPTIMIZATION));
}

void SaveKillSwitchGlobals()
{
   if(!ShouldPersistGlobals())
      return;
   GlobalVariableSet(GVKey("CUM_R"), g_cum_R);
   GlobalVariableSet(GVKey("PEAK_R"), g_peak_R);
   GlobalVariableSet(GVKey("HALTED"), g_halted ? 1.0 : 0.0);
   GlobalVariableSet(GVKey("HALT_CFG"), halt_dd_R);
}

void SaveActivePosGlobals()
{
   if(!ShouldPersistGlobals())
      return;
   GlobalVariableSet(GVKey("ACT_POS_ID"), (double)g_active_pos_id);
   GlobalVariableSet(GVKey("ACT_RISK_USD"), g_active_init_risk);
}

//+------------------------------------------------------------------+
//| Telegram WebRequest helper (JSON-escaped, token never logged)    |
//+------------------------------------------------------------------+
string EscapeJson(const string s)
{
   string out = s;
   StringReplace(out, "\\", "\\\\");
   StringReplace(out, "\"", "\\\"");
   StringReplace(out, "\r", "\\r");
   StringReplace(out, "\n", "\\n");
   StringReplace(out, "\t", "\\t");
   return out;
}

void SendTelegram(const string text)
{
   if(!tg_enable || tg_token == "" || tg_chat_id == "")
      return;
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION))
      return;

   string url     = "https://api.telegram.org/bot" + tg_token + "/sendMessage";
   string headers = "Content-Type: application/json\r\n";
   string payload = "{\"chat_id\":\"" + EscapeJson(tg_chat_id) +
                    "\",\"text\":\"" + EscapeJson(text) + "\"}";

   char data[];
   int len = StringToCharArray(payload, data, 0, WHOLE_ARRAY, CP_UTF8);
   if(len > 0)
      ArrayResize(data, len - 1); // strip trailing null byte

   char   result[];
   string res_headers = "";
   ResetLastError();
   int code = WebRequest("POST", url, headers, 5000, data, result, res_headers);
   if(code != 200)
   {
      int err = GetLastError();
      PrintFormat("V12_EA: Telegram WebRequest failed (HTTP=%d, err=%d). Check Allowed URLs.", code, err);
   }
}

//+------------------------------------------------------------------+
//| Build params struct from EA inputs                               |
//+------------------------------------------------------------------+
void LoadParams(V12_Params &p)
{
   p.trail_len  = trail_len;
   p.sl_atr     = sl_atr;
   p.atr_len    = atr_len;
   p.bo_len     = bo_len;
   p.retest_win = retest_win;
   p.retest_tol = retest_tol;
   p.use_trend  = use_trend;
   p.ema_len    = ema_len;
   p.df_mode    = df_mode;
   p.hook_lb    = hook_lb;
   p.df_len     = df_len;
   p.df_tol     = df_tol;
   p.norm_len   = norm_len;
   p.pct_cut    = pct_cut;
   p.rev_mode   = rev_mode;
   p.rev_sbars  = rev_sbars;
   p.rev_buf    = rev_buf;
   p.rev_rr     = rev_rr;
   p.rev_max    = rev_max;
}

//+------------------------------------------------------------------+
//| Detect symbol filling mode & direct OrderSend wrappers           |
//+------------------------------------------------------------------+
void ConfigureTradeObject()
{
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) != 0)
      g_filling_mode = ORDER_FILLING_IOC;
   else if((filling & SYMBOL_FILLING_FOK) != 0)
      g_filling_mode = ORDER_FILLING_FOK;
   else
      g_filling_mode = ORDER_FILLING_RETURN;
}

bool SendOrderChecked(const MqlTradeRequest &req, MqlTradeResult &res, const string action_name)
{
   ZeroMemory(res);
   if(!OrderSend(req, res))
   {
      PrintFormat("V12_EA: %s OrderSend failed err=%d retcode=%u (%s)",
                  action_name, GetLastError(), res.retcode, res.comment);
      return false;
   }
   if(res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED && res.retcode != TRADE_RETCODE_DONE_PARTIAL)
   {
      PrintFormat("V12_EA: %s rejected retcode=%u (%s)", action_name, res.retcode, res.comment);
      return false;
   }
   return true;
}

bool V12_SendMarketOrder(ENUM_ORDER_TYPE order_type, double volume, double price,
                         double sl, double tp, const string comment, double &out_price)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = volume;
   req.type         = order_type;
   req.price        = price;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = (ulong)MathMax(0, slippage_points);
   req.magic        = magic;
   req.comment      = comment;
   req.type_filling = g_filling_mode;

   if(!SendOrderChecked(req, res, "Open " + comment))
      return false;
   out_price = (res.price > 0.0) ? res.price : price;
   return true;
}

bool V12_ClosePositionByTicket(ulong ticket, ENUM_POSITION_TYPE pos_type, double vol)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = _Symbol;
   req.volume       = vol;
   req.type         = (pos_type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price        = (pos_type == POSITION_TYPE_BUY)
                      ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                      : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   req.deviation    = (ulong)MathMax(0, slippage_points);
   req.magic        = magic;
   req.type_filling = g_filling_mode;

   return SendOrderChecked(req, res, "Close");
}

bool V12_ModifyPositionSLTP(ulong ticket, double sl, double tp)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = _Symbol;
   req.sl       = sl;
   req.tp       = tp;
   req.magic    = magic;

   return SendOrderChecked(req, res, "Modify SL/TP");
}

//+------------------------------------------------------------------+
//| Normalize lot to symbol step & limits                            |
//+------------------------------------------------------------------+
int VolumeDigits(double step)
{
   if(step <= 0.0)
      return 2;
   int d = 0;
   double v = step;
   while(d < 8 && MathAbs(v - MathRound(v)) > 1e-8)
   {
      v *= 10.0;
      d++;
   }
   return d;
}

double RoundDownLot(double raw_lot)
{
   double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot_step <= 0.0)
      lot_step = 0.01;

   double steps = MathFloor((raw_lot + 1e-9) / lot_step);
   double lot   = steps * lot_step;
   if(lot < min_lot)
      lot = min_lot;
   if(lot > max_lot)
      lot = max_lot;
   return NormalizeDouble(lot, VolumeDigits(lot_step));
}

//+------------------------------------------------------------------+
//| Calculate trade lot size & enforce max_loss_usd cap              |
//+------------------------------------------------------------------+
bool CalculateOrderLot(double entry_px, double sl_px, const string side_label,
                       double &out_lot, double &out_risk_usd)
{
   out_lot      = 0.0;
   out_risk_usd = 0.0;

   double stop_dist     = MathAbs(entry_px - sl_px);
   double contract_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double min_lot       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step      = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lot_step <= 0.0)
      lot_step = 0.01;

   if(stop_dist <= 0.0 || contract_size <= 0.0)
   {
      PrintFormat("V12_EA: Invalid stop_dist=%.5f or contract_size=%.2f", stop_dist, contract_size);
      return false;
   }

   double loss_per_lot = stop_dist * contract_size;
   double lot = 0.0;
   if(lot_mode == LOT_FIXED)
   {
      lot = RoundDownLot(fixed_lot);
   }
   else
   {
      double raw_lot = risk_usd / loss_per_lot;
      lot = RoundDownLot(raw_lot);
   }

   double calc_loss = lot * loss_per_lot;

   // Enforce hard max_loss_usd cap
   if(max_loss_usd > 0.0 && calc_loss > max_loss_usd)
   {
      double capped_raw   = max_loss_usd / loss_per_lot;
      double capped_steps = MathFloor((capped_raw + 1e-9) / lot_step);
      double capped_lot   = NormalizeDouble(capped_steps * lot_step, VolumeDigits(lot_step));
      double min_lot_loss = min_lot * loss_per_lot;

      if(capped_lot < min_lot || min_lot_loss > max_loss_usd)
      {
         string msg = StringFormat("[V12 %s] SKIPPED %s: min lot (%.2f) loss $%.2f exceeds max_loss_usd $%.2f (stop=%.2f)",
                                   _Symbol, side_label, min_lot, min_lot_loss, max_loss_usd, stop_dist);
         Print("V12_EA: ", msg);
         SendTelegram(msg);
         return false;
      }

      if(capped_lot > max_lot)
         capped_lot = max_lot;
      lot = capped_lot;
      calc_loss = lot * loss_per_lot;
   }

   out_lot      = lot;
   out_risk_usd = calc_loss;
   return true;
}

//+------------------------------------------------------------------+
//| Find active position belonging to this EA (by symbol & magic)    |
//+------------------------------------------------------------------+
bool FindOpenPosition(ulong &out_ticket, long &out_pos_id, ENUM_POSITION_TYPE &out_type,
                      double &out_sl, double &out_tp, double &out_open_px,
                      datetime &out_open_time, double &out_vol, string &out_comment)
{
   out_ticket    = 0;
   out_pos_id    = 0;
   out_type      = POSITION_TYPE_BUY;
   out_sl        = 0.0;
   out_tp        = 0.0;
   out_open_px   = 0.0;
   out_open_time = 0;
   out_vol       = 0.0;
   out_comment   = "";

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != magic)
         continue;

      out_ticket    = ticket;
      out_pos_id    = PositionGetInteger(POSITION_IDENTIFIER);
      out_type      = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      out_sl        = PositionGetDouble(POSITION_SL);
      out_tp        = PositionGetDouble(POSITION_TP);
      out_open_px   = PositionGetDouble(POSITION_PRICE_OPEN);
      out_open_time = (datetime)PositionGetInteger(POSITION_TIME);
      out_vol       = PositionGetDouble(POSITION_VOLUME);
      out_comment   = PositionGetString(POSITION_COMMENT);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Parse EA position identifier ("L", "S", "RL", "RS")              |
//+------------------------------------------------------------------+
string ParseEntryId(const string comment, ENUM_POSITION_TYPE pos_type, double pos_tp)
{
   if(comment == "L" || comment == "S" || comment == "RL" || comment == "RS")
      return comment;
   if(StringFind(comment, "RL") == 0) return "RL";
   if(StringFind(comment, "RS") == 0) return "RS";
   if(StringFind(comment, "L")  == 0) return "L";
   if(StringFind(comment, "S")  == 0) return "S";

   if(pos_tp > 0.0)
      return (pos_type == POSITION_TYPE_BUY) ? "RL" : "RS";
   return (pos_type == POSITION_TYPE_BUY) ? "L" : "S";
}

//+------------------------------------------------------------------+
//| Record closed position R & evaluate Kill Switch                  |
//+------------------------------------------------------------------+
void RecordClosedPosition(long pos_id, const string exit_reason, double known_init_risk_usd)
{
   if(pos_id <= 0)
      return;

   if(ShouldPersistGlobals())
   {
      double last_id = GlobalVariableCheck(GVKey("LAST_CLOSED_ID")) ? GlobalVariableGet(GVKey("LAST_CLOSED_ID")) : 0.0;
      if((long)last_id == pos_id)
         return;
   }

   if(!HistorySelectByPosition(pos_id))
      return;

   int    deals       = HistoryDealsTotal();
   double net_profit  = 0.0;
   double close_price = 0.0;
   long   deal_reason = -1;
   bool   has_out     = false;

   for(int i = 0; i < deals; i++)
   {
      ulong deal_ticket = HistoryDealGetTicket(i);
      if(deal_ticket == 0)
         continue;
      if(HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID) != pos_id)
         continue;

      long entry_type = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY);
      net_profit += HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
      net_profit += HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
      net_profit += HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);

      if(entry_type == DEAL_ENTRY_OUT || entry_type == DEAL_ENTRY_OUT_BY)
      {
         close_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
         deal_reason = HistoryDealGetInteger(deal_ticket, DEAL_REASON);
         has_out     = true;
      }
   }

   if(!has_out)
      return;

   string reason_str = exit_reason;
   if(reason_str == "")
   {
      if(deal_reason == DEAL_REASON_SL)      reason_str = "Broker SL";
      else if(deal_reason == DEAL_REASON_TP) reason_str = "Broker TP";
      else                                   reason_str = "Closed";
   }

   double denom = (known_init_risk_usd > 0.0) ? known_init_risk_usd : (risk_usd > 0.0 ? risk_usd : 1.0);
   double r_mult = net_profit / denom;

   g_cum_R += r_mult;
   if(g_cum_R > g_peak_R)
      g_peak_R = g_cum_R;
   double dd_R = g_peak_R - g_cum_R;

   if(ShouldPersistGlobals())
      GlobalVariableSet(GVKey("LAST_CLOSED_ID"), (double)pos_id);

   string exit_msg = StringFormat("[V12 %s] EXIT (%s) @ %.2f | PnL: $%.2f (%.2f R) | CumR: %.2f | PeakR: %.2f | DD: %.2fR",
                                  _Symbol, reason_str, close_price, net_profit, r_mult, g_cum_R, g_peak_R, dd_R);
   Print("V12_EA: ", exit_msg);
   SendTelegram(exit_msg);

   if(!g_halted && halt_dd_R > 0.0 && dd_R >= halt_dd_R)
   {
      g_halted = true;
      string halt_msg = StringFormat("[V12 %s] KILL SWITCH TRIGGERED! Drawdown %.2fR >= %.2fR. New entries halted until halt_dd_R input is reset.",
                                     _Symbol, dd_R, halt_dd_R);
      Print("V12_EA: ", halt_msg);
      SendTelegram(halt_msg);
   }

   SaveKillSwitchGlobals();
}

//+------------------------------------------------------------------+
//| Close open position at market                                    |
//+------------------------------------------------------------------+
bool CloseActivePosition(const string reason)
{
   ulong ticket; long pos_id; ENUM_POSITION_TYPE pos_type;
   double sl, tp, open_px, vol; datetime open_time; string comment;

   if(!FindOpenPosition(ticket, pos_id, pos_type, sl, tp, open_px, open_time, vol, comment))
      return true;

   double risk_for_trade = g_active_init_risk;
   if(risk_for_trade <= 0.0 && sl > 0.0)
      risk_for_trade = MathAbs(open_px - sl) * vol * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);

   if(!V12_ClosePositionByTicket(ticket, pos_type, vol))
      return false;

   RecordClosedPosition(pos_id, reason, risk_for_trade);
   g_active_ticket    = 0;
   g_active_pos_id    = 0;
   g_active_init_risk = 0.0;
   g_state.pos_dir    = 0;
   g_state.eid        = "";
   SaveActivePosGlobals();
   return true;
}

//+------------------------------------------------------------------+
//| Open a new market position with broker SL/TP                     |
//+------------------------------------------------------------------+
bool OpenMarketPosition(int dir, const string eid, double sl_raw, double tp_raw)
{
   if(g_halted)
   {
      string msg = StringFormat("[V12 %s] ENTRY BLOCKED (%s): Kill switch active (DD=%.2fR >= %.2fR)",
                                _Symbol, eid, g_peak_R - g_cum_R, halt_dd_R);
      Print("V12_EA: ", msg);
      SendTelegram(msg);
      return false;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry_est = (dir > 0) ? ask : bid;

   double sl_norm = NormalizeDouble(sl_raw, _Digits);
   double tp_norm = (tp_raw > 0.0 && tp_raw != EMPTY_VALUE) ? NormalizeDouble(tp_raw, _Digits) : 0.0;

   double stops_dist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   // Verify SL is on the valid side of market (Buy SL checked vs Bid; Sell SL checked vs Ask)
   if((dir > 0 && sl_norm >= bid - stops_dist) ||
      (dir < 0 && sl_norm <= ask + stops_dist))
   {
      string msg = StringFormat("[V12 %s] SKIPPED %s: market (bid=%.2f/ask=%.2f) already at/past SL %.2f",
                                _Symbol, eid, bid, ask, sl_norm);
      Print("V12_EA: ", msg);
      SendTelegram(msg);
      return false;
   }

   // Verify TP is on the valid side of market if set
   if(tp_norm > 0.0)
   {
      if((dir > 0 && tp_norm <= ask + stops_dist) ||
         (dir < 0 && tp_norm >= bid - stops_dist))
      {
         string msg = StringFormat("[V12 %s] SKIPPED %s: market (bid=%.2f/ask=%.2f) already at/past TP %.2f",
                                   _Symbol, eid, bid, ask, tp_norm);
         Print("V12_EA: ", msg);
         SendTelegram(msg);
         return false;
      }
   }

   double lot = 0.0, trade_risk_usd = 0.0;
   if(!CalculateOrderLot(entry_est, sl_norm, eid, lot, trade_risk_usd))
      return false;

   double fill_px = 0.0;
   ENUM_ORDER_TYPE otype = (dir > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!V12_SendMarketOrder(otype, lot, entry_est, sl_norm, tp_norm, eid, fill_px))
      return false;

   if(fill_px <= 0.0)
      fill_px = entry_est;

   // Re-read position info to get exact ticket, pos_id, and fill price
   ulong ticket; long pos_id; ENUM_POSITION_TYPE pos_type;
   double p_sl, p_tp, p_open, p_vol; datetime p_time; string p_comment;
   if(FindOpenPosition(ticket, pos_id, pos_type, p_sl, p_tp, p_open, p_time, p_vol, p_comment))
   {
      g_active_ticket    = ticket;
      g_active_pos_id    = pos_id;
      fill_px            = p_open;
      double contract_sz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      g_active_init_risk = MathAbs(fill_px - sl_norm) * p_vol * contract_sz;
      if(g_active_init_risk <= 0.0)
         g_active_init_risk = trade_risk_usd;
      g_state.pos_dir = dir;
      g_state.eid     = eid;
      SaveActivePosGlobals();
   }

   string entry_msg = StringFormat("[V12 %s] ENTRY %s @ %.2f | Lot: %.2f | SL: %.2f | TP: %s | Risk: $%.2f",
                                   _Symbol, eid, fill_px, lot, sl_norm,
                                   (tp_norm > 0.0 ? DoubleToString(tp_norm, _Digits) : "None"),
                                   g_active_init_risk);
   Print("V12_EA: ", entry_msg);
   SendTelegram(entry_msg);
   return true;
}

//+------------------------------------------------------------------+
//| Copy closed H1 bars in series order ([0] = most recently closed) |
//+------------------------------------------------------------------+
bool CopyClosedH1Bars(int count, MqlRates &rates[], double &open[], double &high[],
                      double &low[], double &close[])
{
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_H1, 1, count, rates);
   if(copied < count)
      return false;

   ArrayResize(open, copied);  ArraySetAsSeries(open, true);
   ArrayResize(high, copied);  ArraySetAsSeries(high, true);
   ArrayResize(low, copied);   ArraySetAsSeries(low, true);
   ArrayResize(close, copied); ArraySetAsSeries(close, true);

   for(int i = 0; i < copied; i++)
   {
      open[i]  = rates[i].open;
      high[i]  = rates[i].high;
      low[i]   = rates[i].low;
      close[i] = rates[i].close;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Rebuild strategy state from >=3000 historical closed bars        |
//+------------------------------------------------------------------+
bool RebuildStateFromHistory()
{
   int min_warm    = V12_MinWarmupBars(g_params);
   int total_need  = V12_REPLAY_BARS + min_warm + 50;
   int avail       = iBars(_Symbol, PERIOD_H1) - 1;
   int copy_count  = MathMin(total_need, avail);

   if(copy_count <= min_warm + 10)
   {
      PrintFormat("V12_EA: Insufficient H1 history (%d bars available, need > %d)", avail, min_warm + 10);
      return false;
   }

   MqlRates rates[];
   double open[], high[], low[], close[];
   if(!CopyClosedH1Bars(copy_count, rates, open, high, low, close))
   {
      Print("V12_EA: CopyRates failed during history replay");
      return false;
   }

   V12_SeriesData sd;
   if(!V12_ComputeAllSeries(high, low, close, copy_count, g_params, sd))
   {
      Print("V12_EA: Indicator computation failed during history replay");
      return false;
   }

   g_state.Reset();
   int start_b = copy_count - 1 - min_warm;
   g_bar_t = 0;

   for(int b = start_b; b >= 0; b--)
   {
      g_bar_t++;
      string sim_reason = "";
      double sim_px     = 0.0;
      V12_SimulateIntrabarExit(b, open, high, low, g_state, sim_reason, sim_px);

      V12_BarActions act;
      V12_StepBar(b, g_bar_t, high, low, close, sd, g_params, false, g_state, act);
   }

   g_last_bar_time = rates[0].time;

   // Reconcile with live broker position (truth overrides simulation)
   ulong ticket; long pos_id; ENUM_POSITION_TYPE pos_type;
   double p_sl, p_tp, p_open, p_vol; datetime p_time; string p_comment;
   if(FindOpenPosition(ticket, pos_id, pos_type, p_sl, p_tp, p_open, p_time, p_vol, p_comment))
   {
      string eid = ParseEntryId(p_comment, pos_type, p_tp);
      int    dir = (pos_type == POSITION_TYPE_BUY) ? 1 : -1;

      g_active_ticket = ticket;
      g_active_pos_id = pos_id;
      g_state.pos_dir = dir;
      g_state.eid     = eid;

      double contract_sz = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);

      if(eid == "L" || eid == "S")
      {
         if(p_sl > 0.0)
            g_state.stop_px = p_sl;
         else if(g_state.stop_px == EMPTY_VALUE)
            g_state.stop_px = (dir > 0) ? (p_open - g_params.sl_atr * sd.atr[0]) : (p_open + g_params.sl_atr * sd.atr[0]);
      }
      else
      {
         if(p_sl > 0.0)
            g_state.r_stop = p_sl;
         if(p_tp > 0.0)
            g_state.r_tgt = p_tp;

         // Restore rev_bar relative to g_bar_t using position open time
         int b_fill = -1;
         for(int k = 0; k < copy_count; k++)
         {
            if(rates[k].time <= p_time)
            {
               b_fill = k;
               break;
            }
         }
         int b_sig = (p_time >= rates[0].time + PeriodSeconds(PERIOD_H1)) ? 0 : ((b_fill >= 0) ? (b_fill + 1) : g_params.rev_max);
         g_state.rev_bar = g_bar_t - b_sig;
      }

      // Restore initial $ risk for this position if persisted, else estimate from open vs SL
      if(ShouldPersistGlobals() &&
         GlobalVariableCheck(GVKey("ACT_POS_ID")) &&
         (long)GlobalVariableGet(GVKey("ACT_POS_ID")) == pos_id &&
         GlobalVariableCheck(GVKey("ACT_RISK_USD")))
      {
         g_active_init_risk = GlobalVariableGet(GVKey("ACT_RISK_USD"));
      }
      else if(p_sl > 0.0 && contract_sz > 0.0)
      {
         g_active_init_risk = MathAbs(p_open - p_sl) * p_vol * contract_sz;
      }
      else
      {
         g_active_init_risk = risk_usd;
      }
      SaveActivePosGlobals();
   }
   else
   {
      // If a tracked position closed while EA was offline, record it once
      if(ShouldPersistGlobals() && GlobalVariableCheck(GVKey("ACT_POS_ID")))
      {
         long prev_pos_id = (long)GlobalVariableGet(GVKey("ACT_POS_ID"));
         double prev_risk = GlobalVariableCheck(GVKey("ACT_RISK_USD")) ? GlobalVariableGet(GVKey("ACT_RISK_USD")) : risk_usd;
         if(prev_pos_id > 0)
            RecordClosedPosition(prev_pos_id, "", prev_risk);
      }

      g_active_ticket    = 0;
      g_active_pos_id    = 0;
      g_active_init_risk = 0.0;
      g_state.pos_dir    = 0;
      g_state.eid        = "";
      g_state.stop_px    = EMPTY_VALUE;
      g_state.r_stop     = EMPTY_VALUE;
      g_state.r_tgt      = EMPTY_VALUE;
      g_state.rev_bar    = -1;
      SaveActivePosGlobals();
   }

   return true;
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Period != PERIOD_H1)
      Print("V12_EA: Warning - EA is designed for H1; explicitly reading PERIOD_H1 closed bars.");

   LoadParams(g_params);
   ConfigureTradeObject();

   // Restore Kill Switch state and check if halt_dd_R input was reset
   if(ShouldPersistGlobals() && GlobalVariableCheck(GVKey("CUM_R")))
   {
      g_cum_R  = GlobalVariableGet(GVKey("CUM_R"));
      g_peak_R = GlobalVariableCheck(GVKey("PEAK_R")) ? GlobalVariableGet(GVKey("PEAK_R")) : g_cum_R;
      g_halted = GlobalVariableCheck(GVKey("HALTED")) ? (GlobalVariableGet(GVKey("HALTED")) > 0.5) : false;
      double prev_cfg = GlobalVariableCheck(GVKey("HALT_CFG")) ? GlobalVariableGet(GVKey("HALT_CFG")) : halt_dd_R;

      if(g_halted && (halt_dd_R <= 0.0 || MathAbs(halt_dd_R - prev_cfg) > 1e-6))
      {
         g_halted = false;
         g_peak_R = g_cum_R;
         SaveKillSwitchGlobals();
         Print("V12_EA: Kill switch reset via halt_dd_R input change.");
      }
   }
   else
   {
      g_cum_R  = 0.0;
      g_peak_R = 0.0;
      g_halted = false;
      SaveKillSwitchGlobals();
   }

   if(!RebuildStateFromHistory())
      return INIT_FAILED;

   int bars_since_hook = (g_state.last_hook_bar < 0) ? 9999 : (g_bar_t - g_state.last_hook_bar);
   string up_str = (g_state.lvl_up != EMPTY_VALUE) ? DoubleToString(g_state.lvl_up, _Digits) : "na";
   string dn_str = (g_state.lvl_dn != EMPTY_VALUE) ? DoubleToString(g_state.lvl_dn, _Digits) : "na";
   string pos_str = (g_state.pos_dir == 0) ? "FLAT"
                    : StringFormat("%s (SL=%.2f, TP=%s)",
                                   g_state.eid,
                                   (g_state.eid == "L" || g_state.eid == "S") ? g_state.stop_px : g_state.r_stop,
                                   (g_state.eid == "RL" || g_state.eid == "RS") ? DoubleToString(g_state.r_tgt, _Digits) : "na");

   string start_msg = StringFormat("[V12 %s] EA STARTED | Replayed %d bars | Pos: %s | lvl_up=%s | lvl_dn=%s | HookBars=%d | CumR=%.2f | Halted=%s",
                                   _Symbol, g_bar_t, pos_str, up_str, dn_str, bars_since_hook,
                                   g_cum_R, (g_halted ? "YES" : "NO"));
   Print("V12_EA: ", start_msg);
   SendTelegram(start_msg);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert tick handler — executes strictly once per closed H1 bar   |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime cur_closed_time = iTime(_Symbol, PERIOD_H1, 1);
   if(cur_closed_time == 0 || cur_closed_time == g_last_bar_time)
      return;

   // Check if an active broker position closed via SL/TP during the bar that just finished
   ulong cur_ticket = 0; long cur_pos_id = 0; ENUM_POSITION_TYPE cur_type = POSITION_TYPE_BUY;
   double cur_sl = 0.0, cur_tp = 0.0, cur_open_px = 0.0, cur_vol = 0.0;
   datetime cur_open_time = 0; string cur_comment = "";
   bool has_pos = FindOpenPosition(cur_ticket, cur_pos_id, cur_type, cur_sl, cur_tp,
                                   cur_open_px, cur_open_time, cur_vol, cur_comment);

   if(!has_pos && g_active_pos_id > 0)
   {
      RecordClosedPosition(g_active_pos_id, "", g_active_init_risk);
      g_active_ticket    = 0;
      g_active_pos_id    = 0;
      g_active_init_risk = 0.0;
      g_state.pos_dir    = 0;
      g_state.eid        = "";
      SaveActivePosGlobals();
   }
   else if(has_pos)
   {
      g_active_ticket = cur_ticket;
      g_active_pos_id = cur_pos_id;
      g_state.pos_dir = (cur_type == POSITION_TYPE_BUY) ? 1 : -1;
      g_state.eid     = ParseEntryId(cur_comment, cur_type, cur_tp);
   }

   int need_bars = V12_REPLAY_BARS + V12_MinWarmupBars(g_params) + 50;
   int avail     = iBars(_Symbol, PERIOD_H1) - 1;
   int copy_cnt  = MathMin(need_bars, avail);

   MqlRates rates[];
   double open[], high[], low[], close[];
   if(!CopyClosedH1Bars(copy_cnt, rates, open, high, low, close))
      return; // wait for next tick if history isn't ready

   V12_SeriesData sd;
   if(!V12_ComputeAllSeries(high, low, close, copy_cnt, g_params, sd))
      return;

   g_last_bar_time = cur_closed_time;
   g_bar_t++;

   V12_BarActions act;
   V12_StepBar(0, g_bar_t, high, low, close, sd, g_params, true, g_state, act);

   // Telegram skip notifications
   if(act.skip_long || act.skip_short)
   {
      string skip_msg = StringFormat("[V12 %s] SKIP %s (DF hook cooldown active) @ %.2f",
                                     _Symbol, (act.skip_long ? "Trend L" : "Trend S"), close[0]);
      Print("V12_EA: ", skip_msg);
      SendTelegram(skip_msg);
   }

   // Step 10: Apply exits, reversals, entries, and SL/TP updates on first tick of bar t+1
   bool opened_this_bar = false;

   if(act.close_trend_hook)
   {
      CloseActivePosition("DF hook");
   }

   if(act.open_rev_dir != 0)
   {
      bool closed_ok = true;
      if(has_pos)
         closed_ok = CloseActivePosition(act.open_rev_dir == 1 ? "Rev L" : "Rev S");

      if(closed_ok)
      {
         string rev_eid = (act.open_rev_dir == 1) ? "RL" : "RS";
         opened_this_bar = OpenMarketPosition(act.open_rev_dir, rev_eid, g_state.r_stop, g_state.r_tgt);
      }
   }

   if(act.go_long || act.go_short)
   {
      int    dir = act.go_long ? 1 : -1;
      string eid = act.go_long ? "L" : "S";
      opened_this_bar = OpenMarketPosition(dir, eid, g_state.stop_px, 0.0);
   }

   if(act.close_rev_time)
   {
      CloseActivePosition("Rev time");
   }

   // Manage SL / TP on any remaining open position (once per closed bar)
   if(!opened_this_bar && FindOpenPosition(cur_ticket, cur_pos_id, cur_type, cur_sl, cur_tp,
                                           cur_open_px, cur_open_time, cur_vol, cur_comment))
   {
      double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double stops_dist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

      if(g_state.eid == "L" || g_state.eid == "S")
      {
         double new_sl = NormalizeDouble(g_state.stop_px, _Digits);

         // If t+1 open has already crossed the trailed stop, close immediately to match Pine
         if((cur_type == POSITION_TYPE_BUY && bid <= new_sl) ||
            (cur_type == POSITION_TYPE_SELL && ask >= new_sl))
         {
            CloseActivePosition("Trend exit");
         }
         else
         {
            bool improved = (cur_type == POSITION_TYPE_BUY)
                            ? (new_sl > cur_sl + _Point * 0.5)
                            : (cur_sl == 0.0 || new_sl < cur_sl - _Point * 0.5);
            bool valid_dist = (cur_type == POSITION_TYPE_BUY)
                              ? (bid - new_sl >= stops_dist)
                              : (new_sl - ask >= stops_dist);

            if(improved && valid_dist)
            {
               if(V12_ModifyPositionSLTP(cur_ticket, new_sl, 0.0))
               {
                  string mod_msg = StringFormat("[V12 %s] SL MODIFIED (%s): %.2f -> %.2f",
                                                _Symbol, g_state.eid, cur_sl, new_sl);
                  Print("V12_EA: ", mod_msg);
                  SendTelegram(mod_msg);
               }
            }
         }
      }
      else if(g_state.eid == "RL" || g_state.eid == "RS")
      {
         double new_sl = NormalizeDouble(g_state.r_stop, _Digits);
         double new_tp = NormalizeDouble(g_state.r_tgt, _Digits);

         bool hit_now = (cur_type == POSITION_TYPE_BUY && (bid <= new_sl || (new_tp > 0.0 && bid >= new_tp))) ||
                        (cur_type == POSITION_TYPE_SELL && (ask >= new_sl || (new_tp > 0.0 && ask <= new_tp)));
         if(hit_now)
         {
            CloseActivePosition("Rev exit");
         }
         else
         {
            bool sl_changed = MathAbs(new_sl - cur_sl) >= _Point * 0.5;
            bool tp_changed = MathAbs(new_tp - cur_tp) >= _Point * 0.5;
            bool sl_valid   = (cur_type == POSITION_TYPE_BUY) ? (bid - new_sl >= stops_dist) : (new_sl - ask >= stops_dist);
            bool tp_valid   = (new_tp == 0.0) || ((cur_type == POSITION_TYPE_BUY) ? (new_tp - ask >= stops_dist) : (bid - new_tp >= stops_dist));

            if((sl_changed || tp_changed) && sl_valid && tp_valid)
            {
               if(V12_ModifyPositionSLTP(cur_ticket, new_sl, new_tp))
               {
                  string mod_msg = StringFormat("[V12 %s] REV SL/TP MODIFIED (%s): SL %.2f->%.2f | TP %.2f->%.2f",
                                                _Symbol, g_state.eid, cur_sl, new_sl, cur_tp, new_tp);
                  Print("V12_EA: ", mod_msg);
                  SendTelegram(mod_msg);
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+

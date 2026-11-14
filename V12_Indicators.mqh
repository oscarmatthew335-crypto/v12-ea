//+------------------------------------------------------------------+
//|                                               V12_Indicators.mqh |
//|     Exact Pine Script v5 math & state machine port (V12_STRAT)   |
//+------------------------------------------------------------------+
#property copyright "V12 EA"
#property strict

#ifndef __V12_INDICATORS_MQH__
#define __V12_INDICATORS_MQH__

//+------------------------------------------------------------------+
//| Strategy enums (matching V12_STRAT.pine & brief)                 |
//+------------------------------------------------------------------+
enum ENUM_DF_MODE
{
   DF_OFF  = 0, // Off
   DF_SKIP = 1, // Skip entries after a hook
   DF_EXIT = 2, // Exit on a hook
   DF_BOTH = 3  // Both
};

enum ENUM_REV_MODE
{
   REV_OFF             = 0, // Off
   REV_AFTER_HOOK_EXIT = 1, // Only after a V12 hook exit
   REV_EVERY_HOOK      = 2  // On every hook
};

enum ENUM_LOT_MODE
{
   LOT_FIXED    = 0, // Fixed
   LOT_RISK_USD = 1  // RiskUSD
};

//+------------------------------------------------------------------+
//| Strategy parameter bundle                                        |
//+------------------------------------------------------------------+
struct V12_Params
{
   int           trail_len;
   double        sl_atr;
   int           atr_len;
   int           bo_len;
   int           retest_win;
   double        retest_tol;
   bool          use_trend;
   int           ema_len;
   ENUM_DF_MODE  df_mode;
   int           hook_lb;
   int           df_len;
   double        df_tol;
   int           norm_len;
   double        pct_cut;
   ENUM_REV_MODE rev_mode;
   int           rev_sbars;
   double        rev_buf;
   double        rev_rr;
   int           rev_max;

   void SetDefaults()
   {
      trail_len  = 10;
      sl_atr     = 2.0;
      atr_len    = 14;
      bo_len     = 20;
      retest_win = 10;
      retest_tol = 0.25;
      use_trend  = true;
      ema_len    = 200;
      df_mode    = DF_BOTH;
      hook_lb    = 10;
      df_len     = 100;
      df_tol     = 0.07;
      norm_len   = 200;
      pct_cut    = 85.0;
      rev_mode   = REV_AFTER_HOOK_EXIT;
      rev_sbars  = 5;
      rev_buf    = 0.25;
      rev_rr     = 1.5;
      rev_max    = 24;
   }
};

//+------------------------------------------------------------------+
//| Persisted per-bar strategy state                                 |
//+------------------------------------------------------------------+
struct V12_State
{
   double lvl_up;
   int    bar_up;
   double lvl_dn;
   int    bar_dn;
   double stop_px;
   double init_risk;
   double r_stop;
   double r_tgt;
   int    rev_bar;
   int    last_hook_bar;
   int    pos_dir; // 0 = flat, 1 = long, -1 = short
   string eid;     // "", "L", "S", "RL", "RS"

   void Reset()
   {
      lvl_up        = EMPTY_VALUE;
      bar_up        = -1;
      lvl_dn        = EMPTY_VALUE;
      bar_dn        = -1;
      stop_px       = EMPTY_VALUE;
      init_risk     = EMPTY_VALUE;
      r_stop        = EMPTY_VALUE;
      r_tgt         = EMPTY_VALUE;
      rev_bar       = -1;
      last_hook_bar = -1;
      pos_dir       = 0;
      eid           = "";
   }
};

//+------------------------------------------------------------------+
//| Actions emitted by one closed bar's state-machine step           |
//+------------------------------------------------------------------+
struct V12_BarActions
{
   bool   close_trend_hook;
   int    open_rev_dir; // 0 = none, 1 = RL, -1 = RS
   bool   go_long;
   bool   go_short;
   bool   close_rev_time;
   bool   skip_long;
   bool   skip_short;
   string signal_label;

   void Reset()
   {
      close_trend_hook = false;
      open_rev_dir     = 0;
      go_long          = false;
      go_short         = false;
      close_rev_time   = false;
      skip_long        = false;
      skip_short       = false;
      signal_label     = "";
   }
};

//+------------------------------------------------------------------+
//| Precomputed indicator buffers (series-indexed: [0] newest closed)|
//+------------------------------------------------------------------+
struct V12_SeriesData
{
   int    count;
   double atr[];
   double ema[];
   double t_stat[];
   double t_pct[];
   bool   df_hook[];
   double range_hi[];
   double range_lo[];
   bool   fresh_up[];
   bool   fresh_dn[];
   double trail_lo[];
   double trail_hi[];
   double rev_hi[];
   double rev_lo[];
};

//+------------------------------------------------------------------+
//| Minimum history bars needed before all indicators are valid      |
//+------------------------------------------------------------------+
int V12_MinWarmupBars(const V12_Params &p)
{
   int df_warm  = 2 * p.df_len + p.norm_len + 2;
   int bo_warm  = p.bo_len + 3;
   int tr_warm  = p.trail_len + 2;
   int max_warm = MathMax(p.ema_len, p.atr_len);
   max_warm     = MathMax(max_warm, df_warm);
   max_warm     = MathMax(max_warm, bo_warm);
   max_warm     = MathMax(max_warm, tr_warm);
   max_warm     = MathMax(max_warm, p.rev_sbars + 1);
   return max_warm;
}

//+------------------------------------------------------------------+
//| Highest value over arr[start_idx .. start_idx + len - 1]         |
//+------------------------------------------------------------------+
double V12_Highest(const double &arr[], int start_idx, int len)
{
   int size = ArraySize(arr);
   if(len <= 0 || start_idx < 0 || start_idx + len > size)
      return EMPTY_VALUE;

   double mx = arr[start_idx];
   for(int i = 1; i < len; i++)
   {
      double v = arr[start_idx + i];
      if(v > mx)
         mx = v;
   }
   return mx;
}

//+------------------------------------------------------------------+
//| Lowest value over arr[start_idx .. start_idx + len - 1]          |
//+------------------------------------------------------------------+
double V12_Lowest(const double &arr[], int start_idx, int len)
{
   int size = ArraySize(arr);
   if(len <= 0 || start_idx < 0 || start_idx + len > size)
      return EMPTY_VALUE;

   double mn = arr[start_idx];
   for(int i = 1; i < len; i++)
   {
      double v = arr[start_idx + i];
      if(v < mn)
         mn = v;
   }
   return mn;
}

//+------------------------------------------------------------------+
//| Simple Moving Average over arr[start_idx .. start_idx + len - 1] |
//+------------------------------------------------------------------+
double V12_SMA(const double &arr[], int start_idx, int len)
{
   int size = ArraySize(arr);
   if(len <= 0 || start_idx < 0 || start_idx + len > size)
      return EMPTY_VALUE;

   double sum = 0.0;
   for(int i = 0; i < len; i++)
   {
      double v = arr[start_idx + i];
      if(v == EMPTY_VALUE)
         return EMPTY_VALUE;
      sum += v;
   }
   return sum / (double)len;
}

//+------------------------------------------------------------------+
//| True Range at series index idx (idx = count - 1 is oldest bar)   |
//+------------------------------------------------------------------+
double V12_TrueRange(const double &high[], const double &low[], const double &close[], int idx, int count)
{
   if(idx < 0 || idx >= count)
      return EMPTY_VALUE;

   double hl = high[idx] - low[idx];
   if(idx == count - 1)
      return hl;

   double hc = MathAbs(high[idx] - close[idx + 1]);
   double lc = MathAbs(low[idx]  - close[idx + 1]);
   return MathMax(hl, MathMax(hc, lc));
}

//+------------------------------------------------------------------+
//| Wilder's RMA of True Range (matches Pine ta.atr, NOT MT5 iATR)   |
//+------------------------------------------------------------------+
bool V12_CalcATRSeries(const double &high[], const double &low[], const double &close[],
                       int count, int atr_len, double &atr_out[])
{
   if(count <= 0 || atr_len <= 0 || count < atr_len)
      return false;
   if(ArraySize(high) < count || ArraySize(low) < count || ArraySize(close) < count)
      return false;

   ArrayResize(atr_out, count);
   ArraySetAsSeries(atr_out, true);
   ArrayInitialize(atr_out, EMPTY_VALUE);

   // Seed with SMA of the first atr_len TR values (oldest bars: count-1 down to count-atr_len)
   double tr_sum = 0.0;
   for(int k = 0; k < atr_len; k++)
   {
      int idx = count - 1 - k;
      tr_sum += V12_TrueRange(high, low, close, idx, count);
   }
   int seed_idx = count - atr_len;
   atr_out[seed_idx] = tr_sum / (double)atr_len;

   double alpha = 1.0 / (double)atr_len;
   for(int idx = seed_idx - 1; idx >= 0; idx--)
   {
      double tr = V12_TrueRange(high, low, close, idx, count);
      atr_out[idx] = alpha * tr + (1.0 - alpha) * atr_out[idx + 1];
   }
   return true;
}

//+------------------------------------------------------------------+
//| Single-value ATR at series index target_idx                      |
//+------------------------------------------------------------------+
double V12_CalcATR(const double &high[], const double &low[], const double &close[],
                   int count, int atr_len, int target_idx = 0)
{
   double atr_buf[];
   if(!V12_CalcATRSeries(high, low, close, count, atr_len, atr_buf))
      return EMPTY_VALUE;
   if(target_idx < 0 || target_idx >= count)
      return EMPTY_VALUE;
   return atr_buf[target_idx];
}

//+------------------------------------------------------------------+
//| Exponential Moving Average seeded with first ema_len SMA         |
//+------------------------------------------------------------------+
bool V12_CalcEMASeries(const double &close[], int count, int ema_len, double &ema_out[])
{
   if(count <= 0 || ema_len <= 0 || count < ema_len || ArraySize(close) < count)
      return false;

   ArrayResize(ema_out, count);
   ArraySetAsSeries(ema_out, true);
   ArrayInitialize(ema_out, EMPTY_VALUE);

   double sum = 0.0;
   for(int k = 0; k < ema_len; k++)
      sum += close[count - 1 - k];

   int seed_idx = count - ema_len;
   ema_out[seed_idx] = sum / (double)ema_len;

   double alpha = 2.0 / ((double)ema_len + 1.0);
   for(int idx = seed_idx - 1; idx >= 0; idx--)
      ema_out[idx] = alpha * close[idx] + (1.0 - alpha) * ema_out[idx + 1];

   return true;
}

//+------------------------------------------------------------------+
//| Single-value EMA at series index target_idx                      |
//+------------------------------------------------------------------+
double V12_CalcEMA(const double &close[], int count, int ema_len, int target_idx = 0)
{
   double ema_buf[];
   if(!V12_CalcEMASeries(close, count, ema_len, ema_buf))
      return EMPTY_VALUE;
   if(target_idx < 0 || target_idx >= count)
      return EMPTY_VALUE;
   return ema_buf[target_idx];
}

//+------------------------------------------------------------------+
//| Strictly-greater percentile rank over t_stat[b .. b + norm_len-1]|
//+------------------------------------------------------------------+
double V12_CalcPctRank(const double &t_stat[], int b, int norm_len)
{
   int size = ArraySize(t_stat);
   if(norm_len <= 0 || b < 0 || b + norm_len > size)
      return EMPTY_VALUE;

   double val = t_stat[b];
   if(val == EMPTY_VALUE || !MathIsValidNumber(val))
      return EMPTY_VALUE;

   int count_below = 0;
   for(int i = 0; i < norm_len; i++)
   {
      double cmp = t_stat[b + i];
      if(cmp != EMPTY_VALUE && MathIsValidNumber(cmp) && val > cmp)
         count_below++;
   }
   return ((double)count_below / (double)norm_len) * 100.0;
}

//+------------------------------------------------------------------+
//| DF Gauge t-stat series (exact Pine formula, double precision)    |
//+------------------------------------------------------------------+
bool V12_CalcDFSeries(const double &close[], int count, int df_len, double &t_stat_out[])
{
   if(count <= 0 || df_len <= 1 || count <= 2 * df_len || ArraySize(close) < count)
      return false;

   ArrayResize(t_stat_out, count);
   ArraySetAsSeries(t_stat_out, true);
   ArrayInitialize(t_stat_out, EMPTY_VALUE);

   double dy[];
   double y_lag[];
   double dy_ylag[];
   double ylag_sq[];
   double res_sq[];
   double var_y_arr[];
   double beta_arr[];

   ArrayResize(dy, count);        ArraySetAsSeries(dy, true);        ArrayInitialize(dy, EMPTY_VALUE);
   ArrayResize(y_lag, count);     ArraySetAsSeries(y_lag, true);     ArrayInitialize(y_lag, EMPTY_VALUE);
   ArrayResize(dy_ylag, count);   ArraySetAsSeries(dy_ylag, true);   ArrayInitialize(dy_ylag, EMPTY_VALUE);
   ArrayResize(ylag_sq, count);   ArraySetAsSeries(ylag_sq, true);   ArrayInitialize(ylag_sq, EMPTY_VALUE);
   ArrayResize(res_sq, count);    ArraySetAsSeries(res_sq, true);    ArrayInitialize(res_sq, EMPTY_VALUE);
   ArrayResize(var_y_arr, count); ArraySetAsSeries(var_y_arr, true); ArrayInitialize(var_y_arr, EMPTY_VALUE);
   ArrayResize(beta_arr, count);  ArraySetAsSeries(beta_arr, true);  ArrayInitialize(beta_arr, EMPTY_VALUE);

   // Match Pine: y = close; dy = y - nz(y[1]); y_lag = nz(y[1])
   dy[count - 1]      = close[count - 1];
   y_lag[count - 1]   = 0.0;
   dy_ylag[count - 1] = 0.0;
   ylag_sq[count - 1] = 0.0;

   for(int idx = count - 2; idx >= 0; idx--)
   {
      double yl     = close[idx + 1];
      double d      = close[idx] - yl;
      dy[idx]       = d;
      y_lag[idx]    = yl;
      dy_ylag[idx]  = d * yl;
      ylag_sq[idx]  = yl * yl;
   }

   // Direct window sums per bar (no sliding-sum drift) and per-bar residual storage
   int first_reg_idx = count - df_len;
   for(int idx = first_reg_idx; idx >= 0; idx--)
   {
      double s_dy = 0.0, s_yl = 0.0, s_dy_yl = 0.0, s_yl_sq = 0.0;
      for(int k = 0; k < df_len; k++)
      {
         int j = idx + k;
         s_dy    += dy[j];
         s_yl    += y_lag[j];
         s_dy_yl += dy_ylag[j];
         s_yl_sq += ylag_sq[j];
      }

      double mean_dy   = s_dy    / (double)df_len;
      double mean_ylag = s_yl    / (double)df_len;
      double covar     = (s_dy_yl / (double)df_len) - (mean_dy * mean_ylag);
      double var_y     = (s_yl_sq / (double)df_len) - (mean_ylag * mean_ylag);
      double beta      = (var_y == 0.0) ? 0.0 : (covar / var_y);
      double alpha     = mean_dy - (beta * mean_ylag);
      double res       = dy[idx] - (alpha + (beta * y_lag[idx]));

      res_sq[idx]    = res * res;
      var_y_arr[idx] = var_y;
      beta_arr[idx]  = beta;
   }

   int first_t_idx = first_reg_idx - (df_len - 1);
   if(first_t_idx < 0)
      return false;

   for(int idx = first_t_idx; idx >= 0; idx--)
   {
      double s_res_sq = 0.0;
      for(int k = 0; k < df_len; k++)
         s_res_sq += res_sq[idx + k];

      double mse     = MathMax(0.0, s_res_sq / (double)df_len);
      double denom_v = (double)df_len * var_y_arr[idx];
      double se_beta = (denom_v <= 0.0) ? 0.0001 : MathSqrt(mse / denom_v);
      t_stat_out[idx] = (se_beta == 0.0) ? 0.0 : (beta_arr[idx] / se_beta);
   }

   return true;
}

//+------------------------------------------------------------------+
//| Pure single-bar DF calculation at bar target_idx                 |
//+------------------------------------------------------------------+
double V12_CalcDFBar(const double &close[], int count, int df_len, int target_idx = 0)
{
   double t_buf[];
   if(!V12_CalcDFSeries(close, count, df_len, t_buf))
      return EMPTY_VALUE;
   if(target_idx < 0 || target_idx >= count)
      return EMPTY_VALUE;
   return t_buf[target_idx];
}

//+------------------------------------------------------------------+
//| Precompute all indicator series over OHLC buffers                |
//+------------------------------------------------------------------+
bool V12_ComputeAllSeries(const double &high[], const double &low[], const double &close[],
                          int count, const V12_Params &p, V12_SeriesData &out)
{
   if(count <= V12_MinWarmupBars(p))
      return false;

   out.count = count;
   if(!V12_CalcATRSeries(high, low, close, count, p.atr_len, out.atr))
      return false;
   if(!V12_CalcEMASeries(close, count, p.ema_len, out.ema))
      return false;
   if(!V12_CalcDFSeries(close, count, p.df_len, out.t_stat))
      return false;

   ArrayResize(out.t_pct, count);    ArraySetAsSeries(out.t_pct, true);    ArrayInitialize(out.t_pct, EMPTY_VALUE);
   ArrayResize(out.df_hook, count);  ArraySetAsSeries(out.df_hook, true);  ArrayInitialize(out.df_hook, false);
   ArrayResize(out.range_hi, count); ArraySetAsSeries(out.range_hi, true); ArrayInitialize(out.range_hi, EMPTY_VALUE);
   ArrayResize(out.range_lo, count); ArraySetAsSeries(out.range_lo, true); ArrayInitialize(out.range_lo, EMPTY_VALUE);
   ArrayResize(out.fresh_up, count); ArraySetAsSeries(out.fresh_up, true); ArrayInitialize(out.fresh_up, false);
   ArrayResize(out.fresh_dn, count); ArraySetAsSeries(out.fresh_dn, true); ArrayInitialize(out.fresh_dn, false);
   ArrayResize(out.trail_lo, count); ArraySetAsSeries(out.trail_lo, true); ArrayInitialize(out.trail_lo, EMPTY_VALUE);
   ArrayResize(out.trail_hi, count); ArraySetAsSeries(out.trail_hi, true); ArrayInitialize(out.trail_hi, EMPTY_VALUE);
   ArrayResize(out.rev_hi, count);   ArraySetAsSeries(out.rev_hi, true);   ArrayInitialize(out.rev_hi, EMPTY_VALUE);
   ArrayResize(out.rev_lo, count);   ArraySetAsSeries(out.rev_lo, true);   ArrayInitialize(out.rev_lo, EMPTY_VALUE);

   for(int b = count - 1; b >= 0; b--)
   {
      if(b + p.norm_len <= count && out.t_stat[b + p.norm_len - 1] != EMPTY_VALUE)
      {
         out.t_pct[b] = V12_CalcPctRank(out.t_stat, b, p.norm_len);
         double prev_t = (b + 1 < count && out.t_stat[b + 1] != EMPTY_VALUE) ? out.t_stat[b + 1] : 0.0;
         double t_delta = out.t_stat[b] - prev_t;
         if(out.t_pct[b] != EMPTY_VALUE)
            out.df_hook[b] = (out.t_stat[b] > 0.0) && (out.t_pct[b] >= p.pct_cut) && (t_delta < -p.df_tol);
      }

      if(b + 1 + p.bo_len <= count)
      {
         out.range_hi[b] = V12_Highest(high, b + 1, p.bo_len);
         out.range_lo[b] = V12_Lowest(low,   b + 1, p.bo_len);
      }

      if(b + 2 + p.bo_len <= count)
      {
         double r_hi_prev = out.range_hi[b + 1];
         double r_lo_prev = out.range_lo[b + 1];
         if(out.range_hi[b] != EMPTY_VALUE && r_hi_prev != EMPTY_VALUE)
            out.fresh_up[b] = (close[b] > out.range_hi[b]) && (close[b + 1] <= r_hi_prev);
         if(out.range_lo[b] != EMPTY_VALUE && r_lo_prev != EMPTY_VALUE)
            out.fresh_dn[b] = (close[b] < out.range_lo[b]) && (close[b + 1] >= r_lo_prev);
      }

      if(b + 1 + p.trail_len <= count)
      {
         out.trail_lo[b] = V12_Lowest(low,   b + 1, p.trail_len);
         out.trail_hi[b] = V12_Highest(high, b + 1, p.trail_len);
      }

      if(b + p.rev_sbars <= count)
      {
         out.rev_hi[b] = V12_Highest(high, b, p.rev_sbars);
         out.rev_lo[b] = V12_Lowest(low,   b, p.rev_sbars);
      }
   }
   return true;
}

//+------------------------------------------------------------------+
//| Simulate intrabar SL/TP hit on bar b (for replay & debug only)   |
//+------------------------------------------------------------------+
bool V12_SimulateIntrabarExit(int b, const double &open[], const double &high[], const double &low[],
                              V12_State &st, string &sim_exit_reason, double &sim_exit_px)
{
   sim_exit_reason = "";
   sim_exit_px     = 0.0;

   if(st.pos_dir == 0)
      return false;

   if(st.eid == "L")
   {
      if(st.stop_px != EMPTY_VALUE && low[b] <= st.stop_px)
      {
         sim_exit_px     = (open[b] <= st.stop_px) ? open[b] : st.stop_px;
         sim_exit_reason = "Trend exit";
         st.pos_dir      = 0;
         st.eid          = "";
         return true;
      }
   }
   else if(st.eid == "S")
   {
      if(st.stop_px != EMPTY_VALUE && high[b] >= st.stop_px)
      {
         sim_exit_px     = (open[b] >= st.stop_px) ? open[b] : st.stop_px;
         sim_exit_reason = "Trend exit";
         st.pos_dir      = 0;
         st.eid          = "";
         return true;
      }
   }
   else if(st.eid == "RL")
   {
      bool hit_sl = (st.r_stop != EMPTY_VALUE && low[b]  <= st.r_stop);
      bool hit_tp = (st.r_tgt  != EMPTY_VALUE && high[b] >= st.r_tgt);
      if(hit_sl && hit_tp)
      {
         if(open[b] >= st.r_tgt) { sim_exit_px = open[b]; hit_sl = false; }
         else if(open[b] <= st.r_stop) { sim_exit_px = open[b]; hit_tp = false; }
         else
         {
            // Closest to open heuristic (matches Pine standard OHLC simulation)
            double d_sl = MathAbs(open[b] - st.r_stop);
            double d_tp = MathAbs(st.r_tgt - open[b]);
            if(d_tp < d_sl) { hit_sl = false; sim_exit_px = st.r_tgt; }
            else            { hit_tp = false; sim_exit_px = st.r_stop; }
         }
      }
      else if(hit_sl)
         sim_exit_px = (open[b] <= st.r_stop) ? open[b] : st.r_stop;
      else if(hit_tp)
         sim_exit_px = (open[b] >= st.r_tgt)  ? open[b] : st.r_tgt;

      if(hit_sl || hit_tp)
      {
         sim_exit_reason = "Rev exit";
         st.pos_dir      = 0;
         st.eid          = "";
         return true;
      }
   }
   else if(st.eid == "RS")
   {
      bool hit_sl = (st.r_stop != EMPTY_VALUE && high[b] >= st.r_stop);
      bool hit_tp = (st.r_tgt  != EMPTY_VALUE && low[b]  <= st.r_tgt);
      if(hit_sl && hit_tp)
      {
         if(open[b] <= st.r_tgt) { sim_exit_px = open[b]; hit_sl = false; }
         else if(open[b] >= st.r_stop) { sim_exit_px = open[b]; hit_tp = false; }
         else
         {
            double d_sl = MathAbs(st.r_stop - open[b]);
            double d_tp = MathAbs(open[b] - st.r_tgt);
            if(d_tp < d_sl) { hit_sl = false; sim_exit_px = st.r_tgt; }
            else            { hit_tp = false; sim_exit_px = st.r_stop; }
         }
      }
      else if(hit_sl)
         sim_exit_px = (open[b] >= st.r_stop) ? open[b] : st.r_stop;
      else if(hit_tp)
         sim_exit_px = (open[b] <= st.r_tgt)  ? open[b] : st.r_tgt;

      if(hit_sl || hit_tp)
      {
         sim_exit_reason = "Rev exit";
         st.pos_dir      = 0;
         st.eid          = "";
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Execute one closed bar through the exact Pine state machine      |
//| Steps 1..9 in exact order from V12_STRAT.pine & brief            |
//+------------------------------------------------------------------+
void V12_StepBar(int b, int t, const double &high[], const double &low[], const double &close[],
                 const V12_SeriesData &sd, const V12_Params &p, bool is_live,
                 V12_State &st, V12_BarActions &act)
{
   act.Reset();

   double atr_val  = sd.atr[b];
   double ema_val  = sd.ema[b];
   double range_hi = sd.range_hi[b];
   double range_lo = sd.range_lo[b];
   bool   fresh_up = sd.fresh_up[b];
   bool   fresh_dn = sd.fresh_dn[b];
   double trail_lo = sd.trail_lo[b];
   double trail_hi = sd.trail_hi[b];
   double rev_hi   = sd.rev_hi[b];
   double rev_lo   = sd.rev_lo[b];
   bool   df_hook  = sd.df_hook[b];

   if(atr_val == EMPTY_VALUE || ema_val == EMPTY_VALUE ||
      range_hi == EMPTY_VALUE || range_lo == EMPTY_VALUE ||
      trail_lo == EMPTY_VALUE || trail_hi == EMPTY_VALUE ||
      rev_hi == EMPTY_VALUE || rev_lo == EMPTY_VALUE)
   {
      return;
   }

   // Capture start-of-bar position state (matching Pine lines 119-122)
   int  start_pos_dir = st.pos_dir;
   bool in_v12        = (start_pos_dir != 0) && (st.eid == "L" || st.eid == "S");
   bool in_rev        = (start_pos_dir != 0) && (st.eid == "RL" || st.eid == "RS");

   // Update bars-since-hook (bar [0] hook counts as 0 bars since)
   if(df_hook)
      st.last_hook_bar = t;
   int bars_since_hook = (st.last_hook_bar < 0) ? 9999 : (t - st.last_hook_bar);

   bool use_skip = (p.df_mode == DF_SKIP || p.df_mode == DF_BOTH);
   bool use_exit = (p.df_mode == DF_EXIT || p.df_mode == DF_BOTH);
   bool skip_now = use_skip && (bars_since_hook <= p.hook_lb);

   // Step 1: Retest / failed / expired using existing levels (before updates)
   bool has_up = (st.lvl_up != EMPTY_VALUE && st.bar_up >= 0);
   bool has_dn = (st.lvl_dn != EMPTY_VALUE && st.bar_dn >= 0);

   bool retest_long  = has_up && (t > st.bar_up) && (low[b]  <= st.lvl_up + p.retest_tol * atr_val) && (close[b] > st.lvl_up);
   bool retest_short = has_dn && (t > st.bar_dn) && (high[b] >= st.lvl_dn - p.retest_tol * atr_val) && (close[b] < st.lvl_dn);
   bool failed_up    = has_up && (close[b] < st.lvl_up - p.retest_tol * atr_val);
   bool failed_dn    = has_dn && (close[b] > st.lvl_dn + p.retest_tol * atr_val);
   bool expired_up   = has_up && ((t - st.bar_up) > p.retest_win);
   bool expired_dn   = has_dn && ((t - st.bar_dn) > p.retest_win);

   // Step 2: Hook handling
   bool did_rev = false;
   int  rev_dir = 0;
   if(df_hook)
   {
      if(in_v12 && use_exit)
      {
         if(p.rev_mode != REV_OFF)
            rev_dir = (start_pos_dir > 0) ? -1 : 1;
         else
            act.close_trend_hook = true;
      }
      else if(start_pos_dir == 0 && p.rev_mode == REV_EVERY_HOOK)
      {
         if(b + p.bo_len < sd.count)
            rev_dir = (close[b] > close[b + p.bo_len]) ? -1 : 1;
      }
   }

   // Step 3: Open reversal if rev_dir != 0 (also closes trend trade on same fill)
   if(rev_dir != 0)
   {
      double raw    = (rev_dir == 1) ? (rev_lo - p.rev_buf * atr_val) : (rev_hi + p.rev_buf * atr_val);
      double risk   = MathMax(MathAbs(close[b] - raw), 0.5 * atr_val);
      st.r_stop     = (rev_dir == 1) ? (close[b] - risk) : (close[b] + risk);
      bool   ema_ok = (rev_dir == 1) ? (ema_val > close[b]) : (ema_val < close[b]);
      st.r_tgt      = ema_ok ? ema_val : ((rev_dir == 1) ? (close[b] + p.rev_rr * risk) : (close[b] - p.rev_rr * risk));
      st.init_risk  = risk;
      st.rev_bar    = t;
      did_rev       = true;
      act.open_rev_dir = rev_dir;
      act.signal_label = (rev_dir == 1) ? "Rev L" : "Rev S";

      if(!is_live)
      {
         st.pos_dir = rev_dir;
         st.eid     = (rev_dir == 1) ? "RL" : "RS";
      }
   }

   // Step 4: Trend entries
   bool flat     = (start_pos_dir == 0) && (!did_rev);
   bool go_long  = flat && retest_long  && (!skip_now);
   bool go_short = flat && retest_short && (!go_long) && (!skip_now);

   act.skip_long  = flat && retest_long  && skip_now;
   act.skip_short = flat && retest_short && (!retest_long) && skip_now;

   if(go_long || go_short)
   {
      st.init_risk = p.sl_atr * atr_val;
      st.stop_px   = go_long ? (close[b] - st.init_risk) : (close[b] + st.init_risk);
      act.go_long  = go_long;
      act.go_short = go_short;
      act.signal_label = go_long ? "Trend L" : "Trend S";

      if(!is_live)
      {
         st.pos_dir = go_long ? 1 : -1;
         st.eid     = go_long ? "L" : "S";
      }
   }

   // Step 5: Level resets
   if(go_long || failed_up || expired_up)
   {
      st.lvl_up = EMPTY_VALUE;
      st.bar_up = -1;
   }
   if(go_short || failed_dn || expired_dn)
   {
      st.lvl_dn = EMPTY_VALUE;
      st.bar_dn = -1;
   }

   // Step 6: New levels
   bool up_ok = (!p.use_trend) || (close[b] > ema_val);
   bool dn_ok = (!p.use_trend) || (close[b] < ema_val);
   if(fresh_up && up_ok)
   {
      st.lvl_up = range_hi;
      st.bar_up = t;
      st.lvl_dn = EMPTY_VALUE;
      st.bar_dn = -1;
   }
   if(fresh_dn && dn_ok)
   {
      st.lvl_dn = range_lo;
      st.bar_dn = t;
      st.lvl_up = EMPTY_VALUE;
      st.bar_up = -1;
   }

   // Step 7: Trailing (only for trend position open at start of bar, not newly reversed)
   if(in_v12 && !did_rev)
   {
      if(start_pos_dir > 0)
         st.stop_px = MathMax(st.stop_px, trail_lo);
      else
         st.stop_px = MathMin(st.stop_px, trail_hi);
   }

   // Step 8: Reversal target follows EMA while on profit side of close
   if(in_rev && ((start_pos_dir > 0) ? (ema_val > close[b]) : (ema_val < close[b])))
   {
      st.r_tgt = ema_val;
   }

   // Step 9: Reversal time exit
   if(in_rev && ((t - st.rev_bar) >= p.rev_max))
   {
      act.close_rev_time = true;
      if(act.signal_label == "")
         act.signal_label = "Rev time";
   }

   if(act.close_trend_hook && act.signal_label == "")
      act.signal_label = "DF hook";
   if(act.skip_long && act.signal_label == "")
      act.signal_label = "Skip L";
   if(act.skip_short && act.signal_label == "")
      act.signal_label = "Skip S";

   if(!is_live && (act.close_trend_hook || act.close_rev_time))
   {
      st.pos_dir = 0;
      st.eid     = "";
   }
}

#endif // __V12_INDICATORS_MQH__

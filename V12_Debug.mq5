//+------------------------------------------------------------------+
//|                                                    V12_Debug.mq5 |
//|     Per-bar indicator/signal CSV exporter & unit-test script     |
//+------------------------------------------------------------------+
#property copyright "V12 EA"
#property version   "1.00"
#property script_show_inputs
#property strict

#include "V12_Indicators.mqh"

//+------------------------------------------------------------------+
//| Script Inputs                                                    |
//+------------------------------------------------------------------+
input group "Debug Output & Mode"
input datetime      inp_start_date      = D'2025.01.01 00:00'; // Start date for CSV rows
input bool          inp_use_csv_input   = false;               // Read OHLC from CSV instead of chart
input string        inp_input_csv_name  = "V12_Input_OHLC.csv";// Input OHLC CSV (MQL5\Files or Common\Files)
input string        inp_output_csv_name = "V12_Debug_Output.csv"; // Output CSV file name
input bool          inp_run_unit_tests  = true;                // Run pure-function unit tests
input int           inp_warmup_bars     = 3200;                // Extra closed bars before start_date

input group "Strategy Parameters (match V12_STRAT.pine)"
input int           trail_len  = 10;
input double        sl_atr     = 2.0;
input int           atr_len    = 14;
input int           bo_len     = 20;
input int           retest_win = 10;
input double        retest_tol = 0.25;
input bool          use_trend  = true;
input int           ema_len    = 200;
input ENUM_DF_MODE  df_mode    = DF_BOTH;
input int           hook_lb    = 10;
input int           df_len     = 100;
input double        df_tol     = 0.07;
input int           norm_len   = 200;
input double        pct_cut    = 85.0;
input ENUM_REV_MODE rev_mode   = REV_AFTER_HOOK_EXIT;
input int           rev_sbars  = 5;
input double        rev_buf    = 0.25;
input double        rev_rr     = 1.5;
input int           rev_max    = 24;

//+------------------------------------------------------------------+
//| Helper: assert near-equality for unit tests                      |
//+------------------------------------------------------------------+
bool AssertNear(const string name, double actual, double expected, double tol)
{
   double diff = MathAbs(actual - expected);
   if(diff > tol || !MathIsValidNumber(actual))
   {
      PrintFormat("UNIT TEST FAIL [%s]: actual=%.10f expected=%.10f diff=%.10f (tol=%.10f)",
                  name, actual, expected, diff, tol);
      return false;
   }
   return true;
}

bool AssertBool(const string name, bool actual, bool expected)
{
   if(actual != expected)
   {
      PrintFormat("UNIT TEST FAIL [%s]: actual=%s expected=%s",
                  name, (actual ? "true" : "false"), (expected ? "true" : "false"));
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Self-contained unit tests on V12_Indicators.mqh pure functions   |
//+------------------------------------------------------------------+
bool RunIndicatorUnitTests()
{
   bool all_ok = true;

   // 1. Test V12_Highest & V12_Lowest (series order: [0] newest)
   double arr[] = { 10.0, 15.0, 12.0, 8.0, 20.0, 9.0 };
   all_ok &= AssertNear("Highest(1,3)", V12_Highest(arr, 1, 3), 15.0, 1e-12);
   all_ok &= AssertNear("Lowest(1,3)",  V12_Lowest(arr, 1, 3),   8.0, 1e-12);
   all_ok &= AssertNear("Highest(0,5)", V12_Highest(arr, 0, 5), 20.0, 1e-12);

   // 2. Test Wilder's ATR vs simple average (must match RMA, NOT SMA)
   // Chronological oldest->newest (4 bars, atr_len=3):
   // bar 3 (oldest): H=12, L=10, C=11 -> TR = 2
   // bar 2: H=14, L=11, C=13 -> TR = max(3, |14-11|, |11-11|) = 3
   // bar 1: H=16, L=12, C=15 -> TR = max(4, |16-13|, |12-13|) = 4
   // Seed ATR at idx=1 (len=3): (2+3+4)/3 = 3.0
   // bar 0 (newest): H=20, L=14, C=18 -> TR = max(6, |20-15|, |14-15|) = 6
   // RMA at idx=0: (1/3)*6 + (2/3)*3.0 = 4.0 (SMA of last 3 would be (3+4+6)/3 = 4.3333)
   double h_atr[] = { 20.0, 16.0, 14.0, 12.0 };
   double l_atr[] = { 14.0, 12.0, 11.0, 10.0 };
   double c_atr[] = { 18.0, 15.0, 13.0, 11.0 };
   all_ok &= AssertNear("ATR Wilder RMA", V12_CalcATR(h_atr, l_atr, c_atr, 4, 3, 0), 4.0, 1e-12);

   // 3. Test EMA (len=3, alpha=2/4=0.5)
   // Chronological oldest->newest: 10, 12, 14, 18
   // Seed at idx=1: (10+12+14)/3 = 12.0
   // idx=0: 0.5 * 18 + 0.5 * 12 = 15.0
   double c_ema[] = { 18.0, 14.0, 12.0, 10.0 };
   all_ok &= AssertNear("EMA SMA-seed", V12_CalcEMA(c_ema, 4, 3, 0), 15.0, 1e-12);

   // 4. Test V12_CalcPctRank (strictly greater; self index 0 never counts)
   double t_vals[] = { 2.0, 2.0, 1.0, 3.0, 0.5 };
   // Count strictly below 2.0: 1.0, 0.5 -> 2 out of 5 = 40.0%
   all_ok &= AssertNear("PctRank strict", V12_CalcPctRank(t_vals, 0, 5), 40.0, 1e-12);

   // 5. Test DF t_stat analytical check on AR(1)-like synthetic series (df_len=4, count=10)
   // Linear trend with zero noise: close = 100 + k -> dy=1 constant => covar=0 => beta=0 => t_stat=0
   double c_lin[10];
   for(int idx = 9; idx >= 0; idx--)
      c_lin[idx] = 100.0 + (double)(9 - idx);
   all_ok &= AssertNear("DF linear trend t_stat=0", V12_CalcDFBar(c_lin, 10, 4, 0), 0.0, 1e-12);

   // Non-trivial DF check: verify beta & t_stat against direct brute-force calculation
   double c_osc[10] = { 105.0, 101.0, 104.0, 100.0, 103.0, 101.0, 102.0, 100.0, 101.0, 100.0 };
   double t_osc[];
   bool df_ok = V12_CalcDFSeries(c_osc, 10, 3, t_osc);
   all_ok &= AssertBool("DF series ok", df_ok, true);
   if(df_ok)
   {
      // Brute-force check at idx=0 (df_len=3 -> res at idx=0,1,2)
      double res_check[3];
      double var_y0 = 0.0, beta0 = 0.0;
      for(int j = 0; j < 3; j++)
      {
         double s_dy = 0.0, s_yl = 0.0, s_dyyl = 0.0, s_yl2 = 0.0;
         for(int k = 0; k < 3; k++)
         {
            double yl = c_osc[j + k + 1];
            double d  = c_osc[j + k] - yl;
            s_dy   += d;
            s_yl   += yl;
            s_dyyl += d * yl;
            s_yl2  += yl * yl;
         }
         double m_dy = s_dy / 3.0;
         double m_yl = s_yl / 3.0;
         double cov  = (s_dyyl / 3.0) - m_dy * m_yl;
         double vy   = (s_yl2  / 3.0) - m_yl * m_yl;
         double b    = (vy == 0.0) ? 0.0 : (cov / vy);
         double a    = m_dy - b * m_yl;
         res_check[j] = (c_osc[j] - c_osc[j + 1]) - (a + b * c_osc[j + 1]);
         if(j == 0) { var_y0 = vy; beta0 = b; }
      }
      double mse0 = (res_check[0]*res_check[0] + res_check[1]*res_check[1] + res_check[2]*res_check[2]) / 3.0;
      double se0  = (3.0 * var_y0 <= 0.0) ? 0.0001 : MathSqrt(mse0 / (3.0 * var_y0));
      double expected_t0 = beta0 / se0;
      all_ok &= AssertNear("DF brute-force parity", t_osc[0], expected_t0, 1e-12);
   }

   if(all_ok)
      Print("V12_Debug: ALL indicator unit tests PASSED.");
   else
      Print("V12_Debug: ONE OR MORE indicator unit tests FAILED!");
   return all_ok;
}

//+------------------------------------------------------------------+
//| Parse timestamp string or Unix epoch seconds into datetime       |
//+------------------------------------------------------------------+
datetime ParseTimeField(const string raw)
{
   string s = raw;
   StringTrimLeft(s);
   StringTrimRight(s);
   if(s == "")
      return 0;

   // Pure integer Unix timestamp (seconds or milliseconds)
   bool all_digits = true;
   int slen = StringLen(s);
   for(int i = 0; i < slen; i++)
   {
      ushort ch = StringGetCharacter(s, i);
      if(ch < '0' || ch > '9') { all_digits = false; break; }
   }
   if(all_digits)
   {
      long ts = StringToInteger(s);
      if(ts > 100000000000) // ms -> s
         ts /= 1000;
      return (datetime)ts;
   }

   // Normalize ISO "2025-01-01T00:00:00Z" or "2025-01-01 00:00:00+02:00"
   StringReplace(s, "T", " ");
   StringReplace(s, "Z", "");
   StringReplace(s, "-", ".");
   if(StringLen(s) > 19)
      s = StringSubstr(s, 0, 19);
   return StringToTime(s);
}

//+------------------------------------------------------------------+
//| Load OHLC rows from a CSV file into series-ordered arrays        |
//+------------------------------------------------------------------+
bool LoadOHLCFromCSV(const string filename, datetime &time_arr[], string &time_str_arr[],
                     double &open[], double &high[], double &low[], double &close[], int &out_count)
{
   int flags = FILE_READ | FILE_TXT | FILE_ANSI;
   int fh = FileOpen(filename, flags);
   if(fh == INVALID_HANDLE)
      fh = FileOpen(filename, flags | FILE_COMMON);

   if(fh == INVALID_HANDLE)
   {
      PrintFormat("V12_Debug: Unable to open input CSV '%s' (checked MQL5\\Files and Common\\Files). err=%d",
                  filename, GetLastError());
      return false;
   }

   datetime tmp_t[];
   string   tmp_ts[];
   double   tmp_o[], tmp_h[], tmp_l[], tmp_c[];
   int cap = 0, n = 0;

   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "")
         continue;

      string cols[];
      int ncols = StringSplit(line, ',', cols);
      if(ncols < 5)
         continue;

      // Skip header row if Open column isn't numeric
      string o_str = cols[1];
      StringTrimLeft(o_str);
      ushort first_ch = (StringLen(o_str) > 0) ? StringGetCharacter(o_str, 0) : 0;
      if((first_ch < '0' || first_ch > '9') && first_ch != '-' && first_ch != '.')
         continue;

      if(n >= cap)
      {
         cap = (cap == 0) ? 4096 : cap * 2;
         ArrayResize(tmp_t, cap);
         ArrayResize(tmp_ts, cap);
         ArrayResize(tmp_o, cap);
         ArrayResize(tmp_h, cap);
         ArrayResize(tmp_l, cap);
         ArrayResize(tmp_c, cap);
      }

      string raw_time = cols[0];
      StringTrimLeft(raw_time);
      StringTrimRight(raw_time);

      tmp_ts[n] = raw_time;
      tmp_t[n]  = ParseTimeField(raw_time);
      tmp_o[n]  = StringToDouble(cols[1]);
      tmp_h[n]  = StringToDouble(cols[2]);
      tmp_l[n]  = StringToDouble(cols[3]);
      tmp_c[n]  = StringToDouble(cols[4]);
      n++;
   }
   FileClose(fh);

   if(n <= 0)
   {
      Print("V12_Debug: No valid OHLC rows found in input CSV.");
      return false;
   }

   // Detect chronological order (oldest-first vs newest-first) and store as series ([0] = newest)
   bool oldest_first = (n == 1) || (tmp_t[n - 1] >= tmp_t[0]);

   ArrayResize(time_arr, n);     ArraySetAsSeries(time_arr, true);
   ArrayResize(time_str_arr, n); ArraySetAsSeries(time_str_arr, true);
   ArrayResize(open, n);         ArraySetAsSeries(open, true);
   ArrayResize(high, n);         ArraySetAsSeries(high, true);
   ArrayResize(low, n);          ArraySetAsSeries(low, true);
   ArrayResize(close, n);        ArraySetAsSeries(close, true);

   for(int i = 0; i < n; i++)
   {
      int src = oldest_first ? (n - 1 - i) : i;
      time_arr[i]     = tmp_t[src];
      time_str_arr[i] = tmp_ts[src];
      open[i]         = tmp_o[src];
      high[i]         = tmp_h[src];
      low[i]          = tmp_l[src];
      close[i]        = tmp_c[src];
   }

   out_count = n;
   PrintFormat("V12_Debug: Loaded %d OHLC rows from '%s' (oldest_first=%s).",
               n, filename, (oldest_first ? "true" : "false"));
   return true;
}

//+------------------------------------------------------------------+
//| Format float or "na"                                             |
//+------------------------------------------------------------------+
string FmtVal(double v, int digits = 6)
{
   if(v == EMPTY_VALUE || !MathIsValidNumber(v))
      return "na";
   return DoubleToString(v, digits);
}

//+------------------------------------------------------------------+
//| Script entry point                                               |
//+------------------------------------------------------------------+
void OnStart()
{
   if(inp_run_unit_tests)
   {
      if(!RunIndicatorUnitTests())
         Print("V12_Debug: Continuing despite unit test warning.");
   }

   V12_Params p;
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

   datetime time_arr[];
   string   time_str_arr[];
   double   open[], high[], low[], close[];
   int      count = 0;

   if(inp_use_csv_input)
   {
      if(!LoadOHLCFromCSV(inp_input_csv_name, time_arr, time_str_arr, open, high, low, close, count))
         return;
   }
   else
   {
      int avail = iBars(_Symbol, PERIOD_H1) - 1;
      int start_shift = iBarShift(_Symbol, PERIOD_H1, inp_start_date, false);
      if(start_shift < 1)
         start_shift = avail;

      int min_warm  = V12_MinWarmupBars(p);
      int need_bars = start_shift + MathMax(inp_warmup_bars, min_warm + 500);
      count = MathMin(avail, need_bars);

      MqlRates rates[];
      ArraySetAsSeries(rates, true);
      int copied = CopyRates(_Symbol, PERIOD_H1, 1, count, rates);
      if(copied <= min_warm + 10)
      {
         PrintFormat("V12_Debug: Insufficient H1 bars on %s (copied=%d).", _Symbol, copied);
         return;
      }
      count = copied;

      ArrayResize(time_arr, count);     ArraySetAsSeries(time_arr, true);
      ArrayResize(time_str_arr, count); ArraySetAsSeries(time_str_arr, true);
      ArrayResize(open, count);         ArraySetAsSeries(open, true);
      ArrayResize(high, count);         ArraySetAsSeries(high, true);
      ArrayResize(low, count);          ArraySetAsSeries(low, true);
      ArrayResize(close, count);        ArraySetAsSeries(close, true);

      for(int i = 0; i < count; i++)
      {
         time_arr[i]     = rates[i].time;
         time_str_arr[i] = TimeToString(rates[i].time, TIME_DATE | TIME_MINUTES);
         open[i]         = rates[i].open;
         high[i]         = rates[i].high;
         low[i]          = rates[i].low;
         close[i]        = rates[i].close;
      }
   }

   int min_warm = V12_MinWarmupBars(p);
   if(count <= min_warm + 2)
   {
      PrintFormat("V12_Debug: Not enough bars (%d) for warmup (%d).", count, min_warm);
      return;
   }

   V12_SeriesData sd;
   if(!V12_ComputeAllSeries(high, low, close, count, p, sd))
   {
      Print("V12_Debug: V12_ComputeAllSeries failed.");
      return;
   }

   // Open both local MQL5\Files and Common\Files output handles
   int fh_local  = FileOpen(inp_output_csv_name, FILE_WRITE | FILE_TXT | FILE_ANSI);
   int fh_common = FileOpen(inp_output_csv_name, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(fh_local == INVALID_HANDLE && fh_common == INVALID_HANDLE)
   {
      PrintFormat("V12_Debug: Failed to open output CSV '%s' (err=%d).", inp_output_csv_name, GetLastError());
      return;
   }

   string header = "time,open,high,low,close,atr,ema,range_hi,range_lo,t_stat,t_pct,df_hook,lvl_up,lvl_dn,signal";
   if(fh_local  != INVALID_HANDLE) FileWriteString(fh_local,  header + "\r\n");
   if(fh_common != INVALID_HANDLE) FileWriteString(fh_common, header + "\r\n");

   V12_State st;
   st.Reset();
   int start_b = count - 1 - min_warm;
   int bar_t   = 0;
   int rows_written = 0;

   for(int b = start_b; b >= 0; b--)
   {
      bar_t++;

      string sim_exit_reason = "";
      double sim_exit_px     = 0.0;
      bool   had_intrabar_exit = V12_SimulateIntrabarExit(b, open, high, low, st, sim_exit_reason, sim_exit_px);

      V12_BarActions act;
      V12_StepBar(b, bar_t, high, low, close, sd, p, false, st, act);

      string sig = act.signal_label;
      if(had_intrabar_exit)
         sig = (sig == "") ? sim_exit_reason : (sim_exit_reason + " | " + sig);

      bool emit_row = (time_arr[b] == 0) || (time_arr[b] >= inp_start_date);
      if(emit_row)
      {
         int px_digits = inp_use_csv_input ? 5 : _Digits;
         string line = StringFormat("%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s",
                                    time_str_arr[b],
                                    DoubleToString(open[b],  px_digits),
                                    DoubleToString(high[b],  px_digits),
                                    DoubleToString(low[b],   px_digits),
                                    DoubleToString(close[b], px_digits),
                                    FmtVal(sd.atr[b],      6),
                                    FmtVal(sd.ema[b],      6),
                                    FmtVal(sd.range_hi[b], 6),
                                    FmtVal(sd.range_lo[b], 6),
                                    FmtVal(sd.t_stat[b],   6),
                                    FmtVal(sd.t_pct[b],    4),
                                    (sd.df_hook[b] ? "1" : "0"),
                                    FmtVal(st.lvl_up,      6),
                                    FmtVal(st.lvl_dn,      6),
                                    sig);
         if(fh_local  != INVALID_HANDLE) FileWriteString(fh_local,  line + "\r\n");
         if(fh_common != INVALID_HANDLE) FileWriteString(fh_common, line + "\r\n");
         rows_written++;
      }
   }

   if(fh_local  != INVALID_HANDLE) FileClose(fh_local);
   if(fh_common != INVALID_HANDLE) FileClose(fh_common);

   PrintFormat("V12_Debug: Wrote %d bars to '%s' (total bars=%d, start_b=%d).",
               rows_written, inp_output_csv_name, count, start_b);
}
//+------------------------------------------------------------------+

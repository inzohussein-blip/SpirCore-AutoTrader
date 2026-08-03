//+------------------------------------------------------------------+
//|                                        SpirCore_Strategies.mqh    |
//|          SpirCore-AutoTrader :: Analysis / Signal Engine         |
//|                                                                  |
//|  Gold-oriented strategies adapted from geraked/metatrader5:      |
//|    * CEZLSMA : Chandelier Exit + ZLSMA on Heikin-Ashi close      |
//|                (trend-following; dynamic ATR stop) -> strong on  |
//|                XAUUSD momentum legs.                             |
//|    * BBRSI   : Bollinger Bands + RSI (mean-reversion) -> good    |
//|                for XAUUSD ranging / exhaustion snapbacks.        |
//|                                                                  |
//|  This module ONLY produces signals + suggested SL/TP. It never   |
//|  sends orders itself -> execution stays in the EA (decoupled).   |
//+------------------------------------------------------------------+
#property strict

//==================================================================
//  Public types
//==================================================================
enum ENUM_STRATEGY
{
   STRAT_NONE     = 0,   // None (manual only)
   STRAT_CEZLSMA  = 1,   // CEZLSMA  - trend (Chandelier Exit + ZLSMA + HA)
   STRAT_BBRSI    = 2,   // BBRSI    - mean reversion (Bollinger + RSI)
   STRAT_LRCUTB   = 3,   // LRCUTB   - momentum (Lin.Reg Candles + UT Bot)
   STRAT_2MACDSTO = 4,   // 2MACDSTO - momentum (two MACDs + Stochastic)
   STRAT_NWE      = 5    // NWE      - mean reversion (Nadaraya-Watson Envelope, adapted from NWERSIASF)
};

enum ENUM_SIGNAL { SIG_NONE = 0, SIG_BUY = 1, SIG_SELL = -1 };

// A computed signal, including the strategy's own suggested SL/TP prices.
struct SignalResult
{
   ENUM_SIGNAL sig;
   double      sl;   // suggested stop-loss price (0 = none)
   double      tp;   // suggested take-profit price (0 = none)
};

//==================================================================
//  Strategy parameters (extern inputs live in the main EA;
//  these globals are filled by StratConfigure()).
//==================================================================
// --- CEZLSMA ---
int    S_CE_AtrPeriod = 1;
double S_CE_Mult      = 0.75;
int    S_ZL_Period    = 50;
// --- BBRSI ---
int    S_BB_Period    = 500;
double S_BB_Dev       = 2.0;
int    S_RSI_Period   = 7;
// --- LRCUTB ---
int    S_LRC_Len      = 11;    // Linear-regression candle length
int    S_LRC_SmaLen   = 7;     // Signal SMA length over LRC close
int    S_UTB_AtrLen   = 1;     // UT Bot ATR length
double S_UTB_Coef     = 2.0;   // UT Bot ATR multiplier (sensitivity)
int    S_SwingLook    = 10;    // Swing-based SL lookback (bars)
// --- 2MACDSTO ---
int    S_StoLevel     = 30;    // Stochastic threshold (buy < level, sell > 100-level)
// --- NWE (Nadaraya-Watson Envelope) ---
int    S_NWE_Window   = 100;   // bars in the kernel window
double S_NWE_Band     = 8.0;   // Gaussian bandwidth (smoothness)
double S_NWE_Mult     = 3.0;   // envelope width = mult * mean abs deviation
// --- Regime (Auto mode) ---
int    S_AdxTrend     = 25;    // ADX >= this => trending (use trend strategy)
// --- shared risk shaping ---
double S_TPCoef       = 1.5;   // TP = entry +/- TPCoef * |entry-SL|
int    S_SLDevPts     = 50;    // extra buffer (points) added beyond the raw stop

// Working context (set once in StratInit)
string S_Symbol;
ENUM_TIMEFRAMES S_TF;
int    S_Digits;
double S_Point;

// Indicator handles
int    h_atr     = INVALID_HANDLE;   // Chandelier ATR
int    h_bands   = INVALID_HANDLE;
int    h_rsi     = INVALID_HANDLE;
int    h_atr_utb = INVALID_HANDLE;   // UT Bot ATR
int    h_macd_f  = INVALID_HANDLE;   // fast MACD (2MACDSTO)
int    h_macd_s  = INVALID_HANDLE;   // slow MACD (2MACDSTO)
int    h_stoch   = INVALID_HANDLE;   // Stochastic (2MACDSTO)
int    h_adx     = INVALID_HANDLE;   // ADX (regime / Auto mode)

//+------------------------------------------------------------------+
//| Push the EA's input values into this module.                     |
//+------------------------------------------------------------------+
void StratConfigure(int ceAtrPeriod, double ceMult, int zlPeriod,
                    int bbPeriod, double bbDev, int rsiPeriod,
                    int lrcLen, int lrcSmaLen, int utbAtrLen, double utbCoef,
                    int swingLook, double tpCoef, int slDevPts)
{
   S_CE_AtrPeriod = ceAtrPeriod;
   S_CE_Mult      = ceMult;
   S_ZL_Period    = zlPeriod;
   S_BB_Period    = bbPeriod;
   S_BB_Dev       = bbDev;
   S_RSI_Period   = rsiPeriod;
   S_LRC_Len      = lrcLen;
   S_LRC_SmaLen   = lrcSmaLen;
   S_UTB_AtrLen   = utbAtrLen;
   S_UTB_Coef     = utbCoef;
   S_SwingLook    = swingLook;
   S_TPCoef       = tpCoef;
   S_SLDevPts     = slDevPts;
}

//+------------------------------------------------------------------+
//| Extra config for the newer strategies + Auto-mode regime filter. |
//+------------------------------------------------------------------+
void StratConfigureExtra(int stoLevel, int nweWindow, double nweBand,
                         double nweMult, int adxTrend)
{
   S_StoLevel   = stoLevel;
   S_NWE_Window = nweWindow;
   S_NWE_Band   = nweBand;
   S_NWE_Mult   = nweMult;
   S_AdxTrend   = adxTrend;
}

//+------------------------------------------------------------------+
//| Create indicator handles. Call from OnInit.                      |
//+------------------------------------------------------------------+
bool StratInit(const string symbol, const ENUM_TIMEFRAMES tf)
{
   S_Symbol = symbol;
   S_TF     = tf;
   S_Digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   S_Point  = SymbolInfoDouble(symbol, SYMBOL_POINT);

   h_atr     = iATR(symbol, tf, S_CE_AtrPeriod);
   h_bands   = iBands(symbol, tf, S_BB_Period, 0, S_BB_Dev, PRICE_CLOSE);
   h_rsi     = iRSI(symbol, tf, S_RSI_Period, PRICE_CLOSE);
   h_atr_utb = iATR(symbol, tf, S_UTB_AtrLen);
   h_macd_f  = iMACD(symbol, tf, 12, 26, 9, PRICE_CLOSE);
   h_macd_s  = iMACD(symbol, tf, 24, 52, 9, PRICE_CLOSE);
   h_stoch   = iStochastic(symbol, tf, 14, 3, 3, MODE_SMA, STO_LOWHIGH);
   h_adx     = iADX(symbol, tf, 14);

   if(h_atr == INVALID_HANDLE || h_bands == INVALID_HANDLE ||
      h_rsi == INVALID_HANDLE || h_atr_utb == INVALID_HANDLE ||
      h_macd_f == INVALID_HANDLE || h_macd_s == INVALID_HANDLE ||
      h_stoch == INVALID_HANDLE || h_adx == INVALID_HANDLE)
   {
      Print("StratInit ERROR: failed to create one or more indicator handles.");
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Release handles. Call from OnDeinit.                             |
//+------------------------------------------------------------------+
void StratDeinit()
{
   if(h_atr     != INVALID_HANDLE) IndicatorRelease(h_atr);
   if(h_bands   != INVALID_HANDLE) IndicatorRelease(h_bands);
   if(h_rsi     != INVALID_HANDLE) IndicatorRelease(h_rsi);
   if(h_atr_utb != INVALID_HANDLE) IndicatorRelease(h_atr_utb);
   if(h_macd_f  != INVALID_HANDLE) IndicatorRelease(h_macd_f);
   if(h_macd_s  != INVALID_HANDLE) IndicatorRelease(h_macd_s);
   if(h_stoch   != INVALID_HANDLE) IndicatorRelease(h_stoch);
   if(h_adx     != INVALID_HANDLE) IndicatorRelease(h_adx);
}

//==================================================================
//  Small math helpers
//==================================================================

//+------------------------------------------------------------------+
//| Linear-regression endpoint (LSMA) over `len` values ending at    |
//| index `endIdx` in an as-series array (index 0 = newest).         |
//| Returns the regression line value at the newest bar of the win.  |
//+------------------------------------------------------------------+
double LSMA_Endpoint(const double &data[], const int endIdx, const int len)
{
   if(endIdx + len > ArraySize(data)) return(0.0);

   double sx = 0, sy = 0, sxx = 0, sxy = 0;
   // t = 0 is the OLDEST bar in the window, t = len-1 the newest (endIdx).
   for(int t = 0; t < len; t++)
   {
      double y = data[endIdx + (len - 1 - t)];
      sx  += t;
      sy  += y;
      sxx += (double)t * t;
      sxy += (double)t * y;
   }
   double denom = (len * sxx - sx * sx);
   if(MathAbs(denom) < 1e-12) return(data[endIdx]);
   double slope     = (len * sxy - sx * sy) / denom;
   double intercept = (sy - slope * sx) / len;
   return(intercept + slope * (len - 1)); // value at newest bar
}

//+------------------------------------------------------------------+
//| ZLSMA at a given shift = 2*LSMA - LSMA(LSMA).                     |
//+------------------------------------------------------------------+
double ZLSMA_At(const double &close[], const int shift, const int len)
{
   // First LSMA at `shift` and for the `len` bars needed to smooth again.
   double lsma1[];
   ArrayResize(lsma1, len);
   ArraySetAsSeries(lsma1, true);
   for(int i = 0; i < len; i++)
      lsma1[i] = LSMA_Endpoint(close, shift + i, len);

   double lsma2 = LSMA_Endpoint(lsma1, 0, len); // LSMA of the LSMA series
   return(2.0 * lsma1[0] - lsma2);
}

//+------------------------------------------------------------------+
//| Heikin-Ashi close at `shift` (independent of prior HA bars).     |
//+------------------------------------------------------------------+
double HA_Close(const int shift)
{
   double o = iOpen (S_Symbol, S_TF, shift);
   double h = iHigh (S_Symbol, S_TF, shift);
   double l = iLow  (S_Symbol, S_TF, shift);
   double c = iClose(S_Symbol, S_TF, shift);
   return((o + h + l + c) / 4.0);
}

//==================================================================
//  CEZLSMA
//==================================================================

//+------------------------------------------------------------------+
//| Compute Chandelier Exit direction (+1 long / -1 short) and the   |
//| active stop line at shift 1, using a trailing lookback.          |
//+------------------------------------------------------------------+
bool ChandelierState(int &dirOut, double &longStopOut, double &shortStopOut)
{
   const int LOOK = 400; // enough history for the trailing state to settle

   double high[], low[], close[], atr[];
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(atr,   true);

   if(CopyHigh (S_Symbol, S_TF, 0, LOOK, high)  < LOOK) return(false);
   if(CopyLow  (S_Symbol, S_TF, 0, LOOK, low)   < LOOK) return(false);
   if(CopyClose(S_Symbol, S_TF, 0, LOOK, close) < LOOK) return(false);
   if(CopyBuffer(h_atr, 0, 0, LOOK, atr)        < LOOK) return(false);

   double longStop[], shortStop[];
   int    dir[];
   ArrayResize(longStop,  LOOK);
   ArrayResize(shortStop, LOOK);
   ArrayResize(dir,       LOOK);
   ArraySetAsSeries(longStop,  true);
   ArraySetAsSeries(shortStop, true);
   ArraySetAsSeries(dir,       true);

   // ArrayResize does NOT zero new elements in MQL5; the loop reads
   // [i+1] on its first pass, so seed the arrays explicitly to avoid
   // garbage trailing-stop state (which would corrupt the signal).
   ArrayInitialize(longStop,  0.0);
   ArrayInitialize(shortStop, 0.0);
   ArrayInitialize(dir,       0);

   // iterate oldest -> newest (index LOOK-1 down to 0)
   for(int i = LOOK - 2; i >= 1; i--)
   {
      double longBasic  = high[i] - S_CE_Mult * atr[i];
      double shortBasic = low[i]  + S_CE_Mult * atr[i];

      longStop[i]  = (close[i + 1] > longStop[i + 1])
                     ? MathMax(longBasic,  longStop[i + 1])  : longBasic;
      shortStop[i] = (close[i + 1] < shortStop[i + 1])
                     ? MathMin(shortBasic, shortStop[i + 1]) : shortBasic;

      if(close[i] > shortStop[i + 1])      dir[i] = 1;
      else if(close[i] < longStop[i + 1])  dir[i] = -1;
      else                                 dir[i] = dir[i + 1];
   }

   dirOut       = dir[1];
   longStopOut  = longStop[1];
   shortStopOut = shortStop[1];
   return(true);
}

//+------------------------------------------------------------------+
//| CEZLSMA signal on the last CLOSED bar (shift 1).                 |
//|   BUY  : CE dir == +1  AND  HA_close[1] > ZLSMA[1]              |
//|   SELL : CE dir == -1  AND  HA_close[1] < ZLSMA[1]              |
//+------------------------------------------------------------------+
SignalResult Signal_CEZLSMA()
{
   SignalResult r; r.sig = SIG_NONE; r.sl = 0; r.tp = 0;

   double close[];
   ArraySetAsSeries(close, true);
   int need = S_ZL_Period * 2 + 5;
   if(CopyClose(S_Symbol, S_TF, 0, need, close) < need) return(r);

   int dir; double longStop, shortStop;
   if(!ChandelierState(dir, longStop, shortStop)) return(r);

   double zl  = ZLSMA_At(close, 1, S_ZL_Period);
   double hac = HA_Close(1);
   double dev = S_SLDevPts * S_Point;

   if(dir == 1 && hac > zl)
   {
      r.sig = SIG_BUY;
      r.sl  = longStop - dev;
   }
   else if(dir == -1 && hac < zl)
   {
      r.sig = SIG_SELL;
      r.sl  = shortStop + dev;
   }
   return(r);
}

//==================================================================
//  BBRSI
//==================================================================

//+------------------------------------------------------------------+
//| BBRSI signal on the last two closed bars.                        |
//|   BUY  : RSI[2]<30 & Close[2]<LB[2]  then RSI[1]>30 &           |
//|          Close[1]>LB[1] & RSI[1]<50 & Close[1]<MB[1]           |
//|   SELL : symmetric on the upper band / RSI 70.                  |
//+------------------------------------------------------------------+
SignalResult Signal_BBRSI()
{
   SignalResult r; r.sig = SIG_NONE; r.sl = 0; r.tp = 0;

   double mb[], ub[], lb[], rsi[], close[];
   ArraySetAsSeries(mb, true); ArraySetAsSeries(ub, true); ArraySetAsSeries(lb, true);
   ArraySetAsSeries(rsi, true); ArraySetAsSeries(close, true);

   if(CopyBuffer(h_bands, 0, 0, 4, mb) < 4) return(r); // base/middle
   if(CopyBuffer(h_bands, 1, 0, 4, ub) < 4) return(r); // upper
   if(CopyBuffer(h_bands, 2, 0, 4, lb) < 4) return(r); // lower
   if(CopyBuffer(h_rsi,   0, 0, 4, rsi) < 4) return(r);
   if(CopyClose(S_Symbol, S_TF, 0, 4, close) < 4) return(r);

   double dev = S_SLDevPts * S_Point;

   // --- BUY (mean reversion up off the lower band) ---
   if(rsi[2] < 30 && close[2] < lb[2] &&
      rsi[1] > 30 && close[1] > lb[1] &&
      rsi[1] < 50 && close[1] < mb[1])
   {
      r.sig = SIG_BUY;
      r.sl  = lb[1] - dev;   // stop just below the lower band
      // TP shaped from risk distance later in BuildTP()
   }
   // --- SELL (mean reversion down off the upper band) ---
   else if(rsi[2] > 70 && close[2] > ub[2] &&
           rsi[1] < 70 && close[1] < ub[1] &&
           rsi[1] > 50 && close[1] > mb[1])
   {
      r.sig = SIG_SELL;
      r.sl  = ub[1] + dev;   // stop just above the upper band
   }
   return(r);
}

//==================================================================
//  LRCUTB  (Linear Regression Candles + UT Bot)
//==================================================================

//+------------------------------------------------------------------+
//| Simple moving average of the LRC-close series ending at `shift`. |
//| LRC close at each bar = LSMA(close, LRC_Len). Signal = SMA of    |
//| those over LRC_SmaLen bars.                                      |
//+------------------------------------------------------------------+
double LRC_Signal(const double &close[], const int shift, const int lrcLen, const int smaLen)
{
   double sum = 0;
   for(int i = 0; i < smaLen; i++)
      sum += LSMA_Endpoint(close, shift + i, lrcLen);
   return(sum / smaLen);
}

//+------------------------------------------------------------------+
//| UT Bot trailing-stop crossover signals over a lookback.          |
//| Fills as-series boolean arrays: buySig[i]/sellSig[i] true when   |
//| close crosses above/below the ATR trailing stop at bar i.        |
//+------------------------------------------------------------------+
bool UTBotState(bool &buySig[], bool &sellSig[], const int count)
{
   double close[], atr[];
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(atr,   true);
   if(CopyClose(S_Symbol, S_TF, 0, count, close) < count) return(false);
   if(CopyBuffer(h_atr_utb, 0, 0, count, atr)    < count) return(false);

   double stop[];
   ArrayResize(stop, count);
   ArraySetAsSeries(stop, true);
   ArrayInitialize(stop, 0.0); // seed: loop reads stop[i+1] on first pass

   ArrayResize(buySig,  count);
   ArrayResize(sellSig, count);
   ArraySetAsSeries(buySig,  true);
   ArraySetAsSeries(sellSig, true);
   ArrayInitialize(buySig,  false);
   ArrayInitialize(sellSig, false);

   // iterate oldest -> newest
   for(int i = count - 2; i >= 1; i--)
   {
      double nLoss = S_UTB_Coef * atr[i];
      double prevStop = stop[i + 1];

      if(close[i] > prevStop && close[i + 1] > prevStop)
         stop[i] = MathMax(prevStop, close[i] - nLoss);
      else if(close[i] < prevStop && close[i + 1] < prevStop)
         stop[i] = MathMin(prevStop, close[i] + nLoss);
      else if(close[i] > prevStop)
         stop[i] = close[i] - nLoss;
      else
         stop[i] = close[i] + nLoss;

      // crossover detection vs the previous bar's stop
      if(close[i] > stop[i] && close[i + 1] <= prevStop) buySig[i]  = true;
      if(close[i] < stop[i] && close[i + 1] >= prevStop) sellSig[i] = true;
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Swing-based stop: recent lowest-low (buy) / highest-high (sell). |
//+------------------------------------------------------------------+
double SwingSL(const bool isBuy)
{
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low,  true);
   if(CopyHigh(S_Symbol, S_TF, 1, S_SwingLook, high) < S_SwingLook) return(0.0);
   if(CopyLow (S_Symbol, S_TF, 1, S_SwingLook, low)  < S_SwingLook) return(0.0);

   double dev = S_SLDevPts * S_Point;
   if(isBuy)
   {
      int idx = ArrayMinimum(low, 0, S_SwingLook);
      return(low[idx] - dev);
   }
   int idx = ArrayMaximum(high, 0, S_SwingLook);
   return(high[idx] + dev);
}

//+------------------------------------------------------------------+
//| LRCUTB signal on the last closed bar.                            |
//|   BUY  : LRC_C[1] > LRC_O[1] AND LRC_C[1] > LRC_S[1]            |
//|          AND a UT-Bot bullish cross within the last 3 bars.     |
//|   SELL : symmetric (bearish).                                   |
//+------------------------------------------------------------------+
SignalResult Signal_LRCUTB()
{
   SignalResult r; r.sig = SIG_NONE; r.sl = 0; r.tp = 0;

   int need = S_LRC_Len + S_LRC_SmaLen + 5;
   double close[], open[];
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(open,  true);
   if(CopyClose(S_Symbol, S_TF, 0, need, close) < need) return(r);
   if(CopyOpen (S_Symbol, S_TF, 0, need, open)  < need) return(r);

   double lrcC = LSMA_Endpoint(close, 1, S_LRC_Len);
   double lrcO = LSMA_Endpoint(open,  1, S_LRC_Len);
   double lrcS = LRC_Signal(close, 1, S_LRC_Len, S_LRC_SmaLen);

   bool buySig[], sellSig[];
   if(!UTBotState(buySig, sellSig, 300)) return(r);

   bool utbBull = (buySig[1]  || buySig[2]  || buySig[3]);
   bool utbBear = (sellSig[1] || sellSig[2] || sellSig[3]);

   if(lrcC > lrcO && lrcC > lrcS && utbBull)
   {
      r.sig = SIG_BUY;
      r.sl  = SwingSL(true);
   }
   else if(lrcC < lrcO && lrcC < lrcS && utbBear)
   {
      r.sig = SIG_SELL;
      r.sl  = SwingSL(false);
   }
   return(r);
}

//==================================================================
//  2MACDSTO  (two MACDs + Stochastic) -- momentum
//==================================================================

//+------------------------------------------------------------------+
//| BUY  : both MACD lines above their signal (bullish) AND          |
//|        Stochastic oversold (< level) -> momentum turning up.     |
//| SELL : both MACD bearish AND Stochastic overbought (>100-level). |
//| SL from the recent swing.                                        |
//+------------------------------------------------------------------+
SignalResult Signal_2MACDSTO()
{
   SignalResult r; r.sig = SIG_NONE; r.sl = 0; r.tp = 0;

   double mf[], sf[], ms[], ss[], sto[];
   ArraySetAsSeries(mf, true); ArraySetAsSeries(sf, true);
   ArraySetAsSeries(ms, true); ArraySetAsSeries(ss, true);
   ArraySetAsSeries(sto, true);
   // MACD buffers: 0 = main, 1 = signal.
   if(CopyBuffer(h_macd_f, 0, 0, 3, mf) < 3) return(r);
   if(CopyBuffer(h_macd_f, 1, 0, 3, sf) < 3) return(r);
   if(CopyBuffer(h_macd_s, 0, 0, 3, ms) < 3) return(r);
   if(CopyBuffer(h_macd_s, 1, 0, 3, ss) < 3) return(r);
   if(CopyBuffer(h_stoch,  0, 0, 3, sto) < 3) return(r); // main line

   bool bullish = (mf[1] > sf[1]) && (ms[1] > ss[1]);
   bool bearish = (mf[1] < sf[1]) && (ms[1] < ss[1]);

   if(bullish && sto[1] < S_StoLevel)
   {
      r.sig = SIG_BUY;
      r.sl  = SwingSL(true);
   }
   else if(bearish && sto[1] > (100 - S_StoLevel))
   {
      r.sig = SIG_SELL;
      r.sl  = SwingSL(false);
   }
   return(r);
}

//==================================================================
//  NWE  (Nadaraya-Watson Envelope) -- mean reversion
//  Adapted from NWERSIASF: kernel-smoothed price + RSI filter.
//==================================================================

//+------------------------------------------------------------------+
//| Nadaraya-Watson estimate at `shift` using a Gaussian kernel over |
//| S_NWE_Window bars, and the mean absolute deviation (band width). |
//+------------------------------------------------------------------+
bool NWEstimate(const int shift, double &nwOut, double &maeOut)
{
   int w = S_NWE_Window;
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(S_Symbol, S_TF, 0, shift + w + 1, close) < shift + w) return(false);

   double sumW = 0.0, sumWC = 0.0;
   for(int k = 0; k < w; k++)
   {
      double weight = MathExp(-(double)(k * k) / (2.0 * S_NWE_Band * S_NWE_Band));
      sumW  += weight;
      sumWC += weight * close[shift + k];
   }
   if(sumW <= 0.0) return(false);
   double nw = sumWC / sumW;

   double madSum = 0.0;
   for(int k = 0; k < w; k++)
      madSum += MathAbs(close[shift + k] - nw);
   double mae = (madSum / w) * S_NWE_Mult;

   nwOut  = nw;
   maeOut = mae;
   return(true);
}

//+------------------------------------------------------------------+
//| BUY  : close closes back inside from below the lower band AND    |
//|        RSI oversold. SELL : symmetric at the upper band.         |
//+------------------------------------------------------------------+
SignalResult Signal_NWE()
{
   SignalResult r; r.sig = SIG_NONE; r.sl = 0; r.tp = 0;

   double nw, mae;
   if(!NWEstimate(1, nw, mae)) return(r);
   double upper = nw + mae;
   double lower = nw - mae;

   double rsi[], close[];
   ArraySetAsSeries(rsi, true); ArraySetAsSeries(close, true);
   if(CopyBuffer(h_rsi, 0, 0, 3, rsi) < 3) return(r);
   if(CopyClose(S_Symbol, S_TF, 0, 3, close) < 3) return(r);

   double dev = S_SLDevPts * S_Point;

   // Reversion long: previous bar dipped below lower band, RSI oversold.
   if(close[2] < lower && close[1] > close[2] && rsi[1] < 40)
   {
      r.sig = SIG_BUY;
      r.sl  = lower - dev;
   }
   else if(close[2] > upper && close[1] < close[2] && rsi[1] > 60)
   {
      r.sig = SIG_SELL;
      r.sl  = upper + dev;
   }
   return(r);
}

//==================================================================
//  Regime / Hybrid / Auto  (selection modes)
//==================================================================

//+------------------------------------------------------------------+
//| Is the market trending? (ADX main >= threshold on last bar.)     |
//+------------------------------------------------------------------+
bool RegimeIsTrending()
{
   double adx[];
   ArraySetAsSeries(adx, true);
   if(CopyBuffer(h_adx, 0, 0, 3, adx) < 3) return(false); // buffer 0 = ADX main
   return(adx[1] >= S_AdxTrend);
}

//+------------------------------------------------------------------+
//| AUTO: route to a trend strategy when trending, else a            |
//| mean-reversion strategy. Picks the signal from the chosen one.   |
//+------------------------------------------------------------------+
SignalResult Signal_Auto()
{
   if(RegimeIsTrending())
      return(Signal_CEZLSMA());   // trend regime -> trend follower
   return(Signal_BBRSI());        // range regime -> mean reversion
}

//+------------------------------------------------------------------+
//| HYBRID (confluence): poll all base strategies; act only when at  |
//| least `minAgree` agree on the SAME direction. SL = the most      |
//| conservative (nearest-to-price) among the agreeing ones.         |
//+------------------------------------------------------------------+
SignalResult Signal_Hybrid(const int minAgree)
{
   SignalResult r; r.sig = SIG_NONE; r.sl = 0; r.tp = 0;

   SignalResult all[5];
   all[0] = Signal_CEZLSMA();
   all[1] = Signal_BBRSI();
   all[2] = Signal_LRCUTB();
   all[3] = Signal_2MACDSTO();
   all[4] = Signal_NWE();

   int buys = 0, sells = 0;
   double buySL = 0.0, sellSL = 0.0;   // most conservative (highest buy SL / lowest sell SL)
   for(int i = 0; i < 5; i++)
   {
      if(all[i].sig == SIG_BUY)
      {
         buys++;
         if(all[i].sl > 0 && (buySL == 0.0 || all[i].sl > buySL)) buySL = all[i].sl;
      }
      else if(all[i].sig == SIG_SELL)
      {
         sells++;
         if(all[i].sl > 0 && (sellSL == 0.0 || all[i].sl < sellSL)) sellSL = all[i].sl;
      }
   }

   if(buys >= minAgree && buys > sells)
   {
      r.sig = SIG_BUY;  r.sl = buySL;
   }
   else if(sells >= minAgree && sells > buys)
   {
      r.sig = SIG_SELL; r.sl = sellSL;
   }
   return(r);
}

//==================================================================
//  Dispatcher
//==================================================================

//+------------------------------------------------------------------+
//| Fill in TP from SL using the risk-reward coefficient, given the  |
//| intended entry price (ask for buy, bid for sell).                |
//+------------------------------------------------------------------+
void BuildTP(SignalResult &r, const double entry)
{
   if(r.sig == SIG_NONE || r.sl <= 0) return;
   double risk = MathAbs(entry - r.sl);
   if(risk <= 0) return;
   r.tp = (r.sig == SIG_BUY) ? entry + S_TPCoef * risk
                             : entry - S_TPCoef * risk;
}

//+------------------------------------------------------------------+
//| Return the signal for the selected strategy.                     |
//+------------------------------------------------------------------+
SignalResult GetStrategySignal(const ENUM_STRATEGY strat)
{
   SignalResult r; r.sig = SIG_NONE; r.sl = 0; r.tp = 0;
   switch(strat)
   {
      case STRAT_CEZLSMA:  return(Signal_CEZLSMA());
      case STRAT_BBRSI:    return(Signal_BBRSI());
      case STRAT_LRCUTB:   return(Signal_LRCUTB());
      case STRAT_2MACDSTO: return(Signal_2MACDSTO());
      case STRAT_NWE:      return(Signal_NWE());
      default:             return(r);
   }
}
//+------------------------------------------------------------------+

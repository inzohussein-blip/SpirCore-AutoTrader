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
   STRAT_CEZLSMA  = 1,   // CEZLSMA - trend (Chandelier Exit + ZLSMA + HA)
   STRAT_BBRSI    = 2    // BBRSI - mean reversion (Bollinger + RSI)
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
// --- shared risk shaping ---
double S_TPCoef       = 1.5;   // TP = entry +/- TPCoef * |entry-SL|
int    S_SLDevPts     = 50;    // extra buffer (points) added beyond the raw stop

// Working context (set once in StratInit)
string S_Symbol;
ENUM_TIMEFRAMES S_TF;
int    S_Digits;
double S_Point;

// Indicator handles
int    h_atr   = INVALID_HANDLE;
int    h_bands = INVALID_HANDLE;
int    h_rsi   = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Push the EA's input values into this module.                     |
//+------------------------------------------------------------------+
void StratConfigure(int ceAtrPeriod, double ceMult, int zlPeriod,
                    int bbPeriod, double bbDev, int rsiPeriod,
                    double tpCoef, int slDevPts)
{
   S_CE_AtrPeriod = ceAtrPeriod;
   S_CE_Mult      = ceMult;
   S_ZL_Period    = zlPeriod;
   S_BB_Period    = bbPeriod;
   S_BB_Dev       = bbDev;
   S_RSI_Period   = rsiPeriod;
   S_TPCoef       = tpCoef;
   S_SLDevPts     = slDevPts;
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

   h_atr   = iATR(symbol, tf, S_CE_AtrPeriod);
   h_bands = iBands(symbol, tf, S_BB_Period, 0, S_BB_Dev, PRICE_CLOSE);
   h_rsi   = iRSI(symbol, tf, S_RSI_Period, PRICE_CLOSE);

   if(h_atr == INVALID_HANDLE || h_bands == INVALID_HANDLE || h_rsi == INVALID_HANDLE)
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
   if(h_atr   != INVALID_HANDLE) IndicatorRelease(h_atr);
   if(h_bands != INVALID_HANDLE) IndicatorRelease(h_bands);
   if(h_rsi   != INVALID_HANDLE) IndicatorRelease(h_rsi);
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
      double bandWidth = mb[1] - lb[1];
      r.sig = SIG_BUY;
      r.sl  = lb[1] - bandWidth * 0.0 - dev; // stop just below the lower band
      // TP shaped from risk distance later in BuildTP()
   }
   // --- SELL (mean reversion down off the upper band) ---
   else if(rsi[2] > 70 && close[2] > ub[2] &&
           rsi[1] < 70 && close[1] < ub[1] &&
           rsi[1] > 50 && close[1] > mb[1])
   {
      double bandWidth = ub[1] - mb[1];
      r.sig = SIG_SELL;
      r.sl  = ub[1] + bandWidth * 0.0 + dev; // stop just above the upper band
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
      case STRAT_CEZLSMA: return(Signal_CEZLSMA());
      case STRAT_BBRSI:   return(Signal_BBRSI());
      default:            return(r);
   }
}
//+------------------------------------------------------------------+

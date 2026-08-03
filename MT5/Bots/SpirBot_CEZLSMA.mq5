//+------------------------------------------------------------------+
//|                                          SpirBot_CEZLSMA.mq5      |
//|   SpirCore :: standalone TEST bot -- CEZLSMA (trend)              |
//|                                                                  |
//|  Self-contained. Chandelier Exit + ZLSMA on Heikin-Ashi close.    |
//|  Buy when the Chandelier trend is up AND the HA close is above    |
//|  the ZLSMA; sell on the mirror. Simplified: fixed lot + SL/TP.    |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input double InpLot       = 0.10;    // Fixed lot
input int    InpSL        = 300;     // Stop Loss (points)
input int    InpTP        = 600;     // Take Profit (points)
input int    InpMaxSpread = 30;      // Max spread (points); 0 = ignore
input long   InpMagic     = 500002;  // Magic number
input int    InpAtrPeriod = 1;       // Chandelier ATR period
input double InpMult      = 0.75;    // Chandelier ATR multiplier
input int    InpZLPeriod  = 50;      // ZLSMA period

CTrade   trade;
int      h_atr;
datetime g_lastBar = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   h_atr = iATR(_Symbol, _Period, InpAtrPeriod);
   if(h_atr == INVALID_HANDLE) return(INIT_FAILED);
   return(INIT_SUCCEEDED);
}

bool NewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == g_lastBar) return(false);
   g_lastBar = t;
   return(true);
}

bool HasPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return(true);
   }
   return(false);
}

bool SpreadOK()
{
   if(InpMaxSpread <= 0) return(true);
   return((long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= InpMaxSpread);
}

void Open(bool isBuy)
{
   double pt    = _Point;
   double price = isBuy ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;
   if(InpSL > 0) sl = isBuy ? price - InpSL * pt : price + InpSL * pt;
   if(InpTP > 0) tp = isBuy ? price + InpTP * pt : price - InpTP * pt;
   int d = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, d);
   tp = NormalizeDouble(tp, d);
   if(isBuy) trade.Buy(InpLot, _Symbol, price, sl, tp, "SpirBot CEZLSMA");
   else      trade.Sell(InpLot, _Symbol, price, sl, tp, "SpirBot CEZLSMA");
}

// Linear-regression endpoint (LSMA) over `len` values ending at endIdx
// in an as-series array (index 0 = newest).
double LSMA(const double &data[], const int endIdx, const int len)
{
   if(endIdx + len > ArraySize(data)) return(0.0);
   double sx = 0, sy = 0, sxx = 0, sxy = 0;
   for(int t = 0; t < len; t++)
   {
      double y = data[endIdx + (len - 1 - t)];
      sx += t; sy += y; sxx += (double)t * t; sxy += (double)t * y;
   }
   double denom = (len * sxx - sx * sx);
   if(MathAbs(denom) < 1e-12) return(data[endIdx]);
   double slope = (len * sxy - sx * sy) / denom;
   double intercept = (sy - slope * sx) / len;
   return(intercept + slope * (len - 1));
}

// ZLSMA at shift 1 = 2*LSMA - LSMA(LSMA).
double ZLSMA(const double &close[], const int len)
{
   double lsma1[];
   ArrayResize(lsma1, len);
   ArraySetAsSeries(lsma1, true);
   for(int i = 0; i < len; i++)
      lsma1[i] = LSMA(close, 1 + i, len);
   double lsma2 = LSMA(lsma1, 0, len);
   return(2.0 * lsma1[0] - lsma2);
}

void OnTick()
{
   if(!NewBar()) return;
   if(HasPosition() || !SpreadOK()) return;

   const int LOOK = 400;
   double high[], low[], close[], atr[];
   ArraySetAsSeries(high, true); ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true); ArraySetAsSeries(atr, true);
   if(CopyHigh(_Symbol, _Period, 0, LOOK, high) < LOOK) return;
   if(CopyLow(_Symbol, _Period, 0, LOOK, low) < LOOK) return;
   if(CopyClose(_Symbol, _Period, 0, LOOK, close) < LOOK) return;
   if(CopyBuffer(h_atr, 0, 0, LOOK, atr) < LOOK) return;

   // Chandelier Exit trailing state.
   double longStop[], shortStop[];
   int    dir[];
   ArrayResize(longStop, LOOK);  ArrayResize(shortStop, LOOK);  ArrayResize(dir, LOOK);
   ArraySetAsSeries(longStop, true); ArraySetAsSeries(shortStop, true); ArraySetAsSeries(dir, true);
   ArrayInitialize(longStop, 0.0); ArrayInitialize(shortStop, 0.0); ArrayInitialize(dir, 0);

   for(int i = LOOK - 2; i >= 1; i--)
   {
      double lb = high[i] - InpMult * atr[i];
      double sb = low[i]  + InpMult * atr[i];
      longStop[i]  = (close[i + 1] > longStop[i + 1])  ? MathMax(lb, longStop[i + 1])  : lb;
      shortStop[i] = (close[i + 1] < shortStop[i + 1]) ? MathMin(sb, shortStop[i + 1]) : sb;
      if(close[i] > shortStop[i + 1])      dir[i] = 1;
      else if(close[i] < longStop[i + 1])  dir[i] = -1;
      else                                 dir[i] = dir[i + 1];
   }

   double zl  = ZLSMA(close, InpZLPeriod);
   double hac = (iOpen(_Symbol, _Period, 1) + high[1] + low[1] + close[1]) / 4.0;

   if(dir[1] == 1 && hac > zl)       Open(true);
   else if(dir[1] == -1 && hac < zl) Open(false);
}
//+------------------------------------------------------------------+

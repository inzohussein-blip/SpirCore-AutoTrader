//+------------------------------------------------------------------+
//|                                           SpirBot_LRCUTB.mq5      |
//|   SpirCore :: standalone TEST bot -- LRCUTB (momentum)            |
//|                                                                  |
//|  Self-contained. Linear-Regression Candles + UT Bot (ATR trail). |
//|  Buy when the LR candle is bullish and above its signal AND a     |
//|  UT-Bot bullish cross occurred within the last 3 bars. Simplified:|
//|  fixed lot + SL/TP.                                              |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input double InpLot       = 0.10;    // Fixed lot
input int    InpSL        = 300;     // Stop Loss (points)
input int    InpTP        = 600;     // Take Profit (points)
input int    InpMaxSpread = 30;      // Max spread (points); 0 = ignore
input long   InpMagic     = 500003;  // Magic number
input int    InpLrcLen    = 11;      // Linear-regression candle length
input int    InpLrcSma    = 7;       // Signal SMA length
input int    InpUtbAtrLen = 1;       // UT Bot ATR length
input double InpUtbCoef   = 2.0;     // UT Bot ATR multiplier

CTrade   trade;
int      h_atr;
datetime g_lastBar = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   h_atr = iATR(_Symbol, _Period, InpUtbAtrLen);
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
   if(isBuy) trade.Buy(InpLot, _Symbol, price, sl, tp, "SpirBot LRCUTB");
   else      trade.Sell(InpLot, _Symbol, price, sl, tp, "SpirBot LRCUTB");
}

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

void OnTick()
{
   if(!NewBar()) return;
   if(HasPosition() || !SpreadOK()) return;

   const int LOOK = 300;
   double close[], open[], atr[];
   ArraySetAsSeries(close, true); ArraySetAsSeries(open, true); ArraySetAsSeries(atr, true);
   if(CopyClose(_Symbol, _Period, 0, LOOK, close) < LOOK) return;
   if(CopyOpen(_Symbol, _Period, 0, LOOK, open) < LOOK) return;
   if(CopyBuffer(h_atr, 0, 0, LOOK, atr) < LOOK) return;

   // Linear-regression candles at shift 1 + signal (SMA of LRC close).
   double lrcC = LSMA(close, 1, InpLrcLen);
   double lrcO = LSMA(open,  1, InpLrcLen);
   double sum  = 0;
   for(int i = 0; i < InpLrcSma; i++) sum += LSMA(close, 1 + i, InpLrcLen);
   double lrcS = sum / InpLrcSma;

   // UT Bot ATR trailing stop + crossover flags.
   double stop[];
   bool buySig[], sellSig[];
   ArrayResize(stop, LOOK); ArrayResize(buySig, LOOK); ArrayResize(sellSig, LOOK);
   ArraySetAsSeries(stop, true); ArraySetAsSeries(buySig, true); ArraySetAsSeries(sellSig, true);
   ArrayInitialize(stop, 0.0); ArrayInitialize(buySig, false); ArrayInitialize(sellSig, false);
   for(int i = LOOK - 2; i >= 1; i--)
   {
      double nloss = InpUtbCoef * atr[i];
      double prev  = stop[i + 1];
      double c = close[i], cp = close[i + 1];
      if(c > prev && cp > prev)      stop[i] = MathMax(prev, c - nloss);
      else if(c < prev && cp < prev) stop[i] = MathMin(prev, c + nloss);
      else if(c > prev)              stop[i] = c - nloss;
      else                           stop[i] = c + nloss;
      if(c > stop[i] && cp <= prev)  buySig[i]  = true;
      if(c < stop[i] && cp >= prev)  sellSig[i] = true;
   }
   bool utbBull = (buySig[1]  || buySig[2]  || buySig[3]);
   bool utbBear = (sellSig[1] || sellSig[2] || sellSig[3]);

   if(lrcC > lrcO && lrcC > lrcS && utbBull)      Open(true);
   else if(lrcC < lrcO && lrcC < lrcS && utbBear) Open(false);
}
//+------------------------------------------------------------------+

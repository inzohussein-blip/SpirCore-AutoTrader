//+------------------------------------------------------------------+
//|                                             SpirBot_NWE.mq5       |
//|   SpirCore :: standalone TEST bot -- NWE (advanced mean reversion)|
//|                                                                  |
//|  Self-contained. Nadaraya-Watson Envelope (Gaussian kernel) + RSI |
//|  filter. Buy on a snap-back up from below the lower band while    |
//|  RSI is low; sell on the mirror. Simplified: fixed lot + SL/TP.   |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input double InpLot       = 0.10;    // Fixed lot
input int    InpSL        = 300;     // Stop Loss (points)
input int    InpTP        = 600;     // Take Profit (points)
input int    InpMaxSpread = 30;      // Max spread (points); 0 = ignore
input long   InpMagic     = 500005;  // Magic number
input int    InpWindow    = 100;     // Kernel window (bars)
input double InpBand      = 8.0;     // Gaussian bandwidth
input double InpMult      = 3.0;     // Envelope width multiplier
input int    InpRSIPeriod = 14;      // RSI period

CTrade   trade;
int      h_rsi;
datetime g_lastBar = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   h_rsi = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   if(h_rsi == INVALID_HANDLE) return(INIT_FAILED);
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
   if(isBuy) trade.Buy(InpLot, _Symbol, price, sl, tp, "SpirBot NWE");
   else      trade.Sell(InpLot, _Symbol, price, sl, tp, "SpirBot NWE");
}

// Nadaraya-Watson estimate + envelope half-width at shift 1.
bool NW(double &nwOut, double &maeOut)
{
   int w = InpWindow;
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(_Symbol, _Period, 0, 1 + w + 1, close) < 1 + w) return(false);
   double sumW = 0, sumWC = 0;
   for(int k = 0; k < w; k++)
   {
      double weight = MathExp(-(double)(k * k) / (2.0 * InpBand * InpBand));
      sumW  += weight;
      sumWC += weight * close[1 + k];
   }
   if(sumW <= 0) return(false);
   double nw = sumWC / sumW;
   double mad = 0;
   for(int k = 0; k < w; k++) mad += MathAbs(close[1 + k] - nw);
   nwOut  = nw;
   maeOut = (mad / w) * InpMult;
   return(true);
}

void OnTick()
{
   if(!NewBar()) return;
   if(HasPosition() || !SpreadOK()) return;

   double nw, mae;
   if(!NW(nw, mae)) return;
   double upper = nw + mae, lower = nw - mae;

   double rsi[], close[];
   ArraySetAsSeries(rsi, true); ArraySetAsSeries(close, true);
   if(CopyBuffer(h_rsi, 0, 0, 3, rsi) < 3) return;
   if(CopyClose(_Symbol, _Period, 0, 3, close) < 3) return;

   if(close[2] < lower && close[1] > close[2] && rsi[1] < 40)      Open(true);
   else if(close[2] > upper && close[1] < close[2] && rsi[1] > 60) Open(false);
}
//+------------------------------------------------------------------+

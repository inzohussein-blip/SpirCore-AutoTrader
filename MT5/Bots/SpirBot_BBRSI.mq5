//+------------------------------------------------------------------+
//|                                            SpirBot_BBRSI.mq5      |
//|   SpirCore :: standalone TEST bot -- BBRSI (mean reversion)       |
//|                                                                  |
//|  Self-contained (no project includes). Drop it straight onto an  |
//|  XAUUSD chart or the Strategy Tester. Simplified for testing:     |
//|  new-bar signal, spread filter, fixed lot, fixed SL/TP.          |
//|                                                                  |
//|  Strategy: Bollinger Bands + RSI. Buy on a snap-back up off the   |
//|  lower band from oversold; sell symmetrically off the upper band. |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input double InpLot       = 0.10;    // Fixed lot
input int    InpSL        = 300;     // Stop Loss (points)
input int    InpTP        = 600;     // Take Profit (points)
input int    InpMaxSpread = 30;      // Max spread (points); 0 = ignore
input long   InpMagic     = 500001;  // Magic number
input int    InpBBPeriod  = 500;     // Bollinger period
input double InpBBDev     = 2.0;     // Bollinger deviations
input int    InpRSIPeriod = 7;       // RSI period

CTrade   trade;
int      h_bands, h_rsi;
datetime g_lastBar = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   h_bands = iBands(_Symbol, _Period, InpBBPeriod, 0, InpBBDev, PRICE_CLOSE);
   h_rsi   = iRSI(_Symbol, _Period, InpRSIPeriod, PRICE_CLOSE);
   if(h_bands == INVALID_HANDLE || h_rsi == INVALID_HANDLE)
      return(INIT_FAILED);
   return(INIT_SUCCEEDED);
}

// True once per newly-closed bar.
bool NewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t == g_lastBar) return(false);
   g_lastBar = t;
   return(true);
}

// One position at a time (this bot's magic).
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
   long sp = (long)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return(sp <= InpMaxSpread);
}

// Open a market order with fixed SL/TP (simplified; not the ECN 2-step).
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
   if(isBuy) trade.Buy(InpLot, _Symbol, price, sl, tp, "SpirBot BBRSI");
   else      trade.Sell(InpLot, _Symbol, price, sl, tp, "SpirBot BBRSI");
}

void OnTick()
{
   if(!NewBar()) return;
   if(HasPosition() || !SpreadOK()) return;

   double mb[], ub[], lb[], rsi[], close[];
   ArraySetAsSeries(mb, true); ArraySetAsSeries(ub, true); ArraySetAsSeries(lb, true);
   ArraySetAsSeries(rsi, true); ArraySetAsSeries(close, true);
   if(CopyBuffer(h_bands, 0, 0, 4, mb) < 4) return;
   if(CopyBuffer(h_bands, 1, 0, 4, ub) < 4) return;
   if(CopyBuffer(h_bands, 2, 0, 4, lb) < 4) return;
   if(CopyBuffer(h_rsi,   0, 0, 4, rsi) < 4) return;
   if(CopyClose(_Symbol, _Period, 0, 4, close) < 4) return;

   // [2] = two bars ago, [1] = last closed bar.
   if(rsi[2] < 30 && close[2] < lb[2] &&
      rsi[1] > 30 && close[1] > lb[1] &&
      rsi[1] < 50 && close[1] < mb[1])
      Open(true);
   else if(rsi[2] > 70 && close[2] > ub[2] &&
           rsi[1] < 70 && close[1] < ub[1] &&
           rsi[1] > 50 && close[1] > mb[1])
      Open(false);
}
//+------------------------------------------------------------------+

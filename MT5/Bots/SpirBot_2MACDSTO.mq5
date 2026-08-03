//+------------------------------------------------------------------+
//|                                         SpirBot_2MACDSTO.mq5      |
//|   SpirCore :: standalone TEST bot -- 2MACDSTO (momentum)          |
//|                                                                  |
//|  Self-contained. Two MACDs (fast + slow) confirmed by Stochastic. |
//|  Simplified for testing: new-bar signal, spread filter, fixed     |
//|  lot, fixed SL/TP.                                               |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input double InpLot       = 0.10;    // Fixed lot
input int    InpSL        = 300;     // Stop Loss (points)
input int    InpTP        = 600;     // Take Profit (points)
input int    InpMaxSpread = 30;      // Max spread (points); 0 = ignore
input long   InpMagic     = 500004;  // Magic number
input int    InpStoLevel  = 30;      // Stochastic threshold

CTrade   trade;
int      h_mf, h_ms, h_sto;
datetime g_lastBar = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   h_mf  = iMACD(_Symbol, _Period, 12, 26, 9, PRICE_CLOSE);
   h_ms  = iMACD(_Symbol, _Period, 24, 52, 9, PRICE_CLOSE);
   h_sto = iStochastic(_Symbol, _Period, 14, 3, 3, MODE_SMA, STO_LOWHIGH);
   if(h_mf == INVALID_HANDLE || h_ms == INVALID_HANDLE || h_sto == INVALID_HANDLE)
      return(INIT_FAILED);
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
   if(isBuy) trade.Buy(InpLot, _Symbol, price, sl, tp, "SpirBot 2MACDSTO");
   else      trade.Sell(InpLot, _Symbol, price, sl, tp, "SpirBot 2MACDSTO");
}

void OnTick()
{
   if(!NewBar()) return;
   if(HasPosition() || !SpreadOK()) return;

   double mf[], sf[], ms[], ss[], sto[];
   ArraySetAsSeries(mf, true); ArraySetAsSeries(sf, true);
   ArraySetAsSeries(ms, true); ArraySetAsSeries(ss, true);
   ArraySetAsSeries(sto, true);
   if(CopyBuffer(h_mf,  0, 0, 3, mf) < 3) return;   // main
   if(CopyBuffer(h_mf,  1, 0, 3, sf) < 3) return;   // signal
   if(CopyBuffer(h_ms,  0, 0, 3, ms) < 3) return;
   if(CopyBuffer(h_ms,  1, 0, 3, ss) < 3) return;
   if(CopyBuffer(h_sto, 0, 0, 3, sto) < 3) return;  // %K main

   bool bullish = (mf[1] > sf[1]) && (ms[1] > ss[1]);
   bool bearish = (mf[1] < sf[1]) && (ms[1] < ss[1]);

   if(bullish && sto[1] < InpStoLevel)          Open(true);
   else if(bearish && sto[1] > (100 - InpStoLevel)) Open(false);
}
//+------------------------------------------------------------------+

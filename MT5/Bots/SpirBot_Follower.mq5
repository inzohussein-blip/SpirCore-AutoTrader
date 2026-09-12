//+------------------------------------------------------------------+
//|                                        SpirBot_Follower.mq5       |
//|   SpirCore :: Copy-trading FOLLOWER bot                           |
//|                                                                  |
//|  Polls the SaaS signal channel (a master's license key) and      |
//|  mirrors its latest buy/sell/close. Self-contained. Simplified:   |
//|  fixed SL/TP points, spread filter, one position at a time.       |
//|                                                                  |
//|  Requires: whitelist InpServerURL in MT5                          |
//|  Tools > Options > Expert Advisors > Allow WebRequest for URL.    |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

input string InpServerURL   = "http://127.0.0.1:9000"; // SaaS base URL (whitelist it)
input string InpFollowerKey = "";    // YOUR (follower) license key
input string InpChannel     = "";    // master's license key = channel
input int    InpPollSec     = 5;     // Poll interval (seconds)
input double InpLot         = 0.10;  // Lot (used if the signal carries none)
input int    InpSL          = 300;   // Stop Loss (points)
input int    InpTP          = 600;   // Take Profit (points)
input int    InpMaxSpread   = 30;    // Max spread (points); 0 = ignore
input long   InpMagic       = 500900;// Magic number

CTrade trade;
long   g_lastId = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetTypeFillingBySymbol(_Symbol);
   if(InpFollowerKey == "" || InpChannel == "")
      Print("WARN: set InpFollowerKey and InpChannel.");
   EventSetTimer(MathMax(1, InpPollSec));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); }

// --- tiny flat-JSON helpers -----------------------------------------------
string JStr(const string js, const string key)
{
   string pat = "\"" + key + "\":\"";
   int p = StringFind(js, pat);
   if(p < 0) return("");
   p += StringLen(pat);
   int e = StringFind(js, "\"", p);
   if(e < 0) return("");
   return(StringSubstr(js, p, e - p));
}

double JNum(const string js, const string key)
{
   string pat = "\"" + key + "\":";
   int p = StringFind(js, pat);
   if(p < 0) return(0.0);
   p += StringLen(pat);
   int e = p, n = StringLen(js);
   while(e < n)
   {
      ushort ch = StringGetCharacter(js, e);
      if(ch == ',' || ch == '}') break;
      e++;
   }
   return(StringToDouble(StringSubstr(js, p, e - p)));
}

bool HasPosition(const string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return(true);
   }
   return(false);
}

void CloseSym(const string sym)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         trade.PositionClose(ticket);
   }
}

void Execute(const string action, string sym, double sigLot)
{
   if(sym == "") sym = _Symbol;
   SymbolSelect(sym, true);

   if(action == "close") { CloseSym(sym); return; }
   if(action != "buy" && action != "sell") return;

   if(InpMaxSpread > 0 &&
      (long)SymbolInfoInteger(sym, SYMBOL_SPREAD) > InpMaxSpread) return;
   if(HasPosition(sym)) return;   // one at a time per symbol

   bool isBuy = (action == "buy");
   double lot = (sigLot > 0 ? sigLot : InpLot);
   double pt  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double price = isBuy ? SymbolInfoDouble(sym, SYMBOL_ASK)
                        : SymbolInfoDouble(sym, SYMBOL_BID);
   double sl = 0, tp = 0;
   if(InpSL > 0) sl = isBuy ? price - InpSL * pt : price + InpSL * pt;
   if(InpTP > 0) tp = isBuy ? price + InpTP * pt : price - InpTP * pt;
   int d = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   sl = NormalizeDouble(sl, d); tp = NormalizeDouble(tp, d);
   if(isBuy) trade.Buy(lot, sym, price, sl, tp, "SpirFollower");
   else      trade.Sell(lot, sym, price, sl, tp, "SpirFollower");
}

void OnTimer()
{
   if(InpFollowerKey == "" || InpChannel == "") return;

   string url = InpServerURL + "/signals/latest?key=" + InpFollowerKey +
                "&channel=" + InpChannel;
   char data[], result[];
   string headers;
   ResetLastError();
   int code = WebRequest("GET", url, "", 5000, data, result, headers);
   if(code == -1)
   {
      PrintFormat("Follower WebRequest err %d. Whitelist %s in MT5 options.",
                  GetLastError(), InpServerURL);
      return;
   }
   if(code != 200) return;

   string body = CharArrayToString(result);
   long id = (long)JNum(body, "id");
   if(id <= g_lastId) return;          // nothing new
   g_lastId = id;

   string action = JStr(body, "action");
   string sym    = JStr(body, "symbol");
   double lot    = JNum(body, "lot");
   PrintFormat("Copy signal #%I64d: %s %s lot=%.2f", id, action, sym, lot);
   Execute(action, sym, lot);
}
//+------------------------------------------------------------------+

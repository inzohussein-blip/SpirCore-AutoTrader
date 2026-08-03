//+------------------------------------------------------------------+
//|                                              SpirCore_Risk.mqh    |
//|          SpirCore-AutoTrader :: Risk Management Layer            |
//|                                                                  |
//|  What actually separates a professional system from a toy:      |
//|  hard, mechanical limits that survive a bad day.                |
//|                                                                  |
//|   * Daily loss limit  -> auto-trading halts once the day's       |
//|     realized+floating loss crosses a % of balance.              |
//|   * Max trades/day    -> caps over-trading / revenge trading.    |
//|   * Risk-% sizing      -> position size derived from the stop    |
//|     distance so every trade risks the same % of the account.    |
//|                                                                  |
//|  These GATE the automated path only; manual clicks are yours.   |
//+------------------------------------------------------------------+
#property strict

// Config (filled by RiskConfigure)
string R_Symbol;
long   R_Magic;
bool   R_UseRiskSizing   = false;
double R_RiskPct         = 1.0;
double R_MaxDailyLossPct = 5.0;
int    R_MaxTradesPerDay = 10;

//+------------------------------------------------------------------+
//| Configure the risk layer from the EA inputs.                     |
//+------------------------------------------------------------------+
void RiskConfigure(const string symbol, const long magic,
                   const bool useRiskSizing, const double riskPct,
                   const double maxDailyLossPct, const int maxTradesPerDay)
{
   R_Symbol          = symbol;
   R_Magic           = magic;
   R_UseRiskSizing   = useRiskSizing;
   R_RiskPct         = riskPct;
   R_MaxDailyLossPct = maxDailyLossPct;
   R_MaxTradesPerDay = maxTradesPerDay;
}

//+------------------------------------------------------------------+
//| Start of the current server day.                                 |
//+------------------------------------------------------------------+
datetime RiskStartOfDay()
{
   return((datetime)((long)TimeCurrent() / 86400 * 86400));
}

//+------------------------------------------------------------------+
//| Today's P/L for this EA: realized (closed deals) + floating.     |
//+------------------------------------------------------------------+
double RiskDailyPnL()
{
   double realized = 0.0;
   if(HistorySelect(RiskStartOfDay(), TimeCurrent()))
   {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC)  != R_Magic)  continue;
         if(HistoryDealGetString (ticket, DEAL_SYMBOL) != R_Symbol) continue;
         realized += HistoryDealGetDouble(ticket, DEAL_PROFIT)
                   + HistoryDealGetDouble(ticket, DEAL_SWAP)
                   + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
      }
   }

   double floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != R_Magic)  continue;
      if(PositionGetString (POSITION_SYMBOL) != R_Symbol) continue;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return(realized + floating);
}

//+------------------------------------------------------------------+
//| Number of trades (entry deals) opened today by this EA.          |
//+------------------------------------------------------------------+
int RiskTradesToday()
{
   int n = 0;
   if(HistorySelect(RiskStartOfDay(), TimeCurrent()))
   {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC)  != R_Magic)  continue;
         if(HistoryDealGetString (ticket, DEAL_SYMBOL) != R_Symbol) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY)  == DEAL_ENTRY_IN) n++;
      }
   }
   return(n);
}

//+------------------------------------------------------------------+
//| Master gate for the automated path. Returns false (with reason)  |
//| when a hard risk limit is reached.                               |
//+------------------------------------------------------------------+
bool RiskGuardOK(string &reason)
{
   reason = "";

   if(R_MaxTradesPerDay > 0 && RiskTradesToday() >= R_MaxTradesPerDay)
   {
      reason = "max trades/day reached";
      return(false);
   }

   if(R_MaxDailyLossPct > 0)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double maxLoss = balance * R_MaxDailyLossPct / 100.0;
      double pnl     = RiskDailyPnL();
      if(pnl <= -maxLoss)
      {
         reason = StringFormat("daily loss limit hit (P/L %.2f <= -%.2f)", pnl, maxLoss);
         return(false);
      }
   }
   return(true);
}

//+------------------------------------------------------------------+
//| Position size from risk %: lot such that hitting the SL loses    |
//| RiskPct of balance. Falls back to `fallbackLot` when disabled    |
//| or when the stop distance is unusable. Caller normalizes lot.    |
//+------------------------------------------------------------------+
double RiskCalcLot(const double entry, const double slPrice, const double fallbackLot)
{
   if(!R_UseRiskSizing || slPrice <= 0.0)
      return(fallbackLot);

   double slDist = MathAbs(entry - slPrice);
   if(slDist <= 0.0)
      return(fallbackLot);

   double tickSize  = SymbolInfoDouble(R_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(R_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return(fallbackLot);

   double riskMoney  = AccountInfoDouble(ACCOUNT_BALANCE) * R_RiskPct / 100.0;
   double lossPerLot = (slDist / tickSize) * tickValue; // loss for 1.0 lot at the SL
   if(lossPerLot <= 0.0)
      return(fallbackLot);

   return(riskMoney / lossPerLot);
}
//+------------------------------------------------------------------+

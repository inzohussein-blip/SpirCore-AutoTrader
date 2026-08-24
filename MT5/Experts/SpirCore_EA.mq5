//+------------------------------------------------------------------+
//|                                                  SpirCore_EA.mq5  |
//|          SpirCore-AutoTrader :: Phase 1 - Local MT5 Core          |
//|                                                                  |
//|  Cross-Platform Hybrid Trading System for Gold (XAUUSD)          |
//|                                                                  |
//|  Features (this file):                                           |
//|   1) ECN/STP-compliant execution  (Market order first,          |
//|      then instant PositionModify to attach SL/TP).              |
//|   2) Strict Max-Spread filter (Market-Maker / news protection). |
//|   3) Visual future markers: dashed golden horizontal lines      |
//|      +/- N points from price, with sound+visual alert on touch. |
//|   4) On-chart GUI: AUTO ON/OFF toggle + manual BUY/SELL/CLOSE.   |
//|                                                                  |
//|  Architecture note: analysis (line levels / signals) is kept    |
//|  separate from execution (order engine) so the terminal stays   |
//|  lightweight and the two concerns can evolve independently.     |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include "SpirCore_Strategies.mqh"
#include "SpirCore_Risk.mqh"

//====================================================================
//  INPUTS / الإعدادات
//====================================================================
input group    "=== General / عام ==="
input string   InpSymbol        = "XAUUSD";   // Trading symbol (must match broker exactly)
input long     InpMagic         = 990011;     // Magic number (EA identity)
input bool     InpAutoStartOn   = false;      // Start with Auto-Trading ON? (safe default = false)

input group    "=== Money / اللوت ==="
input double   InpFixedLot      = 0.10;       // Fixed lot size per trade

input group    "=== Risk (SL/TP in points) / الأهداف ==="
input int      InpStopLossPts   = 300;        // Stop Loss in points (0 = none)
input int      InpTakeProfitPts = 600;        // Take Profit in points (0 = none)

input group    "=== Spread Filter / فلتر السبريد ==="
input int      InpMaxSpreadPts  = 30;         // Max allowed spread in points (auto-entry blocked above this)

input group    "=== Visual Future Lines / الخطوط المستقبلية ==="
input int      InpLineDistPts   = 150;        // Distance of dashed lines above/below price (points)
input color    InpLineColor     = clrGold;    // Line color
input int      InpLineWidth     = 2;          // Line width
input bool      InpAlertOnTouch  = true;       // Sound + popup alert when price touches a line

input group    "=== Python Bridge Levels / خطوط جسر بايثون ==="
input bool     InpReadPyLevels  = true;        // Read & draw levels pushed by the Python bridge
input string   InpLevelsFile    = "spircore_levels.csv"; // File in MQL5/Files (Python writes it)
input int      InpLevelsRefresh = 2;           // Re-read interval (seconds)
input color    InpPyLineColor   = clrDeepSkyBlue; // Color for Python-pushed lines

input group    "=== Dashboard Control / أوامر لوحة التحكم ==="
input bool     InpReadCommands  = true;        // Obey control commands from the dashboard (via bridge)
input string   InpCommandsFile  = "spircore_commands.csv"; // File in MQL5/Files (bridge writes it)

input group    "=== Licensing / الترخيص ==="
input bool     InpUseLicense    = false;       // Require a valid SaaS license to trade
input string   InpLicenseURL    = "http://127.0.0.1:9000"; // SaaS base URL (whitelist in MT5 options)
input string   InpLicenseKey    = "";          // Your license key (SPIR-...)

input group    "=== Execution / التنفيذ ==="
input int      InpSlippagePts   = 20;         // Max deviation/slippage in points
input int      InpModifyRetries = 3;          // Retries for the ECN PositionModify step
input int      InpMaxPositions  = 1;          // Max simultaneous EA positions on the symbol

input group    "=== Risk Management / إدارة المخاطر ==="
input bool     InpUseRiskSizing = false;      // Size lot from risk % (needs a strategy SL)
input double   InpRiskPercent   = 1.0;        // Risk % of balance per trade
input double   InpMaxDailyLoss  = 5.0;        // Halt auto-trading after this daily loss % (0=off)
input int      InpMaxTradesDay  = 10;         // Max auto trades per day (0=unlimited)
input double   InpMaxTotalLots  = 0.0;        // Max total open lots across positions (0=off)

input group    "=== Session Filter / فلتر الجلسة (kill-switch) ==="
input bool     InpUseSession    = false;      // Restrict auto-trading to session hours
input int      InpSessionStart  = 0;          // Session start hour (server time, 0-23)
input int      InpSessionEnd    = 24;         // Session end hour (server time, 1-24)

input group    "=== Strategy Engine / محرك الاستراتيجيات ==="
input ENUM_STRATEGY InpStrategy      = STRAT_CEZLSMA; // Auto strategy (None = manual only)
input bool     InpUseStratSLTP  = true;       // Use strategy's dynamic SL/TP (else fixed points)

input group    "--- CEZLSMA (trend) ---"
input int      InpCE_AtrPeriod  = 1;          // Chandelier ATR period
input double   InpCE_Mult       = 0.75;       // Chandelier ATR multiplier
input int      InpZL_Period     = 50;         // ZLSMA period

input group    "--- BBRSI (mean reversion) ---"
input int      InpBB_Period     = 500;        // Bollinger period
input double   InpBB_Dev        = 2.0;        // Bollinger deviations
input int      InpRSI_Period    = 7;          // RSI period

input group    "--- LRCUTB (momentum) ---"
input int      InpLRC_Len       = 11;         // Linear-regression candle length
input int      InpLRC_SmaLen    = 7;          // Signal SMA length
input int      InpUTB_AtrLen    = 1;          // UT Bot ATR length
input double   InpUTB_Coef      = 2.0;        // UT Bot ATR multiplier
input int      InpSwingLook     = 10;         // Swing SL lookback (bars)

input group    "--- 2MACDSTO / NWE / Auto ---"
input int      InpStoLevel      = 30;         // 2MACDSTO Stochastic threshold
input int      InpNWEWindow     = 100;        // NWE kernel window (bars)
input double   InpNWEBand       = 8.0;        // NWE Gaussian bandwidth
input double   InpNWEMult       = 3.0;        // NWE envelope width multiplier
input int      InpAdxTrend      = 25;         // Auto mode: ADX >= this => trending
input int      InpHybridMinAgree = 2;         // Hybrid: min strategies agreeing to trade

input group    "--- Strategy risk shaping ---"
input double   InpTPCoef        = 1.5;        // TP = TPCoef x risk distance
input int      InpStratSLDevPts = 50;         // Extra SL buffer beyond raw stop (points)

input group    "=== Position Management / إدارة الصفقات ==="
input bool     InpUseBreakEven  = true;       // Move SL to break-even once in profit
input int      InpBETriggerPts  = 300;        // Profit (points) that triggers break-even
input int      InpBELockPts     = 20;         // Points locked beyond entry at break-even
input bool     InpUseTrailing   = true;       // Enable trailing stop
input int      InpTrailStartPts  = 400;       // Profit (points) to start trailing
input int      InpTrailDistPts   = 250;       // Trailing distance behind price (points)
input int      InpTrailStepPts   = 30;        // Minimum step to move the trailing SL (points)

input group    "=== Journal / السجل ==="
input bool     InpWriteJournal  = true;       // Log closed trades to CSV (MQL5/Files)
input string   InpJournalFile   = "spircore_journal.csv"; // Journal filename

//====================================================================
//  GLOBALS / متغيرات عامة
//====================================================================
CTrade         g_trade;        // Trade wrapper (we drive it in ECN style)
CSymbolInfo    g_sym;          // Symbol info helper

bool           g_autoOn        = false;   // runtime auto-trading state
double         g_upperLine     = 0.0;     // current upper future-entry level
double         g_lowerLine     = 0.0;     // current lower future-entry level
datetime       g_lastLineCalc  = 0;       // last time lines were (re)computed
bool           g_touchedUpper  = false;   // debounce flags so alert fires once per touch
bool           g_touchedLower  = false;
datetime       g_lastSignalBar = 0;       // last bar we evaluated the strategy on
datetime       g_lastLevelsRead = 0;      // last time the Python levels file was read
datetime       g_lastCmdRead   = 0;       // last time the commands file was read
long           g_lastCmdId     = 0;       // id of the last executed dashboard command
ENUM_STRATEGY  g_activeStrategy;          // runtime strategy (dashboard can switch it)
double         g_riskMaxDaily;            // runtime daily-loss limit (dashboard can change it)

// Selection mode: SINGLE (one strategy) / HYBRID (confluence) / AUTO (regime).
enum ENUM_SELMODE { SEL_SINGLE = 0, SEL_HYBRID = 1, SEL_AUTO = 2 };
ENUM_SELMODE   g_selMode = SEL_SINGLE;
datetime       g_lastStatusWrite = 0;
bool           g_licensed = true;          // license validity (when licensing is on)
datetime       g_lastLicenseCheck = 0;

// --- Object names (kept in one place for clean create/delete) -------
#define OBJ_PREFIX     "SPIRCORE_"
#define LN_UPPER       OBJ_PREFIX "LINE_UP"
#define LN_LOWER       OBJ_PREFIX "LINE_DN"
#define BTN_AUTO       OBJ_PREFIX "BTN_AUTO"
#define BTN_BUY        OBJ_PREFIX "BTN_BUY"
#define BTN_SELL       OBJ_PREFIX "BTN_SELL"
#define BTN_CLOSE      OBJ_PREFIX "BTN_CLOSE"
#define LBL_STATUS     OBJ_PREFIX "LBL_STATUS"
#define LBL_TOUCH      OBJ_PREFIX "LBL_TOUCH"
#define LBL_STATS      OBJ_PREFIX "LBL_STATS"

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   // --- Bind symbol -------------------------------------------------
   if(!g_sym.Name(InpSymbol))
   {
      Print("ERROR: symbol not found -> ", InpSymbol);
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(!SymbolSelect(InpSymbol, true))
      Print("WARN: could not add ", InpSymbol, " to Market Watch");

   // --- Configure trade wrapper ------------------------------------
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpSlippagePts);
   g_trade.SetTypeFillingBySymbol(InpSymbol);
   g_trade.SetAsyncMode(false);   // synchronous so we get the ticket immediately for the modify step

   g_autoOn = InpAutoStartOn;

   // --- Configure + initialize the strategy (analysis) engine ------
   //   Always init (even if starting at NONE) so the dashboard can switch
   //   strategies at runtime -- all indicator handles are ready.
   StratConfigure(InpCE_AtrPeriod, InpCE_Mult, InpZL_Period,
                  InpBB_Period, InpBB_Dev, InpRSI_Period,
                  InpLRC_Len, InpLRC_SmaLen, InpUTB_AtrLen, InpUTB_Coef,
                  InpSwingLook, InpTPCoef, InpStratSLDevPts);
   StratConfigureExtra(InpStoLevel, InpNWEWindow, InpNWEBand, InpNWEMult, InpAdxTrend);
   if(!StratInit(InpSymbol, (ENUM_TIMEFRAMES)Period()))
   {
      Print("ERROR: strategy engine failed to initialize.");
      return(INIT_FAILED);
   }
   g_activeStrategy = InpStrategy;   // runtime strategy (dashboard-switchable)
   g_selMode        = SEL_SINGLE;

   // --- Configure the risk-management gate --------------------------
   g_riskMaxDaily = InpMaxDailyLoss;
   RiskConfigure(InpSymbol, InpMagic, InpUseRiskSizing, InpRiskPercent,
                 g_riskMaxDaily, InpMaxTradesDay);

   // --- Build UI + first line levels -------------------------------
   CreatePanel();
   RecalcFutureLines(true);
   RefreshStatusLabel();

   CheckLicense();   // validate up front (no-op unless InpUseLicense)

   WriteStatus();
   ChartRedraw();
   Print("SpirCore_EA initialized on ", InpSymbol, " | Auto=", (g_autoOn ? "ON" : "OFF"));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit - remove every object we created                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   StratDeinit();
   ObjectsDeleteAll(0, OBJ_PREFIX);
   ChartRedraw();
   Print("SpirCore_EA removed. reason=", reason);
}

//+------------------------------------------------------------------+
//| OnTick - analysis + (optional) execution                         |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!g_sym.RefreshRates())
      return;

   // 1) ANALYSIS LAYER: keep the visual future lines updated & watch touches
   RecalcFutureLines(false);
   CheckLineTouch();

   // 2) STATUS: keep the on-screen spread/state readout live
   RefreshStatusLabel();

   // 3) STRATEGY LAYER: evaluate ONCE per newly closed bar (strategies
   //    read closed candles [1]/[2], so ticking every tick is wasteful
   //    and would fire duplicate signals within the same bar).
   EvaluateStrategyOnNewBar();

   // 4) MANAGEMENT LAYER: trail / break-even on open positions.
   ManageOpenPositions();

   // 5) BRIDGE LAYER: draw any levels pushed by the Python bridge.
   ReadPythonLevels();

   // 6) CONTROL LAYER: obey dashboard commands relayed by the bridge.
   ReadCommands();

   // 7) STATUS: publish current state (auto/mode/strategy) for the dashboard.
   if(TimeCurrent() - g_lastStatusWrite >= 3)
   {
      g_lastStatusWrite = TimeCurrent();
      WriteStatus();
   }

   // 8) LICENSE: re-validate hourly (no-op unless licensing is enabled).
   if(InpUseLicense && TimeCurrent() - g_lastLicenseCheck >= 3600)
      CheckLicense();
}

//+------------------------------------------------------------------+
//| Validate the SaaS license via WebRequest. Sets g_licensed.       |
//| NOTE: whitelist InpLicenseURL in Tools > Options > Expert        |
//| Advisors > Allow WebRequest for listed URL.                      |
//+------------------------------------------------------------------+
void CheckLicense()
{
   g_lastLicenseCheck = TimeCurrent();
   if(!InpUseLicense)
   {
      g_licensed = true;
      return;
   }

   long account = AccountInfoInteger(ACCOUNT_LOGIN);
   string url = InpLicenseURL + "/license/validate?key=" + InpLicenseKey +
                "&account=" + (string)account;

   char data[], result[];
   string result_headers;
   ResetLastError();
   int code = WebRequest("GET", url, "", 5000, data, result, result_headers);
   if(code == -1)
   {
      PrintFormat("License check failed (WebRequest err %d). Whitelist %s in MT5 options.",
                  GetLastError(), InpLicenseURL);
      g_licensed = false;   // fail closed: no verification -> no trading
   }
   else if(code == 200)
   {
      string body = CharArrayToString(result);
      g_licensed = (StringFind(body, "\"valid\":true") >= 0);
      PrintFormat("License check: %s", (g_licensed ? "VALID" : "INVALID"));
   }
   else
   {
      PrintFormat("License server HTTP %d -> treating as unlicensed", code);
      g_licensed = false;
   }

   if(!g_licensed)
   {
      g_autoOn = false;   // stop automation when unlicensed
      RefreshAutoButton();
      ShowTouchBanner("LICENSE INVALID - trading disabled");
   }
}

//+------------------------------------------------------------------+
//| Read & execute control commands from the dashboard (via bridge). |
//| File holds ONE line: <id>,<CMD>,<arg1>,<arg2>. Latest wins; a    |
//| command runs only when its id exceeds the last executed id.      |
//+------------------------------------------------------------------+
void ReadCommands()
{
   if(!InpReadCommands)
      return;
   if(TimeCurrent() - g_lastCmdRead < 1)   // poll ~once per second
      return;
   g_lastCmdRead = TimeCurrent();

   int fh = FileOpen(InpCommandsFile, FILE_READ | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE)
      return;

   string line = "";
   if(!FileIsEnding(fh))
      line = FileReadString(fh);
   FileClose(fh);
   if(StringLen(line) == 0)
      return;

   string p[];
   int n = StringSplit(line, ',', p);
   if(n < 2)
      return;

   long id = (long)StringToInteger(p[0]);
   if(id <= g_lastCmdId)     // already handled (or stale)
      return;
   g_lastCmdId = id;

   ExecuteCommand(p[1], (n > 2 ? p[2] : ""), (n > 3 ? p[3] : ""));
}

//+------------------------------------------------------------------+
//| Apply one dashboard command.                                     |
//+------------------------------------------------------------------+
void ExecuteCommand(const string cmd, const string a1, const string a2)
{
   PrintFormat("Dashboard command: %s %s %s", cmd, a1, a2);

   if(cmd == "AUTO")
   {
      g_autoOn = (a1 == "ON");
      RefreshAutoButton();
      RefreshStatusLabel();
   }
   else if(cmd == "STRATEGY")
   {
      g_selMode = SEL_SINGLE;
      g_activeStrategy = StrategyFromName(a1);
      ShowTouchBanner("Strategy set to " + StrategyName(g_activeStrategy));
      WriteStatus();
   }
   else if(cmd == "MODE")
   {
      if(a1 == "HYBRID")    g_selMode = SEL_HYBRID;
      else if(a1 == "AUTO") g_selMode = SEL_AUTO;
      else                  g_selMode = SEL_SINGLE;
      ShowTouchBanner("Selection mode: " + SelModeName());
      WriteStatus();
   }
   else if(cmd == "RISK" && a1 == "MAX_DAILY")
   {
      g_riskMaxDaily = StringToDouble(a2);
      RiskConfigure(InpSymbol, InpMagic, InpUseRiskSizing, InpRiskPercent,
                    g_riskMaxDaily, InpMaxTradesDay);
      ShowTouchBanner(StringFormat("Max daily loss set to %.1f%%", g_riskMaxDaily));
   }
   else if(cmd == "CLOSE" || cmd == "FLATTEN")
   {
      CloseAllOwn();
      if(cmd == "FLATTEN")   // emergency: also stand the EA down
      {
         g_autoOn = false;
         RefreshAutoButton();
         RefreshStatusLabel();
         ShowTouchBanner("FLATTENED - automation OFF");
      }
   }
}

//+------------------------------------------------------------------+
//| Map a strategy name to the enum (default NONE).                  |
//+------------------------------------------------------------------+
ENUM_STRATEGY StrategyFromName(const string name)
{
   if(name == "CEZLSMA")  return(STRAT_CEZLSMA);
   if(name == "BBRSI")    return(STRAT_BBRSI);
   if(name == "LRCUTB")   return(STRAT_LRCUTB);
   if(name == "2MACDSTO") return(STRAT_2MACDSTO);
   if(name == "NWE")      return(STRAT_NWE);
   return(STRAT_NONE);
}

//+------------------------------------------------------------------+
//| Break-even + trailing-stop management for this EA's positions.   |
//| Only ever moves the stop in the favorable direction; keeps TP.   |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   if(!InpUseBreakEven && !InpUseTrailing)
      return;
   if(!g_sym.RefreshRates())
      return;

   double pt   = g_sym.Point();
   double bid  = g_sym.Bid();
   double ask  = g_sym.Ask();
   double step = MathMax(1, InpTrailStepPts) * pt;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)  continue;

      long   ptype  = PositionGetInteger(POSITION_TYPE);
      double entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      double newSL  = curSL;

      if(ptype == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - entry) / pt;
         if(InpUseBreakEven && profitPts >= InpBETriggerPts)
            newSL = MathMax(newSL, entry + InpBELockPts * pt);
         if(InpUseTrailing && profitPts >= InpTrailStartPts)
            newSL = MathMax(newSL, bid - InpTrailDistPts * pt);

         // Apply only if it improves the stop meaningfully and stays valid.
         if(newSL > curSL + step - pt && newSL < bid)
            g_trade.PositionModify(ticket, NormalizePrice(newSL), curTP);
      }
      else if(ptype == POSITION_TYPE_SELL)
      {
         double profitPts = (entry - ask) / pt;
         double sl = (curSL == 0.0) ? DBL_MAX : curSL;
         if(InpUseBreakEven && profitPts >= InpBETriggerPts)
            sl = MathMin(sl, entry - InpBELockPts * pt);
         if(InpUseTrailing && profitPts >= InpTrailStartPts)
            sl = MathMin(sl, ask + InpTrailDistPts * pt);

         if(sl != DBL_MAX && (curSL == 0.0 || sl < curSL - step + pt) && sl > ask)
            g_trade.PositionModify(ticket, NormalizePrice(sl), curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| OnTradeTransaction - append every CLOSED deal to the journal.    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(!InpWriteJournal)
      return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;

   ulong deal = trans.deal;
   if(!HistoryDealSelect(deal))
      return;
   if(HistoryDealGetInteger(deal, DEAL_MAGIC)  != InpMagic)  return;
   if(HistoryDealGetString (deal, DEAL_SYMBOL) != InpSymbol) return;
   if(HistoryDealGetInteger(deal, DEAL_ENTRY)  != DEAL_ENTRY_OUT) return; // closes only

   WriteJournalRow(deal);
}

//+------------------------------------------------------------------+
//| Append one closed-deal row to the journal CSV (with header).     |
//+------------------------------------------------------------------+
void WriteJournalRow(const ulong deal)
{
   double profit  = HistoryDealGetDouble(deal, DEAL_PROFIT);
   double swap    = HistoryDealGetDouble(deal, DEAL_SWAP);
   double comm    = HistoryDealGetDouble(deal, DEAL_COMMISSION);
   double volume  = HistoryDealGetDouble(deal, DEAL_VOLUME);
   double price   = HistoryDealGetDouble(deal, DEAL_PRICE);
   long   dtype   = HistoryDealGetInteger(deal, DEAL_TYPE);
   datetime dtime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   string comment = HistoryDealGetString(deal, DEAL_COMMENT);
   string side    = (dtype == DEAL_TYPE_BUY) ? "buy" : "sell";

   bool isNew = !FileIsExist(InpJournalFile);
   int fh = FileOpen(InpJournalFile, FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE)
   {
      Print("Journal: could not open ", InpJournalFile);
      return;
   }
   FileSeek(fh, 0, SEEK_END);
   if(isNew)
      FileWriteString(fh, "close_time,symbol,side,volume,price,profit,swap,commission,comment\n");

   string row = StringFormat("%s,%s,%s,%.2f,%.3f,%.2f,%.2f,%.2f,%s\n",
                             TimeToString(dtime, TIME_DATE | TIME_MINUTES),
                             InpSymbol, side, volume, price,
                             profit, swap, comm, comment);
   FileWriteString(fh, row);
   FileClose(fh);
}

//+------------------------------------------------------------------+
//| Read the Python-bridge levels CSV (MQL5/Files) and draw each     |
//| price as a dashed line. Throttled to InpLevelsRefresh seconds.   |
//| File format per line:  <price>,<label>                           |
//+------------------------------------------------------------------+
void ReadPythonLevels()
{
   if(!InpReadPyLevels)
      return;
   if(TimeCurrent() - g_lastLevelsRead < InpLevelsRefresh)
      return;
   g_lastLevelsRead = TimeCurrent();

   // Clear previously drawn Python lines so removed levels disappear.
   ObjectsDeleteAll(0, OBJ_PREFIX "PY_");

   int fh = FileOpen(InpLevelsFile, FILE_READ | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE)
      return; // file not present yet -> nothing to draw

   int idx = 0;
   while(!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      if(StringLen(line) == 0)
         continue;

      string parts[];
      int n = StringSplit(line, ',', parts);
      if(n < 1)
         continue;

      double price = StringToDouble(parts[0]);
      if(price <= 0)
         continue;

      string label = (n >= 2) ? parts[1] : ("PY_" + IntegerToString(idx));
      string name  = OBJ_PREFIX "PY_" + IntegerToString(idx);

      if(ObjectFind(0, name) < 0)
         ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetDouble (0, name, OBJPROP_PRICE, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpPyLineColor);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASHDOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK,  true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString (0, name, OBJPROP_TOOLTIP, "Python level: " + label);
      idx++;
   }
   FileClose(fh);
}

//+------------------------------------------------------------------+
//| Run the selected strategy on bar close and, if Auto is ON,       |
//| execute the resulting signal (ECN style, spread-filtered).       |
//+------------------------------------------------------------------+
void EvaluateStrategyOnNewBar()
{
   // In SINGLE mode a NONE strategy means "do nothing"; HYBRID/AUTO always run.
   if(g_selMode == SEL_SINGLE && g_activeStrategy == STRAT_NONE)
      return;

   datetime barTime = iTime(InpSymbol, PERIOD_CURRENT, 0);
   if(barTime == g_lastSignalBar)
      return;                 // still the same bar -> nothing new to decide
   g_lastSignalBar = barTime; // mark this bar handled (once)

   // Pick the signal according to the selection mode.
   SignalResult r;
   if(g_selMode == SEL_HYBRID)      r = Signal_Hybrid(InpHybridMinAgree);
   else if(g_selMode == SEL_AUTO)   r = Signal_Auto();
   else                             r = GetStrategySignal(g_activeStrategy);

   if(r.sig == SIG_NONE)
      return;

   string label = ActiveLabel();

   // Show the signal on the banner regardless of auto state, so the
   // trader can confirm manually when Auto is OFF.
   string dir = (r.sig == SIG_BUY) ? "BUY" : "SELL";
   ShowTouchBanner(StringFormat("SIGNAL: %s (%s)  -> %s",
                    dir, label,
                    (g_autoOn ? "auto-executing" : "click BUY/SELL to confirm")));

   if(!g_autoOn)
      return;                 // Auto OFF: signal is advisory only

   if(CountOwnPositions() >= InpMaxPositions)
      return;                 // respect the position cap

   // SESSION KILL-SWITCH: block auto entries outside the allowed hours.
   if(!SessionOK())
   {
      ShowTouchBanner("SESSION BLOCK: outside trading hours");
      return;
   }

   // RISK GATE: hard daily-loss / trades-per-day limits block the auto path.
   string blockReason;
   if(!RiskGuardOK(blockReason))
   {
      ShowTouchBanner("RISK BLOCK: " + blockReason);
      PrintFormat("Auto entry blocked by risk guard: %s", blockReason);
      return;
   }

   // Fill TP from the strategy's SL using the intended entry price.
   double entry = (r.sig == SIG_BUY) ? g_sym.Ask() : g_sym.Bid();
   BuildTP(r, entry);

   ENUM_ORDER_TYPE ot = (r.sig == SIG_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double useSL = InpUseStratSLTP ? r.sl : 0.0;
   double useTP = InpUseStratSLTP ? r.tp : 0.0;

   // Risk-% position sizing (needs a valid strategy SL); else fixed lot.
   double lot = RiskCalcLot(entry, r.sl, InpFixedLot);

   // EXPOSURE CAP: block if this trade would exceed the total-lots limit.
   if(InpMaxTotalLots > 0.0 && TotalOwnLots() + lot > InpMaxTotalLots)
   {
      ShowTouchBanner(StringFormat("EXPOSURE BLOCK: total lots > %.2f", InpMaxTotalLots));
      return;
   }

   OpenTradeECN(ot, "auto-" + label, useSL, useTP, lot);
}

//+------------------------------------------------------------------+
//| Is trading allowed now? (session-hours kill-switch, server time) |
//+------------------------------------------------------------------+
bool SessionOK()
{
   if(!InpUseSession)
      return(true);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int h = dt.hour;
   int a = InpSessionStart, b = InpSessionEnd;
   return((a <= b) ? (h >= a && h < b) : (h >= a || h < b)); // b<a wraps midnight
}

//+------------------------------------------------------------------+
//| Sum of this EA's open lots on the symbol.                        |
//+------------------------------------------------------------------+
double TotalOwnLots()
{
   double total = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)  continue;
      total += PositionGetDouble(POSITION_VOLUME);
   }
   return(total);
}

//+------------------------------------------------------------------+
//| Human-readable strategy name for logs / banner.                  |
//+------------------------------------------------------------------+
string StrategyName(const ENUM_STRATEGY s)
{
   switch(s)
   {
      case STRAT_CEZLSMA:  return("CEZLSMA");
      case STRAT_BBRSI:    return("BBRSI");
      case STRAT_LRCUTB:   return("LRCUTB");
      case STRAT_2MACDSTO: return("2MACDSTO");
      case STRAT_NWE:      return("NWE");
      default:             return("NONE");
   }
}

//+------------------------------------------------------------------+
//| Selection-mode name.                                             |
//+------------------------------------------------------------------+
string SelModeName()
{
   if(g_selMode == SEL_HYBRID) return("HYBRID");
   if(g_selMode == SEL_AUTO)   return("AUTO");
   return("SINGLE");
}

//+------------------------------------------------------------------+
//| Label for the currently active selection (mode-aware).           |
//+------------------------------------------------------------------+
string ActiveLabel()
{
   if(g_selMode == SEL_HYBRID) return("HYBRID");
   if(g_selMode == SEL_AUTO)   return("AUTO");
   return(StrategyName(g_activeStrategy));
}

//+------------------------------------------------------------------+
//| Write the EA's current state so the bridge/dashboard can show it.|
//| One line: auto,mode,strategy  e.g.  ON,SINGLE,CEZLSMA           |
//+------------------------------------------------------------------+
void WriteStatus()
{
   int fh = FileOpen("spircore_status.csv", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(fh == INVALID_HANDLE)
      return;
   FileWriteString(fh, StringFormat("%s,%s,%s\n",
                   (g_autoOn ? "ON" : "OFF"), SelModeName(),
                   StrategyName(g_activeStrategy)));
   FileClose(fh);
}

//+------------------------------------------------------------------+
//| Count positions opened by THIS EA on the traded symbol.          |
//+------------------------------------------------------------------+
int CountOwnPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0) continue;
      if(PositionGetString(POSITION_SYMBOL)  != InpSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)  != InpMagic)  continue;
      n++;
   }
   return(n);
}

//+------------------------------------------------------------------+
//| OnChartEvent - GUI button handling                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam == BTN_AUTO)
   {
      g_autoOn = !g_autoOn;
      ObjectSetInteger(0, BTN_AUTO, OBJPROP_STATE, false); // release the visual press
      RefreshAutoButton();
      RefreshStatusLabel();
      PrintFormat("Auto-Trading toggled -> %s", (g_autoOn ? "ON" : "OFF"));
   }
   else if(sparam == BTN_BUY)
   {
      ObjectSetInteger(0, BTN_BUY, OBJPROP_STATE, false);
      OpenTradeECN(ORDER_TYPE_BUY, "manual-buy");
   }
   else if(sparam == BTN_SELL)
   {
      ObjectSetInteger(0, BTN_SELL, OBJPROP_STATE, false);
      OpenTradeECN(ORDER_TYPE_SELL, "manual-sell");
   }
   else if(sparam == BTN_CLOSE)
   {
      ObjectSetInteger(0, BTN_CLOSE, OBJPROP_STATE, false);
      CloseAllOwn();
   }

   ChartRedraw();
}

//====================================================================
//  EXECUTION LAYER  /  طبقة التنفيذ (ECN)
//====================================================================

//+------------------------------------------------------------------+
//| Spread filter - true if it is SAFE to trade                      |
//+------------------------------------------------------------------+
bool SpreadOK()
{
   long spreadPts = (long)SymbolInfoInteger(InpSymbol, SYMBOL_SPREAD);
   if(spreadPts <= 0) // some brokers report 0 (floating) -> compute from ask-bid
      spreadPts = (long)MathRound((g_sym.Ask() - g_sym.Bid()) / g_sym.Point());

   if(spreadPts > InpMaxSpreadPts)
   {
      PrintFormat("Spread filter BLOCK: current=%d pts > max=%d pts", (int)spreadPts, InpMaxSpreadPts);
      return(false);
   }
   return(true);
}

//+------------------------------------------------------------------+
//| ECN-compliant open:                                              |
//|   Step 1: market order with NO SL/TP (avoids ECN rejection).     |
//|   Step 2: immediate PositionModify to attach SL/TP brackets.     |
//+------------------------------------------------------------------+
bool OpenTradeECN(const ENUM_ORDER_TYPE type, const string tag,
                  const double slPrice = 0.0, const double tpPrice = 0.0,
                  const double lotOverride = 0.0)
{
   // Licensing gate: block ALL entries (manual + auto) when unlicensed.
   if(InpUseLicense && !g_licensed)
   {
      Print("Entry blocked: no valid license.");
      return(false);
   }

   // Spread filter guards the automatic path; manual clicks also respect it.
   if(!SpreadOK())
   {
      if(InpAlertOnTouch) Alert("SpirCore: entry blocked - spread too high.");
      return(false);
   }

   if(!g_sym.RefreshRates())
      return(false);

   double lot = NormalizeLot(lotOverride > 0.0 ? lotOverride : InpFixedLot);
   double price = (type == ORDER_TYPE_BUY) ? g_sym.Ask() : g_sym.Bid();

   // ----- STEP 1: bare market order (no SL/TP) -----------------------
   bool sent = (type == ORDER_TYPE_BUY)
               ? g_trade.Buy(lot, InpSymbol, price, 0.0, 0.0, tag)
               : g_trade.Sell(lot, InpSymbol, price, 0.0, 0.0, tag);

   if(!sent || g_trade.ResultRetcode() != TRADE_RETCODE_DONE)
   {
      PrintFormat("OPEN FAILED [%s]: retcode=%d (%s)",
                  tag, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      return(false);
   }

   ulong deal   = g_trade.ResultDeal();
   ulong ticket = g_trade.ResultOrder();
   PrintFormat("OPEN OK [%s]: lot=%.2f price=%.3f deal=%I64u", tag, lot, g_trade.ResultPrice(), deal);

   // ----- STEP 2: attach SL/TP via PositionModify (ECN follow-up) ----
   //   If explicit prices were supplied (strategy-driven) use them;
   //   otherwise fall back to the fixed-points config.
   bool wantBrackets = (slPrice > 0 || tpPrice > 0 || InpStopLossPts > 0 || InpTakeProfitPts > 0);
   if(wantBrackets)
      AttachBrackets(type, slPrice, tpPrice);

   return(true);
}

//+------------------------------------------------------------------+
//| Attach SL/TP to the just-opened position on InpSymbol.           |
//| Computed from the ACTUAL fill price, retried a few times so a    |
//| momentary "market changed" does not leave a naked position.      |
//+------------------------------------------------------------------+
void AttachBrackets(const ENUM_ORDER_TYPE type,
                    const double slPrice = 0.0, const double tpPrice = 0.0)
{
   if(!PositionSelect(InpSymbol))
   {
      Print("WARN: no position to modify after open.");
      return;
   }

   double pt      = g_sym.Point();
   double openPx  = PositionGetDouble(POSITION_PRICE_OPEN);

   // Prefer explicit (strategy-supplied) prices; else derive from points.
   double sl = slPrice;
   double tp = tpPrice;
   if(sl <= 0.0)
   {
      if(type == ORDER_TYPE_BUY && InpStopLossPts > 0) sl = openPx - InpStopLossPts * pt;
      if(type == ORDER_TYPE_SELL && InpStopLossPts > 0) sl = openPx + InpStopLossPts * pt;
   }
   if(tp <= 0.0)
   {
      if(type == ORDER_TYPE_BUY && InpTakeProfitPts > 0) tp = openPx + InpTakeProfitPts * pt;
      if(type == ORDER_TYPE_SELL && InpTakeProfitPts > 0) tp = openPx - InpTakeProfitPts * pt;
   }

   // Respect broker's minimum stop distance (stops-level).
   sl = NormalizePrice(sl);
   tp = NormalizePrice(tp);

   for(int i = 0; i < InpModifyRetries; i++)
   {
      if(g_trade.PositionModify(InpSymbol, sl, tp))
      {
         PrintFormat("MODIFY OK: SL=%.3f TP=%.3f (attempt %d)", sl, tp, i + 1);
         return;
      }
      PrintFormat("MODIFY retry %d/%d: retcode=%d (%s)",
                  i + 1, InpModifyRetries, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      Sleep(50); // brief pause; server needs a beat between execution and modify
   }
   Print("ERROR: could not attach SL/TP after retries -> position is NAKED, manage manually!");
}

//+------------------------------------------------------------------+
//| Close all positions opened by THIS EA on InpSymbol.              |
//+------------------------------------------------------------------+
void CloseAllOwn()
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)  continue;

      if(g_trade.PositionClose(ticket))
         closed++;
      else
         PrintFormat("CLOSE FAILED ticket=%I64u retcode=%d", ticket, g_trade.ResultRetcode());
   }
   PrintFormat("CloseAllOwn: %d position(s) closed.", closed);
}

//+------------------------------------------------------------------+
//| Lot / price normalization helpers                                |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = g_sym.LotsMin();
   double maxLot  = g_sym.LotsMax();
   double step    = g_sym.LotsStep();
   if(step <= 0) step = 0.01;

   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / step) * step;
   return(NormalizeDouble(lot, 2));
}

double NormalizePrice(double price)
{
   if(price <= 0) return(0.0);
   return(NormalizeDouble(price, g_sym.Digits()));
}

//====================================================================
//  ANALYSIS / VISUAL LAYER  /  طبقة التحليل والرسم
//====================================================================

//+------------------------------------------------------------------+
//| Recompute the two dashed future-entry lines.                     |
//| Upper = price + N pts, Lower = price - N pts. Recomputed once    |
//| per bar (or when forced) so the levels stay meaningful but don't |
//| jitter on every tick.                                            |
//+------------------------------------------------------------------+
void RecalcFutureLines(bool force)
{
   datetime barTime = iTime(InpSymbol, PERIOD_CURRENT, 0);
   if(!force && barTime == g_lastLineCalc)
      return;
   g_lastLineCalc = barTime;

   double mid  = (g_sym.Ask() + g_sym.Bid()) / 2.0;
   double dist = InpLineDistPts * g_sym.Point();

   g_upperLine = NormalizePrice(mid + dist);
   g_lowerLine = NormalizePrice(mid - dist);

   DrawFutureLine(LN_UPPER, g_upperLine, "SpirCore Upper Entry");
   DrawFutureLine(LN_LOWER, g_lowerLine, "SpirCore Lower Entry");

   // reset touch debounce whenever the levels move
   g_touchedUpper = false;
   g_touchedLower = false;
}

//+------------------------------------------------------------------+
//| Draw / update one dashed golden horizontal line.                 |
//+------------------------------------------------------------------+
void DrawFutureLine(const string name, const double price, const string tip)
{
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, InpLineColor);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, InpLineWidth);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString (0, name, OBJPROP_TOOLTIP, tip);
   }
   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
}

//+------------------------------------------------------------------+
//| Detect price touching either line -> fire alert once per touch.  |
//| Auto path stays OFF: a touch NEVER opens a trade by itself; it   |
//| notifies the trader so they can confirm with one click.          |
//+------------------------------------------------------------------+
void CheckLineTouch()
{
   double bid = g_sym.Bid();
   double ask = g_sym.Ask();

   // Upper line touched (price rose into it)
   if(!g_touchedUpper && ask >= g_upperLine && g_upperLine > 0)
   {
      g_touchedUpper = true;
      OnLineTouched("UPPER", g_upperLine);
   }
   // Lower line touched (price fell into it)
   if(!g_touchedLower && bid <= g_lowerLine && g_lowerLine > 0)
   {
      g_touchedLower = true;
      OnLineTouched("LOWER", g_lowerLine);
   }
}

//+------------------------------------------------------------------+
//| Reaction to a line touch: sound + popup + on-chart banner.       |
//+------------------------------------------------------------------+
void OnLineTouched(const string which, const double level)
{
   string msg = StringFormat("SpirCore: price touched %s future line @ %.3f", which, level);
   PrintFormat("%s | Auto=%s", msg, (g_autoOn ? "ON" : "OFF"));

   if(InpAlertOnTouch)
   {
      Alert(msg);            // popup + default alert sound
      PlaySound("alert.wav"); // explicit sound cue
   }

   // On-chart banner so the trader sees it even without the alert window.
   ShowTouchBanner(which + " LINE TOUCHED @ " + DoubleToString(level, g_sym.Digits())
                   + "  -> click BUY/SELL to confirm");
}

//====================================================================
//  GUI PANEL  /  لوحة التحكم
//====================================================================

//+------------------------------------------------------------------+
//| Build the whole control panel (buttons + labels).                |
//+------------------------------------------------------------------+
void CreatePanel()
{
   int x = 15;   // right-anchored corner offset
   int y = 25;
   int w = 130;
   int h = 26;
   int gap = 6;

   // AUTO toggle
   MakeButton(BTN_AUTO, x, y, w, h, "AUTO: ...", clrWhite, clrDimGray);
   RefreshAutoButton();

   // Manual BUY / SELL
   y += h + gap;
   MakeButton(BTN_BUY,  x + (w/2) + 3, y, (w/2) - 3, h, "BUY",  clrWhite, clrSeaGreen);
   MakeButton(BTN_SELL, x,             y, (w/2) - 3, h, "SELL", clrWhite, clrFireBrick);

   // CLOSE ALL
   y += h + gap;
   MakeButton(BTN_CLOSE, x, y, w, h, "CLOSE ALL", clrWhite, clrSlateGray);

   // Status label
   y += h + gap + 2;
   MakeLabel(LBL_STATUS, x, y, "status...", clrGold, 9);

   // Live performance readout (today)
   MakeLabel(LBL_STATS, x, y + 16, "stats...", clrSilver, 9);

   // Touch banner (hidden until a touch happens)
   MakeLabel(LBL_TOUCH, x, y + 34, "", clrOrange, 9);
}

//+------------------------------------------------------------------+
//| Button factory (top-right corner anchored).                      |
//+------------------------------------------------------------------+
void MakeButton(const string name, int x, int y, int w, int h,
                const string text, color txtColor, color bgColor)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,     h);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     txtColor);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,   bgColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  10);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   ObjectSetInteger(0, name, OBJPROP_STATE,      false);
}

//+------------------------------------------------------------------+
//| Label factory (top-right corner anchored).                       |
//+------------------------------------------------------------------+
void MakeLabel(const string name, int x, int y, const string text, color txtColor, int fontSize)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     txtColor);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
}

//+------------------------------------------------------------------+
//| Reflect auto state on the AUTO button (color + text).            |
//+------------------------------------------------------------------+
void RefreshAutoButton()
{
   if(g_autoOn)
   {
      ObjectSetString (0, BTN_AUTO, OBJPROP_TEXT,    "AUTO: ON");
      ObjectSetInteger(0, BTN_AUTO, OBJPROP_BGCOLOR, clrGreen);
   }
   else
   {
      ObjectSetString (0, BTN_AUTO, OBJPROP_TEXT,    "AUTO: OFF");
      ObjectSetInteger(0, BTN_AUTO, OBJPROP_BGCOLOR, clrDimGray);
   }
}

//+------------------------------------------------------------------+
//| Live status readout: symbol, spread, auto state.                 |
//+------------------------------------------------------------------+
void RefreshStatusLabel()
{
   long spreadPts = (long)SymbolInfoInteger(InpSymbol, SYMBOL_SPREAD);
   string spreadTxt = StringFormat("Spread: %d/%d", (int)spreadPts, InpMaxSpreadPts);
   string state     = StringFormat("%s | %s | %s",
                                    InpSymbol,
                                    (g_autoOn ? "AUTO ON" : "AUTO OFF"),
                                    spreadTxt);
   ObjectSetString(0, LBL_STATUS, OBJPROP_TEXT, state);

   // Color the readout red when spread would block entries.
   color c = (spreadPts > InpMaxSpreadPts) ? clrRed : clrGold;
   ObjectSetInteger(0, LBL_STATUS, OBJPROP_COLOR, c);

   RefreshStatsLabel();
}

//+------------------------------------------------------------------+
//| Live performance readout for today: P/L, trades, win rate.       |
//+------------------------------------------------------------------+
void RefreshStatsLabel()
{
   int wins = 0, losses = 0;
   double netPnl = 0.0;
   if(HistorySelect(RiskStartOfDay(), TimeCurrent()))
   {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC)  != InpMagic)  continue;
         if(HistoryDealGetString (ticket, DEAL_SYMBOL) != InpSymbol) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY)  != DEAL_ENTRY_OUT) continue;
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                  + HistoryDealGetDouble(ticket, DEAL_SWAP)
                  + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         netPnl += p;
         if(p >= 0) wins++; else losses++;
      }
   }
   int total = wins + losses;
   double winRate = (total > 0) ? (100.0 * wins / total) : 0.0;

   string txt = StringFormat("Today: P/L %.2f | %d trades | win %.0f%%",
                             netPnl, total, winRate);
   ObjectSetString(0, LBL_STATS, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, LBL_STATS, OBJPROP_COLOR,
                    (netPnl >= 0 ? clrMediumSeaGreen : clrIndianRed));
}

//+------------------------------------------------------------------+
//| Temporary on-chart banner for a line touch.                      |
//+------------------------------------------------------------------+
void ShowTouchBanner(const string text)
{
   ObjectSetString(0, LBL_TOUCH, OBJPROP_TEXT, text);
   ChartRedraw();
}
//+------------------------------------------------------------------+

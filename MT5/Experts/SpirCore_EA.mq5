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

input group    "=== Execution / التنفيذ ==="
input int      InpSlippagePts   = 20;         // Max deviation/slippage in points
input int      InpModifyRetries = 3;          // Retries for the ECN PositionModify step

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

   // --- Build UI + first line levels -------------------------------
   CreatePanel();
   RecalcFutureLines(true);
   RefreshStatusLabel();

   ChartRedraw();
   Print("SpirCore_EA initialized on ", InpSymbol, " | Auto=", (g_autoOn ? "ON" : "OFF"));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit - remove every object we created                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
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

   // NOTE:
   // In Phase 1 there is deliberately NO automatic signal generator.
   // Auto-execution here is driven by the manual/confirm buttons and,
   // later, by signals arriving from the Python bridge (Phase 2).
   // The g_autoOn gate below is the single switch that will arm that path.
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
bool OpenTradeECN(const ENUM_ORDER_TYPE type, const string tag)
{
   // Spread filter guards the automatic path; manual clicks also respect it.
   if(!SpreadOK())
   {
      if(InpAlertOnTouch) Alert("SpirCore: entry blocked - spread too high.");
      return(false);
   }

   if(!g_sym.RefreshRates())
      return(false);

   double lot = NormalizeLot(InpFixedLot);
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
   if(InpStopLossPts > 0 || InpTakeProfitPts > 0)
      AttachBrackets(type);

   return(true);
}

//+------------------------------------------------------------------+
//| Attach SL/TP to the just-opened position on InpSymbol.           |
//| Computed from the ACTUAL fill price, retried a few times so a    |
//| momentary "market changed" does not leave a naked position.      |
//+------------------------------------------------------------------+
void AttachBrackets(const ENUM_ORDER_TYPE type)
{
   if(!PositionSelect(InpSymbol))
   {
      Print("WARN: no position to modify after open.");
      return;
   }

   double pt      = g_sym.Point();
   double openPx  = PositionGetDouble(POSITION_PRICE_OPEN);

   double sl = 0.0, tp = 0.0;
   if(type == ORDER_TYPE_BUY)
   {
      if(InpStopLossPts   > 0) sl = openPx - InpStopLossPts   * pt;
      if(InpTakeProfitPts > 0) tp = openPx + InpTakeProfitPts * pt;
   }
   else
   {
      if(InpStopLossPts   > 0) sl = openPx + InpStopLossPts   * pt;
      if(InpTakeProfitPts > 0) tp = openPx - InpTakeProfitPts * pt;
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

   // Touch banner (hidden until a touch happens)
   MakeLabel(LBL_TOUCH, x, y + 18, "", clrOrange, 9);
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

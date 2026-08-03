//+------------------------------------------------------------------+
//|                                  SpirCore_ChandelierExit.mq5      |
//|   SpirCore :: Chandelier Exit (ATR trailing stop / trend flip)    |
//|   Green line = long trailing stop, red line = short stop.         |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   2
#property indicator_label1  "CE Long"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrLimeGreen
#property indicator_width1  2
#property indicator_label2  "CE Short"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrangeRed
#property indicator_width2  2

input int    InpAtrPeriod = 1;      // ATR period
input double InpMult      = 0.75;   // ATR multiplier

double PlotLong[], PlotShort[];     // plotted
double LSraw[], SSraw[], DirBuf[];  // calculations (persist state)
int    h_atr;

int OnInit()
{
   SetIndexBuffer(0, PlotLong,  INDICATOR_DATA);
   SetIndexBuffer(1, PlotShort, INDICATOR_DATA);
   SetIndexBuffer(2, LSraw,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(3, SSraw,     INDICATOR_CALCULATIONS);
   SetIndexBuffer(4, DirBuf,    INDICATOR_CALCULATIONS);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   h_atr = iATR(_Symbol, _Period, InpAtrPeriod);
   if(h_atr == INVALID_HANDLE) return(INIT_FAILED);
   IndicatorSetString(INDICATOR_SHORTNAME, "SpirCore ChandelierExit");
   return(INIT_SUCCEEDED);
}

int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[], const double &close[],
                const long &tick_volume[], const long &volume[], const int &spread[])
{
   double atr[];
   ArraySetAsSeries(atr, false);
   if(CopyBuffer(h_atr, 0, 0, rates_total, atr) <= 0)
      return(prev_calculated);

   int start = (prev_calculated > 1) ? prev_calculated - 1 : 1;
   if(prev_calculated == 0)
   {
      LSraw[0] = SSraw[0] = 0.0; DirBuf[0] = 0;
      PlotLong[0] = PlotShort[0] = EMPTY_VALUE;
   }

   for(int i = start; i < rates_total; i++)
   {
      double a = atr[i];
      double basicLong  = high[i] - InpMult * a;
      double basicShort = low[i]  + InpMult * a;

      LSraw[i] = (close[i - 1] > LSraw[i - 1]) ? MathMax(basicLong,  LSraw[i - 1]) : basicLong;
      SSraw[i] = (close[i - 1] < SSraw[i - 1]) ? MathMin(basicShort, SSraw[i - 1]) : basicShort;

      if(close[i] > SSraw[i - 1])      DirBuf[i] = 1;
      else if(close[i] < LSraw[i - 1]) DirBuf[i] = -1;
      else                             DirBuf[i] = DirBuf[i - 1];

      if(DirBuf[i] == 1) { PlotLong[i] = LSraw[i]; PlotShort[i] = EMPTY_VALUE; }
      else               { PlotLong[i] = EMPTY_VALUE; PlotShort[i] = SSraw[i]; }
   }
   return(rates_total);
}
//+------------------------------------------------------------------+

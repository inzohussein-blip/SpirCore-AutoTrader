//+------------------------------------------------------------------+
//|                                     SpirCore_NWEnvelope.mq5       |
//|   SpirCore :: Nadaraya-Watson Envelope (used by the NWE strategy) |
//|   Smooth kernel-regression midline with an adaptive band.        |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3
#property indicator_label1  "NW Mid"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGold
#property indicator_label2  "NW Upper"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDeepSkyBlue
#property indicator_label3  "NW Lower"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrDeepSkyBlue

input int    InpWindow = 100;   // Kernel window (bars)
input double InpBand   = 8.0;   // Gaussian bandwidth
input double InpMult   = 3.0;   // Envelope width multiplier

double MidBuf[], UpBuf[], LoBuf[];

int OnInit()
{
   SetIndexBuffer(0, MidBuf, INDICATOR_DATA);
   SetIndexBuffer(1, UpBuf,  INDICATOR_DATA);
   SetIndexBuffer(2, LoBuf,  INDICATOR_DATA);
   for(int p = 0; p < 3; p++)
   {
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);
      PlotIndexSetInteger(p, PLOT_DRAW_BEGIN, InpWindow);
   }
   IndicatorSetString(INDICATOR_SHORTNAME, "SpirCore NW Envelope");
   return(INIT_SUCCEEDED);
}

int OnCalculate(const int rates_total, const int prev_calculated,
                const int begin, const double &price[])
{
   int start = (prev_calculated > InpWindow) ? prev_calculated - 1 : InpWindow - 1;
   if(prev_calculated == 0)
      for(int i = 0; i < start && i < rates_total; i++)
         MidBuf[i] = UpBuf[i] = LoBuf[i] = EMPTY_VALUE;

   double twoB2 = 2.0 * InpBand * InpBand;
   for(int i = start; i < rates_total; i++)
   {
      double sumW = 0, sumWC = 0;
      for(int k = 0; k < InpWindow; k++)
      {
         double w = MathExp(-(double)(k * k) / twoB2);
         sumW  += w;
         sumWC += w * price[i - k];
      }
      if(sumW <= 0) { MidBuf[i] = UpBuf[i] = LoBuf[i] = EMPTY_VALUE; continue; }
      double nw = sumWC / sumW;
      double mad = 0;
      for(int k = 0; k < InpWindow; k++) mad += MathAbs(price[i - k] - nw);
      double mae = (mad / InpWindow) * InpMult;
      MidBuf[i] = nw;
      UpBuf[i]  = nw + mae;
      LoBuf[i]  = nw - mae;
   }
   return(rates_total);
}
//+------------------------------------------------------------------+

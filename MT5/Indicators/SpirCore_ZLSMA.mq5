//+------------------------------------------------------------------+
//|                                         SpirCore_ZLSMA.mq5        |
//|   SpirCore :: Zero-Lag LSMA line (used by the CEZLSMA strategy)   |
//|   Plots a smooth, low-lag trend line on the chart.               |
//+------------------------------------------------------------------+
#property copyright "SpirCore-AutoTrader"
#property version   "1.00"
#property strict
#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   1
#property indicator_label1  "ZLSMA"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGold
#property indicator_width1  2

input int InpPeriod = 50;   // ZLSMA period

double ZLBuf[];   // plotted
double L1Buf[];   // intermediate LSMA (calculations)

int OnInit()
{
   SetIndexBuffer(0, ZLBuf, INDICATOR_DATA);
   SetIndexBuffer(1, L1Buf, INDICATOR_CALCULATIONS);
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, 2 * InpPeriod);
   IndicatorSetString(INDICATOR_SHORTNAME, "SpirCore ZLSMA(" + (string)InpPeriod + ")");
   return(INIT_SUCCEEDED);
}

// Linear-regression endpoint over [i-len+1 .. i] (chronological arrays).
double LSMAat(const double &price[], const int i, const int len)
{
   if(i - len + 1 < 0) return(price[i]);
   double sx = 0, sy = 0, sxx = 0, sxy = 0;
   for(int t = 0; t < len; t++)
   {
      double y = price[i - len + 1 + t];
      sx += t; sy += y; sxx += (double)t * t; sxy += (double)t * y;
   }
   double denom = (len * sxx - sx * sx);
   if(MathAbs(denom) < 1e-12) return(price[i]);
   double slope = (len * sxy - sx * sy) / denom;
   double intercept = (sy - slope * sx) / len;
   return(intercept + slope * (len - 1));
}

int OnCalculate(const int rates_total, const int prev_calculated,
                const int begin, const double &price[])
{
   int l1start = (prev_calculated > InpPeriod) ? prev_calculated - 1 : InpPeriod - 1;
   for(int i = l1start; i < rates_total; i++)
      L1Buf[i] = LSMAat(price, i, InpPeriod);

   int zlstart = 2 * InpPeriod;
   if(prev_calculated > zlstart) zlstart = prev_calculated - 1;
   // blank the warm-up region on the first pass
   if(prev_calculated == 0)
      for(int i = 0; i < zlstart && i < rates_total; i++)
         ZLBuf[i] = EMPTY_VALUE;

   for(int i = zlstart; i < rates_total; i++)
   {
      double lsma2 = LSMAat(L1Buf, i, InpPeriod);
      ZLBuf[i] = 2.0 * L1Buf[i] - lsma2;
   }
   return(rates_total);
}
//+------------------------------------------------------------------+

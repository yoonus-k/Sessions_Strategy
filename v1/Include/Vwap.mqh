//+------------------------------------------------------------------+
//|                                                         Vwap.mqh  |
//|  Anchored VWAP, ported from the TradingView "Volume Weighted      |
//|  Average Price" indicator (Pine v6):                              |
//|      vwap = sum(src * volume) / sum(volume)  since the anchor      |
//|  Pine defaults reproduced here: source = hlc3, anchor = "Session"  |
//|  (i.e. a DAILY reset).                                            |
//|                                                                   |
//|  Two deliberate adaptations for this EA / for MT5:                 |
//|   - The day boundary is the strategy's own Riyadh day-close hour   |
//|     (DayCloseHourRiyadh), so the VWAP resets on the same calendar  |
//|     the sessions and the prior-day 4H range already use.           |
//|   - Most Gold/CFD feeds report real_volume = 0, so the series      |
//|     falls back to tick_volume when no real volume is present       |
//|     (Pine would raise "No volume is provided by the data vendor"). |
//|                                                                   |
//|  Used to derive the session bias automatically: price at the       |
//|  session open ABOVE the VWAP carried into the session -> BUY,      |
//|  BELOW -> SELL.  The bands from the Pine script are not needed by  |
//|  the strategy and are not ported.                                  |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_VWAP_MQH
#define SESSIONS_STRATEGY_VWAP_MQH

#include "Common.mqh"

class CVwap
  {
private:
   SSettings m_s;
   string    m_symbol;

   //--- Pine 'src' input (default hlc3)
   double Src(const MqlRates &r) const
     {
      switch(m_s.vwapSource)
        {
         case VWAP_SRC_CLOSE: return(r.close);
         case VWAP_SRC_HL2:   return((r.high+r.low)/2.0);
         case VWAP_SRC_OHLC4: return((r.open+r.high+r.low+r.close)/4.0);
         default:             return((r.high+r.low+r.close)/3.0); // hlc3
        }
     }

public:
   void Init(const SSettings &s,const string symbol){ m_s=s; m_symbol=symbol; }

   //+----------------------------------------------------------------+
   //| Start of the current anchor period, in SERVER time.             |
   //| DAY  -> the Riyadh day-close hour (same boundary as the 4H      |
   //|         range and the session calendar).                        |
   //| WEEK -> the Monday of that same boundary.                       |
   //+----------------------------------------------------------------+
   datetime AnchorStart(const datetime serverTime) const
     {
      datetime riyadh=ToRiyadh(serverTime,m_s);
      MqlDateTime dt; TimeToStruct(riyadh,dt);
      datetime midnight=riyadh-(datetime)(dt.hour*3600+dt.min*60+dt.sec);
      datetime start=midnight+(datetime)m_s.dayCloseHourRiyadh*3600;
      if(start>riyadh) start-=86400;          // boundary not reached yet today
      if(m_s.vwapAnchor==VWAP_ANCHOR_WEEK)
        {
         MqlDateTime sd; TimeToStruct(start,sd);
         start-=(datetime)(((sd.day_of_week+6)%7)*86400); // back to Monday
        }
      return(FromRiyadh(start,m_s));
     }

   //+----------------------------------------------------------------+
   //| Running VWAP over the bars in [fromT .. toT] (both inclusive).  |
   //| Fills 'times' / 'vals' oldest-first and returns the point count.|
   //+----------------------------------------------------------------+
   int Series(const datetime fromT,const datetime toT,datetime &times[],double &vals[])
     {
      ArrayFree(times); ArrayFree(vals);
      if(fromT<=0 || toT<=fromT) return(0);

      MqlRates r[]; ArraySetAsSeries(r,false); // index 0 = oldest
      int n=CopyRates(m_symbol,m_s.tf,fromT,toT,r);
      if(n<=0) return(0);

      // real_volume is 0 on most Gold/CFD feeds -> use tick_volume instead
      long realSum=0;
      for(int i=0;i<n;i++) realSum+=r[i].real_volume;
      bool useReal=(realSum>0);

      ArrayResize(times,n); ArrayResize(vals,n);
      double pv=0,vv=0; int cnt=0;
      for(int i=0;i<n;i++)
        {
         double v=useReal?(double)r[i].real_volume:(double)r[i].tick_volume;
         if(v<=0) v=1;              // a bar with no volume still carries price
         pv+=Src(r[i])*v; vv+=v;
         times[cnt]=r[i].time; vals[cnt]=pv/vv; cnt++;
        }
      ArrayResize(times,cnt); ArrayResize(vals,cnt);
      return(cnt);
     }

   //--- VWAP value at 'toT', including the bar that holds toT.
   //    Pass (barTime-1) to get the value carried INTO that bar.
   bool ValueAt(const datetime toT,double &out)
     {
      datetime t[]; double v[];
      int n=Series(AnchorStart(toT),toT,t,v);
      if(n<=0) return(false);
      out=v[n-1];
      return(true);
     }
  };

#endif // SESSIONS_STRATEGY_VWAP_MQH

//+------------------------------------------------------------------+
//|                                               SessionManager.mqh  |
//|  Session windows (Riyadh time), entry-timing gate, and the        |
//|  prior-day last-4h range used by the Asia gate (charter rule 2).  |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_SESSIONMANAGER_MQH
#define SESSIONS_STRATEGY_SESSIONMANAGER_MQH

#include "Common.mqh"

class CSessionManager
  {
private:
   SSettings         m_s;
   string            m_symbol;
   // cached prior-day range
   string            m_rangeDayKey;     // Riyadh date the range was computed for
   double            m_rangeHigh;
   double            m_rangeLow;
   bool              m_rangeValid;
   bool              m_rangeExited;     // has price left the range since computed
   datetime          m_rangeStartSrv;   // range window (server time)
   datetime          m_rangeEndSrv;

   //--- "YYYYMMDD" of a Riyadh time
   string            DayKey(const datetime riyadh) const
     {
      MqlDateTime dt; TimeToStruct(riyadh,dt);
      return(StringFormat("%04d%02d%02d",dt.year,dt.mon,dt.day));
     }

   //--- Riyadh midnight of the day containing 'riyadh'
   datetime          RiyadhMidnight(const datetime riyadh) const
     {
      MqlDateTime dt; TimeToStruct(riyadh,dt);
      dt.hour=0; dt.min=0; dt.sec=0;
      return(StructToTime(dt));
     }

public:
   void Init(const SSettings &s,const string symbol)
     {
      m_s=s; m_symbol=symbol;
      m_rangeDayKey=""; m_rangeValid=false; m_rangeExited=false;
      m_rangeHigh=0; m_rangeLow=0;
     }

   //--- Which approved session the given server time falls in
   ENUM_SESSION CurrentSession(const datetime serverNow) const
     {
      int m=RiyadhMinuteOfDay(ToRiyadh(serverNow,m_s));
      if(m>=m_s.asiaStartMin && m<m_s.asiaEndMin) return(SESSION_ASIA);
      if(m>=m_s.nyStartMin   && m<m_s.nyEndMin)   return(SESSION_NY);
      return(SESSION_NONE);
     }

   //--- Within the first EntryWindowMinutes of the active session?
   bool InEntryWindow(const datetime serverNow) const
     {
      ENUM_SESSION ses=CurrentSession(serverNow);
      if(ses==SESSION_NONE) return(false);
      int start=(ses==SESSION_ASIA)?m_s.asiaStartMin:m_s.nyStartMin;
      int m=RiyadhMinuteOfDay(ToRiyadh(serverNow,m_s));
      return(m>=start && m<start+m_s.entryWindowMinutes);
     }

   //--- Unique key for the current session occurrence (caps reset per key)
   string SessionKey(const datetime serverNow) const
     {
      ENUM_SESSION ses=CurrentSession(serverNow);
      if(ses==SESSION_NONE) return("");
      string tag=(ses==SESSION_ASIA)?"ASIA":"NY";
      return(DayKey(ToRiyadh(serverNow,m_s))+"-"+tag);
     }

   //--- Server time of the active session's open
   datetime SessionStartServer(const datetime serverNow) const
     {
      ENUM_SESSION ses=CurrentSession(serverNow);
      if(ses==SESSION_NONE) return(0);
      int start=(ses==SESSION_ASIA)?m_s.asiaStartMin:m_s.nyStartMin;
      datetime riyadhMidnight=RiyadhMidnight(ToRiyadh(serverNow,m_s));
      return(FromRiyadh(riyadhMidnight+start*60,m_s));
     }

   //+------------------------------------------------------------------+
   //| Prior-day last-4h range (charter rule 2, Asia only)              |
   //+------------------------------------------------------------------+
   void ComputeRangeIfNeeded(const datetime serverNow)
     {
      datetime riyadhNow=ToRiyadh(serverNow,m_s);
      string key=DayKey(riyadhNow);
      if(m_rangeValid && m_rangeDayKey==key) return; // already done today

      // Anchor = most recent dayClose boundary strictly before session start
      datetime midnight=RiyadhMidnight(riyadhNow);
      datetime closeRiyadh=midnight+(datetime)m_s.dayCloseHourRiyadh*3600;
      if(closeRiyadh>riyadhNow) closeRiyadh-=86400; // use previous day's close
      datetime startRiyadh=closeRiyadh-(datetime)m_s.rangeLengthHours*3600;

      datetime endServer=FromRiyadh(closeRiyadh,m_s);
      datetime startServer=FromRiyadh(startRiyadh,m_s);

      // Count-based copy of the last 'rangeLengthHours' of bars ending at the
      // prior-day close. This always returns data even across holiday gaps
      // (a pure time-range copy returns nothing when that day was closed).
      int barsNeeded=(int)(m_s.rangeLengthHours*3600/PeriodSeconds(m_s.tf));
      if(barsNeeded<2) barsNeeded=2;
      MqlRates r[]; ArraySetAsSeries(r,true);
      int n=CopyRates(m_symbol,m_s.tf,endServer,barsNeeded,r);
      if(n<2)
        {
         m_rangeValid=false; // retry next tick (key not cached)
         return;
        }
      double hi=-DBL_MAX, lo=DBL_MAX;
      for(int i=0;i<n;i++)
        {
         if(r[i].high>hi) hi=r[i].high;
         if(r[i].low <lo) lo=r[i].low;
        }
      m_rangeHigh=hi; m_rangeLow=lo;
      m_rangeStartSrv=r[n-1].time; m_rangeEndSrv=endServer;
      m_rangeDayKey=key; m_rangeValid=true; m_rangeExited=false;
     }

   //+------------------------------------------------------------------+
   //| Live range-building window (the last 'rangeLengthHours' before    |
   //| the day-close boundary, e.g. 20:00 -> 00:00). Returns the bounds  |
   //| in SERVER time. This is what the 4H box is drawn against live, so |
   //| it appears the moment 20:00 hits and develops until the close.    |
   //+------------------------------------------------------------------+
   bool RangeWindow(const datetime serverNow,datetime &startSrv,datetime &endSrv) const
     {
      datetime riyadhNow=ToRiyadh(serverNow,m_s);
      datetime midnight =RiyadhMidnight(riyadhNow);
      for(int d=0;d<=1;d++) // today's and tomorrow's close boundary
        {
         datetime closeR=midnight+(datetime)d*86400+(datetime)m_s.dayCloseHourRiyadh*3600;
         datetime startR=closeR-(datetime)m_s.rangeLengthHours*3600;
         if(riyadhNow>=startR && riyadhNow<closeR)
           {
            startSrv=FromRiyadh(startR,m_s);
            endSrv  =FromRiyadh(closeR,m_s);
            return(true);
           }
        }
      return(false);
     }

   //--- Update / query whether price has exited the prior-day range
   bool AsiaRangeExited(const double bid)
     {
      if(!m_rangeValid) return(false);
      if(!m_rangeExited && (bid>m_rangeHigh || bid<m_rangeLow))
         m_rangeExited=true;
      return(m_rangeExited);
     }

   bool     RangeValid()     const { return(m_rangeValid);   }
   double   RangeHigh()      const { return(m_rangeHigh);    }
   double   RangeLow()       const { return(m_rangeLow);     }
   datetime RangeStartSrv()  const { return(m_rangeStartSrv);}
   datetime RangeEndSrv()    const { return(m_rangeEndSrv);  }

   //--- Server time when the entry window closes (rule 3)
   datetime EntryWindowEndServer(const datetime serverNow) const
     {
      datetime ss=SessionStartServer(serverNow);
      if(ss<=0) return(0);
      return(ss+(datetime)m_s.entryWindowMinutes*60);
     }

   //--- Server time of the active session's close
   datetime SessionEndServer(const datetime serverNow) const
     {
      ENUM_SESSION ses=CurrentSession(serverNow);
      if(ses==SESSION_NONE) return(0);
      int end=(ses==SESSION_ASIA)?m_s.asiaEndMin:m_s.nyEndMin;
      datetime riyadhMidnight=RiyadhMidnight(ToRiyadh(serverNow,m_s));
      return(FromRiyadh(riyadhMidnight+end*60,m_s));
     }
  };

#endif // SESSIONS_STRATEGY_SESSIONMANAGER_MQH

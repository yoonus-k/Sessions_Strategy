//+------------------------------------------------------------------+
//|                                                 TimeSessions.mqh  |
//|  P0 - Time & session engine (DST-safe).                           |
//|                                                                   |
//|  Works internally in UTC. The broker->UTC offset is recomputed    |
//|  from the broker's winter/standard offset plus a DST rule set     |
//|  (US or EU) evaluated per call. Riyadh is UTC+3 with no DST, so    |
//|  the session windows themselves never shift; only the broker      |
//|  clock does, twice a year.                                        |
//|                                                                   |
//|  Pure query object - it never places orders and holds no mutable  |
//|  state beyond the settings copy.                                  |
//+------------------------------------------------------------------+
#ifndef V2_TIMESESSIONS_MQH
#define V2_TIMESESSIONS_MQH

#include "V2Common.mqh"

//--- "Everything the time engine can see right now", for the test EA
//--- and later the integration dashboard.
struct SDiagTime
  {
   datetime          brokerNow;
   datetime          utcNow;
   datetime          riyadhNow;
   bool              dstActive;       // broker clock currently on summer time
   int               offsetSec;       // broker -> UTC offset applied now
   ENUM_SESSION_V2   session;
   ENUM_SESSION_ROLE role;
   bool              inEntryWindow;   // in a session, past the entry-window open, before the no-new-entry cutoff
   bool              forceCloseNow;   // at/after the force-flat time
   int               minsToNextOpen;  // -1 if none found in the next 24h
   int               minsToSessionEnd;// -1 if not in a session
   int               minsSinceSessionOpen; // -1 if not in a session
   string            sessionKey;      // "YYYYMMDD-<SESS>" (Riyadh date), "" out of session
  };

class CTimeSessions
  {
private:
   SSettingsV2 m_s;

   int WinterSec() const { return((int)MathRound(m_s.brokerWinterOffsetHr*3600.0)); }

   //--- broker -> UTC offset in seconds, DST-aware, for a broker timestamp
   int OffsetSecAt(const datetime brokerT) const
     {
      int w=WinterSec();
      if(!m_s.brokerObservesDST) return(w);
      datetime tentativeUtc=brokerT-w;
      bool dst=V2_DstActive(m_s.brokerDSTCalendar,tentativeUtc);
      return(w+(dst?3600:0));
     }

   //--- per-session config accessors (the only place that maps a
   //--- session enum onto its settings fields)
   bool SessEnabled(const ENUM_SESSION_V2 s) const
     {
      if(s==SESS_ASIA)   return(m_s.asiaEnabled);
      if(s==SESS_LONDON) return(m_s.londonEnabled);
      if(s==SESS_NY)     return(m_s.nyEnabled);
      return(false);
     }
   ENUM_SESSION_ROLE SessRole(const ENUM_SESSION_V2 s) const
     {
      if(s==SESS_ASIA)   return(m_s.asiaRole);
      if(s==SESS_LONDON) return(m_s.londonRole);
      if(s==SESS_NY)     return(m_s.nyRole);
      return(ROLE_OFF);
     }
   int StartMin(const ENUM_SESSION_V2 s) const
     {
      if(s==SESS_ASIA)   return(m_s.asiaStartMin);
      if(s==SESS_LONDON) return(m_s.londonStartMin);
      if(s==SESS_NY)     return(m_s.nyStartMin);
      return(0);
     }
   int EndMin(const ENUM_SESSION_V2 s) const
     {
      if(s==SESS_ASIA)   return(m_s.asiaEndMin);
      if(s==SESS_LONDON) return(m_s.londonEndMin);
      if(s==SESS_NY)     return(m_s.nyEndMin);
      return(0);
     }

public:
   void Init(const SSettingsV2 &s){ m_s=s; }

   //--- public config views (used by visuals / integration)
   bool              IsEnabled(const ENUM_SESSION_V2 s) const { return(SessEnabled(s) && SessRole(s)!=ROLE_OFF); }
   ENUM_SESSION_ROLE RoleOf(const ENUM_SESSION_V2 s)    const { return(SessRole(s)); }
   int               StartMinOf(const ENUM_SESSION_V2 s) const { return(StartMin(s)); }
   int               EndMinOf(const ENUM_SESSION_V2 s)   const { return(EndMin(s)); }

   //================================================================
   //  TIME CONVERSIONS
   //================================================================
   datetime ToUtc(const datetime brokerT)    const { return(brokerT-OffsetSecAt(brokerT)); }
   datetime ToRiyadh(const datetime brokerT)  const { return(ToUtc(brokerT)+3*3600); }
   int      OffsetSec(const datetime brokerT) const { return(OffsetSecAt(brokerT)); }
   bool     DstActive(const datetime brokerT) const
     {
      return(m_s.brokerObservesDST &&
             V2_DstActive(m_s.brokerDSTCalendar,brokerT-WinterSec()));
     }

   //--- Riyadh wall-clock time -> broker time (DST evaluated on the true UTC)
   datetime RiyadhToBroker(const datetime riyadhT) const
     {
      datetime utc=riyadhT-3*3600;
      int w=WinterSec();
      int off=w;
      if(m_s.brokerObservesDST && V2_DstActive(m_s.brokerDSTCalendar,utc))
         off=w+3600;
      return(utc+off);
     }

   //================================================================
   //  SESSION QUERIES  (checked in order; windows are disjoint)
   //================================================================
   void CurrentSession(const datetime brokerNow,
                       ENUM_SESSION_V2 &ses,ENUM_SESSION_ROLE &role) const
     {
      ses=SESS_NONE; role=ROLE_OFF;
      int m=V2_MinuteOfDay(ToRiyadh(brokerNow));
      ENUM_SESSION_V2 order[3];
      order[0]=SESS_ASIA; order[1]=SESS_LONDON; order[2]=SESS_NY;
      for(int i=0;i<3;i++)
        {
         ENUM_SESSION_V2 s=order[i];
         if(!SessEnabled(s)) continue;
         if(SessRole(s)==ROLE_OFF) continue;
         if(m>=StartMin(s) && m<EndMin(s)){ ses=s; role=SessRole(s); return; }
        }
     }

   ENUM_SESSION_V2 Session(const datetime brokerNow) const
     {
      ENUM_SESSION_V2 s; ENUM_SESSION_ROLE r;
      CurrentSession(brokerNow,s,r);
      return(s);
     }
   ENUM_SESSION_ROLE Role(const datetime brokerNow) const
     {
      ENUM_SESSION_V2 s; ENUM_SESSION_ROLE r;
      CurrentSession(brokerNow,s,r);
      return(r);
     }

   //--- session open / close in BROKER time, for the Riyadh calendar
   //--- day that contains brokerNow
   datetime SessionOpenBroker(const datetime brokerNow,const ENUM_SESSION_V2 ses) const
     {
      if(ses==SESS_NONE) return(0);
      datetime riyMid=V2_Midnight(ToRiyadh(brokerNow));
      return(RiyadhToBroker(riyMid+(datetime)StartMin(ses)*60));
     }
   datetime SessionCloseBroker(const datetime brokerNow,const ENUM_SESSION_V2 ses) const
     {
      if(ses==SESS_NONE) return(0);
      datetime riyMid=V2_Midnight(ToRiyadh(brokerNow));
      return(RiyadhToBroker(riyMid+(datetime)EndMin(ses)*60));
     }

   //--- is the base-TF bar that opened at 'barOpenBroker' a session's
   //--- opening bar? (session windows start on 5-min boundaries)
   bool IsSessionOpenBar(const datetime barOpenBroker,const ENUM_SESSION_V2 ses) const
     {
      if(ses==SESS_NONE) return(false);
      return(V2_MinuteOfDay(ToRiyadh(barOpenBroker))==StartMin(ses));
     }

   //--- in a session and still allowed to open a NEW entry: past session
   //--- open, before entryWindowMinutes elapses (0 = unlimited) AND before
   //--- the noNewEntryOffsetSec cutoff near the session's close
   bool WithinEntryWindow(const datetime brokerNow) const
     {
      ENUM_SESSION_V2 s=Session(brokerNow);
      if(s==SESS_NONE) return(false);
      if(Role(brokerNow)!=ROLE_TRADE) return(false);
      datetime close=SessionCloseBroker(brokerNow,s);
      if(brokerNow >= close-(datetime)m_s.noNewEntryOffsetSec) return(false);
      if(m_s.entryWindowMinutes>0)
        {
         datetime open=SessionOpenBroker(brokerNow,s);
         if(brokerNow >= open+(datetime)m_s.entryWindowMinutes*60) return(false);
        }
      return(true);
     }

   //+--------------------------------------------------------------+
   //| At/after the force-flat time for an EXPLICITLY given session.  |
   //| Deliberately does NOT derive the session from Session(brokerNow)|
   //| - CurrentSession() uses a strict m<EndMin test, so the instant  |
   //| brokerNow reaches the close minute, Session() already reports  |
   //| SESS_NONE. A version that gated on "currently inside" could      |
   //| structurally never fire at the default ForceCloseOffsetSec=0     |
   //| (the window [close-0, close) is empty by construction) and even  |
   //| a positive offset only gave one razor-thin, easy-to-miss window. |
   //| Callers must remember which TRADE session they were last in      |
   //| (e.g. keep the value from the last bar Role()==ROLE_TRADE) and   |
   //| keep passing it every tick even after Session() rolls to NONE -  |
   //| that is what gives a force-close an unlimited number of ticks to |
   //| actually succeed, not just the one tick the boundary is crossed. |
   //+--------------------------------------------------------------+
   bool IsForceCloseTime(const datetime brokerNow,const ENUM_SESSION_V2 ses) const
     {
      if(!m_s.closeOnSessionEnd) return(false);
      if(ses==SESS_NONE) return(false);
      datetime close=SessionCloseBroker(brokerNow,ses);
      return(brokerNow >= close-(datetime)m_s.forceCloseOffsetSec);
     }

   //--- minutes from brokerNow to the next enabled session open (<=24h)
   int MinsToNextOpen(const datetime brokerNow) const
     {
      datetime best=0;
      ENUM_SESSION_V2 order[3];
      order[0]=SESS_ASIA; order[1]=SESS_LONDON; order[2]=SESS_NY;
      for(int d=0;d<=1;d++)
        {
         datetime probe=brokerNow+(datetime)d*86400;
         for(int i=0;i<3;i++)
           {
            if(!SessEnabled(order[i]) || SessRole(order[i])==ROLE_OFF) continue;
            datetime o=SessionOpenBroker(probe,order[i]);
            if(o>brokerNow && (best==0 || o<best)) best=o;
           }
        }
      if(best==0) return(-1);
      return((int)((best-brokerNow)/60));
     }

   int MinsToSessionEnd(const datetime brokerNow) const
     {
      ENUM_SESSION_V2 s=Session(brokerNow);
      if(s==SESS_NONE) return(-1);
      return((int)((SessionCloseBroker(brokerNow,s)-brokerNow)/60));
     }

   int MinsSinceSessionOpen(const datetime brokerNow) const
     {
      ENUM_SESSION_V2 s=Session(brokerNow);
      if(s==SESS_NONE) return(-1);
      return((int)((brokerNow-SessionOpenBroker(brokerNow,s))/60));
     }

   //--- unique key for a session occurrence (per-session state resets on change)
   string SessionKey(const datetime brokerNow) const
     {
      ENUM_SESSION_V2 s=Session(brokerNow);
      if(s==SESS_NONE) return("");
      MqlDateTime dt; TimeToStruct(ToRiyadh(brokerNow),dt);
      return(StringFormat("%04d%02d%02d-%s",dt.year,dt.mon,dt.day,V2_SessionName(s)));
     }

   //================================================================
   //  DIAGNOSTICS
   //================================================================
   SDiagTime Diag(const datetime brokerNow) const
     {
      SDiagTime d;
      d.brokerNow=brokerNow;
      d.utcNow   =ToUtc(brokerNow);
      d.riyadhNow=ToRiyadh(brokerNow);
      d.dstActive=DstActive(brokerNow);
      d.offsetSec=OffsetSec(brokerNow);
      CurrentSession(brokerNow,d.session,d.role);
      d.inEntryWindow   =WithinEntryWindow(brokerNow);
      d.forceCloseNow   =IsForceCloseTime(brokerNow,d.session);
      d.minsToNextOpen  =MinsToNextOpen(brokerNow);
      d.minsToSessionEnd=MinsToSessionEnd(brokerNow);
      d.minsSinceSessionOpen=MinsSinceSessionOpen(brokerNow);
      d.sessionKey      =SessionKey(brokerNow);
      return(d);
     }
  };

#endif // V2_TIMESESSIONS_MQH

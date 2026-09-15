//+------------------------------------------------------------------+
//|                                              T0_TimeSessions.mq5  |
//|  Isolated visual test for Include/TimeSessions.mqh (v2 milestone 1)|
//|                                                                   |
//|  Run in the Strategy Tester: XAUUSD, M5, "Every tick based on     |
//|  real ticks", Visual mode ON. Use a range that spans BOTH a March |
//|  and an Oct/Nov DST weekend (e.g. 2024-03-01 .. 2024-11-15) plus  |
//|  one plain week.                                                  |
//|                                                                   |
//|  PASS checklist (see v2/doc/IMPLEMENTATION_PLAN.md C0):            |
//|   [ ] Asia box left edge = 03:00 Riyadh, London 09:00, NY 15:00   |
//|       on EVERY day, incl. the DST-change weekend.                 |
//|   [ ] Dashboard Riyadh == broker + shown offset.                  |
//|   [ ] London labelled ANCHOR, never TRADE.                        |
//|   [ ] "To sess end" counts down to 0 at session close.           |
//|   [ ] Nothing shifts by an hour across the DST switch.           |
//+------------------------------------------------------------------+
#property copyright "Sessions Strategy v2"
#property version   "1.00"
#property strict

#include "../Include/V2Common.mqh"
#include "../Include/TimeSessions.mqh"
#include "../Include/VisualsV2.mqh"
#include "../Include/DashboardV2.mqh"

//--- Inputs --------------------------------------------------------
input group "General"
input ENUM_TIMEFRAMES InpTF    = PERIOD_M5;   // Base timeframe
input long            InpMagic = 930000;      // Magic (unused in T0)

input group "Server clock -> Riyadh"
input double InpServerToRiyadhOffsetHr      = 0.0;         // hours to ADD to server time to get Riyadh (0 = server already = Riyadh)
input bool   InpServerObservesDST           = false;       // server clock shifts for DST (Riyadh never does)
input ENUM_DST_CALENDAR      InpServerDSTCal = DSTCAL_US;   // DST rule set for the server, if it observes DST
input ENUM_SESSION_TIME_MODE InpSessionMode  = STM_FIXED_RIYADH;

input group "Sessions (Riyadh local time, UTC+3, no DST)"
input bool   InpAsiaEnabled          = true;
input ENUM_SESSION_ROLE InpAsiaRole  = ROLE_TRADE;
input string InpAsiaStart            = "03:00";
input string InpAsiaEnd              = "06:00";
input bool   InpLondonEnabled        = true;
input ENUM_SESSION_ROLE InpLondonRole= ROLE_ANCHOR_ONLY;
input string InpLondonStart          = "09:00";
input string InpLondonEnd            = "12:00";
input bool   InpNYEnabled            = true;
input ENUM_SESSION_ROLE InpNYRole    = ROLE_TRADE;
input string InpNYStart              = "15:00";
input string InpNYEnd                = "18:00";
input int    InpNoNewEntryOffsetSec  = 0;
input int    InpEntryWindowMinutes   = 30;    // no NEW trade after this many minutes since session open; 0 = unlimited
input int    InpForceCloseOffsetSec  = 0;
input bool   InpCloseOnSessionEnd    = true;

input group "Test / diagnostics"
input int    InpDrawPastDays = 4;      // prior days of session boxes to draw
input bool   InpVerbose      = false;  // per-bar [T0] journal trace

//--- Globals -----------------------------------------------------
SSettingsV2     g_s;
CTimeSessions   g_time;
CVisualsV2      g_vis;
CDashboardV2    g_dash;
datetime        g_lastBar   = 0;
ENUM_SESSION_V2 g_prevSess  = SESS_NONE;

//+------------------------------------------------------------------+
void BuildSettingsV2()
  {
   g_s.tf                   = InpTF;
   g_s.magic                = InpMagic;
   g_s.sessionTimeMode      = InpSessionMode;
   // engine works in UTC. Riyadh is UTC+3, so:  broker(winter) = UTC + (3 - serverToRiyadh).
   // Default serverToRiyadh = 0  ->  server clock already shows Riyadh time.
   g_s.brokerWinterOffsetHr = 3.0 - InpServerToRiyadhOffsetHr;
   g_s.brokerObservesDST    = InpServerObservesDST;
   g_s.brokerDSTCalendar    = InpServerDSTCal;

   g_s.asiaEnabled   = InpAsiaEnabled;   g_s.asiaRole   = InpAsiaRole;
   g_s.asiaStartMin  = V2_ParseHM(InpAsiaStart);  g_s.asiaEndMin  = V2_ParseHM(InpAsiaEnd);
   g_s.londonEnabled = InpLondonEnabled; g_s.londonRole = InpLondonRole;
   g_s.londonStartMin= V2_ParseHM(InpLondonStart); g_s.londonEndMin= V2_ParseHM(InpLondonEnd);
   g_s.nyEnabled     = InpNYEnabled;     g_s.nyRole     = InpNYRole;
   g_s.nyStartMin    = V2_ParseHM(InpNYStart);     g_s.nyEndMin    = V2_ParseHM(InpNYEnd);

   g_s.noNewEntryOffsetSec = InpNoNewEntryOffsetSec;
   g_s.entryWindowMinutes  = InpEntryWindowMinutes;
   g_s.forceCloseOffsetSec = InpForceCloseOffsetSec;
   g_s.closeOnSessionEnd   = InpCloseOnSessionEnd;
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,InpTF,0);
   if(t!=g_lastBar){ g_lastBar=t; return(true); }
   return(false);
  }

//+------------------------------------------------------------------+
string HM(const int minOfDay)
  {
   return(StringFormat("%02d:%02d",minOfDay/60,minOfDay%60));
  }

string ClockStr(const datetime t)
  {
   return(TimeToString(t,TIME_DATE|TIME_MINUTES)+" ("+V2_DayName(t)+")");
  }

//+------------------------------------------------------------------+
void DrawSessionBoxes(const datetime now)
  {
   ENUM_SESSION_V2 arr[3]; arr[0]=SESS_ASIA; arr[1]=SESS_LONDON; arr[2]=SESS_NY;

   for(int d=InpDrawPastDays; d>=0; d--)
     {
      datetime dayRef=now-(datetime)d*86400;
      for(int i=0;i<3;i++)
        {
         ENUM_SESSION_V2 s=arr[i];
         if(!g_time.IsEnabled(s)) continue;

         datetime o=g_time.SessionOpenBroker(dayRef,s);
         datetime c=g_time.SessionCloseBroker(dayRef,s);
         if(o<=0 || c<=o) continue;
         if(o>now) continue;                       // not started yet
         datetime rEdge=(c<now)?c:now;

         // box hugs the session's own high/low (like v1), not the chart height
         MqlRates rr[]; ArraySetAsSeries(rr,true);
         int n=CopyRates(_Symbol,InpTF,o,rEdge,rr);
         if(n<=0) continue;
         double hi=-DBL_MAX,lo=DBL_MAX;
         for(int k=0;k<n;k++){ if(rr[k].high>hi) hi=rr[k].high; if(rr[k].low<lo) lo=rr[k].low; }
         if(hi<=lo) continue;
         double pad=(hi-lo)*0.05; hi+=pad; lo-=pad;

         MqlDateTime rt; TimeToStruct(g_time.ToRiyadh(o),rt);
         string key=StringFormat("%04d%02d%02d_%s",rt.year,rt.mon,rt.day,V2_SessionName(s));
         color clr=(s==SESS_ASIA)?clrDodgerBlue:(s==SESS_LONDON)?clrMediumSeaGreen:clrTomato;

         g_vis.Rect(g_vis.Name("SB",key),o,hi,rEdge,lo,clr,false,2);
         string lbl=StringFormat("%s %s  %s-%s (Riyadh)",
                                 V2_SessionName(s),V2_RoleName(g_time.RoleOf(s)),
                                 HM(g_time.StartMinOf(s)),HM(g_time.EndMinOf(s)));
         g_vis.Text(g_vis.Name("SB",key+"_t"),o,hi,lbl,clr,8,ANCHOR_LEFT_LOWER);
        }
     }
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
void RefreshDash(const datetime now)
  {
   SDiagTime d=g_time.Diag(now);

   g_dash.Title(0,"--- V2 . TIME & SESSIONS (T0) ---");
   g_dash.KV(1,"Broker",ClockStr(d.brokerNow),clrGainsboro);
   g_dash.KV(2,"UTC",   ClockStr(d.utcNow),   clrSilver);
   g_dash.KV(3,"Riyadh",ClockStr(d.riyadhNow),clrWhite);

   string dstTxt;
   if(!InpServerObservesDST) dstTxt="no DST";
   else dstTxt=(d.dstActive?"SUMMER":"WINTER")+
              StringFormat(" (%s)",InpServerDSTCal==DSTCAL_US?"US":InpServerDSTCal==DSTCAL_EU?"EU":"NONE");
   int riyMinusSrv=(int)MathRound((d.riyadhNow-d.brokerNow)/3600.0);
   g_dash.KV(4,"Clock",StringFormat("Riyadh = server %+dh   (server = UTC+%.0f)  %s",
             riyMinusSrv,d.offsetSec/3600.0,dstTxt),
             d.dstActive?clrGold:clrGainsboro);

   color sc=(d.role==ROLE_TRADE)?clrLime:(d.role==ROLE_ANCHOR_ONLY)?clrGold:clrSilver;
   g_dash.KV(5,"Session",StringFormat("%s   role %s",V2_SessionName(d.session),V2_RoleName(d.role)),sc);
   g_dash.KV(6,"Gates",StringFormat("entry-window %s (%d min, %s since open)   force-close %s",
             d.inEntryWindow?"YES":"no",InpEntryWindowMinutes,
             d.minsSinceSessionOpen>=0?(string)d.minsSinceSessionOpen:"-",
             d.forceCloseNow?"YES":"no"),
             d.inEntryWindow?clrLime:clrSilver);
   g_dash.KV(7,"Countdowns",StringFormat("next open %d min   sess end %s",
             d.minsToNextOpen,
             d.minsToSessionEnd>=0?(string)d.minsToSessionEnd+" min":"-"),clrGainsboro);
   g_dash.KV(8,"Session key",d.sessionKey==""?"-":d.sessionKey,clrSilver);
   g_dash.Line(9,"");
   g_dash.Line(10,"check: box edges at the labelled Riyadh hours, incl. DST weekend",clrDimGray);
   g_dash.Render();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   BuildSettingsV2();
   g_time.Init(g_s);
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());

   datetime nowB=TimeCurrent();
   PrintFormat("[T0] server->Riyadh = %+.1fh, observesDST=%s (%s). Now: server %s = Riyadh %s",
               InpServerToRiyadhOffsetHr, InpServerObservesDST?"true":"false",
               InpServerDSTCal==DSTCAL_US?"US":InpServerDSTCal==DSTCAL_EU?"EU":"NONE",
               TimeToString(nowB,TIME_DATE|TIME_MINUTES),
               TimeToString(g_time.ToRiyadh(nowB),TIME_DATE|TIME_MINUTES));
   PrintFormat("[T0] sessions: %s %s %s-%s | %s %s %s-%s | %s %s %s-%s",
               V2_SessionName(SESS_ASIA),  V2_RoleName(g_time.RoleOf(SESS_ASIA)),
               HM(g_s.asiaStartMin),  HM(g_s.asiaEndMin),
               V2_SessionName(SESS_LONDON),V2_RoleName(g_time.RoleOf(SESS_LONDON)),
               HM(g_s.londonStartMin),HM(g_s.londonEndMin),
               V2_SessionName(SESS_NY),    V2_RoleName(g_time.RoleOf(SESS_NY)),
               HM(g_s.nyStartMin),    HM(g_s.nyEndMin));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_vis.Destroy();
   g_dash.Destroy();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now=TimeCurrent();
   bool newBar=IsNewBar();

   RefreshDash(now);

   if(!newBar) return;

   DrawSessionBoxes(now);

   ENUM_SESSION_V2 s; ENUM_SESSION_ROLE r;
   g_time.CurrentSession(now,s,r);
   if(s!=g_prevSess)
     {
      PrintFormat("[T0] %s -> session %s (role %s) | broker %s | UTC %s | Riyadh %s | key %s",
                  V2_SessionName(g_prevSess),V2_SessionName(s),V2_RoleName(r),
                  TimeToString(now,TIME_DATE|TIME_MINUTES),
                  TimeToString(g_time.ToUtc(now),TIME_DATE|TIME_MINUTES),
                  TimeToString(g_time.ToRiyadh(now),TIME_DATE|TIME_MINUTES),
                  g_time.SessionKey(now));
      g_prevSess=s;
     }

   if(InpVerbose)
      PrintFormat("[T0] bar %s | Riyadh %s | sess %s/%s | ew=%s fc=%s | endIn %d",
                  TimeToString(now,TIME_MINUTES),
                  TimeToString(g_time.ToRiyadh(now),TIME_DATE|TIME_MINUTES),
                  V2_SessionName(s),V2_RoleName(r),
                  g_time.WithinEntryWindow(now)?"Y":"n",
                  g_time.IsForceCloseTime(now,s)?"Y":"n",
                  g_time.MinsToSessionEnd(now));
  }
//+------------------------------------------------------------------+

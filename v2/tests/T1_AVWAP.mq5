//+------------------------------------------------------------------+
//|                                                     T1_AVWAP.mq5  |
//|  Isolated visual test for Include/AVWAP.mqh (v2 milestone 2).      |
//|                                                                   |
//|  Run: XAUUSD, M5, "Every tick based on real ticks", Visual ON.    |
//|                                                                   |
//|  PASS checklist (v2/doc/IMPLEMENTATION_PLAN.md C1):               |
//|   [ ] With T1_MANUAL_FIXED anchored to the SAME bar as            |
//|       ref/aVWAP.mq5 (set that indicator to HLC3), the VWAP lines  |
//|       overlap.                                                    |
//|   [ ] Bands are exactly symmetric about VWAP.                     |
//|   [ ] sigma starts ~0, grows, stabilises; no bands before bar 5.  |
//|   [ ] Scrubbing the visual tester back/forward moves no already-  |
//|       drawn segment (no repaint).                                 |
//|   [ ] T1_SESSION_OPEN: a fresh curve appears at each TRADE        |
//|       session open; the previous one is cleared.                  |
//+------------------------------------------------------------------+
#property copyright "Sessions Strategy v2"
#property version   "1.00"
#property strict

#include "../Include/V2Common.mqh"
#include "../Include/TimeSessions.mqh"
#include "../Include/AVWAP.mqh"
#include "../Include/VisualsV2.mqh"
#include "../Include/DashboardV2.mqh"

enum ENUM_T1_ANCHOR
  {
   T1_SESSION_OPEN = 0, // auto: anchor at each TRADE session's first bar (test convenience)
   T1_MANUAL_FIXED = 1, // anchor at InpManualAnchor
   T1_MANUAL_DRAG  = 2  // anchor at a draggable vertical line (live charts)
  };

//--- Inputs --------------------------------------------------------
input group "General"
input ENUM_TIMEFRAMES InpTF = PERIOD_M5;

input group "Server clock -> Riyadh (for T1_SESSION_OPEN)"
input double InpServerToRiyadhOffsetHr = 0.0;    // hours to ADD to server time to get Riyadh (0 = server already = Riyadh)
input bool   InpServerObservesDST      = false;  // server clock shifts for DST
input ENUM_DST_CALENDAR InpServerDSTCal = DSTCAL_US;

input group "Sessions (Riyadh local time)"
input string InpAsiaStart   = "03:00";
input string InpAsiaEnd     = "06:00";
input string InpLondonStart = "09:00";
input string InpLondonEnd   = "12:00";
input string InpNYStart     = "15:00";
input string InpNYEnd       = "18:00";

input group "AVWAP + sigma bands"
input ENUM_PRICE_INPUT_V2 InpPriceInput        = PI_HLC3;
input ENUM_VOLUME_SRC_V2  InpVolumeSrc         = VS_TICK;
input double              InpBand1Mult         = 1.0;
input double              InpBand2Mult         = 2.0;
input int                 InpMinBarsSinceAnchor= 5;

input group "Test / diagnostics"
input ENUM_T1_ANCHOR InpAnchorMode  = T1_SESSION_OPEN;
input datetime       InpManualAnchor= 0;      // T1_MANUAL_FIXED anchor time (server)
input int            InpDrawBars    = 700;    // max curve history drawn
input bool           InpVerbose     = false;

//--- Globals -----------------------------------------------------
SSettingsV2   g_s;
CTimeSessions g_time;
CAVWAP        g_avwap;
CVisualsV2    g_vis;
CDashboardV2  g_dash;
datetime      g_lastBar   = 0;
datetime      g_lastAnchor= 0;
datetime      g_drawnTo   = 0;

#define T1_DRAGLINE "T1_ANCHOR_DRAG"

//+------------------------------------------------------------------+
void BuildSettingsV2()
  {
   g_s.tf                   = InpTF;
   g_s.magic                = 0;
   g_s.sessionTimeMode      = STM_FIXED_RIYADH;
   g_s.brokerWinterOffsetHr = 3.0 - InpServerToRiyadhOffsetHr; // Riyadh = UTC+3
   g_s.brokerObservesDST    = InpServerObservesDST;
   g_s.brokerDSTCalendar    = InpServerDSTCal;

   g_s.asiaEnabled=true;   g_s.asiaRole=ROLE_TRADE;
   g_s.asiaStartMin=V2_ParseHM(InpAsiaStart);   g_s.asiaEndMin=V2_ParseHM(InpAsiaEnd);
   g_s.londonEnabled=true; g_s.londonRole=ROLE_ANCHOR_ONLY;
   g_s.londonStartMin=V2_ParseHM(InpLondonStart);g_s.londonEndMin=V2_ParseHM(InpLondonEnd);
   g_s.nyEnabled=true;     g_s.nyRole=ROLE_TRADE;
   g_s.nyStartMin=V2_ParseHM(InpNYStart);        g_s.nyEndMin=V2_ParseHM(InpNYEnd);

   g_s.noNewEntryOffsetSec=0; g_s.forceCloseOffsetSec=0; g_s.closeOnSessionEnd=true;

   g_s.priceInput         = InpPriceInput;
   g_s.volumeSrc          = InpVolumeSrc;
   g_s.band1Mult          = InpBand1Mult;
   g_s.band2Mult          = InpBand2Mult;
   g_s.minBarsSinceAnchor = InpMinBarsSinceAnchor;
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,InpTF,0);
   if(t!=g_lastBar){ g_lastBar=t; return(true); }
   return(false);
  }

//+------------------------------------------------------------------+
//| Decide / update the anchor for the current bar                   |
//+------------------------------------------------------------------+
void UpdateAnchor(const datetime nowBar)
  {
   if(InpAnchorMode==T1_MANUAL_FIXED)
     {
      if(InpManualAnchor>0) g_avwap.SetAnchor(InpManualAnchor);
      return;
     }
   if(InpAnchorMode==T1_MANUAL_DRAG)
     {
      if(ObjectFind(0,T1_DRAGLINE)>=0)
         g_avwap.SetAnchor((datetime)ObjectGetInteger(0,T1_DRAGLINE,OBJPROP_TIME));
      return;
     }
   // T1_SESSION_OPEN
   ENUM_SESSION_V2 s; ENUM_SESSION_ROLE r;
   g_time.CurrentSession(nowBar,s,r);
   if(r==ROLE_TRADE && g_time.IsSessionOpenBar(nowBar,s))
      g_avwap.SetAnchor(nowBar);
  }

//+------------------------------------------------------------------+
void DrawCurve(const datetime nowBar)
  {
   datetime t[]; double vw[],sg[];
   int n=g_avwap.Compute(nowBar,t,vw,sg);

   // anchor changed -> wipe and redraw the whole curve
   if(g_avwap.Anchor()!=g_lastAnchor)
     {
      g_vis.ClearGroup("VW");
      g_lastAnchor=g_avwap.Anchor();
      g_drawnTo=0;
      if(g_lastAnchor>0)
        {
         g_vis.VLine(g_vis.Name("VW","ANCHOR"),g_lastAnchor,C'41,98,255',STYLE_SOLID,1);
         double pm=g_vis.PriceMax();
         if(pm>0) g_vis.Text(g_vis.Name("VW","ANCHOR_T"),g_lastAnchor,pm,"AVWAP anchor",
                             C'41,98,255',8,ANCHOR_LEFT_UPPER);
        }
     }
   if(n<=1) return;

   int start=(n>InpDrawBars)?n-InpDrawBars:1;
   if(start<1) start=1;
   for(int i=start;i<n;i++)
     {
      if(t[i]<=g_drawnTo) continue;
      string kb=(string)(long)t[i-1];
      double u1a=vw[i-1]+InpBand1Mult*sg[i-1], u1b=vw[i]+InpBand1Mult*sg[i];
      double l1a=vw[i-1]-InpBand1Mult*sg[i-1], l1b=vw[i]-InpBand1Mult*sg[i];
      double u2a=vw[i-1]+InpBand2Mult*sg[i-1], u2b=vw[i]+InpBand2Mult*sg[i];
      double l2a=vw[i-1]-InpBand2Mult*sg[i-1], l2b=vw[i]-InpBand2Mult*sg[i];
      g_vis.Segment(g_vis.Name("VW","M_"+kb), t[i-1],vw[i-1], t[i],vw[i], C'41,98,255',2);
      g_vis.Segment(g_vis.Name("VW","U1_"+kb),t[i-1],u1a,     t[i],u1b,   clrGoldenrod,1);
      g_vis.Segment(g_vis.Name("VW","L1_"+kb),t[i-1],l1a,     t[i],l1b,   clrGoldenrod,1);
      g_vis.Segment(g_vis.Name("VW","U2_"+kb),t[i-1],u2a,     t[i],u2b,   clrTomato,1);
      g_vis.Segment(g_vis.Name("VW","L2_"+kb),t[i-1],l2a,     t[i],l2b,   clrTomato,1);
     }
   g_drawnTo=t[n-1];
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
void RefreshDash()
  {
   double ref=iClose(_Symbol,InpTF,1);
   SDiagAVWAP d=g_avwap.Diag(ref);

   string modeTxt=(InpAnchorMode==T1_SESSION_OPEN)?"session-open [test]":
                  (InpAnchorMode==T1_MANUAL_FIXED)?"manual (fixed)":"manual (drag)";

   g_dash.Title(0,"--- V2 . AVWAP + SIGMA BANDS (T1) ---");
   g_dash.KV(1,"Anchor mode",modeTxt,clrSilver);
   g_dash.KV(2,"Anchor",d.hasAnchor?TimeToString(d.anchorTime,TIME_DATE|TIME_MINUTES):"- none -",
             d.hasAnchor?clrWhite:clrTomato);
   g_dash.KV(3,"Bars",StringFormat("%d  (min %d)",d.barsSinceAnchor,InpMinBarsSinceAnchor),clrGainsboro);
   g_dash.KV(4,"VWAP",d.ready?DoubleToString(d.vwap,_Digits):"-",clrDeepSkyBlue);
   g_dash.KV(5,"sigma",d.ready?DoubleToString(d.sigma,_Digits):"-",clrGainsboro);
   g_dash.KV(6,"+/-1 sigma",d.ready?StringFormat("%s / %s",DoubleToString(d.u1,_Digits),DoubleToString(d.l1,_Digits)):"-",clrGoldenrod);
   g_dash.KV(7,"+/-2 sigma",d.ready?StringFormat("%s / %s",DoubleToString(d.u2,_Digits),DoubleToString(d.l2,_Digits)):"-",clrTomato);
   g_dash.KV(8,"d",d.ready?StringFormat("%s  (%.2f sigma)",DoubleToString(d.dPrice,_Digits),d.dSigma):"-",
             clrWhite);
   string state=!d.hasAnchor?"NO ANCHOR":d.ready?"READY":StringFormat("WARM-UP (%d/%d)",d.barsSinceAnchor,InpMinBarsSinceAnchor);
   g_dash.KV(9,"State",state,d.ready?clrLime:clrGold);
   g_dash.Line(10,"");
   g_dash.Line(11,"check: overlay ref/aVWAP.mq5 (HLC3) at same anchor -> lines match",clrDimGray);
   g_dash.Render();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   BuildSettingsV2();
   g_time.Init(g_s);
   g_avwap.Init(g_s,_Symbol);
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());

   if(InpAnchorMode==T1_MANUAL_DRAG && ObjectFind(0,T1_DRAGLINE)<0)
     {
      datetime seed=iTime(_Symbol,InpTF,60);
      if(seed==0) seed=TimeCurrent();
      ObjectCreate(0,T1_DRAGLINE,OBJ_VLINE,0,seed,0);
      ObjectSetInteger(0,T1_DRAGLINE,OBJPROP_COLOR,clrDodgerBlue);
      ObjectSetInteger(0,T1_DRAGLINE,OBJPROP_STYLE,STYLE_DASH);
      ObjectSetInteger(0,T1_DRAGLINE,OBJPROP_SELECTABLE,true);
      ObjectSetString (0,T1_DRAGLINE,OBJPROP_TEXT,"AVWAP anchor (drag me)");
     }

   PrintFormat("[T1] anchor mode=%d, price=%d, vol=%d, bands %.1f/%.1f, minBars=%d",
               InpAnchorMode,InpPriceInput,InpVolumeSrc,InpBand1Mult,InpBand2Mult,InpMinBarsSinceAnchor);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_vis.Destroy();
   g_dash.Destroy();
   ObjectDelete(0,T1_DRAGLINE);
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id==CHARTEVENT_OBJECT_DRAG && sparam==T1_DRAGLINE)
     {
      g_avwap.SetAnchor((datetime)ObjectGetInteger(0,T1_DRAGLINE,OBJPROP_TIME));
      DrawCurve(iTime(_Symbol,InpTF,0));
      RefreshDash();
     }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   datetime nowBar=iTime(_Symbol,InpTF,0);
   bool newBar=IsNewBar();

   RefreshDash();
   if(!newBar) return;

   UpdateAnchor(nowBar);
   DrawCurve(nowBar);

   if(InpVerbose)
     {
      double vw,sg; int b;
      g_avwap.Latest(vw,sg,b);
      PrintFormat("[T1] %s anchor=%s bars=%d vwap=%s sigma=%s ready=%s",
                  TimeToString(nowBar,TIME_DATE|TIME_MINUTES),
                  g_avwap.HasAnchor()?TimeToString(g_avwap.Anchor(),TIME_MINUTES):"none",
                  b,DoubleToString(vw,_Digits),DoubleToString(sg,_Digits),
                  g_avwap.Ready()?"Y":"n");
     }
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                              T3b_RejectBreak.mq5  |
//|  Isolated visual test for Include/RejectBreak.mqh (milestone 8).  |
//|                                                                   |
//|  Self-contained, same lineage as T3a: also runs ZigZag (T2a),     |
//|  calibrated SessionQuality (T2c), AnchorSelect (T2d) and Zones    |
//|  (T3a) internally so RejectBreak's lean is checked against a REAL |
//|  zone/AVWAP, not a fake one.                                      |
//|                                                                   |
//|  On every newly CLOSED bar, marks any firing primitive at its     |
//|  band: green up-arrow rejSup/brkUp, red down-arrow rejRes/brkDn,  |
//|  labelled "<primitive>@<band>" (e.g. "rejSup@+1"). Dashboard shows|
//|  the current Z2 provisional lean, how long it's been held, and    |
//|  the Extended-transition flag.                                    |
//|                                                                   |
//|  Run: XAUUSD, M5, "Every tick based on real ticks", Visual ON,   |
//|  1-2 weeks with several band tests (reuse the T3a window).       |
//|                                                                   |
//|  PASS checklist (v2/doc/IMPLEMENTATION_PLAN.md C3b):             |
//|   [ ] A rejSup@+1 mark only on a candle that visibly wicks the    |
//|       +1σ band and closes back above it with a lower wick >= 50%  |
//|       of its range (InpRejectWickMinFrac).                        |
//|   [ ] A brkUp@+1 mark only on a momentum close beyond the band by |
//|       >= InpBreakBufferSigma*sigma with body >= InpBreakBodyAtr*ATR.|
//|   [ ] Lean text always matches the most recent qualifying         |
//|       primitive, and resets to NONE the moment price leaves Z2.   |
//|   [ ] A close through +/-2sigma flips the Extended-transition flag|
//|       on (independent of whether a lean was active).              |
//+------------------------------------------------------------------+
#property copyright "Sessions Strategy v2"
#property version   "1.00"
#property strict

#include "../Include/V2Common.mqh"
#include "../Include/TimeSessions.mqh"
#include "../Include/SessionQuality.mqh"
#include "../Include/ZigZag.mqh"
#include "../Include/AnchorSelect.mqh"
#include "../Include/AVWAP.mqh"
#include "../Include/Zones.mqh"
#include "../Include/RejectBreak.mqh"
#include "../Include/VisualsV2.mqh"
#include "../Include/DashboardV2.mqh"

input group "General"
input ENUM_TIMEFRAMES InpTF = PERIOD_M5;

input group "Server clock -> Riyadh"
input double InpServerToRiyadhOffsetHr = 0.0;
input bool   InpServerObservesDST      = false;
input ENUM_DST_CALENDAR InpServerDSTCal = DSTCAL_US;

input group "Sessions (Riyadh local time)"
input string InpAsiaStart   = "03:00";
input string InpAsiaEnd     = "06:00";
input string InpLondonStart = "09:00";
input string InpLondonEnd   = "12:00";
input string InpNYStart     = "15:00";
input string InpNYEnd       = "18:00";

input group "ZigZag (Examples\\ZigZag params)"
input int InpZZDepth     = 24;
input int InpZZDeviation = 5;
input int InpZZBackstep  = 2;
input int InpAtrPeriod   = 14;

input group "Session-quality (calibrated 2026-09-14 vs 520 hand-labelled sessions - see T2c)"
input ENUM_QUALITY_MODE_V2 InpQualityMode      = QM_GATES;
input double               InpScoreThreshold   = 0.60;
input int                  InpBaselineN        = 20;
input double               InpMinRangeRatio    = 0.70;
input double               InpMinRangeAtr      = 10.0;
input double               InpMinLegAtr        = 6.0;
input double               InpMinEfficiency    = 0.15;
input double               InpImpulseBarAtrMult= 0.8;
input int                  InpMinImpulseBars   = 1;
input double               InpWRangeBase       = 0.45;
input double               InpWLeg             = 0.25;
input double               InpWRangeAtr        = 0.20;
input double               InpWEff             = 0.10;

input group "Anchor selection"
input double InpMaxAnchorLookbackHr = 48.0;
input double InpAnchorFlexMin       = 120.0;
input double InpAnchorPreRollMin    = 30.0;

input group "AVWAP + sigma bands"
input ENUM_PRICE_INPUT_V2 InpPriceInput         = PI_HLC3;
input ENUM_VOLUME_SRC_V2  InpVolumeSrc          = VS_TICK;
input double              InpBand1Mult          = 1.0;
input double              InpBand2Mult          = 2.0;
input int                 InpMinBarsSinceAnchor = 5;
input int                 InpDrawVwapBars       = 700;

input group "Zone classifier"
input int InpConfirmStateMaxBars = 12;

input group "Rejection / breakthrough primitives (spec Sec9.1)"
input double InpTouchTolSigma     = 0.10;
input double InpRejectCloseSigma  = 0.05;
input bool   InpRejectRequireWick = true;
input double InpRejectWickMinFrac = 0.5;
input double InpBreakBufferSigma  = 0.15;
input bool   InpBreakRequireMomentum = true;
input double InpBreakBodyAtr      = 0.8;

input group "Test / diagnostics"
input int  InpMaxQualityBoxes = 80;
input int  InpMaxStripCells   = 600;
input bool InpWriteCsv        = true;
input bool InpVerbose         = true;

SSettingsV2     g_s;
CTimeSessions   g_time;
CSessionQuality g_sq;
CZigZag         g_zz;
CAnchorSelect   g_anchor;
CAVWAP          g_avwap;
CZones          g_zones;
CRejectBreak    g_rb;
CVisualsV2      g_vis;
CDashboardV2    g_dash;

datetime        g_lastBar       = 0;
ENUM_SESSION_V2 g_activeSession = SESS_NONE;
datetime        g_drawnVwapTo   = 0;
datetime        g_lastAvwapAnchor = 0;
string          g_lastAnchorKey = "";

SQualityResult  g_qres[128];
int             g_qresN = 0;

string          g_csv[];

struct SZoneRow { datetime barTime; SDiagZones z; };
SZoneRow        g_zrows[600];
int             g_zrowsN = 0;

SDiagRejectBreak g_lastRb;

//+------------------------------------------------------------------+
void BuildSettingsV2()
  {
   g_s.tf                   = InpTF;
   g_s.brokerWinterOffsetHr = 3.0 - InpServerToRiyadhOffsetHr;
   g_s.brokerObservesDST    = InpServerObservesDST;
   g_s.brokerDSTCalendar    = InpServerDSTCal;

   g_s.asiaEnabled=true;   g_s.asiaRole=ROLE_TRADE;
   g_s.asiaStartMin=V2_ParseHM(InpAsiaStart);   g_s.asiaEndMin=V2_ParseHM(InpAsiaEnd);
   g_s.londonEnabled=true; g_s.londonRole=ROLE_ANCHOR_ONLY;
   g_s.londonStartMin=V2_ParseHM(InpLondonStart);g_s.londonEndMin=V2_ParseHM(InpLondonEnd);
   g_s.nyEnabled=true;     g_s.nyRole=ROLE_TRADE;
   g_s.nyStartMin=V2_ParseHM(InpNYStart);        g_s.nyEndMin=V2_ParseHM(InpNYEnd);
   g_s.noNewEntryOffsetSec=0; g_s.forceCloseOffsetSec=0; g_s.closeOnSessionEnd=true;

   g_s.zzDepth=InpZZDepth; g_s.zzDeviation=InpZZDeviation; g_s.zzBackstep=InpZZBackstep;
   g_s.atrPeriod=InpAtrPeriod;

   g_s.qualityMode          =InpQualityMode;
   g_s.qualityScoreThreshold=InpScoreThreshold;
   g_s.qualityBaselineN     =InpBaselineN;
   g_s.minRangeRatio        =InpMinRangeRatio;
   g_s.minRangeAtr          =InpMinRangeAtr;
   g_s.minLegAtr            =InpMinLegAtr;
   g_s.minEfficiency        =InpMinEfficiency;
   g_s.impulseBarAtrMult    =InpImpulseBarAtrMult;
   g_s.minImpulseBars       =InpMinImpulseBars;
   g_s.wLeg=InpWLeg; g_s.wEff=InpWEff; g_s.wRangeBase=InpWRangeBase; g_s.wRangeAtr=InpWRangeAtr;

   g_s.maxAnchorLookbackHr=InpMaxAnchorLookbackHr;
   g_s.anchorFlexMin      =InpAnchorFlexMin;
   g_s.anchorPreRollMin   =InpAnchorPreRollMin;
   g_s.noAnchorAction     =NA_SKIP_SESSION;

   g_s.priceInput         =InpPriceInput;
   g_s.volumeSrc          =InpVolumeSrc;
   g_s.band1Mult          =InpBand1Mult;
   g_s.band2Mult          =InpBand2Mult;
   g_s.minBarsSinceAnchor =InpMinBarsSinceAnchor;

   g_s.confirmStateMaxBars=InpConfirmStateMaxBars;

   g_s.touchTolSigma        =InpTouchTolSigma;
   g_s.rejectCloseSigma     =InpRejectCloseSigma;
   g_s.rejectRequireWick    =InpRejectRequireWick;
   g_s.rejectWickMinFrac    =InpRejectWickMinFrac;
   g_s.breakBufferSigma     =InpBreakBufferSigma;
   g_s.breakRequireMomentum =InpBreakRequireMomentum;
   g_s.breakBodyAtr         =InpBreakBodyAtr;
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,InpTF,0);
   if(t!=g_lastBar){ g_lastBar=t; return(true); }
   return(false);
  }

string RiyStr(const datetime serverT){ return(TimeToString(g_time.ToRiyadh(serverT),TIME_DATE|TIME_MINUTES)); }
string RiyDate(const datetime serverT){ return(TimeToString(g_time.ToRiyadh(serverT),TIME_DATE)); }

//+------------------------------------------------------------------+
//|  ZigZag pivots (T2a-style)                                        |
//+------------------------------------------------------------------+
void DrawZigZag()
  {
   g_vis.ClearGroup("ZZ");
   int total=g_zz.Total();
   if(total<2){ g_vis.Redraw(); return; }

   int want=MathMin(total,300);
   datetime t[]; double p[]; bool hi[];
   ArrayResize(t,want); ArrayResize(p,want); ArrayResize(hi,want);
   int c=0;
   for(int from=want-1;from>=0;from--)
     {
      SZZPivot pv;
      if(!g_zz.Get(from,pv,true)) continue;
      t[c]=pv.time; p[c]=pv.price; hi[c]=pv.isHigh; c++;
     }

   bool tail=g_zz.TailPending();
   for(int i=1;i<c;i++)
     {
      bool tentative=(tail && i==c-1);
      g_vis.Segment(g_vis.Name("ZZ","L"+(string)i),t[i-1],p[i-1],t[i],p[i],
                    tentative?clrDimGray:clrGold,tentative?1:2,tentative?STYLE_DASH:STYLE_SOLID);
     }
   for(int i=0;i<c;i++)
      g_vis.Arrow(g_vis.Name("ZZ","P"+(string)i),t[i],p[i],159,
                  hi[i]?clrTomato:clrLimeGreen,2,hi[i]?ANCHOR_TOP:ANCHOR_BOTTOM);
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
//|  SessionQuality boxes (T2c-style, one-line label)                |
//+------------------------------------------------------------------+
void PushQuality(const SQualityResult &r)
  {
   int cap=MathMin(InpMaxQualityBoxes,128);
   if(g_qresN<cap){ g_qres[g_qresN++]=r; return; }
   for(int i=1;i<cap;i++) g_qres[i-1]=g_qres[i];
   g_qres[cap-1]=r;
  }

void DrawQuality()
  {
   g_vis.ClearGroup("SQ");
   for(int i=0;i<g_qresN;i++)
     {
      SQualityResult r=g_qres[i];
      if(!r.evaluated) continue;
      MqlRates b[]; ArraySetAsSeries(b,false);
      int n=CopyRates(_Symbol,InpTF,r.openTime,r.closeTime,b);
      double hi=-DBL_MAX, lo=DBL_MAX;
      for(int k=0;k<n;k++)
        {
         if(b[k].time<r.openTime || b[k].time>=r.closeTime) continue;
         if(b[k].high>hi) hi=b[k].high;
         if(b[k].low <lo) lo=b[k].low;
        }
      if(hi<=lo) continue;
      color c=r.pass?clrLime:clrTomato;
      string key=RiyDate(r.openTime)+"_"+V2_SessionName(r.session);
      g_vis.Rect(g_vis.Name("SQ",key),r.openTime,hi,r.closeTime,lo,c,false,1);
      g_vis.Text(g_vis.Name("SQ",key+"_L"),r.openTime,hi,
                 StringFormat("%s %s %s%s %.2f",V2_SessionName(r.session),RiyDate(r.openTime),r.state,
                              r.baselineWarm?"(w)":"",r.score),
                 c,8,ANCHOR_LEFT_LOWER);
     }
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
void DrawLiveBox(const datetime now)
  {
   g_vis.ClearGroup("LIVE");
   if(g_activeSession==SESS_NONE) return;

   datetime openB =g_time.SessionOpenBroker(now,g_activeSession);
   datetime closeB=g_time.SessionCloseBroker(now,g_activeSession);
   if(openB<=0 || closeB<=openB) return;

   MqlRates b[]; ArraySetAsSeries(b,false);
   int n=CopyRates(_Symbol,InpTF,openB,now+PeriodSeconds(InpTF),b);
   double hi=-DBL_MAX, lo=DBL_MAX;
   for(int k=0;k<n;k++)
     {
      if(b[k].time<openB) continue;
      if(b[k].high>hi) hi=b[k].high;
      if(b[k].low <lo) lo=b[k].low;
     }
   if(hi<=lo) return;

   g_vis.Rect(g_vis.Name("LIVE","cur"),openB,hi,closeB,lo,clrYellow,false,2);
   g_vis.Text(g_vis.Name("LIVE","cur_L"),openB,hi,
              StringFormat("%s %s  IN PROGRESS...",V2_SessionName(g_activeSession),RiyDate(openB)),
              clrYellow,9,ANCHOR_LEFT_LOWER);
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
//|  Anchor marker + ray + label at a TRADE session open              |
//+------------------------------------------------------------------+
void DrawAnchor(const SAnchorResult &ar)
  {
   string key="ANC_"+RiyDate(ar.tradeOpenTime)+"_"+V2_SessionName(ar.tradeSession);
   double atr=g_zz.CurrentATR();
   double pad=(atr>0)?atr*0.4:50*_Point;

   if(ar.found)
     {
      g_vis.Arrow(g_vis.Name("ANC",key+"_PIV"),ar.anchorTime,ar.anchorPrice,159,
                  clrAqua,3,ar.anchorIsHigh?ANCHOR_TOP:ANCHOR_BOTTOM);
      g_vis.Segment(g_vis.Name("ANC",key+"_RAY"),ar.anchorTime,ar.anchorPrice,
                    ar.tradeOpenTime,ar.anchorPrice,clrAqua,1,STYLE_DOT);
      g_vis.Text(g_vis.Name("ANC",key+"_LBL"),ar.anchorTime,
                 ar.anchorPrice+(ar.anchorIsHigh?pad:-pad),
                 StringFormat("ANCHOR <- %s %s pivot %s (score %.2f, %.0fh back)",
                    V2_SessionName(ar.srcSession),RiyDate(ar.srcOpenTime),
                    DoubleToString(ar.anchorPrice,_Digits),ar.srcScore,ar.hoursBack),
                 clrAqua,9,ar.anchorIsHigh?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER);
     }
   else
     {
      int sh=iBarShift(_Symbol,InpTF,ar.tradeOpenTime,false);
      double refP=(sh>=0)?iHigh(_Symbol,InpTF,sh):0.0;
      if(refP<=0) refP=g_vis.PriceMax();
      g_vis.VLine(g_vis.Name("ANC",key+"_VL"),ar.tradeOpenTime,clrTomato,STYLE_DASH,1);
      g_vis.Text(g_vis.Name("ANC",key+"_LBL"),ar.tradeOpenTime,refP+pad,
                 StringFormat("NO ANCHOR -> SKIP  (%s, nothing PASS within %.0fh)",
                    V2_SessionName(ar.tradeSession),InpMaxAnchorLookbackHr),
                 clrTomato,9,ANCHOR_LEFT_LOWER);
     }
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
//|  AVWAP overlay, anchored wherever AnchorSelect resolved (T1-style)|
//+------------------------------------------------------------------+
void DrawVwap(const datetime nowBar)
  {
   datetime t[]; double vw[],sg[];
   int n=g_avwap.Compute(nowBar,t,vw,sg);

   if(g_avwap.Anchor()!=g_lastAvwapAnchor)
     {
      g_vis.ClearGroup("AVW");
      g_lastAvwapAnchor=g_avwap.Anchor();
      g_drawnVwapTo=0;
     }
   if(n<=1) return;

   int start=(n>InpDrawVwapBars)?n-InpDrawVwapBars:1;
   if(start<1) start=1;
   for(int i=start;i<n;i++)
     {
      if(t[i]<=g_drawnVwapTo) continue;
      string kb=(string)(long)t[i-1];
      double u1a=vw[i-1]+InpBand1Mult*sg[i-1], u1b=vw[i]+InpBand1Mult*sg[i];
      double l1a=vw[i-1]-InpBand1Mult*sg[i-1], l1b=vw[i]-InpBand1Mult*sg[i];
      double u2a=vw[i-1]+InpBand2Mult*sg[i-1], u2b=vw[i]+InpBand2Mult*sg[i];
      double l2a=vw[i-1]-InpBand2Mult*sg[i-1], l2b=vw[i]-InpBand2Mult*sg[i];
      g_vis.Segment(g_vis.Name("AVW","M_"+kb), t[i-1],vw[i-1], t[i],vw[i], C'41,98,255',2);
      g_vis.Segment(g_vis.Name("AVW","U1_"+kb),t[i-1],u1a,     t[i],u1b,   clrGoldenrod,1);
      g_vis.Segment(g_vis.Name("AVW","L1_"+kb),t[i-1],l1a,     t[i],l1b,   clrGoldenrod,1);
      g_vis.Segment(g_vis.Name("AVW","U2_"+kb),t[i-1],u2a,     t[i],u2b,   clrTomato,1);
      g_vis.Segment(g_vis.Name("AVW","L2_"+kb),t[i-1],l2a,     t[i],l2b,   clrTomato,1);
     }
   g_drawnVwapTo=t[n-1];
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
//|  Zone strip: one cell per bar, Z1 grey / Z2 amber / Z3 red        |
//+------------------------------------------------------------------+
void PushZoneRow(const datetime barTime,const SDiagZones &z)
  {
   int cap=MathMin(InpMaxStripCells,600);
   SZoneRow row; row.barTime=barTime; row.z=z;
   if(g_zrowsN<cap){ g_zrows[g_zrowsN++]=row; return; }
   for(int i=1;i<cap;i++) g_zrows[i-1]=g_zrows[i];
   g_zrows[cap-1]=row;
  }

void DrawZoneStrip()
  {
   g_vis.ClearGroup("ZS");
   if(g_zrowsN<1) return;

   datetime t0=g_zrows[0].barTime;
   datetime t1=g_zrows[g_zrowsN-1].barTime+PeriodSeconds(InpTF);
   MqlRates b[]; ArraySetAsSeries(b,false);
   int n=CopyRates(_Symbol,InpTF,t0,t1,b);
   double hi=-DBL_MAX, lo=DBL_MAX;
   for(int k=0;k<n;k++){ if(b[k].high>hi) hi=b[k].high; if(b[k].low<lo) lo=b[k].low; }
   if(hi<=lo) return;

   double range=hi-lo;
   double stripLo=lo-range*0.06;
   double stripHi=lo-range*0.02;

   for(int i=0;i<g_zrowsN;i++)
     {
      SDiagZones z=g_zrows[i].z;
      if(!z.ready) continue;
      color c=(z.zone==ZONE_Z1)?clrSilver:(z.zone==ZONE_Z2)?clrOrange:clrRed;
      string nm=g_vis.Name("ZS",(string)(long)g_zrows[i].barTime);
      g_vis.Rect(nm,g_zrows[i].barTime,stripHi,g_zrows[i].barTime+PeriodSeconds(InpTF),stripLo,c,true,1);
     }
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
//|  RejectBreak markers - persist forever once drawn (append-only,   |
//|  keyed by bar time), unlike the strip/boxes which redraw a ring.  |
//+------------------------------------------------------------------+
void DrawRejectBreak(const datetime barTime,const SDiagRejectBreak &rd,
                     const double vwap,const double sigma)
  {
   if(rd.firedPrimitive=="-") return;
   bool bullish=(rd.firedPrimitive=="rejSup" || rd.firedPrimitive=="brkUp");
   color c=bullish?clrLime:clrRed;

   double bandMult=0.0;
   if(rd.firedBand=="+1") bandMult= InpBand1Mult;
   else if(rd.firedBand=="-1") bandMult=-InpBand1Mult;
   else if(rd.firedBand=="+2") bandMult= InpBand2Mult;
   else if(rd.firedBand=="-2") bandMult=-InpBand2Mult;
   double bandPrice=vwap+bandMult*sigma;

   string key=(string)(long)barTime;
   g_vis.Arrow(g_vis.Name("RB",key),barTime,bandPrice,bullish?233:234,c,3,
               bullish?ANCHOR_TOP:ANCHOR_BOTTOM);
   g_vis.Text(g_vis.Name("RB",key+"_L"),barTime,bandPrice+(bullish?1.0:-1.0)*sigma*0.15,
              StringFormat("%s@%s",rd.firedPrimitive,rd.firedBand),c,8,
              bullish?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER);
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
void CsvHeader()
  {
   if(!InpWriteCsv) return;
   ArrayResize(g_csv,1);
   g_csv[0]="trade_session,trade_open_riyadh,found,skip,src_session,src_open_riyadh,"
            "src_close_riyadh,src_score,hours_back,anchor_time_riyadh,anchor_price,anchor_is_high";
  }
void CsvRow(const SAnchorResult &r)
  {
   if(!InpWriteCsv) return;
   int n=ArraySize(g_csv);
   ArrayResize(g_csv,n+1);
   g_csv[n]=StringFormat("%s,%s,%s,%s,%s,%s,%s,%.4f,%.1f,%s,%s,%s",
      V2_SessionName(r.tradeSession),RiyStr(r.tradeOpenTime),
      r.found?"1":"0",r.skip?"1":"0",
      r.found?V2_SessionName(r.srcSession):"-",
      r.found?RiyStr(r.srcOpenTime):"-",
      r.found?RiyStr(r.srcCloseTime):"-",
      r.srcScore,r.hoursBack,
      r.found?RiyStr(r.anchorTime):"-",
      r.found?DoubleToString(r.anchorPrice,_Digits):"-",
      r.found?(r.anchorIsHigh?"1":"0"):"-");
  }
//+------------------------------------------------------------------+
void CheckAnchorPreRoll(const datetime now)
  {
   ENUM_SESSION_V2 cands[2]; cands[0]=SESS_ASIA; cands[1]=SESS_NY;
   int nowMin=V2_MinuteOfDay(g_time.ToRiyadh(now));

   for(int k=0;k<2;k++)
     {
      ENUM_SESSION_V2 s=cands[k];
      if(!g_time.IsEnabled(s) || g_time.RoleOf(s)!=ROLE_TRADE) continue;

      int trigMin=g_time.StartMinOf(s)-(int)MathRound(InpAnchorPreRollMin);
      if(trigMin<0 || nowMin!=trigMin) continue;

      datetime realOpen=g_time.SessionOpenBroker(now,s);
      string key=RiyDate(realOpen)+"_"+V2_SessionName(s);
      if(key==g_lastAnchorKey) continue;
      g_lastAnchorKey=key;

      SAnchorResult ar=g_anchor.Select(s,realOpen,g_zz);
      DrawAnchor(ar);
      CsvRow(ar);
      if(ar.found) g_avwap.SetAnchor(ar.anchorTime);
      else         g_avwap.ClearAnchor();

      if(InpVerbose)
        {
         if(ar.found)
            PrintFormat("[T3b] pre-roll %.0fmin before %s %s -> ANCHOR <- %s %s pivot %s (%.0fh back, score %.2f)",
                        InpAnchorPreRollMin,V2_SessionName(s),RiyDate(realOpen),
                        V2_SessionName(ar.srcSession),RiyDate(ar.srcOpenTime),
                        DoubleToString(ar.anchorPrice,_Digits),ar.hoursBack,ar.srcScore);
         else
            PrintFormat("[T3b] pre-roll %.0fmin before %s %s -> NO ANCHOR -> SKIP",
                        InpAnchorPreRollMin,V2_SessionName(s),RiyDate(realOpen));
        }
     }
  }

void CsvFlush()
  {
   if(!InpWriteCsv || ArraySize(g_csv)<=1) return;
   string fn="SessionsStrategyV2_Anchor_"+_Symbol+".csv";
   int h=FileOpen(fn,FILE_WRITE|FILE_ANSI|FILE_TXT|FILE_COMMON);
   if(h==INVALID_HANDLE){ PrintFormat("[T3b] CSV open failed: %s",fn); return; }
   for(int i=0;i<ArraySize(g_csv);i++) FileWriteString(h,g_csv[i]+"\r\n");
   FileClose(h);
   PrintFormat("[T3b] wrote %d rows to Common\\Files\\%s",ArraySize(g_csv)-1,fn);
  }

//+------------------------------------------------------------------+
void RefreshDash()
  {
   SDiagZones d=g_zones.Diag();

   g_dash.Title(0,"--- V2 . REJECT/BREAK + LEAN (T3b) ---");
   g_dash.KV(1,"Now",RiyStr(TimeCurrent())+" Riyadh",clrSilver);

   if(!d.ready)
      g_dash.KV(2,"Zone","suppressed (AVWAP warm-up)",clrDimGray);
   else
     {
      color zc=(d.zone==ZONE_Z1)?clrSilver:(d.zone==ZONE_Z2)?clrOrange:clrRed;
      g_dash.KV(2,"d",StringFormat("%s  (%+.2f sigma)",DoubleToString(d.d,_Digits),d.dSigma),clrWhite);
      g_dash.KV(3,"Zone",StringFormat("%s   stance: %s",V2_ZoneName(d.zone),V2_StanceText(d)),zc);
     }

   color lc=(g_lastRb.lean==DIR_LONG)?clrLime:(g_lastRb.lean==DIR_SHORT)?clrRed:clrDimGray;
   g_dash.KV(4,"Provisional lean",StringFormat("%s  (%d bars, last: %s@%s)  ATR %s",
             V2_DirName(g_lastRb.lean),g_lastRb.leanBars,
             g_lastRb.firedPrimitive,g_lastRb.firedBand,
             DoubleToString(g_lastRb.atr,_Digits)),lc);
   g_dash.KV(5,"Extended transition",g_lastRb.extendedTransition?"YES (just fired)":"no",
             g_lastRb.extendedTransition?clrGold:clrGainsboro);

   g_dash.Line(7,"recent zones (newest first):",clrSilver);
   int shown=0;
   for(int i=g_zrowsN-1;i>=0 && shown<6;i--,shown++)
     {
      SDiagZones z=g_zrows[i].z;
      color c=!z.ready?clrDimGray:(z.zone==ZONE_Z1)?clrSilver:(z.zone==ZONE_Z2)?clrOrange:clrRed;
      string txt=!z.ready?"suppressed":StringFormat("%s  d=%+.2fs  %s",
                 V2_ZoneName(z.zone),z.dSigma,V2_StanceText(z));
      g_dash.Line(8+shown,StringFormat("  %s  %s",RiyStr(g_zrows[i].barTime),txt),c);
     }
   g_dash.Line(15,"check: rejSup/brkUp=green up-arrow, rejRes/brkDn=red down-arrow at the band",clrDimGray);
   g_dash.Render();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   BuildSettingsV2();
   g_time.Init(g_s);
   g_sq.Init(g_s,_Symbol);
   g_zz.Init(g_s,_Symbol);
   g_anchor.Init(g_s);
   g_avwap.Init(g_s,_Symbol);
   g_zones.Init(g_s);
   g_rb.Init(g_s,_Symbol);
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());
   CsvHeader();

   if(!g_zz.HandleOk())
     {
      Print("[T3b] ERROR: could not create Examples\\ZigZag indicator handle");
      Alert("T3b: Examples\\ZigZag indicator not found - compile it in MetaEditor");
     }

   PrintFormat("[T3b] touchTol=%.2f rejClose=%.2f wick>=%.0f%% breakBuf=%.2f breakBody>=%.1fxATR",
               InpTouchTolSigma,InpRejectCloseSigma,InpRejectWickMinFrac*100,
               InpBreakBufferSigma,InpBreakBodyAtr);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   CsvFlush();
   g_sq.Deinit();
   g_zz.Deinit();
   g_rb.Deinit();
   g_vis.Destroy();
   g_dash.Destroy();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   bool newBar=IsNewBar();
   RefreshDash();
   if(!newBar) return;

   g_zz.Refresh();
   DrawZigZag();

   datetime now=iTime(_Symbol,InpTF,0);
   ENUM_SESSION_V2 curr=g_time.Session(now);

   if(curr!=g_activeSession)
     {
      if(g_activeSession!=SESS_NONE)
        {
         datetime inSess=iTime(_Symbol,InpTF,1);
         datetime openB =g_time.SessionOpenBroker(inSess,g_activeSession);
         datetime closeB=g_time.SessionCloseBroker(inSess,g_activeSession);
         if(openB>0 && closeB>openB)
           {
            SQualityResult r=g_sq.EvaluateCompleted(g_activeSession,openB,closeB);
            if(r.evaluated)
              {
               g_anchor.RecordSession(r);
               PushQuality(r);
               DrawQuality();
               if(InpVerbose)
                  PrintFormat("[T3b] quality %s %s %s score %.2f",
                              V2_SessionName(r.session),RiyDate(r.openTime),r.state,r.score);
              }
           }
        }
      g_activeSession=curr;
     }

   DrawLiveBox(now);
   CheckAnchorPreRoll(now);
   DrawVwap(now);

   double vw,sg; int bars;
   bool hasLatest=g_avwap.Latest(vw,sg,bars);
   double closePrice=iClose(_Symbol,InpTF,1);
   SDiagZones zd=g_zones.Update(hasLatest && g_avwap.Ready(),closePrice,vw,sg);
   PushZoneRow(iTime(_Symbol,InpTF,1),zd);
   DrawZoneStrip();

   if(zd.ready)
     {
      MqlRates rbBar[];
      if(CopyRates(_Symbol,InpTF,1,1,rbBar)==1)
        {
         SDiagRejectBreak rd=g_rb.Update(rbBar[0],zd.dSigma,vw,sg);
         g_lastRb=rd;
         DrawRejectBreak(rbBar[0].time,rd,vw,sg);
         if(InpVerbose && rd.firedPrimitive!="-")
            PrintFormat("[T3b] %s @ %s  band=%s  lean=%s (%d bars)  extTransition=%s",
                        rd.firedPrimitive,RiyStr(rbBar[0].time),rd.firedBand,
                        V2_DirName(rd.lean),rd.leanBars,rd.extendedTransition?"Y":"n");
        }
     }

   if(InpVerbose && zd.ready)
      PrintFormat("[T3b] %s close=%s d=%s (%+.2fs) zone=%s dir=%s%s",
                  RiyStr(iTime(_Symbol,InpTF,1)),DoubleToString(closePrice,_Digits),
                  DoubleToString(zd.d,_Digits),zd.dSigma,V2_ZoneName(zd.zone),
                  V2_DirName(zd.committedDir),
                  zd.confirming?StringFormat(" CONFIRMING %d/%d",zd.confirmBars,zd.confirmMax):"");
  }
//+------------------------------------------------------------------+

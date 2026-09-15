//+------------------------------------------------------------------+
//|                                             SessionLabeler.mq5   |
//|  Interactive labelling tool for the session-quality classifier.  |
//|                                                                   |
//|  *** RUN ON A NORMAL CHART - NOT THE STRATEGY TESTER ***          |
//|  Attach it to a live/offline XAUUSD M5 chart with the history you |
//|  want to label already loaded (scroll back first if needed - MT5  |
//|  shows the scanned date range on attach so you know if you need   |
//|  more). It does NOT run inside OnTick-per-bar simulation at all:  |
//|  it scans the whole loaded history ONCE on attach, then reviews   |
//|  sessions one at a time by scrolling the chart to each and        |
//|  waiting for a click - a normal OnChartEvent, which fires exactly |
//|  as documented on a real chart (unlike inside the tester, where a |
//|  Sleep()-based block does NOT actually halt the simulated clock - |
//|  confirmed not to work; this rewrite drops that approach          |
//|  entirely rather than trying to patch it further).                |
//|                                                                   |
//|  Output: Common\Files\SessionsStrategyV2_Labels_<symbol>.csv -    |
//|  same columns as T2c's quality CSV (V2_QualityCsvHeader/Row in    |
//|  SessionQuality.mqh) plus a trailing 'label' column (1/0),        |
//|  appended after every click so nothing is lost if you stop early. |
//|  Feed it straight to v2/ml/calibrate_quality.py --labelled-csv.   |
//+------------------------------------------------------------------+
#property copyright "Sessions Strategy v2"
#property version   "1.00"
#property strict

#include "../Include/V2Common.mqh"
#include "../Include/TimeSessions.mqh"
#include "../Include/SessionQuality.mqh"
#include "../Include/VisualsV2.mqh"
#include "../Include/DashboardV2.mqh"

input group "General"
input ENUM_TIMEFRAMES InpTF = PERIOD_M5;
input datetime InpFromDate = 0;   // 0 = earliest loaded bar
input datetime InpToDate   = 0;   // 0 = most recent loaded bar

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

input group "Session-quality (same metrics as T2c - not gating here)"
input int                  InpAtrPeriod        = 14;
input ENUM_QUALITY_MODE_V2 InpQualityMode      = QM_GATES;
input double               InpScoreThreshold   = 0.60;
input int                  InpBaselineN        = 20;
// 2026-09-14 recalibration #2, same 520 hand-labelled sessions from this
// tool (v2/ml/calibrate_quality.py --labelled-csv): the baseline/range-
// ratio check no longer BLOCKS a verdict during baseline warm-up (it used
// to force every session to WARMING for the first ~20 same-type priors) -
// it's now confirm-only, applied when a baseline exists. Also dropped an
// uncalibrated 3rd movement OR-clause (leg/baseline) that was never grid-
// searched and cost 0.106 MCC on the real data. MCC=0.580, F1=0.859,
// precision=0.892, recall=0.828. Re-run the script as more labels come in.
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

input group "Labelling"
input bool InpSkipWarming    = false; // true = don't list sessions whose baseline is still warming up

SSettingsV2     g_s;
CTimeSessions   g_time;
CSessionQuality g_sq;
CVisualsV2      g_vis;
CDashboardV2    g_dash;

SQualityResult  g_pending[];
int             g_pendingN = 0;
int             g_cursor   = 0;
int             g_csvHandle = INVALID_HANDLE;
int             g_countGreen=0, g_countRed=0, g_countSkip=0;
bool            g_scanned = false;
int             g_navRetries = 0;

#define LP_PREFIX "LBL_"
#define BTN_GREEN  LP_PREFIX "green"
#define BTN_RED    LP_PREFIX "red"
#define BTN_SKIP   LP_PREFIX "skip"
#define BTN_GOTO   LP_PREFIX "goto"
#define LBL_BANNER LP_PREFIX "banner"

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
  }

string RiyStr(const datetime serverT){ return(TimeToString(g_time.ToRiyadh(serverT),TIME_DATE|TIME_MINUTES)); }
string RiyDate(const datetime serverT){ return(TimeToString(g_time.ToRiyadh(serverT),TIME_DATE)); }

//====================================================================
//  Tiny inline button panel (GREEN / RED / SKIP)
//====================================================================
void CreateBtn(const string name,const int x,const int y,const int w,
               const string text,const color bg)
  {
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,name,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,name,OBJPROP_YSIZE,34);
   ObjectSetString (0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,11);
   ObjectSetInteger(0,name,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,name,OBJPROP_STATE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,50);
  }
void SetBanner(const string text,const color clr)
  {
   if(ObjectFind(0,LBL_BANNER)<0)
     {
      ObjectCreate(0,LBL_BANNER,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,LBL_BANNER,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,LBL_BANNER,OBJPROP_XDISTANCE,12);
      ObjectSetInteger(0,LBL_BANNER,OBJPROP_YDISTANCE,275);
      ObjectSetInteger(0,LBL_BANNER,OBJPROP_FONTSIZE,11);
      ObjectSetString (0,LBL_BANNER,OBJPROP_FONT,"Consolas Bold");
      ObjectSetInteger(0,LBL_BANNER,OBJPROP_SELECTABLE,false);
     }
   ObjectSetString (0,LBL_BANNER,OBJPROP_TEXT,text);
   ObjectSetInteger(0,LBL_BANNER,OBJPROP_COLOR,clr);
   ChartRedraw(0);
  }

//====================================================================
//  CSV (append, flushed after every row so nothing is lost)
//====================================================================
bool OpenCsv()
  {
   string fn="SessionsStrategyV2_Labels_"+_Symbol+".csv";
   bool existed=FileIsExist(fn,FILE_COMMON);
   g_csvHandle=FileOpen(fn,FILE_READ|FILE_WRITE|FILE_ANSI|FILE_TXT|FILE_COMMON);
   if(g_csvHandle==INVALID_HANDLE)
     {
      PrintFormat("[Labeler] ERROR: could not open %s (err %d)",fn,GetLastError());
      return(false);
     }
   FileSeek(g_csvHandle,0,SEEK_END);
   if(!existed || FileTell(g_csvHandle)==0)
      FileWriteString(g_csvHandle,V2_QualityCsvHeader()+",label\r\n");
   PrintFormat("[Labeler] appending to Common\\Files\\%s",fn);
   return(true);
  }
void WriteLabelRow(const SQualityResult &r,const int label)
  {
   if(g_csvHandle==INVALID_HANDLE) return;
   string row=V2_QualityCsvRow(r,_Digits,RiyStr(r.openTime),RiyStr(r.closeTime))+","+(string)label;
   FileSeek(g_csvHandle,0,SEEK_END);
   FileWriteString(g_csvHandle,row+"\r\n");
   FileFlush(g_csvHandle);
  }

//====================================================================
//  One pass over ALL loaded history - builds g_pending[], chronologically,
//  so CSessionQuality's baseline rings fill up exactly as they would live.
//====================================================================
void ScanAllSessions()
  {
   ArrayResize(g_pending,0); g_pendingN=0;

   int total=iBars(_Symbol,InpTF);
   if(total<10){ Print("[Labeler] ERROR: not enough history loaded on this chart"); return; }

   MqlRates all[]; ArraySetAsSeries(all,false); // oldest first
   int n=CopyRates(_Symbol,InpTF,0,total,all);
   if(n<10){ Print("[Labeler] ERROR: CopyRates returned too little data"); return; }

   datetime fromT=(InpFromDate>0)?InpFromDate:all[0].time;
   datetime toT  =(InpToDate>0)  ?InpToDate  :all[n-1].time;

   PrintFormat("[Labeler] scanning %d bars, %s -> %s (chart has %s -> %s)",
               n,TimeToString(fromT,TIME_DATE),TimeToString(toT,TIME_DATE),
               TimeToString(all[0].time,TIME_DATE),TimeToString(all[n-1].time,TIME_DATE));
   if(InpFromDate>0 && all[0].time>InpFromDate)
      PrintFormat("[Labeler] WARNING: chart history only starts %s - scroll the chart further "
                  "back (or raise Max bars in Tools>Options>Charts) and re-attach to cover "
                  "your requested start date %s",
                  TimeToString(all[0].time,TIME_DATE),TimeToString(InpFromDate,TIME_DATE));

   ENUM_SESSION_V2 prevSes=SESS_NONE;
   datetime prevBarTime=0;
   for(int i=0;i<n;i++)
     {
      if(all[i].time<fromT || all[i].time>toT) continue;
      ENUM_SESSION_V2 curr=g_time.Session(all[i].time);
      if(curr!=prevSes)
        {
         if(prevSes!=SESS_NONE && prevBarTime>0)
           {
            datetime openB =g_time.SessionOpenBroker(prevBarTime,prevSes);
            datetime closeB=g_time.SessionCloseBroker(prevBarTime,prevSes);
            if(openB>0 && closeB>openB)
              {
               SQualityResult r=g_sq.EvaluateCompleted(prevSes,openB,closeB);
               if(r.evaluated && !(InpSkipWarming && r.baselineWarm))
                 {
                  ArrayResize(g_pending,g_pendingN+1);
                  g_pending[g_pendingN++]=r;
                 }
              }
           }
         prevSes=curr;
        }
      prevBarTime=all[i].time;
     }
   PrintFormat("[Labeler] %d sessions queued for review",g_pendingN);
  }

//====================================================================
//  Draw the current pending session prominently + scroll the chart to it
//====================================================================
//--- scroll the chart so the CURRENT pending session is on screen. Called
//--- from ShowCurrent() and again a few times from OnTimer() right after,
//--- because the terminal can reassert its own "jump to the live edge"
//--- once, asynchronously, right after EA attach/init - a single call can
//--- lose that race. AUTOSCROLL must be turned off BEFORE FIRST_VISIBLE_BAR
//--- is set, or the very next redraw snaps back to the live edge.
void ApplyChartNav(const bool verbose=false)
  {
   if(g_cursor>=g_pendingN) return;
   SQualityResult r=g_pending[g_cursor];
   // CHART_FIRST_VISIBLE_BAR is the shift (0=newest overall bar, increasing
   // into the past) of whatever bar sits at the chart's RIGHT edge; the
   // window then covers [that shift .. that shift + visibleBars) going
   // left/older. To CENTER the session, put its own middle bar at
   // visibleBars/2 in from the right edge.
   int openShift =iBarShift(_Symbol,InpTF,r.openTime,false);
   int closeShift=iBarShift(_Symbol,InpTF,r.closeTime,false);
   int midShift  =(openShift+closeShift)/2;
   long visibleBars=ChartGetInteger(0,CHART_VISIBLE_BARS);
   if(visibleBars<=0) visibleBars=100; // not known yet (very first call) - reasonable default
   int target=(int)MathMax(0,midShift-visibleBars/2);

   ChartSetInteger(0,CHART_AUTOSCROLL,false);
   ChartSetInteger(0,CHART_FIRST_VISIBLE_BAR,target);
   ChartRedraw(0);
   long actual=ChartGetInteger(0,CHART_FIRST_VISIBLE_BAR);

   if(actual!=target)
     {
      // fallback: the dedicated navigation call instead of poking the
      // property directly - some builds honour one but not the other
      ChartNavigate(0,CHART_END,-(target));
      ChartRedraw(0);
      actual=ChartGetInteger(0,CHART_FIRST_VISIBLE_BAR);
     }
   if(verbose || actual!=target)
      PrintFormat("[Labeler] nav: open=%s close=%s openShift=%d closeShift=%d midShift=%d "
                  "visibleBars=%I64d target=%d autoscroll=%s actualFirstVisible=%I64d %s",
                  TimeToString(r.openTime,TIME_DATE|TIME_MINUTES),
                  TimeToString(r.closeTime,TIME_DATE|TIME_MINUTES),
                  openShift,closeShift,midShift,visibleBars,target,
                  ChartGetInteger(0,CHART_AUTOSCROLL)?"ON(!)":"off",actual,
                  (actual==target)?"OK":"MISMATCH - click RECENTER, or tell me this line");
  }

void ShowCurrent()
  {
   g_vis.ClearGroup("PEND");
   if(g_cursor>=g_pendingN)
     {
      EventKillTimer();
      SetBanner(StringFormat("ALL DONE - %d green, %d red, %d skipped. File closed? check Common\\Files.",
                g_countGreen,g_countRed,g_countSkip),clrLime);
      return;
     }
   SQualityResult r=g_pending[g_cursor];

   ApplyChartNav();
   g_navRetries=0;
   EventKillTimer();
   EventSetMillisecondTimer(500); // re-assert the scroll position for a few seconds (see OnTimer)

   MqlRates b[]; ArraySetAsSeries(b,false);
   int n=CopyRates(_Symbol,InpTF,r.openTime,r.closeTime,b);
   double hi=-DBL_MAX,lo=DBL_MAX;
   for(int k=0;k<n;k++)
     {
      if(b[k].time<r.openTime || b[k].time>=r.closeTime) continue;
      if(b[k].high>hi) hi=b[k].high;
      if(b[k].low <lo) lo=b[k].low;
     }
   if(hi>lo)
     {
      g_vis.Rect(g_vis.Name("PEND","box"),r.openTime,hi,r.closeTime,lo,clrYellow,false,3);
      g_vis.Text(g_vis.Name("PEND","t1"),r.openTime,hi,
                 StringFormat("[%d/%d] %s %s  AWAITING LABEL",g_cursor+1,g_pendingN,
                              V2_SessionName(r.session),RiyDate(r.openTime)),
                 clrYellow,10,ANCHOR_LEFT_LOWER);
      g_vis.Text(g_vis.Name("PEND","t2"),r.openTime,hi-(hi-lo)*0.10,
                 StringFormat("rng/base %.2f  rng/atr %.1f  leg/atr %.1f  eff %.2f  imp %d/%d  body-imp %d",
                              r.rangeRatio,r.rangeAtr,r.legAtr,r.efficiency,
                              r.impulseBarCount,r.bars,r.bodyImpulseCount),
                 clrYellow,9,ANCHOR_LEFT_UPPER);
      g_vis.Text(g_vis.Name("PEND","t3"),r.openTime,hi-(hi-lo)*0.19,
                 StringFormat("maxBar/rng %.2f  run %d/%d  vol/base %.2f  [%s %s%s]",
                              r.maxBarRangeShare,r.longestRun,r.bars,r.volumeRatio,r.mode,r.state,
                              r.baselineWarm?" warm":""),
                 clrSilver,9,ANCHOR_LEFT_UPPER);
     }
   g_vis.Redraw();
   SetBanner(StringFormat("[%d/%d] %s %s -- click GREEN / RED / SKIP",
             g_cursor+1,g_pendingN,V2_SessionName(r.session),RiyDate(r.openTime)),clrYellow);
   RefreshDash();
  }

void Advance(const int label,const bool wasSkip)
  {
   if(g_cursor>=g_pendingN) return;
   SQualityResult r=g_pending[g_cursor];
   if(wasSkip) g_countSkip++;
   else { WriteLabelRow(r,label); if(label==1) g_countGreen++; else g_countRed++; }
   g_cursor++;
   ShowCurrent();
  }

//+------------------------------------------------------------------+
void RefreshDash()
  {
   g_dash.Title(0,"--- V2 . SESSION LABELER (live chart) ---");
   g_dash.KV(1,"Progress",StringFormat("%d/%d reviewed   green %d   red %d   skipped %d",
             g_cursor,g_pendingN,g_countGreen,g_countRed,g_countSkip),clrGainsboro);
   g_dash.Line(2,"click GREEN/RED/SKIP below the chart for the highlighted session",clrSilver);
   g_dash.Render();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   // off BEFORE anything else touches the chart, so nothing can snap the
   // view back to the live edge while we set up
   ChartSetInteger(0,CHART_AUTOSCROLL,false);

   BuildSettingsV2();
   g_time.Init(g_s);
   g_sq.Init(g_s,_Symbol);
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());
   if(!OpenCsv()) return(INIT_FAILED);

   CreateBtn(BTN_GREEN,12, 300,140,"GREEN (quality)",clrForestGreen);
   CreateBtn(BTN_RED,  158,300,140,"RED (flat/chop)",clrFireBrick);
   CreateBtn(BTN_SKIP, 304,300,90, "SKIP",           clrDimGray);
   CreateBtn(BTN_GOTO, 400,300,140,"GO TO SESSION",  clrDarkSlateBlue);

   ScanAllSessions();
   g_scanned=true;
   ShowCurrent();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_csvHandle!=INVALID_HANDLE) FileClose(g_csvHandle);
   g_sq.Deinit();
   g_vis.Destroy();
   g_dash.Destroy();
   ObjectDelete(0,BTN_GREEN); ObjectDelete(0,BTN_RED);
   ObjectDelete(0,BTN_SKIP);  ObjectDelete(0,LBL_BANNER);
   ObjectDelete(0,BTN_GOTO);
  }

//+------------------------------------------------------------------+
//| Re-assert the scroll position a few times right after showing a   |
//| session, then stop. Guards against the terminal snapping the      |
//| view back to the live edge once, asynchronously, after attach.    |
//+------------------------------------------------------------------+
void OnTimer()
  {
   g_navRetries++;
   ApplyChartNav(g_navRetries==1); // print full diagnostics on the very first retry
   if(g_navRetries>=12) EventKillTimer(); // ~6s of re-assertion, then leave it alone
  }

//+------------------------------------------------------------------+
//| Normal chart -> OnChartEvent fires on every click, immediately.   |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id!=CHARTEVENT_OBJECT_CLICK || !g_scanned) return;
   if(sparam==BTN_GREEN){ ObjectSetInteger(0,BTN_GREEN,OBJPROP_STATE,false); Advance(1,false); }
   else if(sparam==BTN_RED){ ObjectSetInteger(0,BTN_RED,OBJPROP_STATE,false); Advance(0,false); }
   else if(sparam==BTN_SKIP){ ObjectSetInteger(0,BTN_SKIP,OBJPROP_STATE,false); Advance(0,true); }
   else if(sparam==BTN_GOTO){ ObjectSetInteger(0,BTN_GOTO,OBJPROP_STATE,false); ApplyChartNav(true); }
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // nothing to do per-tick: everything happens once on attach (OnInit)
   // and on button clicks (OnChartEvent). Kept only so the terminal
   // treats this as a normal running EA.
  }
//+------------------------------------------------------------------+

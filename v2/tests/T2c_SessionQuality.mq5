//+------------------------------------------------------------------+
//|                                            T2c_SessionQuality.mq5 |
//|  Isolated visual test for Include/SessionQuality.mqh (milestone 5)|
//|                                                                   |
//|  For EVERY completed session it recolours the session box:       |
//|    green = PASS  red = FAIL  (+"(warm)" suffix while that type's  |
//|    same-type baseline is still under qualityBaselineN samples -   |
//|    informational only since 2026-09-14, does NOT block a verdict) |
//|  with a two-line label of the score and every ratio, and writes  |
//|  one CSV row per session for auditing in Excel.                  |
//|                                                                   |
//|  Run: XAUUSD, M5, "Every tick based on real ticks", Visual ON,   |
//|  over >= 6 weeks (the baseline confirm check is more meaningful   |
//|  once it has priors, but every session gets a real verdict from   |
//|  the start).                                                      |
//|                                                                   |
//|  PASS checklist (v2/doc/IMPLEMENTATION_PLAN.md C2c):             |
//|   [ ] Clearly trending / wide-range sessions come out GREEN.     |
//|   [ ] Clearly choppy / tight sessions come out RED.              |
//|   [ ] Borderline sessions score near the threshold.             |
//|   [ ] Baseline uses same-type sessions only (check the CSV).     |
//|   [ ] GATES<->SCORE and threshold/weight nudges recolour as      |
//|       expected on the next run.                                  |
//|   [ ] No session classified until it is complete.               |
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

input group "Session-quality"
input int                  InpAtrPeriod        = 14;
input ENUM_QUALITY_MODE_V2 InpQualityMode      = QM_GATES;  // GATES: movement AND not-spike AND confirm
input double               InpScoreThreshold   = 0.60;      // SCORE mode only
input int                  InpBaselineN        = 20;
// 2026-09-14 recalibration #2 vs the same 520 hand-labelled sessions
// (v2/ml/calibrate_quality.py --labelled-csv): the baseline/range-ratio
// check no longer BLOCKS a verdict while the baseline is warming up (it
// used to force every session to WARMING for the first ~20 same-type
// priors) - it's now a confirm-only check applied when a baseline exists,
// vacuously true otherwise. Also dropped an uncalibrated 3rd movement
// OR-clause (leg/baseline) that had crept in without ever being grid-
// searched. Checked on the real data: blocking=0.57 MCC, that stray
// clause alone=0.46 MCC, this (non-blocking, clause removed)=0.58 MCC.
// MCC=0.580, F1=0.859, precision=0.892, recall=0.828. Re-run the script
// as more labels come in.
input double               InpMinRangeRatio    = 0.70;      // range / baseline  (confirm-only, never blocks)
input double               InpMinRangeAtr      = 10.0;      // range / ATR       (movement, path A)
input double               InpMinLegAtr        = 6.0;       // largest leg / ATR (movement, path B)
input double               InpMinEfficiency    = 0.15;      // SCORE mode only (does NOT gate)
input double               InpImpulseBarAtrMult= 0.8;       // a bar counts as "impulse" if its range >= this*ATR
input int                  InpMinImpulseBars   = 1;         // anti-single-spike gate (GATES mode)
input double               InpWRangeBase       = 0.45;      // SCORE weights
input double               InpWLeg             = 0.25;
input double               InpWRangeAtr        = 0.20;
input double               InpWEff             = 0.10;

input group "Test / diagnostics"
input int  InpMaxBoxes = 80;
input bool InpWriteCsv = true;
input bool InpVerbose  = true;

SSettingsV2     g_s;
CTimeSessions   g_time;
CSessionQuality g_sq;
CVisualsV2      g_vis;
CDashboardV2    g_dash;

datetime        g_lastBar = 0;
ENUM_SESSION_V2 g_activeSession = SESS_NONE;

SQualityResult  g_res[128];
int             g_resN = 0;

string          g_csv[];

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
void PushResult(const SQualityResult &r)
  {
   int cap=MathMin(InpMaxBoxes,128);
   if(g_resN<cap){ g_res[g_resN++]=r; return; }
   for(int i=1;i<cap;i++) g_res[i-1]=g_res[i];
   g_res[cap-1]=r;
  }

//+------------------------------------------------------------------+
void DrawResults()
  {
   g_vis.ClearGroup("SQ");
   for(int i=0;i<g_resN;i++)
     {
      SQualityResult r=g_res[i];
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
      string warmTag=r.baselineWarm?" (warm)":"";

      g_vis.Rect(g_vis.Name("SQ",key),r.openTime,hi,r.closeTime,lo,c,false,2);
      g_vis.Text(g_vis.Name("SQ",key+"_1"),r.openTime,hi,
                 StringFormat("%s %s  %s %.2f %s%s",V2_SessionName(r.session),
                              RiyDate(r.openTime),r.mode,r.score,r.state,warmTag),
                 c,9,ANCHOR_LEFT_LOWER);
      g_vis.Text(g_vis.Name("SQ",key+"_2"),r.openTime,hi-(hi-lo)*0.13,
                 StringFormat("rng/base %.2f  rng/atr %.1f  leg/atr %.1f  eff %.2f  imp %d  base %s",
                              r.rangeRatio,r.rangeAtr,r.legAtr,r.efficiency,r.impulseBarCount,
                              DoubleToString(r.baseline,_Digits)),
                 c,8,ANCHOR_LEFT_UPPER);
     }
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
void CsvHeader()
  {
   if(!InpWriteCsv) return;
   ArrayResize(g_csv,1);
   g_csv[0]=V2_QualityCsvHeader();
  }
void CsvRow(const SQualityResult &r)
  {
   if(!InpWriteCsv) return;
   int n=ArraySize(g_csv);
   ArrayResize(g_csv,n+1);
   g_csv[n]=V2_QualityCsvRow(r,_Digits,RiyStr(r.openTime),RiyStr(r.closeTime));
  }
void CsvFlush()
  {
   if(!InpWriteCsv || ArraySize(g_csv)<=1) return;
   string fn="SessionsStrategyV2_Quality_"+_Symbol+".csv";
   int h=FileOpen(fn,FILE_WRITE|FILE_ANSI|FILE_TXT|FILE_COMMON);
   if(h==INVALID_HANDLE){ PrintFormat("[T2c] CSV open failed: %s",fn); return; }
   for(int i=0;i<ArraySize(g_csv);i++) FileWriteString(h,g_csv[i]+"\r\n");
   FileClose(h);
   PrintFormat("[T2c] wrote %d rows to Common\\Files\\%s",ArraySize(g_csv)-1,fn);
  }

//+------------------------------------------------------------------+
void RefreshDash()
  {
   SDiagQuality d=g_sq.Diag();
   int tgt=d.baselineTarget;

   g_dash.Title(0,"--- V2 . SESSION QUALITY (T2c) ---");
   g_dash.KV(1,"Mode",StringFormat("%s   threshold %.2f   baselineN %d",
             InpQualityMode==QM_GATES?"GATES":"SCORE",InpScoreThreshold,tgt),clrGainsboro);

   bool warm=(d.asiaSamples<tgt || d.londonSamples<tgt || d.nySamples<tgt);
   g_dash.KV(2,"Samples",StringFormat("Asia %d/%d  London %d/%d  NY %d/%d",
             d.asiaSamples,tgt,d.londonSamples,tgt,d.nySamples,tgt),
             warm?clrGold:clrLime);
   g_dash.KV(3,"Baseline rng",StringFormat("A %s   L %s   NY %s",
             DoubleToString(d.asiaBaseline,_Digits),DoubleToString(d.londonBaseline,_Digits),
             DoubleToString(d.nyBaseline,_Digits)),clrGainsboro);
   g_dash.KV(4,"Active now",V2_SessionName(g_time.Session(TimeCurrent())),clrSilver);

   if(g_resN>0)
     {
      SQualityResult r=g_res[g_resN-1];
      color c=r.pass?clrLime:clrTomato;
      g_dash.KV(5,"Last session",StringFormat("%s %s   %s%s   score %.2f",
                V2_SessionName(r.session),RiyDate(r.openTime),r.state,
                r.baselineWarm?" (warm)":"",r.score),c);
      g_dash.Line(6,StringFormat("  rng/base %.2f  rng/atr %.1f  leg/atr %.1f  leg/base %.2f  eff %.2f  impulse %d",
                  r.rangeRatio,r.rangeAtr,r.legAtr,r.legRatio,r.efficiency,r.impulseBarCount),clrGainsboro);
      g_dash.Line(7,StringFormat("  body-imp %d  maxBar/rng %.2f  run %d/%d  vol/base %.2f",
                  r.bodyImpulseCount,r.maxBarRangeShare,r.longestRun,r.bars,r.volumeRatio),clrDimGray);
     }
   else
      g_dash.KV(5,"Last session","- none completed yet -",clrSilver);

   g_dash.Line(8,"recent (newest first):",clrSilver);
   int shown=0;
   for(int i=g_resN-1;i>=0 && shown<6;i--,shown++)
     {
      SQualityResult r=g_res[i];
      color c=r.pass?clrLime:clrTomato;
      g_dash.Line(9+shown,StringFormat("  %-6s %s  %.2f  %s%s",
                  V2_SessionName(r.session),RiyDate(r.openTime),r.score,r.state,
                  r.baselineWarm?" (warm)":""),c);
     }
   g_dash.Line(15,"tune thresholds/weights until green/red matches your eye",clrDimGray);
   g_dash.Render();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   BuildSettingsV2();
   g_time.Init(g_s);
   g_sq.Init(g_s,_Symbol);
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());
   CsvHeader();

   PrintFormat("[T2c] %s | GATES pass = (rng/atr>=%.1f OR leg/atr>=%.1f) AND impulseBars>=%d AND (no baseline yet OR rng/base>=%.2f) | SCORE thr %.2f",
               InpQualityMode==QM_GATES?"GATES":"SCORE",
               InpMinRangeAtr,InpMinLegAtr,InpMinImpulseBars,InpMinRangeRatio,InpScoreThreshold);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   CsvFlush();
   g_sq.Deinit();
   g_vis.Destroy();
   g_dash.Destroy();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   bool newBar=IsNewBar();
   RefreshDash();
   if(!newBar) return;

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
               PushResult(r);
               CsvRow(r);
               DrawResults();
               if(InpVerbose)
                  PrintFormat("[T2c] %s %s  %s  score %.2f | rng %s (base %s, %d priors)  rng/atr %.1f  leg/atr %.1f  eff %.2f",
                              V2_SessionName(r.session),RiyDate(r.openTime),r.state,r.score,
                              DoubleToString(r.range,_Digits),DoubleToString(r.baseline,_Digits),
                              r.baselineN,r.rangeAtr,r.legAtr,r.efficiency);
              }
           }
        }
      g_activeSession=curr;
     }
  }
//+------------------------------------------------------------------+

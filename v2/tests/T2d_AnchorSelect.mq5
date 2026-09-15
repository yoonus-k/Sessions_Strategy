//+------------------------------------------------------------------+
//|                                             T2d_AnchorSelect.mq5  |
//|  Isolated visual test for Include/AnchorSelect.mqh (milestone 6). |
//|                                                                   |
//|  Self-contained: also runs ZigZag (T2a) and SessionQuality (T2c, |
//|  calibrated defaults) internally so every cross-check in the      |
//|  checklist below is visible on ONE chart, plus an AVWAP overlay   |
//|  anchored wherever AnchorSelect resolves (the whole point).       |
//|                                                                   |
//|  InpAnchorPreRollMin (default 30) BEFORE each TRADE session's own  |
//|  open bar, the anchor is (re-)selected and AVWAP re-pointed, so    |
//|  bands already have some warm-up by the time the session actually  |
//|  starts instead of beginning stone cold at bar 0. That draws:      |
//|    "ANCHOR <- <session> <date> pivot <price> (score X.XX, Nh back)"|
//|  or, if nothing qualifies within the lookback:                    |
//|    "NO ANCHOR -> SKIP"                                            |
//|  A session box is drawn the MOMENT a session starts (yellow, "IN  |
//|  PROGRESS", y-extent growing bar by bar) - not only after it ends -|
//|  so it's obvious you're inside a session live; it's replaced by    |
//|  the real green/red PASS/FAIL box once the session actually closes.|
//|                                                                   |
//|  Run: XAUUSD, M5, "Every tick based on real ticks", Visual ON,   |
//|  over >= 6 weeks (SessionQuality's baseline confirm-check is more  |
//|  meaningful with priors, but every session gets a real verdict     |
//|  from the start - see SessionQuality.mqh, 2026-09-14).            |
//|                                                                   |
//|  PASS checklist (v2/doc/IMPLEMENTATION_PLAN.md C2d):             |
//|   [ ] The anchor bar is always a real swing extreme (matches the |
//|       gold ZigZag arrows drawn here, same as T2a).                |
//|   [ ] The anchor's source session is always GREEN (matches the    |
//|       quality box colour drawn here, same as T2c) - never anchors|
//|       inside a red session.                                       |
//|   [ ] Never reaches back more than InpMaxAnchorLookbackHr; if the |
//|       only PASS session is older, it SKIPs.                       |
//|   [ ] The chosen pivot is the MOST RECENT significant one from     |
//|       that session (open through close+InpAnchorFlexMin), not an  |
//|       older one further back in the session.                      |
//|   [ ] The anchor updates InpAnchorPreRollMin before each session   |
//|       opens, not exactly on the open bar.                          |
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
input double InpMaxAnchorLookbackHr = 120 ; // one week of 24/7 sessions is 168h, but the last 5-6 days are usually enough to find a PASS session
// 2026-09-14: widened 60->120 - real testing showed a session's decisive swing
// routinely confirms MORE than 60min after its own close (it keeps running into
// the gap before the next session), which silently produced "PASS but NO ANCHOR"
// on sessions that plainly qualified. Search window is now [source session open,
// close + this], not a symmetric +/- window - see AnchorSelect.mqh header.
input double InpAnchorFlexMin       = 120.0;
input double InpAnchorPreRollMin    = 30.0;    // re-select/re-anchor this many minutes BEFORE the
                                                // trade session opens, so AVWAP has a head start
                                                // by the time the session actually begins

input group "AVWAP overlay (bonus - shows the anchor's downstream effect)"
input ENUM_PRICE_INPUT_V2 InpPriceInput         = PI_HLC3;
input ENUM_VOLUME_SRC_V2  InpVolumeSrc          = VS_TICK;
input double              InpBand1Mult          = 1.0;
input double              InpBand2Mult          = 2.0;
input int                 InpMinBarsSinceAnchor = 5;
input int                 InpDrawVwapBars       = 700;

input group "Test / diagnostics"
input int  InpMaxQualityBoxes = 80;
input int  InpMaxAnchorMarks  = 80;
input bool InpWriteCsv        = true;
input bool InpVerbose         = true;

SSettingsV2     g_s;
CTimeSessions   g_time;
CSessionQuality g_sq;
CZigZag         g_zz;
CAnchorSelect   g_anchor;
CAVWAP          g_avwap;
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
//|  ZigZag pivots (T2a-style, minus the "ANCHOR CANDIDATE" label -   |
//|  our own anchor labels below replace that)                       |
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
//|  The currently-open session, drawn IMMEDIATELY when it starts     |
//|  (not after it closes) so it's obvious a session is live. Y-extent|
//|  grows bar by bar; X-extent is the full scheduled window so it's  |
//|  visible from bar 1. Replaced by the real PASS/FAIL "SQ" box the  |
//|  moment the session actually closes.                              |
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
                 StringFormat("ANCHOR [%s] <- %s %s pivot %s (score %.2f, %.0fh back)",
                    ar.anchorTier,V2_SessionName(ar.srcSession),RiyDate(ar.srcOpenTime),
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
void CsvHeader()
  {
   if(!InpWriteCsv) return;
   ArrayResize(g_csv,1);
   g_csv[0]="trade_session,trade_open_riyadh,found,skip,src_session,src_open_riyadh,"
            "src_close_riyadh,src_score,hours_back,anchor_tier,anchor_time_riyadh,anchor_price,anchor_is_high";
  }
void CsvRow(const SAnchorResult &r)
  {
   if(!InpWriteCsv) return;
   int n=ArraySize(g_csv);
   ArrayResize(g_csv,n+1);
   g_csv[n]=StringFormat("%s,%s,%s,%s,%s,%s,%s,%.4f,%.1f,%s,%s,%s,%s",
      V2_SessionName(r.tradeSession),RiyStr(r.tradeOpenTime),
      r.found?"1":"0",r.skip?"1":"0",
      r.found?V2_SessionName(r.srcSession):"-",
      r.found?RiyStr(r.srcOpenTime):"-",
      r.found?RiyStr(r.srcCloseTime):"-",
      r.srcScore,r.hoursBack,
      r.found?r.anchorTier:"-",
      r.found?RiyStr(r.anchorTime):"-",
      r.found?DoubleToString(r.anchorPrice,_Digits):"-",
      r.found?(r.anchorIsHigh?"1":"0"):"-");
  }
//+------------------------------------------------------------------+
//|  Fires InpAnchorPreRollMin minutes BEFORE a TRADE session's own    |
//|  open bar (not on it) - re-selects the anchor and re-points AVWAP  |
//|  early so the bands already have InpAnchorPreRollMin worth of      |
//|  bars/warm-up by the time the session itself actually starts,      |
//|  instead of starting stone cold at bar 0 of the session.           |
//|  'realOpen' (the ACTUAL session open, still in the future here) is |
//|  what gets passed to Select()/labels/CSV, so lookback-hours and    |
//|  the on-chart "NY 06-03" naming stay correct - only the TIMING of  |
//|  the call moves earlier, not the reference point it reasons about. |
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
      if(key==g_lastAnchorKey) continue; // already fired for this session occurrence
      g_lastAnchorKey=key;

      SAnchorResult ar=g_anchor.Select(s,realOpen,g_zz);
      DrawAnchor(ar);
      CsvRow(ar);
      if(ar.found) g_avwap.SetAnchor(ar.anchorTime);
      else         g_avwap.ClearAnchor();

      if(InpVerbose)
        {
         if(ar.found)
            PrintFormat("[T2d] pre-roll %.0fmin before %s %s -> ANCHOR [%s] <- %s %s pivot %s (%.0fh back, score %.2f)",
                        InpAnchorPreRollMin,V2_SessionName(s),RiyDate(realOpen),ar.anchorTier,
                        V2_SessionName(ar.srcSession),RiyDate(ar.srcOpenTime),
                        DoubleToString(ar.anchorPrice,_Digits),ar.hoursBack,ar.srcScore);
         else
            PrintFormat("[T2d] pre-roll %.0fmin before %s %s -> NO ANCHOR -> SKIP",
                        InpAnchorPreRollMin,V2_SessionName(s),RiyDate(realOpen));
        }
     }
  }

void CsvFlush()
  {
   if(!InpWriteCsv || ArraySize(g_csv)<=1) return;
   string fn="SessionsStrategyV2_Anchor_"+_Symbol+".csv";
   int h=FileOpen(fn,FILE_WRITE|FILE_ANSI|FILE_TXT|FILE_COMMON);
   if(h==INVALID_HANDLE){ PrintFormat("[T2d] CSV open failed: %s",fn); return; }
   for(int i=0;i<ArraySize(g_csv);i++) FileWriteString(h,g_csv[i]+"\r\n");
   FileClose(h);
   PrintFormat("[T2d] wrote %d rows to Common\\Files\\%s",ArraySize(g_csv)-1,fn);
  }

//+------------------------------------------------------------------+
void RefreshDash()
  {
   SDiagAnchorSelect d =g_anchor.Diag();
   SDiagZigZag       zd=g_zz.Diag();
   SDiagQuality      qd=g_sq.Diag();

   g_dash.Title(0,"--- V2 . ANCHOR SELECT (T2d) ---");
   g_dash.KV(1,"Now",RiyStr(TimeCurrent())+" Riyadh",clrSilver);
   g_dash.KV(2,"ZigZag",StringFormat("%d confirmed  tail %s",
             zd.confirmedCount,zd.tailPending?"developing":"-"),clrGainsboro);
   g_dash.KV(3,"Quality baseline",StringFormat("A %d/%d  L %d/%d  NY %d/%d",
             qd.asiaSamples,qd.baselineTarget,qd.londonSamples,qd.baselineTarget,
             qd.nySamples,qd.baselineTarget),clrGainsboro);
   g_dash.KV(4,"Sessions recorded",(string)g_anchor.HistoryCount(),clrGainsboro);

   if(d.result.done)
     {
      SAnchorResult r=d.result;
      if(r.found)
        {
         g_dash.KV(5,"Last anchor",StringFormat("%s %s <- %s %s  (%.0fh back, score %.2f)",
                   V2_SessionName(r.tradeSession),RiyDate(r.tradeOpenTime),
                   V2_SessionName(r.srcSession),RiyDate(r.srcOpenTime),
                   r.hoursBack,r.srcScore),clrAqua);
         g_dash.Line(6,StringFormat("  pivot %s @ %s (%s, tier %s)",
                     DoubleToString(r.anchorPrice,_Digits),RiyStr(r.anchorTime),
                     r.anchorIsHigh?"HIGH":"LOW",r.anchorTier),clrGainsboro);
        }
      else
         g_dash.KV(5,"Last anchor",StringFormat("%s %s -> SKIP (nothing PASS within %.0fh)",
                   V2_SessionName(r.tradeSession),RiyDate(r.tradeOpenTime),InpMaxAnchorLookbackHr),clrTomato);

      g_dash.Line(7,"scanned this selection (newest first):",clrSilver);
      int shown=0;
      for(int i=0;i<d.scannedCount && shown<6;i++,shown++)
        {
         SAnchorCandidate c=d.scanned[i];
         color cc=c.pass?clrLime:clrTomato;
         g_dash.Line(8+shown,StringFormat("  %-6s %s  score %.2f %s  %.0fh back",
                     V2_SessionName(c.session),RiyDate(c.openTime),c.score,c.state,c.hoursBack),cc);
        }
     }
   else
      g_dash.KV(5,"Last anchor","- none resolved yet -",clrSilver);

   g_dash.Line(15,"check: pivot=real swing(T2a); source session=green(T2c); never >lookback",clrDimGray);
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
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());
   CsvHeader();

   if(!g_zz.HandleOk())
     {
      Print("[T2d] ERROR: could not create Examples\\ZigZag indicator handle");
      Alert("T2d: Examples\\ZigZag indicator not found - compile it in MetaEditor");
     }

   PrintFormat("[T2d] lookback=%.0fh flex=%.0fmin | quality GATES pass = (rng/atr>=%.1f OR leg/atr>=%.1f) AND impulseBars>=%d AND (no baseline yet OR rng/base>=%.2f)",
               InpMaxAnchorLookbackHr,InpAnchorFlexMin,
               InpMinRangeAtr,InpMinLegAtr,InpMinImpulseBars,InpMinRangeRatio);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   CsvFlush();
   g_sq.Deinit();
   g_zz.Deinit();
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
   ENUM_SESSION_V2   curr    =g_time.Session(now);

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
                  PrintFormat("[T2d] quality %s %s %s score %.2f",
                              V2_SessionName(r.session),RiyDate(r.openTime),r.state,r.score);
              }
           }
        }
      g_activeSession=curr;
     }

   DrawLiveBox(now);
   CheckAnchorPreRoll(now);
   DrawVwap(now);
  }
//+------------------------------------------------------------------+

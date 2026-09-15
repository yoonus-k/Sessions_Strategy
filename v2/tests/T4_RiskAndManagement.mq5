//+------------------------------------------------------------------+
//|                                       T4_RiskAndManagement.mq5    |
//|  Isolated visual test for Include/RiskV2.mqh +                    |
//|  Include/TradeManagerV2.mqh (milestone 11).                       |
//|                                                                   |
//|  Extends T3d's full chain (TimeSessions -> SessionQuality ->       |
//|  ZigZag -> AnchorSelect -> AVWAP -> Zones -> RejectBreak +         |
//|  Triggers -> ZoneEngine) with REAL order placement: every ZoneEngine|
//|  `take` that TradeManagerV2::CanOpenNew() allows is sized by       |
//|  RiskV2 and actually sent via CTrade. THIS TEST PLACES ORDERS -    |
//|  run it in the Strategy Tester only, never on a live/demo chart.   |
//|                                                                   |
//|  Direction lock, MaxTriesPerSession, SecondTryOnlyAfterSL,         |
//|  AllowReentryAfterWin, force-close-at-session-end and the spread   |
//|  guard are all real now (TradeManagerV2), replacing T3d's session- |
//|  direction simulation and preview-only SL/TP.                     |
//|                                                                   |
//|  Run: XAUUSD, M5, "Every tick based on real ticks", Visual ON,   |
//|  1-2 weeks, both sessions enabled.                                |
//|                                                                   |
//|  PASS checklist (v2/doc/IMPLEMENTATION_PLAN.md C4):              |
//|   [ ] Never more than one position open at a time.                |
//|   [ ] 2nd try appears ONLY after the 1st trade closed at SL; never |
//|       after a win, never a 3rd.                                   |
//|   [ ] After the first fill, a trigger in the opposite direction is |
//|       ignored (direction locked).                                 |
//|   [ ] Every position is flat by the session force-close time.     |
//|   [ ] Hand-check: R x lots ~ RiskPercent x balance at entry (the   |
//|       dashboard prints both).                                     |
//|   [ ] TP distance = RR x SL distance from entry.                  |
//|   [ ] Entry rejected + logged when spread > MaxSpreadPoints.       |
//|   [ ] SL clamped up to STOPS_LEVEL when the raw extreme is too     |
//|       close.                                                       |
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
#include "../Include/Triggers.mqh"
#include "../Include/ZoneEngine.mqh"
#include "../Include/RiskV2.mqh"
#include "../Include/TradeManagerV2.mqh"
#include "../Include/VisualsV2.mqh"
#include "../Include/DashboardV2.mqh"

input group "General"
input ENUM_TIMEFRAMES InpTF    = PERIOD_M5;
input long             InpMagic = 20260914;

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
input bool   InpCloseOnSessionEnd   = true;  // force-flat any open position at session end
input int    InpForceCloseOffsetSec = 0;     // close this many seconds BEFORE the session's own end
input int    InpEntryWindowMinutes  = 30;    // no NEW trade after this many minutes since session open; 0 = unlimited

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
input double InpTouchTolSigma        = 0.10;
input double InpRejectCloseSigma     = 0.05;
input bool   InpRejectRequireWick    = true;
input double InpRejectWickMinFrac    = 0.5;
input double InpBreakBufferSigma     = 0.15;
input bool   InpBreakRequireMomentum = true;
input double InpBreakBodyAtr         = 0.8;

input group "Fractals / BOS (Entry Type A)"
input int                 InpBosSwingDepth   = 3;
input int                 InpBosBufferPoints = 0;
input ENUM_BOS_CONFIRM_V2 InpBosConfirmMode  = BC_CLOSE;

input group "Reversal + Momentum (Entry Type B, spec Sec9.3)"
input int    InpRevCounterLookback   = 8;
input double InpRevMinCounterMoveAtr = 0.8;
input double InpRevBodyAtr           = 1.0;
input double InpRevCloseLocPct       = 0.33;
input bool   InpRevRequireEngulf     = false;
input int    InpRevBreakBars         = 2;
input int    InpRevConfirmCloses     = 1;

input group "Entry"
input ENUM_ENTRY_MODE_V2 InpEntryMode     = EM_BOTH;
input ENUM_ENTRY_FILL_V2 InpEntryFillMode = EF_BOS_CLOSE;

input group "ZoneEngine"
input bool InpAllowFlipInDirectZone   = false;
input bool InpAllowFlipInExtendedZone = false;

input group "Risk / SL / TP / Sizing (spec Sec10)"
input double                  InpRR                = 1.5;
input ENUM_SL_BUFFER_MODE_V2  InpSlBufferMode      = SLB_PCT_OF_LEG;
input double                  InpSlBufferPct       = 0.10;
input double                  InpSlBufferAtrMult   = 0.0;
input double                  InpSlBufferPoints    = 0.0;
input double                  InpMinStopAtrMult    = 0.0;
input bool                    InpClampStopsToBroker= true;
input ENUM_RISK_MODE_V2       InpRiskMode          = RM_PERCENT;
input double                  InpRiskPercent       = 0.5;
input double                  InpFixedLot          = 0.01;

input group "Trade & Session Management (spec Sec11)"
input int  InpMaxTriesPerSession   = 2;
input bool InpSecondTryOnlyAfterSl = true;
input bool InpAllowReentryAfterWin = false;
input int  InpMaxSpreadPoints      = 50;
input int  InpMaxSlippagePoints    = 20;
input bool   InpBeEnabled          = true;
input double InpBeTriggerR         = 0.5;

input group "Test / diagnostics"
input int  InpMaxQualityBoxes   = 80;
input int  InpMaxStripCells     = 600;
input int  InpMaxDrawnDecisions = 3;
input bool InpWriteCsv          = true;
input bool InpVerbose           = true;

SSettingsV2     g_s;
CTimeSessions   g_time;
CSessionQuality g_sq;
CZigZag         g_zz;
CAnchorSelect   g_anchor;
CAVWAP          g_avwap;
CZones          g_zones;
CRejectBreak    g_rb;
CTriggers       g_trig;
CZoneEngine     g_engine;
CRiskV2         g_risk;
CTradeManagerV2 g_tm;
CVisualsV2      g_vis;
CDashboardV2    g_dash;

datetime        g_lastBar       = 0;
ENUM_SESSION_V2 g_activeSession = SESS_NONE;
datetime        g_drawnVwapTo   = 0;
datetime        g_lastAvwapAnchor = 0;
string          g_lastAnchorKey = "";
string          g_tradeSessionKey = "";
ENUM_SESSION_V2 g_forceCloseSession = SESS_NONE; // last TRADE session seen; survives Session()
                                                  // rolling to NONE at the exact close boundary -
                                                  // see TimeSessions.mqh::IsForceCloseTime header

SQualityResult  g_qres[128];
int             g_qresN = 0;

string          g_csv[];

struct SZoneRow { datetime barTime; SDiagZones z; };
SZoneRow        g_zrows[600];
int             g_zrowsN = 0;

SDiagRejectBreak g_lastRb;
bool             g_wasOpen = false;   // edge-detects a position close to wipe its risk lines (DECRISK)

struct SDecisionRow
  {
   datetime       barTime;
   SEngineDecision dec;
   SRiskCalc      risk;
   bool           opened;
  };
SDecisionRow    g_decRing[64];
int             g_decRingN = 0;
SEngineDecision g_lastDec;
bool            g_hasLastDec = false;

int             g_spreadRejects = 0;
datetime        g_lastSpreadReject = 0;

//+------------------------------------------------------------------+
void BuildSettingsV2()
  {
   g_s.tf    = InpTF;
   g_s.magic = InpMagic;
   g_s.brokerWinterOffsetHr = 3.0 - InpServerToRiyadhOffsetHr;
   g_s.brokerObservesDST    = InpServerObservesDST;
   g_s.brokerDSTCalendar    = InpServerDSTCal;

   g_s.asiaEnabled=true;   g_s.asiaRole=ROLE_TRADE;
   g_s.asiaStartMin=V2_ParseHM(InpAsiaStart);   g_s.asiaEndMin=V2_ParseHM(InpAsiaEnd);
   g_s.londonEnabled=true; g_s.londonRole=ROLE_ANCHOR_ONLY;
   g_s.londonStartMin=V2_ParseHM(InpLondonStart);g_s.londonEndMin=V2_ParseHM(InpLondonEnd);
   g_s.nyEnabled=true;     g_s.nyRole=ROLE_TRADE;
   g_s.nyStartMin=V2_ParseHM(InpNYStart);        g_s.nyEndMin=V2_ParseHM(InpNYEnd);
   g_s.noNewEntryOffsetSec=0; g_s.entryWindowMinutes=InpEntryWindowMinutes;
   g_s.forceCloseOffsetSec=InpForceCloseOffsetSec; g_s.closeOnSessionEnd=InpCloseOnSessionEnd;

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

   g_s.bosSwingDepth   = InpBosSwingDepth;
   g_s.bosBufferPoints = InpBosBufferPoints;
   g_s.bosConfirmMode  = InpBosConfirmMode;

   g_s.entryMode       = InpEntryMode;
   g_s.entryFillMode   = InpEntryFillMode;
   g_s.revCounterLookback   = InpRevCounterLookback;
   g_s.revMinCounterMoveAtr = InpRevMinCounterMoveAtr;
   g_s.revBodyAtr           = InpRevBodyAtr;
   g_s.revCloseLocPct       = InpRevCloseLocPct;
   g_s.revRequireEngulf     = InpRevRequireEngulf;
   g_s.revBreakBars         = InpRevBreakBars;
   g_s.revConfirmCloses     = InpRevConfirmCloses;

   g_s.allowFlipInDirectZone   = InpAllowFlipInDirectZone;
   g_s.allowFlipInExtendedZone = InpAllowFlipInExtendedZone;

   g_s.rr                 = InpRR;
   g_s.slBufferMode        = InpSlBufferMode;
   g_s.slBufferPct         = InpSlBufferPct;
   g_s.slBufferAtrMult     = InpSlBufferAtrMult;
   g_s.slBufferPoints      = InpSlBufferPoints;
   g_s.minStopAtrMult      = InpMinStopAtrMult;
   g_s.clampStopsToBroker  = InpClampStopsToBroker;
   g_s.riskMode            = InpRiskMode;
   g_s.riskPercent         = InpRiskPercent;
   g_s.fixedLot            = InpFixedLot;

   g_s.maxTriesPerSession   = InpMaxTriesPerSession;
   g_s.secondTryOnlyAfterSl = InpSecondTryOnlyAfterSl;
   g_s.allowReentryAfterWin = InpAllowReentryAfterWin;
   g_s.maxSpreadPoints      = InpMaxSpreadPoints;
   g_s.maxSlippagePoints    = InpMaxSlippagePoints;
   g_s.beEnabled            = InpBeEnabled;
   g_s.beTriggerR           = InpBeTriggerR;
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
              StringFormat("%s %s  IN PROGRESS...  DIR LOCK: %s  try %d/%d",
                 V2_SessionName(g_activeSession),RiyDate(openB),
                 V2_DirName(g_tm.SessionDirection()),g_tm.Tries(),InpMaxTriesPerSession),
              clrYellow,9,ANCHOR_LEFT_LOWER);
   g_vis.Redraw();
  }

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
//|  TAKE decision: big arrow + label + REAL SL/TP (from RiskV2). Red |
//|  outline + "NOT OPENED (reason)" when the engine wanted to take   |
//|  but TradeManagerV2/RiskV2 blocked it (locked out, spread, lots=0)|
//+------------------------------------------------------------------+
void DrawDecisionObj(const SDecisionRow &row)
  {
   SEngineDecision dec=row.dec;
   if(!dec.take) return;
   bool up=(dec.direction==DIR_LONG);
   color c=row.opened?(up?clrLime:clrOrangeRed):clrGray;
   string key=(string)(long)row.barTime+"_"+(up?"L":"S");
   double entry=dec.trigger.entryPrice;
   datetime entryT=dec.trigger.entryTime;
   datetime endT=entryT+PeriodSeconds(InpTF)*20;

   g_vis.Arrow(g_vis.Name("DEC",key+"_arr"),entryT,entry,up?233:234,c,4,up?ANCHOR_TOP:ANCHOR_BOTTOM);
   g_vis.Text(g_vis.Name("DEC",key+"_txt"),entryT,entry,
              StringFormat(" %s %s . %s . trigger %s . lean %s%s",
                 row.opened?"TAKE":"NOT OPENED",up?"LONG":"SHORT",V2_ZoneName(dec.zone),dec.triggerType,
                 V2_DirName(dec.lean),dec.isFlip?" . FLIP":""),
              c,10,up?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER);

  }

//+------------------------------------------------------------------+
//|  Live SL/TP rays for the CURRENTLY open position only - a         |
//|  separate group from DEC (entry markers) on purpose. RayH() is an |
//|  infinite ray (RAY_RIGHT=true regardless of the passed end-time), |
//|  so bundling these into DEC's "last N" ring buffer still let an   |
//|  old, already-closed trade's SL/TP stretch across every later      |
//|  session until enough new trades pushed it out of the ring - the   |
//|  same bug reported and fixed in SessionsStrategyV2.mq5 on          |
//|  2026-09-14, applied here too so both real-order-placing EAs share |
//|  the fix. Wiped the instant the position closes (edge-detected via |
//|  g_wasOpen in OnTick, since T4 predates AnalyticsV2's              |
//|  ConsumeCloseEvent) and again defensively at every session end.    |
//+------------------------------------------------------------------+
void DrawDecisionRisk(const SDecisionRow &row)
  {
   if(!row.opened) return;
   datetime entryT=row.dec.trigger.entryTime;
   datetime endT=entryT+PeriodSeconds(InpTF)*20;
   g_vis.RayH(g_vis.Name("DECRISK","sl"),entryT,row.risk.sl,endT,clrRed,STYLE_DASH);
   g_vis.RayH(g_vis.Name("DECRISK","tp"),entryT,row.risk.tp,endT,clrLime,STYLE_DASH);
   g_vis.Text(g_vis.Name("DECRISK","sltxt"),endT,row.risk.sl," SL",clrRed,8,ANCHOR_RIGHT_UPPER);
   g_vis.Text(g_vis.Name("DECRISK","tptxt"),endT,row.risk.tp," TP",clrLime,8,ANCHOR_RIGHT_LOWER);
   g_vis.Redraw();
  }

void ClearDecisionRisk()
  {
   g_vis.ClearGroup("DECRISK");
   g_vis.Redraw();
  }

void RedrawDecisions()
  {
   g_vis.ClearGroup("DEC");
   int show=MathMin(MathMax(InpMaxDrawnDecisions,0),g_decRingN);
   for(int i=g_decRingN-show;i<g_decRingN;i++)
      DrawDecisionObj(g_decRing[i]);
   g_vis.Redraw();
  }

void PushDecision(const datetime barTime,const SEngineDecision &dec,const SRiskCalc &risk,const bool opened)
  {
   int cap=64;
   SDecisionRow row; row.barTime=barTime; row.dec=dec; row.risk=risk; row.opened=opened;
   if(g_decRingN<cap){ g_decRing[g_decRingN++]=row; return; }
   for(int i=1;i<cap;i++) g_decRing[i-1]=g_decRing[i];
   g_decRing[cap-1]=row;
  }

//+------------------------------------------------------------------+
//|  Force-close marker at session end                                |
//+------------------------------------------------------------------+
void DrawForceClose(const datetime barTime,const double price)
  {
   string key=(string)(long)barTime;
   g_vis.VLine(g_vis.Name("FC",key+"_vl"),barTime,clrMagenta,STYLE_SOLID,2);
   g_vis.Text(g_vis.Name("FC",key+"_txt"),barTime,price,"  FORCE-CLOSE",clrMagenta,9,ANCHOR_LEFT_LOWER);
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
//|  Spread-reject mark                                                |
//+------------------------------------------------------------------+
void DrawSpreadReject(const datetime barTime,const double price)
  {
   string key=(string)(long)barTime;
   g_vis.Text(g_vis.Name("SPR",key),barTime,price,"  x SPREAD",clrOrange,9,ANCHOR_LEFT_LOWER);
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
            PrintFormat("[T4] pre-roll %.0fmin before %s %s -> ANCHOR <- %s %s (%.0fh back, score %.2f)",
                        InpAnchorPreRollMin,V2_SessionName(s),RiyDate(realOpen),
                        V2_SessionName(ar.srcSession),RiyDate(ar.srcOpenTime),ar.hoursBack,ar.srcScore);
         else
            PrintFormat("[T4] pre-roll %.0fmin before %s %s -> NO ANCHOR -> SKIP",
                        InpAnchorPreRollMin,V2_SessionName(s),RiyDate(realOpen));
        }
     }
  }

void CsvFlush()
  {
   if(!InpWriteCsv || ArraySize(g_csv)<=1) return;
   string fn="SessionsStrategyV2_Anchor_"+_Symbol+".csv";
   int h=FileOpen(fn,FILE_WRITE|FILE_ANSI|FILE_TXT|FILE_COMMON);
   if(h==INVALID_HANDLE){ PrintFormat("[T4] CSV open failed: %s",fn); return; }
   for(int i=0;i<ArraySize(g_csv);i++) FileWriteString(h,g_csv[i]+"\r\n");
   FileClose(h);
   PrintFormat("[T4] wrote %d rows to Common\\Files\\%s",ArraySize(g_csv)-1,fn);
  }

//+------------------------------------------------------------------+
void RefreshDash()
  {
   SDiagZones d=g_zones.Diag();
   SDiagTradeManager tmd=g_tm.Diag();

   g_dash.Title(0,"--- V2 . RISK + TRADE MANAGEMENT (T4) ---");
   g_dash.KV(1,"Now",RiyStr(TimeCurrent())+" Riyadh",clrSilver);
   bool inWindow=(g_time.Role(TimeCurrent())==ROLE_TRADE);
   bool inEntryWindow=g_time.WithinEntryWindow(TimeCurrent());
   int  minsSinceOpen=g_time.MinsSinceSessionOpen(TimeCurrent());
   g_dash.KV(2,"Trade window",StringFormat("%s%s  entry-window %s (%s min, limit %d)",
             inWindow?"YES (":"no",inWindow?V2_SessionName(g_time.Session(TimeCurrent()))+")":"",
             inEntryWindow?"OPEN":"CLOSED",minsSinceOpen>=0?(string)minsSinceOpen:"-",InpEntryWindowMinutes),
             inWindow?(inEntryWindow?clrLime:clrOrange):clrDimGray);
   g_dash.KV(3,"DIR LOCK",StringFormat("%s   try %d/%d   sessionClosed:%s",
             V2_DirName(tmd.sessionDirection),tmd.tries,tmd.maxTries,tmd.sessionClosed?"Y":"N"),
             tmd.sessionDirection==DIR_NONE?clrSilver:(tmd.sessionDirection==DIR_LONG?clrLime:clrOrangeRed));

   if(tmd.isOpen)
     {
      double lossPerLot=g_risk.LossPerLot(tmd.entry,tmd.sl);
      double riskMoney=lossPerLot*tmd.lots;
      double balance=AccountInfoDouble(ACCOUNT_BALANCE);
      double initBal =g_risk.InitialBalance();
      g_dash.KV(4,"OPEN position",StringFormat("#%I64d  entry %s  SL %s  TP %s  lots %.2f  BE:%s",
                tmd.posId,DoubleToString(tmd.entry,_Digits),DoubleToString(tmd.sl,_Digits),
                DoubleToString(tmd.tp,_Digits),tmd.lots,tmd.beApplied?"Y":"waiting"),clrLime);
      g_dash.Line(5,StringFormat("  risk %.2f (%.2f%% of INITIAL %.2f; %.2f%% of current %.2f)  target%.2f (RR %.2f)",
                  riskMoney,initBal>0?riskMoney/initBal*100.0:0.0,initBal,
                  balance>0?riskMoney/balance*100.0:0.0,balance,riskMoney*InpRR,InpRR),clrGainsboro);
     }
   else
      g_dash.KV(4,"OPEN position","- none -",clrSilver);

   g_dash.KV(6,"Spread",StringFormat("%d pts (max %d)  rejects: %d",
             (int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD),InpMaxSpreadPoints,g_spreadRejects),
             clrGainsboro);

   if(!d.ready)
      g_dash.KV(7,"Zone","suppressed (AVWAP warm-up)",clrDimGray);
   else
     {
      color zc=(d.zone==ZONE_Z1)?clrSilver:(d.zone==ZONE_Z2)?clrOrange:clrRed;
      g_dash.KV(7,"Zone",StringFormat("%s (d %+.2fs)  stance: %s",V2_ZoneName(d.zone),d.dSigma,V2_StanceText(d)),zc);
     }

   if(tmd.lastAction!="")
      g_dash.Line(8,"  "+tmd.lastAction,clrGainsboro);

   if(g_hasLastDec && g_lastDec.regimeLocked)
     {
      string regTxt=(g_lastDec.regimeZone==ZONE_Z1)?"CONTINUATION "+V2_DirName(g_lastDec.regimeDir):
                    (g_lastDec.regimeZone==ZONE_Z3)?"REVERSAL "+V2_DirName(g_lastDec.regimeDir):
                    StringFormat("CONFIRMATION (both dirs, %s)",g_lastDec.confirmArmed?"ARMED":"waiting for Z1 touch");
      color regColor=(g_lastDec.regimeZone==ZONE_Z2)?(g_lastDec.confirmArmed?clrOrange:clrDimGray):
                     (g_lastDec.regimeDir==DIR_LONG?clrLime:clrOrangeRed);
      g_dash.KV(9,"Regime (locked @ session open)",regTxt,regColor);
     }
   else
      g_dash.KV(9,"Regime (locked @ session open)","not captured yet",clrDimGray);

   g_dash.Line(10,"recent decisions (newest first):",clrSilver);
   int shown=0;
   for(int i=g_decRingN-1;i>=0 && shown<6;i--,shown++)
     {
      SDecisionRow row=g_decRing[i];
      color c=!row.opened?clrDimGray:(row.dec.direction==DIR_LONG?clrLime:clrOrangeRed);
      g_dash.Line(11+shown,StringFormat("  %s  %s %s%s",RiyStr(row.barTime),
                  row.opened?"OPENED":"blocked",V2_DirName(row.dec.direction),
                  row.dec.isFlip?" FLIP":""),c);
     }
   g_dash.Line(18,"check: 1 pos max; 2nd try only after SL; flat by force-close; R*lots~=risk%*bal",clrDimGray);
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
   g_trig.Init(g_s,_Symbol);
   g_engine.Init(g_s);
   g_risk.Init(g_s,_Symbol);
   g_tm.Init(g_s,_Symbol);
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());
   CsvHeader();

   if(!g_zz.HandleOk())
      Alert("T4: Examples\\ZigZag indicator not found - compile it in MetaEditor");

   PrintFormat("[T4] magic=%d RR=%.2f slBufMode=%d riskMode=%d riskPct=%.2f maxTries=%d 2ndTryAfterSL=%s maxSpread=%d",
               InpMagic,InpRR,InpSlBufferMode,InpRiskMode,InpRiskPercent,InpMaxTriesPerSession,
               InpSecondTryOnlyAfterSl?"Y":"N",InpMaxSpreadPoints);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   CsvFlush();
   g_sq.Deinit();
   g_zz.Deinit();
   g_rb.Deinit();
   g_trig.Deinit();
   g_risk.Deinit();
   g_vis.Destroy();
   g_dash.Destroy();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // position/force-close management runs every tick, not only on new bars
   g_tm.PollClosed();
   g_tm.ManageBreakEven();

   bool isOpenNow=g_tm.HasOpenPosition();
   if(g_wasOpen && !isOpenNow) ClearDecisionRisk();
   g_wasOpen=isOpenNow;

   bool forceCloseNow=g_time.IsForceCloseTime(TimeCurrent(),g_forceCloseSession);
   if(forceCloseNow && g_tm.HasOpenPosition())
     {
      double px=iClose(_Symbol,InpTF,0);
      g_tm.ForceCloseIfDue(true);
      DrawForceClose(iTime(_Symbol,InpTF,0),px);
     }

   RefreshDash();
   bool newBar=IsNewBar();
   if(!newBar) return;

   g_zz.Refresh();
   DrawZigZag();
   g_trig.RefreshStructure();

   datetime now=iTime(_Symbol,InpTF,0);
   ENUM_SESSION_V2   curr    =g_time.Session(now);
   ENUM_SESSION_ROLE currRole=g_time.Role(now);

   if(currRole==ROLE_TRADE) g_forceCloseSession=curr;

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
              }
           }
         ClearDecisionRisk();   // defensive - should already be gone via the g_wasOpen edge-detect above
        }
      g_activeSession=curr;
     }

   string curTradeKey=(currRole==ROLE_TRADE)?g_time.SessionKey(now):"";
   if(curTradeKey!=g_tradeSessionKey)
     {
      g_tradeSessionKey=curTradeKey;
      g_tm.ResetSession();
      g_engine.ResetSession();   // clear the regime lock so the new session captures its own at its own open
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

   MqlRates rbBar[];
   SDiagRejectBreak rd; rd.atr=0; rd.firedPrimitive="-"; rd.firedBand="-";
   rd.lean=DIR_NONE; rd.leanBars=0; rd.extendedTransition=false;
   bool touchedZ1ThisBar=false;
   if(zd.ready && CopyRates(_Symbol,InpTF,1,1,rbBar)==1)
     {
      rd=g_rb.Update(rbBar[0],zd.dSigma,vw,sg);
      g_lastRb=rd;
      DrawRejectBreak(rbBar[0].time,rd,vw,sg);
      double u1=vw+InpBand1Mult*sg, l1=vw-InpBand1Mult*sg;
      touchedZ1ThisBar=(rbBar[0].low<=u1 && rbBar[0].high>=l1);
     }

   g_trig.Update();
   STriggerEvent trigLong =g_trig.Query(DIR_LONG);
   STriggerEvent trigShort=g_trig.Query(DIR_SHORT);

   if(currRole==ROLE_TRADE)
     {
      SEngineDecision dec=g_engine.Decide(g_tm.SessionDirection(),zd,rd,trigLong,trigShort,touchedZ1ThisBar);
      g_lastDec=dec; g_hasLastDec=true;

      if(dec.take)
        {
         bool entryWindowOpen=g_time.WithinEntryWindow(now);
         if(!g_tm.CanOpenNew() || !entryWindowOpen)
           {
            SRiskCalc blankRisk; blankRisk.valid=false; blankRisk.dir=dec.direction;
            blankRisk.entry=dec.trigger.entryPrice; blankRisk.sl=0; blankRisk.tp=0;
            PushDecision(now,dec,blankRisk,false);
            RedrawDecisions();
            if(InpVerbose)
               PrintFormat("[T4] decision TAKE %s but %s (locked/capped/session closed)",
                           V2_DirName(dec.direction),
                           !entryWindowOpen?StringFormat("entry window closed (%d min elapsed, limit %d)",
                                            g_time.MinsSinceSessionOpen(now),InpEntryWindowMinutes)
                                           :"CanOpenNew()=false");
           }
         else
           {
            SRiskCalc risk=g_risk.Compute(dec.direction,dec.trigger.entryPrice,
                                          dec.trigger.protectedExtreme,dec.trigger.legRange);
            string comment=StringFormat("V2 %s %s",V2_ZoneName(dec.zone),dec.triggerType);
            bool opened=false;
            long spreadBefore=SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
            if(risk.valid && InpMaxSpreadPoints>0 && spreadBefore>InpMaxSpreadPoints)
              {
               g_spreadRejects++; g_lastSpreadReject=now;
               DrawSpreadReject(now,dec.trigger.entryPrice);
              }
            opened=g_tm.TryOpen(risk,comment);
            PushDecision(now,dec,risk,opened);
            RedrawDecisions();
            if(opened) DrawDecisionRisk(g_decRing[g_decRingN-1]);
           }
        }
     }
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                               SessionQuality.mqh  |
//|  P2 - relative volatility / "quality" classifier for a COMPLETED  |
//|  session. Every metric is ATR- or ratio-normalised - no point     |
//|  thresholds anywhere.                                             |
//|                                                                   |
//|  Metrics that GATE (see EvaluateCompleted for the exact formula): |
//|   range       = session high - session low                       |
//|   atr         = ATR(atrPeriod) at the session's opening bar       |
//|   baseline    = median 'range' of the last qualityBaselineN       |
//|                 COMPLETED sessions of the SAME type               |
//|   largestLeg  = largest sustained one-directional excursion in    |
//|                 the session (max rise from a prior low / fall     |
//|                 from a prior high) - captures a V-reversal's big  |
//|                 leg, which efficiency cannot see                  |
//|   impulseBars = count of bars with RANGE >= impulseBarAtrMult*ATR;|
//|                 guards against ONE spike bar carrying an          |
//|                 otherwise-choppy session through the movement gate|
//|                                                                   |
//|  Extra metrics, exported (CSV/labeler) but NOT gating yet -       |
//|  candidates for v2/ml/calibrate_quality.py to evaluate against    |
//|  real labels before any of them are promoted into a gate:         |
//|   efficiency      = Kaufman efficiency ratio                      |
//|   bodyImpulseBars = bars whose BODY (not full range) clears the   |
//|                     same threshold - a wick/spike bar has a big   |
//|                     range but a small body, so this is a cleaner  |
//|                     "real conviction candle" count than range-    |
//|                     based impulseBars                             |
//|   maxBarRangeShare= (largest single bar's range) / session range  |
//|                     - close to 1.0 means ONE bar produced almost  |
//|                     the whole session range (spike, not expansion)|
//|   longestRun/runRatio = longest streak of same-direction bars,    |
//|                     as a fraction of the session's bar count -    |
//|                     persistence, distinct from net-displacement   |
//|                     efficiency                                    |
//|   volumeRatio     = session tick-volume / median tick-volume of   |
//|                     the last qualityBaselineN same-type sessions  |
//|                     (same baseline machinery as range)            |
//|                                                                   |
//|  GATES pass = (range/atr>=minRangeAtr OR leg/atr>=minLegAtr) [mv]  |
//|            AND (impulseBars >= minImpulseBars)    [not one spike] |
//|            AND (no baseline yet OR range/baseline>=minRangeRatio) |
//|                                                    [confirm]      |
//|  SCORE = weighted terms, pass >= qualityScoreThreshold           |
//|                                                                   |
//|  2026-09-14 recalibration (520 real hand-labelled sessions, see   |
//|  v2/ml/calibrate_quality.py): the baseline/range-ratio check used |
//|  to be a hard AND that forced every session to WARMING (no        |
//|  verdict at all) until qualityBaselineN same-type priors existed. |
//|  Checked against real labels this was strictly worse than not     |
//|  blocking on it: MCC 0.57 (blocking) vs 0.58 (confirm-only, never |
//|  blocks) vs 0.56 (baseline removed entirely). The movement gates  |
//|  (ATR-based, no baseline needed) correlate with the real label    |
//|  MORE than the baseline-ratio ones (0.425 vs 0.354) - they are    |
//|  the real signal. So: baselineWarm is now purely INFORMATIONAL -  |
//|  a session gets a real PASS/FAIL from session 1, and the ratio    |
//|  check only ever narrows a PASS down, never withholds a verdict.  |
//|  (Also dropped an uncalibrated 3rd OR-clause, leg/baseline, that  |
//|  had crept into the live gate without ever being grid-searched -  |
//|  it alone cost 0.106 MCC on the real data.)                       |
//|                                                                   |
//|  Pure measurement - never places orders / gates anything here.   |
//+------------------------------------------------------------------+
#ifndef V2_SESSIONQUALITY_MQH
#define V2_SESSIONQUALITY_MQH

#include "V2Common.mqh"

struct SQualityResult
  {
   bool            evaluated;
   ENUM_SESSION_V2 session;
   datetime        openTime;
   datetime        closeTime;
   int             bars;
   double          range;
   double          atr;
   double          baseline;
   int             baselineN;       // priors that fed the range median
   double          largestLeg;
   double          efficiency;
   int             impulseBarCount; // bars with range      >= impulseBarAtrMult * ATR
   int             bodyImpulseCount;// bars with |close-open|>= impulseBarAtrMult * ATR
   double          maxBarRangeShare;// largest single bar's range / session range
   int             longestRun;      // longest streak of same-direction bars
   double          runRatio;        // longestRun / bars
   double          volumeRatio;     // session tick-volume / baseline tick-volume (0 if no baseline)
   double          rangeRatio;      // range / baseline (0 if no baseline)
   double          rangeAtr;        // range / atr
   double          legAtr;          // largestLeg / atr
   double          legRatio;        // largestLeg / baseline (0 if no baseline)
   double          score;           // 0..1  (SCORE mode)
   bool            pass;            // true only for a real PASS
   bool            baselineWarm;    // informational only: baselineN < qualityBaselineN
                                    // (does NOT withhold pass/fail - see file header, 2026-09-14)
   string          state;          // "PASS" | "FAIL"
   string          mode;           // "SCORE" | "GATES"
  };

struct SDiagQuality
  {
   int    asiaSamples, londonSamples, nySamples;
   int    baselineTarget;
   double asiaBaseline, londonBaseline, nyBaseline;
  };

class CSessionQuality
  {
private:
   SSettingsV2 m_s;
   string      m_sym;
   int         m_atrHandle;

   double      m_asia[]; // ring buffers of session 'range', chronological, capped at baselineN
   double      m_lon[];
   double      m_ny[];
   double      m_asiaVol[]; // parallel ring buffers of session tick-volume
   double      m_lonVol[];
   double      m_nyVol[];

   void Push(double &ring[],const double v)
     {
      int cap=MathMax(1,m_s.qualityBaselineN);
      int n=ArraySize(ring);
      if(n<cap){ ArrayResize(ring,n+1); ring[n]=v; return; }
      for(int i=1;i<cap;i++) ring[i-1]=ring[i];
      ring[cap-1]=v;
     }

   double Median(const double &ring[]) const
     {
      int n=ArraySize(ring);
      if(n<=0) return(0.0);
      double t[]; ArrayResize(t,n);
      for(int i=0;i<n;i++) t[i]=ring[i];
      ArraySort(t);
      if(n%2==1) return(t[n/2]);
      return(0.5*(t[n/2-1]+t[n/2]));
     }

   double ATRatOpen(const datetime openB) const
     {
      if(m_atrHandle==INVALID_HANDLE) return(0.0);
      int sh=iBarShift(m_sym,m_s.tf,openB,false);
      if(sh<0) sh=0;
      double a[];
      if(CopyBuffer(m_atrHandle,0,sh,1,a)<1) return(0.0);
      return(a[0]);
     }

public:
   void Init(const SSettingsV2 &s,const string sym)
     {
      m_s=s; m_sym=sym;
      m_atrHandle=(s.atrPeriod>0)?iATR(sym,s.tf,s.atrPeriod):INVALID_HANDLE;
      ArrayResize(m_asia,0); ArrayResize(m_lon,0); ArrayResize(m_ny,0);
      ArrayResize(m_asiaVol,0); ArrayResize(m_lonVol,0); ArrayResize(m_nyVol,0);
     }
   void Deinit(){ if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle); }

   int SamplesFor(const ENUM_SESSION_V2 ses) const
     {
      if(ses==SESS_ASIA)   return(ArraySize(m_asia));
      if(ses==SESS_LONDON) return(ArraySize(m_lon));
      if(ses==SESS_NY)     return(ArraySize(m_ny));
      return(0);
     }
   double BaselineFor(const ENUM_SESSION_V2 ses) const
     {
      if(ses==SESS_ASIA)   return(Median(m_asia));
      if(ses==SESS_LONDON) return(Median(m_lon));
      if(ses==SESS_NY)     return(Median(m_ny));
      return(0.0);
     }
   double VolBaselineFor(const ENUM_SESSION_V2 ses) const
     {
      if(ses==SESS_ASIA)   return(Median(m_asiaVol));
      if(ses==SESS_LONDON) return(Median(m_lonVol));
      if(ses==SESS_NY)     return(Median(m_nyVol));
      return(0.0);
     }

   //+--------------------------------------------------------------+
   //| Evaluate a session that has JUST fully completed.             |
   //|                                                              |
   //| largestLeg is measured HERE as the largest sustained one-     |
   //| directional excursion inside the session (biggest rise from  |
   //| any prior low, or fall from any prior high) - NOT a ZigZag    |
   //| leg: at session scale (~36 M5 bars) a confirmed ZZ leg almost |
   //| never exists, and this excursion is what actually captures    |
   //| "there was a real directional push", including the big leg of |
   //| a V-reversal that Kaufman efficiency cannot see.              |
   //|                                                              |
   //| GATES pass = expansion AND movement AND not-a-single-spike:   |
   //|   expansion  : range/baseline >= minRangeRatio  (key gate)    |
   //|   movement   : range/ATR>=minRangeAtr OR leg/ATR>=minLegAtr   |
   //|   not-a-spike: impulseBarCount >= minImpulseBars              |
   //| Every other metric (efficiency, bodyImpulseCount,             |
   //| maxBarRangeShare, longestRun/runRatio, volumeRatio) is         |
   //| exported for the labeler / calibration script but does NOT    |
   //| gate until real labelled data says it should.                 |
   //+--------------------------------------------------------------+
   SQualityResult EvaluateCompleted(const ENUM_SESSION_V2 ses,
                                    const datetime openB,const datetime closeB)
     {
      SQualityResult r;
      r.evaluated=false; r.session=ses; r.openTime=openB; r.closeTime=closeB;
      r.bars=0; r.range=0; r.atr=0; r.baseline=0; r.baselineN=0;
      r.largestLeg=0; r.efficiency=0; r.impulseBarCount=0; r.bodyImpulseCount=0;
      r.maxBarRangeShare=0; r.longestRun=0; r.runRatio=0; r.volumeRatio=0;
      r.rangeRatio=0; r.rangeAtr=0; r.legAtr=0; r.legRatio=0;
      r.score=0; r.pass=false; r.baselineWarm=true; r.state="FAIL";
      r.mode=(m_s.qualityMode==QM_GATES)?"GATES":"SCORE";
      if(ses==SESS_NONE) return(r);

      MqlRates bar[]; ArraySetAsSeries(bar,false);
      int n=CopyRates(m_sym,m_s.tf,openB,closeB,bar);
      if(n<3) return(r);

      double atr=ATRatOpen(openB); // needed inside the loop for the impulse-bar counts

      double hi=-DBL_MAX, lo=DBL_MAX, sumAbs=0.0, maxBarRange=0.0;
      double runLo=DBL_MAX, runHi=-DBL_MAX, maxUp=0.0, maxDn=0.0;
      long   volSum=0;
      int    used=0, impulseBars=0, bodyImpulseBars=0;
      int    curDir=0, curRunLen=0, longestRun=0;
      double firstClose=0, lastClose=0;
      for(int i=0;i<n;i++)
        {
         if(bar[i].time<openB || bar[i].time>=closeB) continue;
         double barRange=bar[i].high-bar[i].low;
         double barBody =MathAbs(bar[i].close-bar[i].open);
         if(bar[i].high>hi) hi=bar[i].high;
         if(bar[i].low <lo) lo=bar[i].low;
         if(barRange>maxBarRange) maxBarRange=barRange;
         // largest sustained directional excursion, either way
         if(bar[i].low <runLo) runLo=bar[i].low;
         if(bar[i].high>runHi) runHi=bar[i].high;
         if(bar[i].high-runLo>maxUp) maxUp=bar[i].high-runLo;
         if(runHi-bar[i].low>maxDn) maxDn=runHi-bar[i].low;
         // anti-single-spike: RANGE-based (gates) and BODY-based (exported only)
         if(atr>0.0)
           {
            if(barRange>=m_s.impulseBarAtrMult*atr) impulseBars++;
            if(barBody >=m_s.impulseBarAtrMult*atr) bodyImpulseBars++;
           }
         // persistence: longest run of same-direction bars
         int dir=(bar[i].close>bar[i].open)?1:(bar[i].close<bar[i].open)?-1:0;
         if(dir!=0 && dir==curDir) curRunLen++;
         else curRunLen=(dir!=0)?1:0;
         curDir=dir;
         if(curRunLen>longestRun) longestRun=curRunLen;
         volSum+=bar[i].tick_volume;
         if(used==0) firstClose=bar[i].close;
         else        sumAbs+=MathAbs(bar[i].close-lastClose);
         lastClose=bar[i].close;
         used++;
        }
      if(used<3 || hi<=lo) return(r);

      r.evaluated=true;
      r.bars=used;
      r.range=hi-lo;
      r.largestLeg=MathMax(maxUp,maxDn);
      r.atr=atr;
      r.impulseBarCount =impulseBars;
      r.bodyImpulseCount=bodyImpulseBars;
      r.maxBarRangeShare=(r.range>0.0)?maxBarRange/r.range:0.0;
      r.longestRun=longestRun;
      r.runRatio  =(used>0)?(double)longestRun/used:0.0;
      r.efficiency=(sumAbs>0.0)?MathAbs(lastClose-firstClose)/sumAbs:0.0;

      int nOut=SamplesFor(ses);
      r.baseline =BaselineFor(ses);
      r.baselineN=nOut;
      double volBaseline=VolBaselineFor(ses);
      r.volumeRatio=(volBaseline>0.0)?((double)volSum/volBaseline):0.0;

      if(r.atr>0.0)
        {
         r.rangeAtr=r.range/r.atr;
         r.legAtr  =r.largestLeg/r.atr;
        }
      if(r.baseline>0.0)
        {
         r.rangeRatio=r.range/r.baseline;
         r.legRatio  =r.largestLeg/r.baseline;
        }

      r.baselineWarm=(nOut<MathMax(1,m_s.qualityBaselineN)); // informational only, see file header

      if(m_s.qualityMode==QM_GATES)
        {
         bool gMovement =(r.rangeAtr>=m_s.minRangeAtr) || (r.legAtr>=m_s.minLegAtr);
         bool gNotSpike =(r.impulseBarCount>=m_s.minImpulseBars);
         bool gConfirm  =(r.baseline<=0.0) || (r.rangeRatio>=m_s.minRangeRatio);
         r.pass=(gMovement && gNotSpike && gConfirm);
        }
      // SCORE (also computed in GATES mode, for the panel)
      double tLeg=(m_s.minLegAtr>0.0)    ? MathMin(1.0,r.legAtr/m_s.minLegAtr)        : 0.0;
      double tEff=(m_s.minEfficiency>0.0)? MathMin(1.0,r.efficiency/m_s.minEfficiency): 0.0;
      double tRB =(m_s.minRangeRatio>0.0 && r.baseline>0.0)
                  ? MathMin(1.0,r.rangeRatio/m_s.minRangeRatio) : 0.0;
      double tRA =(m_s.minRangeAtr>0.0)  ? MathMin(1.0,r.rangeAtr/m_s.minRangeAtr)    : 0.0;
      double wsum=m_s.wLeg+m_s.wEff+m_s.wRangeBase+m_s.wRangeAtr;
      if(wsum<=0.0) wsum=1.0;
      r.score=(m_s.wLeg*tLeg + m_s.wEff*tEff +
               m_s.wRangeBase*tRB + m_s.wRangeAtr*tRA)/wsum;

      if(m_s.qualityMode==QM_SCORE)
         r.pass=(r.score>=m_s.qualityScoreThreshold);

      r.state = r.pass ? "PASS" : "FAIL";

      // ingest for future baselines (AFTER using the prior median)
      if(ses==SESS_ASIA)   { Push(m_asia,r.range);  Push(m_asiaVol,(double)volSum); }
      if(ses==SESS_LONDON) { Push(m_lon, r.range);  Push(m_lonVol, (double)volSum); }
      if(ses==SESS_NY)     { Push(m_ny,  r.range);  Push(m_nyVol,  (double)volSum); }

      return(r);
     }

   SDiagQuality Diag() const
     {
      SDiagQuality d;
      d.baselineTarget=m_s.qualityBaselineN;
      d.asiaSamples  =ArraySize(m_asia);
      d.londonSamples=ArraySize(m_lon);
      d.nySamples    =ArraySize(m_ny);
      d.asiaBaseline  =Median(m_asia);
      d.londonBaseline=Median(m_lon);
      d.nyBaseline    =Median(m_ny);
      return(d);
     }
  };

//+------------------------------------------------------------------+
//| CSV header/row shared by T2c and the session labeler, so both     |
//| tools (and calibrate_quality.py) agree on column order without    |
//| duplicating the format string. Times are passed in pre-formatted  |
//| (Riyadh strings) since this module has no CTimeSessions of its own|
//+------------------------------------------------------------------+
string V2_QualityCsvHeader()
  {
   return("session,open_riyadh,close_riyadh,bars,range,atr,baseline,baseline_n,"
          "largest_leg,efficiency,impulse_bars,body_impulse_bars,max_bar_range_share,"
          "longest_run,run_ratio,volume_ratio,"
          "range_ratio,range_atr,leg_atr,leg_ratio,score,state,mode");
  }

string V2_QualityCsvRow(const SQualityResult &r,const int digits,
                        const string riyOpen,const string riyClose)
  {
   return(StringFormat(
      "%s,%s,%s,%d,%s,%s,%s,%d,%s,%.4f,%d,%d,%.4f,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%s,%s",
      V2_SessionName(r.session),riyOpen,riyClose,r.bars,
      DoubleToString(r.range,digits),DoubleToString(r.atr,digits),
      DoubleToString(r.baseline,digits),r.baselineN,
      DoubleToString(r.largestLeg,digits),r.efficiency,r.impulseBarCount,
      r.bodyImpulseCount,r.maxBarRangeShare,r.longestRun,r.runRatio,r.volumeRatio,
      r.rangeRatio,r.rangeAtr,r.legAtr,r.legRatio,r.score,r.state,r.mode));
  }

#endif // V2_SESSIONQUALITY_MQH

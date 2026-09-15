//+------------------------------------------------------------------+
//|                                                  RejectBreak.mqh  |
//|  P3 - the four sigma/ATR-relative primitives from spec §9.1, on   |
//|  closed bars, plus the Z2 "provisional lean" they feed and the    |
//|  ±2σ -> Extended transition flag.                                 |
//|                                                                   |
//|  rejectionAsSupport(bar,B):    low<=B+TouchTolSigma*sigma AND     |
//|                                close>=B+RejectCloseSigma*sigma AND|
//|                                (!RejectRequireWick OR             |
//|                                 lowerWick>=RejectWickMinFrac*range)|
//|  rejectionAsResistance(bar,B): high>=B-TouchTolSigma*sigma AND    |
//|                                close<=B-RejectCloseSigma*sigma AND|
//|                                (!RejectRequireWick OR             |
//|                                 upperWick>=RejectWickMinFrac*range)|
//|  breakUp(bar,B):   close>=B+BreakBufferSigma*sigma AND            |
//|                    (!BreakRequireMomentum OR bullBody>=BreakBodyATR*ATR)|
//|  breakDown(bar,B): close<=B-BreakBufferSigma*sigma AND            |
//|                    (!BreakRequireMomentum OR bearBody>=BreakBodyATR*ATR)|
//|                                                                   |
//|  Provisional lean (spec §8 Z2, informational only - the actual    |
//|  entry direction is whichever trigger fires first, per Triggers): |
//|   upper Z2 half (0 <= dSigma < band2Mult): rejSup@U1 -> lean LONG;|
//|                     brkDn@U1 (toward vwap) -> lean SHORT.         |
//|   lower Z2 half (-band2Mult < dSigma <= 0): rejRes@L1 -> lean     |
//|                     SHORT; brkUp@L1 (toward vwap) -> lean LONG.   |
//|  Lean persists (and its bar-counter grows) while price stays in   |
//|  Z2 without a new firing; resets to NONE the moment |dSigma|      |
//|  leaves the Z2 range in either direction.                         |
//|                                                                   |
//|  Extended-transition flag: breakUp(bar,U2) or breakDown(bar,L2) - |
//|  evaluated independently of the current zone (it structurally can|
//|  only ever be true on a bar whose close is already beyond ±2σ,    |
//|  i.e. a Z3 bar) - a momentum-confirmed cross into Extended, for   |
//|  display/confirmation alongside Zones.mqh's own reclassification. |
//|                                                                   |
//|  Deliberately does NOT depend on Zones.mqh: zone membership here  |
//|  is re-derived from dSigma directly, so this module stays pure    |
//|  and independently testable (per-module isolation convention).   |
//|                                                                   |
//|  Pure detection - never places orders.                           |
//+------------------------------------------------------------------+
#ifndef V2_REJECTBREAK_MQH
#define V2_REJECTBREAK_MQH

#include "V2Common.mqh"

struct SDiagRejectBreak
  {
   double      atr;
   string      firedPrimitive;   // "rejSup" | "rejRes" | "brkUp" | "brkDn" | "-"
   string      firedBand;        // "+1" | "-1" | "+2" | "-2" | "-"
   ENUM_DIR_V2 lean;             // provisional Z2 lean, DIR_NONE outside Z2
   int         leanBars;         // bars the current lean has been held (0 if none)
   bool        extendedTransition; // breakUp(U2) or breakDown(L2) fired this bar
  };

class CRejectBreak
  {
private:
   SSettingsV2      m_s;
   string           m_sym;
   int              m_atrHandle;
   ENUM_DIR_V2      m_lean;
   int              m_leanBars;
   SDiagRejectBreak m_diag;

   double LowerWick(const MqlRates &bar) const { return(MathMin(bar.open,bar.close)-bar.low); }
   double UpperWick(const MqlRates &bar) const { return(bar.high-MathMax(bar.open,bar.close)); }
   double Range(const MqlRates &bar)     const { return(bar.high-bar.low); }
   double BullBody(const MqlRates &bar)  const { return((bar.close>bar.open)?(bar.close-bar.open):0.0); }
   double BearBody(const MqlRates &bar)  const { return((bar.close<bar.open)?(bar.open-bar.close):0.0); }

   bool RejSupport(const MqlRates &bar,const double B,const double sigma) const
     {
      if(bar.low>B+m_s.touchTolSigma*sigma) return(false);
      if(bar.close<B+m_s.rejectCloseSigma*sigma) return(false);
      if(m_s.rejectRequireWick && LowerWick(bar)<m_s.rejectWickMinFrac*Range(bar)) return(false);
      return(true);
     }
   bool RejResistance(const MqlRates &bar,const double B,const double sigma) const
     {
      if(bar.high<B-m_s.touchTolSigma*sigma) return(false);
      if(bar.close>B-m_s.rejectCloseSigma*sigma) return(false);
      if(m_s.rejectRequireWick && UpperWick(bar)<m_s.rejectWickMinFrac*Range(bar)) return(false);
      return(true);
     }
   bool BreakUp(const MqlRates &bar,const double B,const double sigma,const double atr) const
     {
      if(bar.close<B+m_s.breakBufferSigma*sigma) return(false);
      if(m_s.breakRequireMomentum && BullBody(bar)<m_s.breakBodyAtr*atr) return(false);
      return(true);
     }
   bool BreakDown(const MqlRates &bar,const double B,const double sigma,const double atr) const
     {
      if(bar.close>B-m_s.breakBufferSigma*sigma) return(false);
      if(m_s.breakRequireMomentum && BearBody(bar)<m_s.breakBodyAtr*atr) return(false);
      return(true);
     }

public:
   void Init(const SSettingsV2 &s,const string sym)
     {
      m_s=s; m_sym=sym;
      m_atrHandle=(s.atrPeriod>0)?iATR(sym,s.tf,s.atrPeriod):INVALID_HANDLE;
      m_lean=DIR_NONE; m_leanBars=0;
      m_diag.atr=0; m_diag.firedPrimitive="-"; m_diag.firedBand="-";
      m_diag.lean=DIR_NONE; m_diag.leanBars=0; m_diag.extendedTransition=false;
     }
   void Deinit(){ if(m_atrHandle!=INVALID_HANDLE) IndicatorRelease(m_atrHandle); }

   double CurrentATR() const
     {
      if(m_atrHandle==INVALID_HANDLE) return(0.0);
      double a[]; ArraySetAsSeries(a,true);
      if(CopyBuffer(m_atrHandle,0,0,2,a)<1) return(0.0);
      return(a[0]);
     }

   //+--------------------------------------------------------------+
   //| Call once per newly CLOSED bar with that bar's OHLC and the    |
   //| AVWAP state for the same bar (vwap/sigma). dSigma = (close -   |
   //| vwap) / sigma - the caller (Zones.mqh consumer) already has    |
   //| this, passed straight through so zone math never drifts.       |
   //+--------------------------------------------------------------+
   SDiagRejectBreak Update(const MqlRates &bar,const double dSigma,
                          const double vwap,const double sigma)
     {
      SDiagRejectBreak d;
      double atr=CurrentATR();
      d.atr=atr;
      d.firedPrimitive="-"; d.firedBand="-"; d.extendedTransition=false;

      if(sigma<=0.0)
        {
         m_lean=DIR_NONE; m_leanBars=0;
         d.lean=DIR_NONE; d.leanBars=0;
         m_diag=d;
         return(d);
        }

      double u1=vwap+m_s.band1Mult*sigma, u2=vwap+m_s.band2Mult*sigma;
      double l1=vwap-m_s.band1Mult*sigma, l2=vwap-m_s.band2Mult*sigma;
      bool absIn2=(MathAbs(dSigma)<m_s.band2Mult);
      bool inZ2  =(MathAbs(dSigma)>=m_s.band1Mult && absIn2);
      bool upperSide=(dSigma>=0.0);

      ENUM_DIR_V2 newLean=DIR_NONE;
      bool leanFired=false;

      if(inZ2)
        {
         newLean=m_lean; // persists unless something fires this bar
         if(upperSide)
           {
            if(RejSupport(bar,u1,sigma))
              { newLean=DIR_LONG;  d.firedPrimitive="rejSup"; d.firedBand="+1"; leanFired=true; }
            else if(BreakDown(bar,u1,sigma,atr))
              { newLean=DIR_SHORT; d.firedPrimitive="brkDn";  d.firedBand="+1"; leanFired=true; }
           }
         else
           {
            if(RejResistance(bar,l1,sigma))
              { newLean=DIR_SHORT; d.firedPrimitive="rejRes"; d.firedBand="-1"; leanFired=true; }
            else if(BreakUp(bar,l1,sigma,atr))
              { newLean=DIR_LONG;  d.firedPrimitive="brkUp";  d.firedBand="-1"; leanFired=true; }
           }
        }

      // Extended-transition: independent of the Z2 gate above (structurally
      // mutually exclusive with it - see file header).
      if(upperSide && BreakUp(bar,u2,sigma,atr))
        {
         d.extendedTransition=true;
         if(!leanFired){ d.firedPrimitive="brkUp"; d.firedBand="+2"; }
        }
      else if(!upperSide && BreakDown(bar,l2,sigma,atr))
        {
         d.extendedTransition=true;
         if(!leanFired){ d.firedPrimitive="brkDn"; d.firedBand="-2"; }
        }

      if(newLean!=m_lean){ m_lean=newLean; m_leanBars=(newLean!=DIR_NONE)?1:0; }
      else if(m_lean!=DIR_NONE) m_leanBars++;

      d.lean=m_lean; d.leanBars=m_leanBars;
      m_diag=d;
      return(d);
     }

   SDiagRejectBreak Diag() const { return(m_diag); }
  };

#endif // V2_REJECTBREAK_MQH

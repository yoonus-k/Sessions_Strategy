//+------------------------------------------------------------------+
//|                                                        Zones.mqh  |
//|  P3 - classifies price vs the anchored VWAP + sigma bands into a  |
//|  zone, on CLOSED bars only.                                       |
//|                                                                   |
//|  d = price - vwap ; dSigma = d / sigma                            |
//|   Z1  |dSigma| <  band1Mult   direct / committed trend            |
//|   Z2  band1Mult <= |dSigma| < band2Mult   confirmation (contested)|
//|   Z3  |dSigma| >= band2Mult   extended / committed reversion      |
//|                                                                   |
//|  committedDir:                                                    |
//|   Z1 -> sign(d)   (above vwap = long-committed, below = short)    |
//|   Z3 -> -sign(d)  (above +2sigma -> reversion SHORT, and mirror)  |
//|   Z2 -> DIR_NONE  (NOT committed - contested, flip-enabled zone)  |
//|                                                                   |
//|  Z2 CONFIRMING: entering Z2 (from anywhere else) starts the state,|
//|  confirmBars increments once per bar while price stays in Z2 and  |
//|  wraps back to 1 after ConfirmStateMaxBars (spec: "hold <=12      |
//|  bars"); leaving Z2 (to Z1 or Z3) clears it immediately. Actually  |
//|  ending the CONFIRMING episode (session end / a trigger firing)   |
//|  is a ZoneEngine (C3d) concern, not this pure classifier's.       |
//|                                                                   |
//|  Suppressed (ZONE_NONE, no direction, no confirming) whenever the |
//|  caller's AVWAP isn't ready or sigma<=0 - never guesses through   |
//|  warm-up.                                                         |
//|                                                                   |
//|  Pure classification - never places orders.                      |
//+------------------------------------------------------------------+
#ifndef V2_ZONES_MQH
#define V2_ZONES_MQH

#include "V2Common.mqh"

struct SDiagZones
  {
   bool            ready;         // false during AVWAP warm-up / sigma<=0 -> everything else is 0/NONE
   double          d;             // price - vwap, in price units
   double          dSigma;        // d / sigma
   ENUM_ZONE_V2    zone;          // ZONE_NONE while !ready, else Z1/Z2/Z3
   ENUM_DIR_V2     committedDir;  // Z1: trend dir. Z3: reversion dir. Z2/NONE: DIR_NONE
   bool            confirming;    // true while in a Z2 CONFIRMING episode
   int             confirmBars;   // 1..confirmStateMaxBars, wraps; 0 when not confirming
   int             confirmMax;    // echo of the setting, for the dashboard
  };

class CZones
  {
private:
   SSettingsV2  m_s;
   ENUM_ZONE_V2 m_prevZone;
   bool         m_confirming;
   int          m_confirmBars;
   SDiagZones   m_diag;

public:
   void Init(const SSettingsV2 &s)
     {
      m_s=s;
      m_prevZone=ZONE_NONE;
      m_confirming=false; m_confirmBars=0;
      m_diag.ready=false; m_diag.d=0; m_diag.dSigma=0; m_diag.zone=ZONE_NONE;
      m_diag.committedDir=DIR_NONE; m_diag.confirming=false; m_diag.confirmBars=0;
      m_diag.confirmMax=m_s.confirmStateMaxBars;
     }

   //+--------------------------------------------------------------+
   //| Call once per newly CLOSED bar with that bar's close price and|
   //| the AVWAP state as of the same bar (Compute() already run).   |
   //+--------------------------------------------------------------+
   SDiagZones Update(const bool avwapReady,const double price,
                     const double vwap,const double sigma)
     {
      SDiagZones d;
      d.confirmMax=m_s.confirmStateMaxBars;

      if(!avwapReady || sigma<=0.0)
        {
         d.ready=false; d.d=0; d.dSigma=0; d.zone=ZONE_NONE; d.committedDir=DIR_NONE;
         d.confirming=false; d.confirmBars=0;
         m_prevZone=ZONE_NONE; m_confirming=false; m_confirmBars=0;
         m_diag=d;
         return(d);
        }

      d.ready=true;
      d.d=price-vwap;
      d.dSigma=d.d/sigma;
      double absS=MathAbs(d.dSigma);

      if(absS<m_s.band1Mult)      d.zone=ZONE_Z1;
      else if(absS<m_s.band2Mult) d.zone=ZONE_Z2;
      else                        d.zone=ZONE_Z3;

      if(d.zone==ZONE_Z1)
         d.committedDir=(d.d>0.0)?DIR_LONG:(d.d<0.0)?DIR_SHORT:DIR_NONE;
      else if(d.zone==ZONE_Z3)
         d.committedDir=(d.d>0.0)?DIR_SHORT:(d.d<0.0)?DIR_LONG:DIR_NONE;
      else
         d.committedDir=DIR_NONE;

      if(d.zone==ZONE_Z2)
        {
         if(m_prevZone!=ZONE_Z2){ m_confirming=true; m_confirmBars=1; }
         else
           {
            m_confirmBars++;
            if(m_confirmBars>m_s.confirmStateMaxBars) m_confirmBars=1;
           }
        }
      else
        {
         m_confirming=false; m_confirmBars=0;
        }

      d.confirming =m_confirming;
      d.confirmBars=m_confirmBars;

      m_prevZone=d.zone;
      m_diag=d;
      return(d);
     }

   SDiagZones Diag() const { return(m_diag); }
  };

string V2_StanceText(const SDiagZones &d)
  {
   if(!d.ready) return("suppressed (AVWAP warm-up)");
   if(d.zone==ZONE_Z1) return(StringFormat("committed %s",V2_DirName(d.committedDir)));
   if(d.zone==ZONE_Z3) return(StringFormat("reversion %s",V2_DirName(d.committedDir)));
   return(StringFormat("contested%s",d.confirming?StringFormat(" (CONFIRMING %d/%d)",d.confirmBars,d.confirmMax):""));
  }

#endif // V2_ZONES_MQH

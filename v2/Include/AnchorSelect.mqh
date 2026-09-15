//+------------------------------------------------------------------+
//|                                                 AnchorSelect.mqh  |
//|  P2 - turns SessionQuality + ZigZag into a chosen VWAP anchor.    |
//|                                                                   |
//|  At a TRADE session open: walk backward through prior sessions   |
//|  (any role - Asia/London/NY all count as anchor SOURCES) within   |
//|  MaxAnchorLookbackHours. Skip anything SessionQuality did not     |
//|  PASS. For the first (most recent) PASS, resolve its anchor pivot |
//|  in two tiers (2026-09-14, redesign #2):                          |
//|                                                                   |
//|    Tier 1 - INSIDE the session. If any confirmed ZigZag pivot     |
//|    falls in [session.open, session.close), take the newest one.   |
//|                                                                   |
//|    Tier 2 - nearest BOUNDARY pivot, only if tier 1 finds nothing. |
//|    Look both directions within AnchorFlexMinutes of the session:  |
//|    the newest pivot BEFORE open, and the oldest pivot AFTER close |
//|    (i.e. the one closest to each boundary). Take whichever one    |
//|    exists; if both exist, take whichever is closer in time to its |
//|    boundary (ties favour the BEFORE side, arbitrary but            |
//|    deterministic - same "first side wins" convention as           |
//|    ZoneEngine's LONG-tie-break).                                  |
//|                                                                   |
//|  If that PASS session has no usable pivot under either tier, it   |
//|  cannot anchor - keep walking further back (a session with no      |
//|  swing at all is unusable, but that doesn't disqualify an older    |
//|  PASS session). If nothing usable turns up within the lookback -> |
//|  skip (no anchor this session).                                   |
//|                                                                   |
//|  Why tiers, not one window: the original design (see git history  |
//|  for the 2026-09-14 #1 fix) searched ONE window,                  |
//|  [session.open, session.close+flex], and always took the NEWEST   |
//|  pivot in it. That silently favoured a late, low-conviction        |
//|  post-close pivot over an earlier, more decisive one from the      |
//|  session itself purely because it was more recent - and it never   |
//|  looked BEFORE the session's own open at all, so a pivot forming   |
//|  minutes before a session opens (often the actual swing that       |
//|  defines the session) was invisible to the search. Reported by     |
//|  the user via a screenshot: a London session's obvious pre-open    |
//|  swing high was skipped in favour of an unrelated pivot ~1h into   |
//|  the post-close tail, chosen only because it was newer.            |
//|                                                                   |
//|  This module owns NO detection of its own: it only remembers      |
//|  SessionQuality results the caller hands it (RecordSession, once  |
//|  per completed session, from the SAME EvaluateCompleted() call    |
//|  the caller already made for its own purposes) and queries a      |
//|  CZigZag the caller keeps refreshed. That keeps SessionQuality's  |
//|  once-per-session baseline ingestion single-owner.                |
//|                                                                   |
//|  Pure selection - never places orders.                           |
//+------------------------------------------------------------------+
#ifndef V2_ANCHORSELECT_MQH
#define V2_ANCHORSELECT_MQH

#include "V2Common.mqh"
#include "ZigZag.mqh"
#include "SessionQuality.mqh"

#define ANCHORSEL_HIST_CAP 256   // ~ a few weeks of Asia+London+NY sessions

struct SAnchorCandidate
  {
   ENUM_SESSION_V2 session;
   datetime        openTime;
   datetime        closeTime;
   bool            pass;
   string          state;
   double          score;
   double          hoursBack;   // filled in by Select(), vs the trade-session open resolved
  };

struct SAnchorResult
  {
   bool            done;          // Select() has run at least once
   bool            found;         // an anchor was chosen
   bool            skip;          // true whenever !found -> NO ANCHOR, skip the session
   ENUM_SESSION_V2 tradeSession;
   datetime        tradeOpenTime;
   ENUM_SESSION_V2 srcSession;    // the chosen prior (source) session
   datetime        srcOpenTime;
   datetime        srcCloseTime;
   double          srcScore;
   double          hoursBack;
   datetime        anchorTime;    // chosen ZigZag pivot bar time
   double          anchorPrice;
   bool            anchorIsHigh;
   string          anchorTier;    // "INSIDE" / "BEFORE" / "AFTER" - which tier resolved the pivot
  };

struct SDiagAnchorSelect
  {
   SAnchorCandidate scanned[32];  // newest-first, within the lookback window
   int              scannedCount;
   SAnchorResult    result;
  };

class CAnchorSelect
  {
private:
   SSettingsV2       m_s;
   SAnchorCandidate  m_hist[];    // chronological, oldest-first
   int               m_histN;
   SDiagAnchorSelect m_diag;

   void PushHistory(const SAnchorCandidate &c)
     {
      int n=ArraySize(m_hist);
      if(n<ANCHORSEL_HIST_CAP){ ArrayResize(m_hist,n+1); m_hist[n]=c; m_histN=n+1; return; }
      for(int i=1;i<ANCHORSEL_HIST_CAP;i++) m_hist[i-1]=m_hist[i];
      m_hist[ANCHORSEL_HIST_CAP-1]=c; m_histN=ANCHORSEL_HIST_CAP;
     }

public:
   void Init(const SSettingsV2 &s)
     {
      m_s=s;
      ArrayResize(m_hist,0); m_histN=0;
      m_diag.scannedCount=0;
      m_diag.result.done=false; m_diag.result.found=false; m_diag.result.skip=true;
     }

   //--- Call once per session, right after the caller's own
   //--- SessionQuality.EvaluateCompleted() returns an evaluated result
   //--- (any session role - London counts, it's an anchor source).
   void RecordSession(const SQualityResult &q)
     {
      if(!q.evaluated) return;
      SAnchorCandidate c;
      c.session=q.session; c.openTime=q.openTime; c.closeTime=q.closeTime;
      c.pass=q.pass; c.state=q.state; c.score=q.score; c.hoursBack=0.0;
      PushHistory(c);
     }

   int HistoryCount() const { return(m_histN); }

   //+--------------------------------------------------------------+
   //| Two-tier pivot resolution for one PASS source session c, per   |
   //| the header comment. Returns false if neither tier finds a      |
   //| usable confirmed pivot.                                        |
   //+--------------------------------------------------------------+
   bool ResolvePivot(const SAnchorCandidate &c,const CZigZag &zz,
                     SZZPivot &piv,string &tier) const
     {
      // Tier 1 - inside the session itself: newest confirmed pivot in [open, close).
      if(zz.LastSignificantIn(c.openTime,c.closeTime-1,piv)) { tier="INSIDE"; return(true); }

      // Tier 2 - nearest boundary pivot, searched both directions.
      datetime flexSec=(datetime)(m_s.anchorFlexMin*60.0);
      SZZPivot before,after;
      bool hasBefore=zz.LastSignificantIn(c.openTime-flexSec,c.openTime-1,before);
      bool hasAfter =zz.FirstSignificantIn(c.closeTime,c.closeTime+flexSec,after);
      if(!hasBefore && !hasAfter) return(false);
      if(hasBefore && !hasAfter)      { piv=before; tier="BEFORE"; return(true); }
      if(hasAfter  && !hasBefore)     { piv=after;  tier="AFTER";  return(true); }

      double distBefore=(double)(c.openTime-before.time);
      double distAfter =(double)(after.time-c.closeTime);
      if(distBefore<=distAfter) { piv=before; tier="BEFORE"; }
      else                      { piv=after;  tier="AFTER";  }
      return(true);
     }

   SAnchorResult Select(const ENUM_SESSION_V2 tradeSes,const datetime tradeOpenBroker,
                        const CZigZag &zz)
     {
      SAnchorResult r;
      r.done=true; r.found=false; r.skip=true;
      r.tradeSession=tradeSes; r.tradeOpenTime=tradeOpenBroker;
      r.srcSession=SESS_NONE; r.srcOpenTime=0; r.srcCloseTime=0; r.srcScore=0;
      r.hoursBack=0; r.anchorTime=0; r.anchorPrice=0; r.anchorIsHigh=false; r.anchorTier="";

      m_diag.scannedCount=0;

      for(int i=m_histN-1;i>=0;i--)
        {
         SAnchorCandidate c=m_hist[i];
         if(c.closeTime>tradeOpenBroker) continue;           // not completed before this open
         double hrsBack=(double)(tradeOpenBroker-c.closeTime)/3600.0;
         if(hrsBack>m_s.maxAnchorLookbackHr) break;           // everything older is even further back

         c.hoursBack=hrsBack;
         if(m_diag.scannedCount<32) m_diag.scanned[m_diag.scannedCount++]=c;

         if(!c.pass) continue;

         SZZPivot piv; string tier;
         if(!ResolvePivot(c,zz,piv,tier)) continue;          // PASS but no usable swing - keep walking

         r.found=true; r.skip=false;
         r.srcSession=c.session; r.srcOpenTime=c.openTime; r.srcCloseTime=c.closeTime;
         r.srcScore=c.score; r.hoursBack=hrsBack;
         r.anchorTime=piv.time; r.anchorPrice=piv.price; r.anchorIsHigh=piv.isHigh;
         r.anchorTier=tier;
         break;
        }

      m_diag.result=r;
      return(r);
     }

   SDiagAnchorSelect Diag() const { return(m_diag); }
  };

#endif // V2_ANCHORSELECT_MQH

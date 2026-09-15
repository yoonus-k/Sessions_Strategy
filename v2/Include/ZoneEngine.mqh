//+------------------------------------------------------------------+
//|                                                    ZoneEngine.mqh  |
//|  P3 - the per-bar decision resolver. REDESIGNED 2026-09-15 per    |
//|  explicit user correction: the regime (continuation / reversal /  |
//|  confirmation) is captured ONCE, on the first AVWAP-ready closed   |
//|  bar of the trade session ("when the session opens"), and held     |
//|  FIXED for the rest of the session - it is never re-derived from   |
//|  the live zone again, even if price later drifts into a different  |
//|  band. This replaces the original spec text (§8/§11/§14/§15/§18),  |
//|  which called for re-evaluating the zone on every closed bar until |
//|  the first trade opened; the user identified that as a             |
//|  misunderstanding of the intended design and asked for the lock to  |
//|  happen at session open instead. See doc/Anchored_VWAP_Sessions_   |
//|  EA_Spec.md's "Regime lock (2026-09-15 correction)" section.       |
//|                                                                   |
//|  Session-open zone -> regime (captured once, held all session):   |
//|    Z1 -> CONTINUATION: regimeDir = that bar's committedDir (trend) |
//|          hunt ONLY regimeDir's trigger, all session.               |
//|    Z3 -> REVERSAL:     regimeDir = that bar's committedDir         |
//|          (reversion). hunt ONLY regimeDir's trigger, all session.  |
//|    Z2 -> CONFIRMATION: NO direction lock at all. Hunt BOTH          |
//|          directions every bar, first valid trigger (either side)   |
//|          wins, for the WHOLE session - not just while price is     |
//|          literally still inside the Z2 band. This is the user's    |
//|          explicit answer for the Z2-at-open case: "there is no     |
//|          locking rigid dir, it's like confirmation, whoever wins   |
//|          we open a trade with it."                                 |
//|                                                                   |
//|  If the session-open bar's own d==0.0 exactly (price exactly AT    |
//|  vwap, zone Z1/Z3 but committedDir momentarily DIR_NONE), the      |
//|  regime capture is deferred to the next ready bar rather than      |
//|  locking a meaningless NONE direction.                             |
//|                                                                   |
//|  POST-entry: once the caller's sessionDirection lock (TradeManagerV2|
//|  after the first trade) is non-NONE, THAT takes precedence over    |
//|  everything above - only that direction's trigger is ever checked. |
//|  This part is unchanged from before: it governs re-entries          |
//|  (2nd try, same direction only, only after SL), a separate concern  |
//|  from the PRE-entry regime lock this file now owns.                |
//|                                                                   |
//|  'sessionDirection' stays a CALLER-supplied parameter (TradeManager |
//|  V2 owns that lock). The regime lock, by contrast, is now state    |
//|  THIS class owns internally (m_regimeZone/m_regimeDir) - it has no |
//|  other legitimate owner, since it must persist bar-to-bar within a |
//|  session but is entirely internal to "which direction(s) should    |
//|  Decide() hunt." Call ResetSession() on every session-key change,  |
//|  same pattern as CTriggers/CTradeManagerV2's own ResetSession().   |
//|                                                                   |
//|  Pure decision (never places orders) - but no longer a pure        |
//|  function of its arguments alone, unlike the original design; it   |
//|  now also depends on its own regime-lock state, by necessity.      |
//|                                                                   |
//|  CONFIRMATION-armed gate (2026-09-15, follow-up user correction):  |
//|  a session that opens in Z2 must NOT hunt triggers from wherever   |
//|  price happens to be inside Z2 - the user's screenshot showed a    |
//|  BOS taken at dSigma=-1.89, deep in Z2, having never come near      |
//|  VWAP at all. Fix: CONFIRMATION regime now requires price to first |
//|  touch Z1 (close OR wick) at least once this session - m_confirm   |
//|  Armed, a one-way latch, never re-arms/un-arms once set - before    |
//|  ANY trigger is hunted. Once armed, the existing hunt-both logic    |
//|  IS the "check how price reacts" step the user described: a BOS    |
//|  means it broke through with momentum, a Reversal+Momentum trigger |
//|  means it snapped back - no new detection needed, just the gate.    |
//|  Needs one extra input the class can't derive from SDiagZones      |
//|  alone (which only carries CLOSE-derived dSigma, no wick data):     |
//|  the caller passes touchedZ1ThisBar, a simple range-overlap test    |
//|  (barLow<=U1 && barHigh>=L1) computed from the same bar+vwap/sigma  |
//|  data it already fetches for RejectBreak::Update().                |
//+------------------------------------------------------------------+
#ifndef V2_ZONEENGINE_MQH
#define V2_ZONEENGINE_MQH

#include "V2Common.mqh"
#include "Zones.mqh"
#include "RejectBreak.mqh"
#include "Triggers.mqh"

struct SEngineDecision
  {
   bool           take;
   ENUM_DIR_V2    direction;
   bool           isFlip;
   ENUM_ZONE_V2   zone;          // the LIVE zone this bar (display only - no longer drives hunting)
   ENUM_DIR_V2    lean;
   string         triggerType;   // "BOS" | "REV" | "-"
   STriggerEvent  trigger;       // the winning trigger (valid only when take==true)
   string         reason;
   ENUM_ZONE_V2   regimeZone;    // ZONE_NONE until locked; then Z1=continuation/Z2=confirmation/Z3=reversal
   ENUM_DIR_V2    regimeDir;     // the locked hunt direction (DIR_NONE for confirmation mode)
   bool           regimeLocked;  // has the session-open regime been captured yet
   bool           confirmArmed;  // CONFIRMATION regime only: has price touched Z1 yet this session
  };

class CZoneEngine
  {
private:
   SSettingsV2  m_s;
   ENUM_ZONE_V2 m_regimeZone;   // ZONE_NONE = not captured yet this session
   ENUM_DIR_V2  m_regimeDir;    // valid only when m_regimeZone==Z1 or Z3
   bool         m_confirmArmed; // CONFIRMATION regime only - one-way latch, see file header

   SEngineDecision Blank(const SDiagZones &zd,const SDiagRejectBreak &rb) const
     {
      SEngineDecision d;
      d.take=false; d.direction=DIR_NONE; d.isFlip=false;
      d.zone=zd.zone; d.lean=rb.lean; d.triggerType="-"; d.reason="";
      d.regimeZone=m_regimeZone; d.regimeDir=m_regimeDir; d.regimeLocked=(m_regimeZone!=ZONE_NONE);
      d.confirmArmed=m_confirmArmed;
      STriggerEvent none; none.valid=false; none.type="-"; none.dir=DIR_NONE;
      none.entryPrice=0; none.entryTime=0; none.protectedExtreme=0; none.legRange=0;
      none.barTime=0; none.legFromTime=0; none.legToTime=0;
      d.trigger=none;
      return(d);
     }

   //--- committed-direction hunt shared by CONTINUATION (Z1-locked) and REVERSAL (Z3-locked)
   SEngineDecision HuntCommitted(const SDiagZones &zd,const SDiagRejectBreak &rb,
                                 const STriggerEvent &trigLong,const STriggerEvent &trigShort,
                                 const ENUM_DIR_V2 want,const bool allowFlip,const string tag) const
     {
      SEngineDecision d=Blank(zd,rb);

      STriggerEvent t=(want==DIR_LONG)?trigLong:trigShort;
      if(t.valid)
        {
         d.take=true; d.direction=want; d.trigger=t; d.triggerType=t.type;
         d.reason=StringFormat("%s locked %s, %s trigger confirmed",tag,V2_DirName(want),t.type);
         return(d);
        }

      if(allowFlip)
        {
         STriggerEvent opp=(want==DIR_LONG)?trigShort:trigLong;
         if(opp.valid)
           {
            d.take=true; d.direction=(want==DIR_LONG)?DIR_SHORT:DIR_LONG; d.isFlip=true;
            d.trigger=opp; d.triggerType=opp.type;
            d.reason=StringFormat("%s flip (AllowFlip): locked %s never triggered, took opposing %s",
                                  tag,V2_DirName(want),opp.type);
            return(d);
           }
        }

      d.reason=StringFormat("%s locked %s, waiting for trigger",tag,V2_DirName(want));
      return(d);
     }

public:
   void Init(const SSettingsV2 &s)
     {
      m_s=s;
      m_regimeZone=ZONE_NONE; m_regimeDir=DIR_NONE; m_confirmArmed=false;
     }

   //--- call on every NEW trade-session occurrence (Asia/NY open, or leaving
   //--- one) - clears the regime lock so the next session captures its own,
   //--- fresh, at its own open. Mirrors every other v2 module's session-key
   //--- reset (CTriggers, CTradeManagerV2).
   void ResetSession()
     {
      m_regimeZone=ZONE_NONE; m_regimeDir=DIR_NONE; m_confirmArmed=false;
     }

   //+--------------------------------------------------------------+
   //| Call once per closed bar. trigLong/trigShort = the caller's    |
   //| CTriggers::Query(DIR_LONG)/Query(DIR_SHORT) results for THIS   |
   //| bar. sessionDirection = DIR_NONE until the caller's own trade   |
   //| management has locked one this session (post-entry, see file    |
   //| header) - takes precedence over the regime lock below when set. |
   //| touchedZ1ThisBar = did this bar's H/L range overlap the Z1 band |
   //| (barLow<=U1 && barHigh>=L1)? Only matters for the CONFIRMATION   |
   //| regime's arm gate - see file header.                            |
   //+--------------------------------------------------------------+
   SEngineDecision Decide(const ENUM_DIR_V2 sessionDirection,
                          const SDiagZones &zd,const SDiagRejectBreak &rb,
                          const STriggerEvent &trigLong,const STriggerEvent &trigShort,
                          const bool touchedZ1ThisBar=false)
     {
      if(!zd.ready)
        {
         SEngineDecision d=Blank(zd,rb);
         d.reason="AVWAP not ready (warm-up)";
         return(d);
        }

      // Capture the regime ONCE, on the first AVWAP-ready bar since the last
      // ResetSession() - i.e. "when the session opens" (practically the
      // session's own open bar, given the anchor pre-roll already warms
      // AVWAP up before the session starts). Deferred one bar if d==0.0
      // exactly (committedDir momentarily DIR_NONE) rather than locking a
      // meaningless direction.
      if(m_regimeZone==ZONE_NONE)
        {
         if(zd.zone==ZONE_Z1 && zd.committedDir!=DIR_NONE)
           { m_regimeZone=ZONE_Z1; m_regimeDir=zd.committedDir; }
         else if(zd.zone==ZONE_Z3 && zd.committedDir!=DIR_NONE)
           { m_regimeZone=ZONE_Z3; m_regimeDir=zd.committedDir; }
         else if(zd.zone==ZONE_Z2)
           { m_regimeZone=ZONE_Z2; m_regimeDir=DIR_NONE; }
        }

      if(sessionDirection!=DIR_NONE)
        {
         SEngineDecision d=Blank(zd,rb);
         STriggerEvent t=(sessionDirection==DIR_LONG)?trigLong:trigShort;
         if(t.valid)
           {
            d.take=true; d.direction=sessionDirection; d.trigger=t; d.triggerType=t.type;
            d.reason=StringFormat("locked %s, %s trigger confirmed",V2_DirName(sessionDirection),t.type);
           }
         else
            d.reason=StringFormat("locked %s, waiting for a %s trigger",
                                  V2_DirName(sessionDirection),V2_DirName(sessionDirection));
         return(d);
        }

      if(m_regimeZone==ZONE_NONE)
        {
         SEngineDecision d=Blank(zd,rb);
         d.reason="regime not yet captured (waiting for a non-zero d)";
         return(d);
        }

      if(m_regimeZone==ZONE_Z1)
         return(HuntCommitted(zd,rb,trigLong,trigShort,m_regimeDir,m_s.allowFlipInDirectZone,"CONTINUATION"));

      if(m_regimeZone==ZONE_Z3)
         return(HuntCommitted(zd,rb,trigLong,trigShort,m_regimeDir,m_s.allowFlipInExtendedZone,"REVERSAL"));

      // CONFIRMATION regime (session opened in Z2) - contested. Gate: must
      // touch Z1 (close or wick) at least once this session before ANY
      // trigger is hunted - see file header. One-way latch.
      if(!m_confirmArmed && (zd.zone==ZONE_Z1 || touchedZ1ThisBar))
         m_confirmArmed=true;

      if(!m_confirmArmed)
        {
         SEngineDecision d=Blank(zd,rb);
         d.reason="CONFIRMATION regime: waiting for price to enter Z1 (close or wick) before hunting triggers";
         return(d);
        }

      // Armed: hunt BOTH directions every bar, for the whole rest of the
      // session, regardless of where price wanders afterward. First valid
      // trigger wins.
      // Same-bar dual-fire (both long and short trigger together) is a rare
      // edge case the spec doesn't resolve explicitly; LONG wins the tie,
      // documented here rather than left implicit.
      SEngineDecision d=Blank(zd,rb);
      ENUM_DIR_V2 dir=DIR_NONE; STriggerEvent t;
      if(trigLong.valid)      { dir=DIR_LONG;  t=trigLong;  }
      else if(trigShort.valid){ dir=DIR_SHORT; t=trigShort; }

      if(dir!=DIR_NONE)
        {
         d.take=true; d.direction=dir; d.trigger=t; d.triggerType=t.type;
         d.isFlip=(rb.lean!=DIR_NONE && dir!=rb.lean);
         d.reason=StringFormat("CONFIRMATION %s trigger %s (lean %s)%s",V2_DirName(dir),t.type,
                               V2_DirName(rb.lean),d.isFlip?" -> FLIP":"");
        }
      else
         d.reason=StringFormat("CONFIRMATION, lean %s%s, no trigger yet",V2_DirName(rb.lean),
                               (rb.lean!=DIR_NONE)?StringFormat(" (%d bars)",rb.leanBars):"");
      return(d);
     }
  };

#endif // V2_ZONEENGINE_MQH

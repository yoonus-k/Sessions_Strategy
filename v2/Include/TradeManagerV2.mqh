//+------------------------------------------------------------------+
//|                                              TradeManagerV2.mqh  |
//|  P4 - the only module in v2 that places orders (spec Sec11).      |
//|  One position at a time, one MagicNumber, single slot (v2 is      |
//|  "one trade per session" - v1's multi-slot SOpenPos machinery is  |
//|  overkill here and deliberately not reused).                      |
//|                                                                   |
//|  Reused verbatim from v1 (see [[trading-ea-build-conventions]]):  |
//|   - retcode+recovery discipline: after Buy/Sell, if the result    |
//|     deal doesn't resolve to a position id, FindOwnRecentPosition  |
//|     scans PositionsTotal() for a same-magic/symbol/type/volume    |
//|     position opened in the last ~2s - MT5 has returned false+     |
//|     retcode 0 for an order the server actually placed; a false    |
//|     OrderSend/trade.Buy return with a live position must still be |
//|     adopted, never silently dropped.                              |
//|   - [SS]->[V2] journal: every open/fail/close prints AND Alert()s |
//|     (skips print but don't Alert - matches v1's SKIPPED style).   |
//|                                                                   |
//|  Direction lock: the first successful open sets sessionDirection, |
//|  immutable until ResetSession() (caller calls this on a NEW trade |
//|  -session occurrence, same pattern as every other v2 module's     |
//|  session-key-change reset).                                       |
//|                                                                   |
//|  Close detection is POLLED (PollClosed(), call every tick) rather |
//|  than OnTradeTransaction, matching this codebase's established    |
//|  poll-don't-event convention (v1's BiasPanel clicks). Win/loss    |
//|  and the SL-vs-other reason come from the closing deal's own      |
//|  DEAL_REASON/DEAL_PROFIT - not a guess.                           |
//+------------------------------------------------------------------+
#ifndef V2_TRADEMANAGERV2_MQH
#define V2_TRADEMANAGERV2_MQH

#include <Trade\Trade.mqh>
#include "V2Common.mqh"
#include "RiskV2.mqh"

struct SPositionRecordV2
  {
   bool        open;
   long        posId;
   ENUM_DIR_V2 dir;
   double      entry, sl, tp, lots;
   double      r;            // |entry-origSl| at open time - fixed, used as the breakeven trigger unit
  };

struct SCloseEventV2
  {
   bool   valid;
   long   posId;
   string reason;      // "TP" | "SL" | "FORCE_CLOSE" | "OTHER"
   double closePrice;
   double netProfit;   // profit+swap+commission
  };

struct SDiagTradeManager
  {
   ENUM_DIR_V2 sessionDirection;
   int         tries;
   int         maxTries;
   bool        isOpen;
   long        posId;
   double      entry, sl, tp, lots;
   bool        sessionClosed;   // a win closed the session (AllowReentryAfterWin=false)
   bool        lastCloseWasSl;
   bool        beApplied;       // SL already moved to entry on the current/last position
   string      lastAction;
  };

class CTradeManagerV2
  {
private:
   SSettingsV2 m_s;
   string      m_sym;
   CTrade      m_trade;

   ENUM_DIR_V2      m_sessionDirection;
   int              m_tries;
   bool             m_sessionClosed;
   bool             m_lastCloseWasSl;
   SPositionRecordV2 m_pos;
   string           m_lastAction;
   bool             m_forceCloseInFlight;
   SCloseEventV2    m_closeEvent;
   bool             m_beApplied;      // one-way latch: SL already moved to entry this trade
   bool             m_beFailLogged;   // suppress repeat-print spam when PositionModify keeps rejecting

   ulong FindOwnRecentPosition(const bool isBuy,const double lots,const datetime since) const
     {
      long want=isBuy?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
      for(int i=PositionsTotal()-1;i>=0;i--)
        {
         ulong t=PositionGetTicket(i);
         if(t==0) continue;
         if(m_pos.open && (long)t==m_pos.posId) continue; // already ours
         if(PositionGetInteger(POSITION_MAGIC)!=m_s.magic) continue;
         if(PositionGetString(POSITION_SYMBOL)!=m_sym) continue;
         if(PositionGetInteger(POSITION_TYPE)!=want) continue;
         if((datetime)PositionGetInteger(POSITION_TIME)<since) continue;
         if(MathAbs(PositionGetDouble(POSITION_VOLUME)-lots)>0.00001) continue;
         return(t);
        }
      return(0);
     }

public:
   void Init(const SSettingsV2 &s,const string sym)
     {
      m_s=s; m_sym=sym;
      m_trade.SetExpertMagicNumber(s.magic);
      m_trade.SetDeviationInPoints(s.maxSlippagePoints);
      m_trade.SetTypeFillingBySymbol(sym);
      ResetSession();
     }

   //--- call on every NEW trade-session occurrence (Asia/NY open, or
   //--- leaving one) - mirrors every other v2 module's session-key reset
   //--- CRITICAL (2026-09-15 bug fix): do NOT touch m_pos/m_beApplied/
   //--- m_beFailLogged/m_forceCloseInFlight/m_closeEvent while a position
   //--- is still open. A session-key change can land on the SAME tick
   //--- ForceCloseIfDue() just sent a close order on - PollClosed() only
   //--- runs once, at the TOP of OnTick, before ForceCloseIfDue() executes
   //--- later that same tick - so blindly wiping m_pos.open here orphans
   //--- the position: PollClosed()'s own `if(!m_pos.open) return` guard
   //--- means it will never look for that position's close deal again, so
   //--- ConsumeCloseEvent()/OnClose() never fire for it. Verified on a
   //--- 2020-2026 XAUUSD run: EVERY force-closed trade (671 of 2085, 32%)
   //--- was silently orphaned this way, surviving only as a garbage
   //--- "still open" record that AnalyticsV2's FinalizeOpenAsEndOfTest()
   //--- later closed using the FINAL test price/date - years after the
   //--- trade's real close for the older ones - corrupting net_r into the
   //--- thousands and skewing every aggregate stat derived from the CSV.
   //--- Leaving m_pos untouched here lets PollClosed() finish tracking it
   //--- to its REAL close (the force-close resolving, or its own SL/TP) on
   //--- a later tick; CanOpenNew() already blocks a new open the whole
   //--- time since it checks m_pos.open first, so this costs nothing.
   void ResetSession()
     {
      m_sessionDirection=DIR_NONE; m_tries=0; m_sessionClosed=false; m_lastCloseWasSl=false;
      m_lastAction="";
      if(!m_pos.open)
        {
         m_pos.posId=0; m_pos.dir=DIR_NONE;
         m_pos.entry=0; m_pos.sl=0; m_pos.tp=0; m_pos.lots=0; m_pos.r=0;
         m_forceCloseInFlight=false;
         m_closeEvent.valid=false;
         m_beApplied=false; m_beFailLogged=false;
        }
     }

   bool        HasOpenPosition()   const { return(m_pos.open); }
   ENUM_DIR_V2 SessionDirection()  const { return(m_sessionDirection); }
   int         Tries()             const { return(m_tries); }

   bool CanOpenNew() const
     {
      if(m_pos.open) return(false);
      if(m_sessionClosed) return(false);
      if(m_tries>=MathMax(1,m_s.maxTriesPerSession)) return(false);
      if(m_tries>0 && m_s.secondTryOnlyAfterSl && !m_lastCloseWasSl) return(false);
      return(true);
     }

   //+--------------------------------------------------------------+
   //| Places a market order for risk.dir/lots/sl/tp. Returns true    |
   //| only once a real position is confirmed open (fresh or          |
   //| recovered). risk.entry is informational only - the actual fill |
   //| price is whatever the market gives; SL/TP are sent as-is.      |
   //+--------------------------------------------------------------+
   bool TryOpen(const SRiskCalc &risk,const string comment)
     {
      if(!risk.valid)
        {
         m_lastAction=StringFormat("[V2] SKIPPED (%s): %s",V2_DirName(risk.dir),risk.reason);
         Print(m_lastAction);
         return(false);
        }

      long spreadPts=SymbolInfoInteger(m_sym,SYMBOL_SPREAD);
      if(m_s.maxSpreadPoints>0 && spreadPts>m_s.maxSpreadPoints)
        {
         m_lastAction=StringFormat("[V2] SKIPPED (%s): spread %d pts > max %d",
                     V2_DirName(risk.dir),(int)spreadPts,m_s.maxSpreadPoints);
         Print(m_lastAction);
         return(false);
        }

      bool     isBuy=(risk.dir==DIR_LONG);
      datetime sentAt=TimeCurrent();
      bool     ok=isBuy?m_trade.Buy (risk.lots,m_sym,0.0,risk.sl,risk.tp,comment)
                       :m_trade.Sell(risk.lots,m_sym,0.0,risk.sl,risk.tp,comment);

      long posId=0;
      if(ok)
        {
         ulong deal=m_trade.ResultDeal();
         if(HistoryDealSelect(deal)) posId=(long)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
        }
      if(posId==0)
        {
         ulong found=FindOwnRecentPosition(isBuy,risk.lots,sentAt-2);
         if(found!=0)
           {
            posId=(long)found;
            m_lastAction=StringFormat("[V2] MARKET %s RECOVERED: #%I64u exists despite retcode=%d",
                        V2_DirName(risk.dir),found,m_trade.ResultRetcode());
            Print(m_lastAction);
           }
        }
      if(posId==0)
        {
         m_lastAction=StringFormat("[V2] MARKET %s FAILED: retcode=%d %s",
                     V2_DirName(risk.dir),m_trade.ResultRetcode(),m_trade.ResultRetcodeDescription());
         Print(m_lastAction);
         Alert(StringFormat("V2: MARKET %s FAILED - %s",V2_DirName(risk.dir),m_trade.ResultRetcodeDescription()));
         return(false);
        }

      if(!PositionSelectByTicket((ulong)posId)) { /* adopted anyway; entry below uses risk values */ }
      m_pos.open=true; m_pos.posId=posId; m_pos.dir=risk.dir;
      m_pos.entry=risk.entry; m_pos.sl=risk.sl; m_pos.tp=risk.tp; m_pos.lots=risk.lots;
      m_pos.r=MathAbs(risk.entry-risk.sl);
      m_beApplied=false; m_beFailLogged=false;
      m_tries++;
      if(m_sessionDirection==DIR_NONE) m_sessionDirection=risk.dir;

      m_lastAction=StringFormat("[V2] POSITION OPENED: %s #%I64d @ %s SL %s TP %s lots %.2f (try %d/%d)",
                  V2_DirName(risk.dir),posId,DoubleToString(risk.entry,_Digits),
                  DoubleToString(risk.sl,_Digits),DoubleToString(risk.tp,_Digits),
                  risk.lots,m_tries,MathMax(1,m_s.maxTriesPerSession));
      Print(m_lastAction);
      Alert(StringFormat("V2: OPENED %s #%I64d",V2_DirName(risk.dir),posId));
      return(true);
     }

   //+--------------------------------------------------------------+
   //| Call every tick. Detects the tracked position closing (SL/TP/  |
   //| force-close/manual) and updates win/SL-reason state from the   |
   //| closing deal itself.                                          |
   //+--------------------------------------------------------------+
   void PollClosed()
     {
      if(!m_pos.open) return;
      if(PositionSelectByTicket((ulong)m_pos.posId)) return; // still open

      if(!HistorySelect(0,TimeCurrent())) { m_pos.open=false; return; }
      int total=HistoryDealsTotal();
      double netProfit=0.0, closePrice=0.0; ENUM_DEAL_REASON reason=DEAL_REASON_CLIENT;
      for(int i=total-1;i>=0;i--)
        {
         ulong dt=HistoryDealGetTicket(i);
         if(dt==0) continue;
         if((long)HistoryDealGetInteger(dt,DEAL_POSITION_ID)!=m_pos.posId) continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
         netProfit=HistoryDealGetDouble(dt,DEAL_PROFIT)+HistoryDealGetDouble(dt,DEAL_SWAP)
                   +HistoryDealGetDouble(dt,DEAL_COMMISSION);
         closePrice=HistoryDealGetDouble(dt,DEAL_PRICE);
         reason=(ENUM_DEAL_REASON)HistoryDealGetInteger(dt,DEAL_REASON);
         break;
        }
      bool win=(netProfit>0.0);
      m_lastCloseWasSl=(reason==DEAL_REASON_SL);
      long closedId=m_pos.posId;
      bool wasForceClose=m_forceCloseInFlight;
      m_forceCloseInFlight=false;
      m_pos.open=false;

      string reasonTxt=(reason==DEAL_REASON_SL)?"SL":(reason==DEAL_REASON_TP)?"TP":
                       wasForceClose?"FORCE_CLOSE":
                       (reason==DEAL_REASON_CLIENT||reason==DEAL_REASON_EXPERT)?"MANUAL":"OTHER";
      m_closeEvent.valid=true; m_closeEvent.posId=closedId; m_closeEvent.reason=reasonTxt;
      m_closeEvent.closePrice=closePrice; m_closeEvent.netProfit=netProfit;

      m_lastAction=StringFormat("[V2] POSITION CLOSED: #%I64d %s  net %.2f  reason %s",
                  closedId,win?"WIN":"LOSS",netProfit,reasonTxt);
      Print(m_lastAction);
      Alert(StringFormat("V2: CLOSED #%I64d %s",closedId,win?"WIN":"LOSS"));

      if(win && !m_s.allowReentryAfterWin) m_sessionClosed=true;
     }

   //+--------------------------------------------------------------+
   //| Call every tick (after PollClosed). Once price has moved       |
   //| beTriggerR * R in the trade's favor - R fixed at the ORIGINAL  |
   //| entry->SL distance, never the post-BE one - moves the broker   |
   //| SL to breakeven (=entry) exactly once. A rejected modify (e.g. |
   //| broker stops-level) is retried silently on later ticks rather  |
   //| than being marked done, mirroring v1's AllOpenAtBreakEven      |
   //| lesson: never let the flag claim protection that isn't live.   |
   //+--------------------------------------------------------------+
   void ManageBreakEven()
     {
      if(!m_s.beEnabled || !m_pos.open || m_beApplied || m_pos.r<=0.0) return;

      double bid=SymbolInfoDouble(m_sym,SYMBOL_BID);
      double ask=SymbolInfoDouble(m_sym,SYMBOL_ASK);
      double price=(m_pos.dir==DIR_LONG)?bid:ask; // conservative side of the spread
      double moveNeeded=m_s.beTriggerR*m_pos.r;
      bool reached=(m_pos.dir==DIR_LONG)?(price-m_pos.entry>=moveNeeded)
                                        :(m_pos.entry-price>=moveNeeded);
      if(!reached) return;

      double newSl=NormalizeDouble(m_pos.entry,(int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS));
      bool improves=(m_pos.dir==DIR_LONG)?(newSl>m_pos.sl):(newSl<m_pos.sl);
      if(!improves) { m_beApplied=true; return; } // SL already at/beyond entry somehow

      if(!PositionSelectByTicket((ulong)m_pos.posId)) return;
      bool ok=m_trade.PositionModify((ulong)m_pos.posId,newSl,m_pos.tp);
      if(ok)
        {
         m_pos.sl=newSl;
         m_beApplied=true;
         m_lastAction=StringFormat("[V2] BREAK-EVEN: #%I64d SL -> %s (reached %.2fR)",
                     m_pos.posId,DoubleToString(newSl,_Digits),m_s.beTriggerR);
         Print(m_lastAction);
         Alert(StringFormat("V2: BREAK-EVEN #%I64d",m_pos.posId));
        }
      else if(!m_beFailLogged)
        {
         m_beFailLogged=true;
         Print(StringFormat("[V2] BREAK-EVEN MODIFY FAILED: #%I64d %s (will keep retrying)",
                     m_pos.posId,m_trade.ResultRetcodeDescription()));
        }
     }

   //--- one-shot: true (and fills ev) exactly once per close, then clears
   bool ConsumeCloseEvent(SCloseEventV2 &ev)
     {
      if(!m_closeEvent.valid) return(false);
      ev=m_closeEvent;
      m_closeEvent.valid=false;
      return(true);
     }

   //--- force-flat at session end; PollClosed() finalizes state next tick
   void ForceCloseIfDue(const bool isForceCloseTime)
     {
      if(!isForceCloseTime || !m_pos.open) return;
      m_forceCloseInFlight=true;
      bool ok=m_trade.PositionClose((ulong)m_pos.posId);
      if(!ok) m_forceCloseInFlight=false;
      m_lastAction=StringFormat("[V2] FORCE-CLOSE %s: #%I64d%s",
                  ok?"OK":"FAILED",m_pos.posId,ok?"":(" "+m_trade.ResultRetcodeDescription()));
      Print(m_lastAction);
      if(ok) Alert(StringFormat("V2: FORCE-CLOSED #%I64d",m_pos.posId));
     }

   SDiagTradeManager Diag() const
     {
      SDiagTradeManager d;
      d.sessionDirection=m_sessionDirection; d.tries=m_tries; d.maxTries=MathMax(1,m_s.maxTriesPerSession);
      d.isOpen=m_pos.open; d.posId=m_pos.posId;
      d.entry=m_pos.entry; d.sl=m_pos.sl; d.tp=m_pos.tp; d.lots=m_pos.lots;
      d.sessionClosed=m_sessionClosed; d.lastCloseWasSl=m_lastCloseWasSl;
      d.beApplied=m_beApplied;
      d.lastAction=m_lastAction;
      return(d);
     }
  };

#endif // V2_TRADEMANAGERV2_MQH

//+------------------------------------------------------------------+
//|                                                   AnalyticsV2.mqh  |
//|  P5 - one CSV row per closed trade (spec D2). Reuses v1's proven   |
//|  buffer-and-flush-in-OnDeinit design and a global trade_no counter |
//|  that never resets (unlike per-session counters).                 |
//|                                                                   |
//|  MAE/MFE are folded from COMPLETED-bar highs/lows via SampleBar() |
//|  (call once per new closed bar while a trade is open) - the same  |
//|  model-independent approach v1 uses, so the numbers don't change  |
//|  between tick models.                                             |
//|                                                                   |
//|  Measurement only - never gates a decision. The caller            |
//|  (SessionsStrategyV2.mq5) owns the actual trade lifecycle; this    |
//|  module just records what it's told.                              |
//+------------------------------------------------------------------+
#ifndef V2_ANALYTICSV2_MQH
#define V2_ANALYTICSV2_MQH

#include "V2Common.mqh"

struct STradeRecordV2
  {
   long     tradeNo;
   long     posId;
   string   tradeSession;
   datetime openTimeRaw;    // for barsHeld at close; openTimeStr is the display copy
   string   openTimeStr;
   string   closeTimeStr;
   string   anchorSession;
   double   anchorPivotPx;
   double   anchorHoursBack;
   double   sessionQualityScore;
   string   zoneAtEntry;
   string   leanAtEntry;
   string   triggerType;
   int      isFlip;
   int      confirmBars;
   string   direction;      // "LONG" | "SHORT"
   int      tryNumber;
   double   entry, sl, tp;
   double   rMoney;
   double   rrPlanned;
   string   exitReason;     // "TP" | "SL" | "FORCE_CLOSE" | "END_OF_TEST" | "UNKNOWN"
   double   netR;
   double   netPctBalance;
   double   maeR, mfeR;
   bool     open;
   double   worstPrice, bestPrice; // live excursion state, price terms
   //--- advanced analytics (2026-09-15, user request - diagnose why the
   //--- system is losing): entry-time context + close-time outcome detail
   double   dSigmaEntry;        // |price-vwap|/sigma, signed, at the trigger bar
   double   atrEntry;           // raw ATR at entry, for volatility context
   double   slAtrRatio;         // |entry-sl| / atrEntry - is this a wide or tight stop?
   double   spreadEntryPts;     // spread at entry, points - execution cost context
   int      entryMinsSinceOpen; // minutes since session open at entry - for EntryWindowMinutes tuning
   string   regimeAtEntry;      // "CONTINUATION"|"REVERSAL"|"CONFIRMATION"|"NOT_CAPTURED" (session-open regime lock, may differ from zoneAtEntry - the LIVE zone at the trigger bar)
   int      confirmArmedAtEntry;// CONFIRMATION regime only: was the Z1-touch arm-latch set yet
   int      beApplied;          // set at close: did ManageBreakEven() move SL to entry on this trade
   int      barsHeld;           // base-TF bars from open to close
   int      barsSampled;        // SampleBar() call counter - internal, drives mfeBar/maeBar
   int      mfeBar, maeBar;     // bars-from-open at which bestPrice/worstPrice was LAST set -
                                 // lets a post-hoc analysis re-simulate an alternate RR/TP: if
                                 // mfeBar < maeBar the favorable excursion came first (2026-09-15)
  };

class CAnalyticsV2
  {
private:
   bool               m_enabled;
   string             m_sym;
   ENUM_TIMEFRAMES    m_tf;
   STradeRecordV2     m_rec[];
   int                m_n;
   long               m_seq;
   string             m_csv[];

   void PushCsvRow(const STradeRecordV2 &r)
     {
      if(!m_enabled) return;
      int n=ArraySize(m_csv);
      ArrayResize(m_csv,n+1);
      int dg=(int)SymbolInfoInteger(m_sym,SYMBOL_DIGITS);
      m_csv[n]=StringFormat(
         "%d,%I64d,%s,%s,%s,%s,%s,%.2f,%.3f,%s,%s,%s,%d,%d,%s,%d,%s,%s,%s,%.2f,%.3f,%s,%.3f,%.4f,%.3f,%.3f,"
         "%.3f,%.5f,%.3f,%.1f,%d,%s,%d,%d,%d,%d,%d",
         r.tradeNo,r.posId,r.tradeSession,r.openTimeStr,r.closeTimeStr,
         r.anchorSession,DoubleToString(r.anchorPivotPx,dg),r.anchorHoursBack,r.sessionQualityScore,
         r.zoneAtEntry,r.leanAtEntry,r.triggerType,r.isFlip,r.confirmBars,
         r.direction,r.tryNumber,
         DoubleToString(r.entry,dg),DoubleToString(r.sl,dg),DoubleToString(r.tp,dg),
         r.rMoney,r.rrPlanned,r.exitReason,r.netR,r.netPctBalance,r.maeR,r.mfeR,
         r.dSigmaEntry,r.atrEntry,r.slAtrRatio,r.spreadEntryPts,r.entryMinsSinceOpen,
         r.regimeAtEntry,r.confirmArmedAtEntry,r.beApplied,r.barsHeld,r.mfeBar,r.maeBar);
     }

public:
   void Init(const string sym,const bool enabled,const ENUM_TIMEFRAMES tf)
     {
      m_sym=sym; m_enabled=enabled; m_tf=tf; m_n=0; m_seq=0;
      ArrayResize(m_rec,0);
      ArrayResize(m_csv,1);
      m_csv[0]="trade_no,pos_id,trade_session,open_time,close_time,anchor_session,anchor_pivot_px,"
               "anchor_hours_back,session_quality_score,zone_at_entry,lean_at_entry,trigger_type,"
               "is_flip,confirm_bars,direction,try_number,entry,sl,tp,r_money,rr_planned,"
               "exit_reason,net_r,net_pct_balance,mae_r,mfe_r,"
               "dsigma_entry,atr_entry,sl_atr_ratio,spread_entry_pts,entry_mins_since_open,"
               "regime_at_entry,confirm_armed_at_entry,be_applied,bars_held,mfe_bar,mae_bar";
     }

   //--- call once right after TradeManagerV2 confirms a fresh open. Returns
   //--- the index to pass to SampleBar()/OnClose() for this trade.
   int OnOpen(const long posId,const string tradeSession,
             const string anchorSession,const double anchorPivotPx,const double anchorHoursBack,
             const double sessionQualityScore,
             const string zoneAtEntry,const string leanAtEntry,const string triggerType,
             const bool isFlip,const int confirmBars,
             const string direction,const int tryNumber,
             const double entry,const double sl,const double tp,
             const double rMoney,const double rrPlanned,
             const double dSigmaEntry,const double atrEntry,const double spreadEntryPts,
             const int entryMinsSinceOpen,const string regimeAtEntry,const bool confirmArmedAtEntry)
     {
      STradeRecordV2 r;
      r.tradeNo=++m_seq; r.posId=posId; r.tradeSession=tradeSession;
      r.openTimeRaw=TimeCurrent();
      r.openTimeStr=TimeToString(r.openTimeRaw,TIME_DATE|TIME_MINUTES|TIME_SECONDS);
      r.closeTimeStr="";
      r.anchorSession=anchorSession; r.anchorPivotPx=anchorPivotPx; r.anchorHoursBack=anchorHoursBack;
      r.sessionQualityScore=sessionQualityScore;
      r.zoneAtEntry=zoneAtEntry; r.leanAtEntry=leanAtEntry; r.triggerType=triggerType;
      r.isFlip=isFlip?1:0; r.confirmBars=confirmBars;
      r.direction=direction; r.tryNumber=tryNumber;
      r.entry=entry; r.sl=sl; r.tp=tp; r.rMoney=rMoney; r.rrPlanned=rrPlanned;
      r.exitReason=""; r.netR=0; r.netPctBalance=0; r.maeR=0; r.mfeR=0;
      r.open=true; r.worstPrice=entry; r.bestPrice=entry;
      r.dSigmaEntry=dSigmaEntry; r.atrEntry=atrEntry;
      r.slAtrRatio=(atrEntry>0.0)?MathAbs(entry-sl)/atrEntry:0.0;
      r.spreadEntryPts=spreadEntryPts; r.entryMinsSinceOpen=entryMinsSinceOpen;
      r.regimeAtEntry=regimeAtEntry; r.confirmArmedAtEntry=confirmArmedAtEntry?1:0;
      r.beApplied=0; r.barsHeld=0;
      r.barsSampled=0; r.mfeBar=0; r.maeBar=0;

      ArrayResize(m_rec,m_n+1); m_rec[m_n]=r;
      return(m_n++);
     }

   //--- call once per newly CLOSED bar while idx's trade is still open
   //--- (skip the entry bar itself - its extremes predate the entry)
   void SampleBar(const int idx,const double barHigh,const double barLow)
     {
      if(idx<0 || idx>=m_n || !m_rec[idx].open) return;
      m_rec[idx].barsSampled++;
      bool isLong=(m_rec[idx].direction=="LONG");
      if(isLong)
        {
         if(barLow <m_rec[idx].worstPrice) { m_rec[idx].worstPrice=barLow;  m_rec[idx].maeBar=m_rec[idx].barsSampled; }
         if(barHigh>m_rec[idx].bestPrice)  { m_rec[idx].bestPrice =barHigh; m_rec[idx].mfeBar=m_rec[idx].barsSampled; }
        }
      else
        {
         if(barHigh>m_rec[idx].worstPrice) { m_rec[idx].worstPrice=barHigh; m_rec[idx].maeBar=m_rec[idx].barsSampled; }
         if(barLow <m_rec[idx].bestPrice)  { m_rec[idx].bestPrice =barLow;  m_rec[idx].mfeBar=m_rec[idx].barsSampled; }
        }
     }

   void OnClose(const int idx,const string exitReason,const double closePrice,
               const double balanceBeforeClose,const double netProfitMoney,
               const bool beApplied=false)
     {
      if(idx<0 || idx>=m_n || !m_rec[idx].open) return;
      STradeRecordV2 r=m_rec[idx];
      bool     isLong=(r.direction=="LONG");
      double   rDist =MathAbs(r.entry-r.sl);
      datetime closeTimeRaw=TimeCurrent();

      r.closeTimeStr=TimeToString(closeTimeRaw,TIME_DATE|TIME_MINUTES|TIME_SECONDS);
      r.exitReason=exitReason;
      r.netR=(rDist>0.0)?((isLong?(closePrice-r.entry):(r.entry-closePrice))/rDist):0.0;
      r.netPctBalance=(balanceBeforeClose>0.0)?netProfitMoney/balanceBeforeClose*100.0:0.0;
      r.maeR=(rDist>0.0)?MathAbs(r.entry-r.worstPrice)/rDist:0.0;
      r.mfeR=(rDist>0.0)?MathAbs(r.bestPrice-r.entry)/rDist:0.0;
      r.beApplied=beApplied?1:0;
      int periodSec=PeriodSeconds(m_tf);
      r.barsHeld=(periodSec>0)?(int)((closeTimeRaw-r.openTimeRaw)/periodSec):0;
      r.open=false;
      m_rec[idx]=r;
      PushCsvRow(r);
     }

   //--- any records still open at the end of a run must be finalized so
   //--- the CSV never has an implicit "still open" row (D4: zero UNKNOWN)
   void FinalizeOpenAsEndOfTest(const double lastPrice,const double balance)
     {
      for(int i=0;i<m_n;i++)
         if(m_rec[i].open) OnClose(i,"END_OF_TEST",lastPrice,balance,0.0);
     }

   int OpenCount() const
     {
      int c=0; for(int i=0;i<m_n;i++) if(m_rec[i].open) c++; return(c);
     }

   void Flush(const string filenamePrefix)
     {
      if(!m_enabled || ArraySize(m_csv)<=1) return;
      string fn=filenamePrefix+"_"+m_sym+".csv";
      int h=FileOpen(fn,FILE_WRITE|FILE_ANSI|FILE_TXT|FILE_COMMON);
      if(h==INVALID_HANDLE){ PrintFormat("[V2] Analytics CSV open failed: %s",fn); return; }
      for(int i=0;i<ArraySize(m_csv);i++) FileWriteString(h,m_csv[i]+"\r\n");
      FileClose(h);
      PrintFormat("[V2] Analytics: wrote %d trade rows to Common\\Files\\%s",ArraySize(m_csv)-1,fn);
     }
  };

#endif // V2_ANALYTICSV2_MQH

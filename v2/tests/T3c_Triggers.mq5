//+------------------------------------------------------------------+
//|                                                 T3c_Triggers.mq5  |
//|  Isolated visual test for Include/Triggers.mqh (milestone 9).     |
//|                                                                   |
//|  Independent of the AVWAP/Zones/AnchorSelect chain (Triggers has  |
//|  no dependency on any of it - BOS delegates to Fractals, Reversal |
//|  reads raw price action) - so this test only needs Fractals, same |
//|  as T2b, plus Triggers on top. Draws the T2b-style fractal/BOS    |
//|  overlay (via Triggers' internal CFractals) so BOS marks can be   |
//|  eyeballed 1:1 against T2b, plus Reversal+Momentum markers.       |
//|                                                                   |
//|  On every detected trigger (either type, both directions): an     |
//|  entry arrow, the protected extreme as a dashed line, a           |
//|  "BOS UP"/"REV DN" label, and the leg shaded.                     |
//|                                                                   |
//|  Run: XAUUSD, M5, "Every tick based on real ticks", Visual ON,   |
//|  3-5 days with a mix of clean breaks and sharp reversals.        |
//|                                                                   |
//|  PASS checklist (v2/doc/IMPLEMENTATION_PLAN.md C3c):             |
//|   [ ] BOS triggers coincide 1:1 with T2b's BOS marks.            |
//|   [ ] Reversal marks sit on visually sharp counter-then-reverse   |
//|       candles, not on trend continuation.                        |
//|   [ ] The protected extreme is the true local extreme of the      |
//|       triggering move.                                            |
//|   [ ] EntryMode (BOS_ONLY/REVERSAL_ONLY/BOTH) filters the trigger |
//|       stream as expected.                                         |
//|   [ ] No trigger from a forming bar (step forward - marks never   |
//|       appear then move).                                          |
//+------------------------------------------------------------------+
#property copyright "Sessions Strategy v2"
#property version   "1.00"
#property strict

#include "../Include/V2Common.mqh"
#include "../Include/Triggers.mqh"
#include "../Include/VisualsV2.mqh"
#include "../Include/DashboardV2.mqh"

input group "General"
input ENUM_TIMEFRAMES InpTF = PERIOD_M5;

input group "Fractals / BOS (Entry Type A)"
input int                 InpBosSwingDepth   = 3;
input int                 InpBosBufferPoints = 0;
input ENUM_BOS_CONFIRM_V2 InpBosConfirmMode  = BC_CLOSE;
input int                 InpAtrPeriod       = 14;

input group "Reversal + Momentum (Entry Type B, spec Sec9.3)"
input int    InpRevCounterLookback    = 8;
input double InpRevMinCounterMoveAtr  = 0.8;
input double InpRevBodyAtr            = 1.0;
input double InpRevCloseLocPct        = 0.33;
input bool   InpRevRequireEngulf      = false;
input int    InpRevBreakBars          = 2;
input int    InpRevConfirmCloses      = 1;

input group "Entry"
input ENUM_ENTRY_MODE_V2 InpEntryMode     = EM_BOTH;
input ENUM_ENTRY_FILL_V2 InpEntryFillMode = EF_BOS_CLOSE;

input group "Test / diagnostics"
input int  InpMaxFractalsDraw   = 120;
input int  InpKeepTriggerMarks  = 40;  // how many stay in the dashboard's "recent" text list
input int  InpMaxDrawnTriggers  = 2;   // how many stay drawn ON THE CHART (redrawn from the ring each bar - keeps it clean)
input bool InpVerbose           = true;

SSettingsV2  g_s;
CTriggers    g_trig;
CVisualsV2   g_vis;
CDashboardV2 g_dash;
datetime     g_lastBar = 0;

STriggerEvent g_ring[128];
int           g_ringN = 0;

//+------------------------------------------------------------------+
void BuildSettingsV2()
  {
   g_s.tf              = InpTF;
   g_s.bosSwingDepth   = InpBosSwingDepth;
   g_s.bosBufferPoints = InpBosBufferPoints;
   g_s.bosConfirmMode  = InpBosConfirmMode;
   g_s.atrPeriod       = InpAtrPeriod;

   g_s.entryMode       = InpEntryMode;
   g_s.entryFillMode   = InpEntryFillMode;
   g_s.revCounterLookback   = InpRevCounterLookback;
   g_s.revMinCounterMoveAtr = InpRevMinCounterMoveAtr;
   g_s.revBodyAtr           = InpRevBodyAtr;
   g_s.revCloseLocPct       = InpRevCloseLocPct;
   g_s.revRequireEngulf     = InpRevRequireEngulf;
   g_s.revBreakBars         = InpRevBreakBars;
   g_s.revConfirmCloses     = InpRevConfirmCloses;
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,InpTF,0);
   if(t!=g_lastBar){ g_lastBar=t; return(true); }
   return(false);
  }

//+------------------------------------------------------------------+
void PushTrigger(const STriggerEvent &ev)
  {
   int cap=MathMin(InpKeepTriggerMarks,128);
   if(g_ringN<cap){ g_ring[g_ringN++]=ev; return; }
   for(int i=1;i<cap;i++) g_ring[i-1]=g_ring[i];
   g_ring[cap-1]=ev;
  }

//+------------------------------------------------------------------+
//|  Fractal pivots + "next BOS" preview rays, same as T2b            |
//+------------------------------------------------------------------+
void DrawFractals()
  {
   g_vis.ClearGroup("FR");
   CFractals *fr=g_trig.FractalsPtr();

   SFractal p;
   for(int i=0;i<InpMaxFractalsDraw;i++)
     {
      if(!fr.GetHigh(i,p)) break;
      g_vis.Arrow(g_vis.Name("FR","H"+(string)i),p.time,p.price,159,clrTomato,1,ANCHOR_TOP);
     }
   for(int i=0;i<InpMaxFractalsDraw;i++)
     {
      if(!fr.GetLow(i,p)) break;
      g_vis.Arrow(g_vis.Name("FR","L"+(string)i),p.time,p.price,159,clrLimeGreen,1,ANCHOR_BOTTOM);
     }

   SDiagFractals d=fr.Diag();
   datetime now=iTime(_Symbol,InpTF,0);
   if(d.lastSwingHighTime>0)
     {
      color c=d.swingHighBroken?clrDimGray:clrAqua;
      g_vis.RayH(g_vis.Name("FR","NBU"),d.lastSwingHighTime,d.lastSwingHigh,now,c,STYLE_DOT);
     }
   if(d.lastSwingLowTime>0)
     {
      color c=d.swingLowBroken?clrDimGray:clrAqua;
      g_vis.RayH(g_vis.Name("FR","NBD"),d.lastSwingLowTime,d.lastSwingLow,now,c,STYLE_DOT);
     }
  }

//+------------------------------------------------------------------+
//|  Entry arrow + protected-extreme dashed line + label + leg shade  |
//+------------------------------------------------------------------+
void DrawTriggerObj(const STriggerEvent &ev)
  {
   if(!ev.valid) return;
   bool up=(ev.dir==DIR_LONG);
   color c=up?clrLime:clrOrangeRed;
   string key=(string)(long)ev.barTime+"_"+ev.type+"_"+(up?"L":"S");

   if(ev.legToTime>ev.legFromTime)
      g_vis.Rect(g_vis.Name("TRG",key+"_leg"),ev.legFromTime,MathMax(ev.entryPrice,ev.protectedExtreme),
                 ev.legToTime,MathMin(ev.entryPrice,ev.protectedExtreme),c,false,1);

   g_vis.RayH(g_vis.Name("TRG",key+"_pe"),ev.barTime,ev.protectedExtreme,
              ev.entryTime+PeriodSeconds(InpTF)*3,clrGoldenrod,STYLE_DASH);

   g_vis.Arrow(g_vis.Name("TRG",key+"_arr"),ev.entryTime,ev.entryPrice,up?233:234,c,3,
               up?ANCHOR_TOP:ANCHOR_BOTTOM);
   g_vis.Text(g_vis.Name("TRG",key+"_txt"),ev.entryTime,ev.entryPrice,
              StringFormat(" %s %s",ev.type,up?"UP":"DN"),c,9,
              up?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER);
  }

//+------------------------------------------------------------------+
//|  Chart stays clean: wipe every trigger object and redraw only the |
//|  last InpMaxDrawnTriggers from the ring (the dashboard's text     |
//|  list can keep more history - that costs no chart clutter).       |
//+------------------------------------------------------------------+
void RedrawTriggers()
  {
   g_vis.ClearGroup("TRG");
   int show=MathMin(MathMax(InpMaxDrawnTriggers,0),g_ringN);
   for(int i=g_ringN-show;i<g_ringN;i++)
      DrawTriggerObj(g_ring[i]);
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
void RefreshDash()
  {
   SDiagTriggers d=g_trig.Diag();

   g_dash.Title(0,"--- V2 . TRIGGERS: BOS + REVERSAL (T3c) ---");
   g_dash.KV(1,"Mode",StringFormat("%s   fill %s",
             InpEntryMode==EM_BOTH?"BOTH":InpEntryMode==EM_BOS_ONLY?"BOS_ONLY":"REVERSAL_ONLY",
             InpEntryFillMode==EF_NEXT_OPEN?"NEXT_OPEN":"BOS_CLOSE"),clrGainsboro);
   g_dash.KV(2,"ATR",DoubleToString(d.atr,_Digits),clrGainsboro);
   g_dash.KV(3,"Triggers this session-run",(string)d.countThisSession,clrGainsboro);

   if(d.hasLast)
     {
      STriggerEvent e=d.last;
      color c=(e.dir==DIR_LONG)?clrLime:clrOrangeRed;
      g_dash.KV(4,"Last trigger",StringFormat("%s %s  entry %s  prot.ext %s  leg %s (%.2fx ATR)",
                e.type,e.dir==DIR_LONG?"UP":"DN",DoubleToString(e.entryPrice,_Digits),
                DoubleToString(e.protectedExtreme,_Digits),DoubleToString(e.legRange,_Digits),
                d.lastLegRangeAtr),c);
      g_dash.KV(5,"  @",TimeToString(e.barTime,TIME_DATE|TIME_MINUTES),clrSilver);
     }
   else
      g_dash.KV(4,"Last trigger","- none yet -",clrSilver);

   g_dash.Line(7,"recent triggers (newest first):",clrSilver);
   int shown=0;
   for(int i=g_ringN-1;i>=0 && shown<8;i--,shown++)
     {
      STriggerEvent e=g_ring[i];
      color c=(e.dir==DIR_LONG)?clrLime:clrOrangeRed;
      g_dash.Line(8+shown,StringFormat("  %s %s %s  entry %s",
                  TimeToString(e.barTime,TIME_DATE|TIME_MINUTES),e.type,
                  e.dir==DIR_LONG?"UP":"DN",DoubleToString(e.entryPrice,_Digits)),c);
     }
   g_dash.Line(17,"check: BOS marks match T2b 1:1; reversal marks sit on sharp V-turns only",clrDimGray);
   g_dash.Render();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   BuildSettingsV2();
   g_trig.Init(g_s,_Symbol);
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());

   PrintFormat("[T3c] BOS N=%d buffer=%d mode=%s | Rev lookback=%d minMoveATR=%.1f bodyATR=%.1f closeLoc=%.2f engulf=%s breakBars=%d confirm=%d | mode=%s fill=%s",
               InpBosSwingDepth,InpBosBufferPoints,InpBosConfirmMode==BC_WICK?"WICK":"CLOSE",
               InpRevCounterLookback,InpRevMinCounterMoveAtr,InpRevBodyAtr,InpRevCloseLocPct,
               InpRevRequireEngulf?"Y":"N",InpRevBreakBars,InpRevConfirmCloses,
               InpEntryMode==EM_BOTH?"BOTH":InpEntryMode==EM_BOS_ONLY?"BOS_ONLY":"REVERSAL_ONLY",
               InpEntryFillMode==EF_NEXT_OPEN?"NEXT_OPEN":"BOS_CLOSE");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_trig.Deinit();
   g_vis.Destroy();
   g_dash.Destroy();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   bool newBar=IsNewBar();
   RefreshDash();
   if(!newBar) return;

   g_trig.RefreshStructure();
   g_trig.Update();
   DrawFractals();

   STriggerEvent evs[3];
   evs[0]=g_trig.BosThisBar();
   evs[1]=g_trig.RevLongThisBar();
   evs[2]=g_trig.RevShortThisBar();
   bool any=false;
   for(int i=0;i<3;i++)
     {
      if(!evs[i].valid) continue;
      any=true;
      PushTrigger(evs[i]);
      if(InpVerbose)
         PrintFormat("[T3c] %s %s  entry=%s  protExt=%s  leg=%s  @ %s",
                     evs[i].type,evs[i].dir==DIR_LONG?"UP":"DN",
                     DoubleToString(evs[i].entryPrice,_Digits),
                     DoubleToString(evs[i].protectedExtreme,_Digits),
                     DoubleToString(evs[i].legRange,_Digits),
                     TimeToString(evs[i].barTime,TIME_DATE|TIME_MINUTES));
     }
   if(any) RedrawTriggers();
  }
//+------------------------------------------------------------------+

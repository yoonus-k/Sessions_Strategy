//+------------------------------------------------------------------+
//|                                                    T2a_ZigZag.mq5 |
//|  Isolated visual test for Include/ZigZag.mqh (v2 milestone 3).    |
//|                                                                   |
//|  Run: XAUUSD, M5, "Every tick based on real ticks", Visual ON.   |
//|                                                                   |
//|  PASS checklist (v2/doc/IMPLEMENTATION_PLAN.md C2a):             |
//|   [ ] Polyline matches the stock  Examples\ZigZag  indicator     |
//|       loaded on the same chart with the same Depth/Dev/Backstep. |
//|   [ ] Confirmed pivots never move once a newer pivot forms; only |
//|       the dim dashed tail leg changes.                           |
//|   [ ] Depth / Deviation / Backstep visibly change pivot density. |
//|   [ ] The "ANCHOR CANDIDATE" label sits on a real swing extreme. |
//+------------------------------------------------------------------+
#property copyright "Sessions Strategy v2"
#property version   "1.00"
#property strict

#include "../Include/V2Common.mqh"
#include "../Include/ZigZag.mqh"
#include "../Include/VisualsV2.mqh"
#include "../Include/DashboardV2.mqh"

input group "General"
input ENUM_TIMEFRAMES InpTF = PERIOD_M5;

input group "ZigZag (Examples\\ZigZag params)"
input int InpZZDepth     = 24;
input int InpZZDeviation = 5;
input int InpZZBackstep  = 2;
input int InpAtrPeriod   = 14;

input group "Test / diagnostics"
input int  InpMaxPivotsDraw = 250;
input bool InpVerbose       = false;

SSettingsV2  g_s;
CZigZag      g_zz;
CVisualsV2   g_vis;
CDashboardV2 g_dash;
datetime     g_lastBar    = 0;
datetime     g_lastPivotT = 0;

//+------------------------------------------------------------------+
void BuildSettingsV2()
  {
   g_s.tf          = InpTF;
   g_s.zzDepth     = InpZZDepth;
   g_s.zzDeviation = InpZZDeviation;
   g_s.zzBackstep  = InpZZBackstep;
   g_s.atrPeriod   = InpAtrPeriod;
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,InpTF,0);
   if(t!=g_lastBar){ g_lastBar=t; return(true); }
   return(false);
  }

//+------------------------------------------------------------------+
void DrawZigZag()
  {
   g_vis.ClearGroup("ZZ");

   int total=g_zz.Total();
   if(total<2) { g_vis.Redraw(); return; }

   // collect chronologically (oldest -> newest), capped.
   // Get(from,..,true): from=0 is the newest (tentative) pivot, so iterating
   // from = want-1 down to 0 yields oldest -> newest.
   int want=MathMin(total,InpMaxPivotsDraw);
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
      color lc=tentative?clrDimGray:clrGold;
      int   lw=tentative?1:2;
      int   ls=tentative?STYLE_DASH:STYLE_SOLID;
      g_vis.Segment(g_vis.Name("ZZ","L"+(string)i),t[i-1],p[i-1],t[i],p[i],lc,lw,ls);
     }
   for(int i=0;i<c;i++)
      g_vis.Arrow(g_vis.Name("ZZ","P"+(string)i),t[i],p[i],159,
                  hi[i]?clrTomato:clrLimeGreen,2,
                  hi[i]?ANCHOR_TOP:ANCHOR_BOTTOM);

   // newest CONFIRMED pivot = the anchor candidate
   SZZPivot cand;
   if(g_zz.Get(0,cand,false))
      g_vis.Text(g_vis.Name("ZZ","CAND"),cand.time,cand.price,
                 "  ANCHOR CANDIDATE",clrWhite,9,
                 cand.isHigh?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER);

   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
void RefreshDash()
  {
   SDiagZigZag d=g_zz.Diag();

   g_dash.Title(0,"--- V2 . ZIGZAG anchor pivots (T2a) ---");
   g_dash.KV(1,"Indicator",d.handleOk?"Examples\\ZigZag OK":"NOT FOUND",
             d.handleOk?clrLime:clrTomato);
   g_dash.KV(2,"Confirmed",StringFormat("%d pivots   tail %s",
             d.confirmedCount,d.tailPending?"developing":"-"),clrGainsboro);
   g_dash.KV(3,"ATR(14)",d.atr>0?DoubleToString(d.atr,_Digits):"-",clrGainsboro);
   g_dash.KV(4,"Last leg",d.lastLegSize>0
             ?StringFormat("%s  (%.2f x ATR)",DoubleToString(d.lastLegSize,_Digits),d.lastLegAtr)
             :"-",clrWhite);
   g_dash.Line(5,"recent confirmed pivots (newest first):",clrSilver);
   for(int i=0;i<d.lastN && i<6;i++)
     {
      double leg=0;
      if(i+1<d.lastN) leg=MathAbs(d.last[i].price-d.last[i+1].price);
      g_dash.Line(6+i,StringFormat("  %s %s  %s   leg %s",
                  d.last[i].isHigh?"H":"L",
                  DoubleToString(d.last[i].price,_Digits),
                  TimeToString(d.last[i].time,TIME_DATE|TIME_MINUTES),
                  leg>0?DoubleToString(leg,_Digits):"-"),
                  d.last[i].isHigh?clrTomato:clrLimeGreen);
     }
   g_dash.Line(12,"check: overlay Examples\\ZigZag (same params) -> pivots match",clrDimGray);
   g_dash.Render();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   BuildSettingsV2();
   g_zz.Init(g_s,_Symbol);
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());

   if(!g_zz.HandleOk())
     {
      Print("[T2a] ERROR: could not create Examples\\ZigZag indicator handle");
      Alert("T2a: Examples\\ZigZag indicator not found - compile it in MetaEditor");
     }
   PrintFormat("[T2a] ZigZag Depth=%d Deviation=%d Backstep=%d, ATR=%d",
               InpZZDepth,InpZZDeviation,InpZZBackstep,InpAtrPeriod);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
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

   if(InpVerbose)
     {
      SZZPivot p;
      if(g_zz.Get(0,p,false) && p.time!=g_lastPivotT)
        {
         g_lastPivotT=p.time;
         PrintFormat("[T2a] new confirmed pivot: %s %s @ %s  (confirmed=%d)",
                     p.isHigh?"HIGH":"LOW",DoubleToString(p.price,_Digits),
                     TimeToString(p.time,TIME_DATE|TIME_MINUTES),g_zz.ConfirmedCount());
        }
     }
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                              T2b_Fractals_BOS.mq5 |
//|  Isolated visual test for Include/Fractals.mqh (v2 milestone 4).  |
//|                                                                   |
//|  Run: XAUUSD, M5, "Every tick based on real ticks", Visual ON.   |
//|                                                                   |
//|  PASS checklist (v2/doc/IMPLEMENTATION_PLAN.md C2b):             |
//|   [ ] Every BOS mark sits on a bar that closed past a swing      |
//|       level that was ALREADY drawn before the break.            |
//|   [ ] No fractal dot appears until its N right-side bars closed; |
//|       dots never move afterward.                                 |
//|   [ ] No BOS without a preceding confirmed fractal.              |
//|   [ ] WICK vs CLOSE mode changes which bars qualify.            |
//+------------------------------------------------------------------+
#property copyright "Sessions Strategy v2"
#property version   "1.00"
#property strict

#include "../Include/V2Common.mqh"
#include "../Include/Fractals.mqh"
#include "../Include/VisualsV2.mqh"
#include "../Include/DashboardV2.mqh"

input group "General"
input ENUM_TIMEFRAMES InpTF = PERIOD_M5;

input group "Fractals / BOS"
input int                 InpBosSwingDepth  = 3;
input int                 InpBosBufferPoints= 0;
input ENUM_BOS_CONFIRM_V2 InpBosConfirmMode = BC_CLOSE;
input int                 InpAtrPeriod      = 14;

input group "Test / diagnostics"
input int  InpMaxFractalsDraw = 120;
input int  InpKeepBosMarks    = 12;
input bool InpVerbose         = false;

SSettingsV2  g_s;
CFractals    g_fr;
CVisualsV2   g_vis;
CDashboardV2 g_dash;
datetime     g_lastBar = 0;

SBosEvent    g_bosRing[64];
int          g_bosN = 0;

//+------------------------------------------------------------------+
void BuildSettingsV2()
  {
   g_s.tf              = InpTF;
   g_s.bosSwingDepth   = InpBosSwingDepth;
   g_s.bosBufferPoints = InpBosBufferPoints;
   g_s.bosConfirmMode  = InpBosConfirmMode;
   g_s.atrPeriod       = InpAtrPeriod;
  }

//+------------------------------------------------------------------+
bool IsNewBar()
  {
   datetime t=iTime(_Symbol,InpTF,0);
   if(t!=g_lastBar){ g_lastBar=t; return(true); }
   return(false);
  }

//+------------------------------------------------------------------+
void PushBos(const SBosEvent &ev)
  {
   int cap=MathMin(InpKeepBosMarks,64);
   if(g_bosN<cap){ g_bosRing[g_bosN++]=ev; return; }
   for(int i=1;i<cap;i++) g_bosRing[i-1]=g_bosRing[i];
   g_bosRing[cap-1]=ev;
  }

//+------------------------------------------------------------------+
void DrawFractals()
  {
   g_vis.ClearGroup("FR");

   SFractal p;
   for(int i=0;i<InpMaxFractalsDraw;i++)
     {
      if(!g_fr.GetHigh(i,p)) break;
      g_vis.Arrow(g_vis.Name("FR","H"+(string)i),p.time,p.price,159,clrTomato,1,ANCHOR_TOP);
     }
   for(int i=0;i<InpMaxFractalsDraw;i++)
     {
      if(!g_fr.GetLow(i,p)) break;
      g_vis.Arrow(g_vis.Name("FR","L"+(string)i),p.time,p.price,159,clrLimeGreen,1,ANCHOR_BOTTOM);
     }

   SDiagFractals d=g_fr.Diag();
   datetime now=iTime(_Symbol,InpTF,0);
   if(d.lastSwingHighTime>0)
     {
      color c=d.swingHighBroken?clrDimGray:clrAqua;
      g_vis.RayH(g_vis.Name("FR","NBU"),d.lastSwingHighTime,d.lastSwingHigh,now,c,STYLE_DOT);
      g_vis.Text(g_vis.Name("FR","NBUt"),now,d.lastSwingHigh,
                 d.swingHighBroken?" swing hi (broken)":" next BOS UP",c,8,ANCHOR_LEFT_LOWER);
     }
   if(d.lastSwingLowTime>0)
     {
      color c=d.swingLowBroken?clrDimGray:clrAqua;
      g_vis.RayH(g_vis.Name("FR","NBD"),d.lastSwingLowTime,d.lastSwingLow,now,c,STYLE_DOT);
      g_vis.Text(g_vis.Name("FR","NBDt"),now,d.lastSwingLow,
                 d.swingLowBroken?" swing lo (broken)":" next BOS DN",c,8,ANCHOR_LEFT_UPPER);
     }
  }

//+------------------------------------------------------------------+
void DrawBosMarks()
  {
   g_vis.ClearGroup("BOS");
   for(int i=0;i<g_bosN;i++)
     {
      SBosEvent e=g_bosRing[i];
      if(!e.valid) continue;
      string k=(string)(long)e.barTime;
      bool up=(e.dir==DIR_LONG);
      color c=up?clrLime:clrOrangeRed;

      // broken structure level, from the swing bar to the break bar
      g_vis.Segment(g_vis.Name("BOS",k+"lvl"),e.brokenTime,e.brokenLevel,e.barTime,e.brokenLevel,
                    clrOrange,1,STYLE_SOLID);
      // BOS leg box
      g_vis.Rect(g_vis.Name("BOS",k+"leg"),e.legFromTime,e.legHigh,e.barTime,e.legLow,c,false,1);
      // break arrow + label
      g_vis.Arrow(g_vis.Name("BOS",k+"arr"),e.barTime,e.brokenLevel,up?233:234,c,2,
                  up?ANCHOR_BOTTOM:ANCHOR_TOP);
      g_vis.Text(g_vis.Name("BOS",k+"txt"),e.barTime,up?e.legHigh:e.legLow,
                 up?"BOS UP":"BOS DN",c,8,up?ANCHOR_LEFT_LOWER:ANCHOR_LEFT_UPPER);
     }
   g_vis.Redraw();
  }

//+------------------------------------------------------------------+
void RefreshDash()
  {
   SDiagFractals d=g_fr.Diag();

   g_dash.Title(0,"--- V2 . FRACTALS + BOS (T2b) ---");
   g_dash.KV(1,"Swings",StringFormat("%d highs / %d lows   depth N=%d  (%s)",
             d.swingHighCount,d.swingLowCount,InpBosSwingDepth,
             InpBosConfirmMode==BC_WICK?"WICK":"CLOSE"),clrGainsboro);
   g_dash.KV(2,"Last swing hi",d.lastSwingHigh>0
             ?StringFormat("%s  %s%s",DoubleToString(d.lastSwingHigh,_Digits),
                           TimeToString(d.lastSwingHighTime,TIME_DATE|TIME_MINUTES),
                           d.swingHighBroken?"  [broken]":"")
             :"-",d.swingHighBroken?clrDimGray:clrTomato);
   g_dash.KV(3,"Last swing lo",d.lastSwingLow>0
             ?StringFormat("%s  %s%s",DoubleToString(d.lastSwingLow,_Digits),
                           TimeToString(d.lastSwingLowTime,TIME_DATE|TIME_MINUTES),
                           d.swingLowBroken?"  [broken]":"")
             :"-",d.swingLowBroken?clrDimGray:clrLimeGreen);
   g_dash.KV(4,"BOS count",(string)d.bosCount+"   ATR "+DoubleToString(d.atr,_Digits),clrGainsboro);

   if(d.lastBos.valid)
     {
      SBosEvent e=d.lastBos;
      double legAtr=(d.atr>0)?e.legRange/d.atr:0;
      g_dash.KV(5,"Last BOS",StringFormat("%s  broke %s  leg %s (%.2fx ATR)  @ %s",
                e.dir==DIR_LONG?"UP":"DN",DoubleToString(e.brokenLevel,_Digits),
                DoubleToString(e.legRange,_Digits),legAtr,
                TimeToString(e.barTime,TIME_DATE|TIME_MINUTES)),
                e.dir==DIR_LONG?clrLime:clrOrangeRed);
     }
   else
      g_dash.KV(5,"Last BOS","- none yet -",clrSilver);

   g_dash.Line(6,"recent fractal highs / lows (newest first):",clrSilver);
   for(int i=0;i<5;i++)
     {
      string hs=(i<d.lastHiN)?StringFormat("H %s %s",DoubleToString(d.lastHi[i].price,_Digits),
                 TimeToString(d.lastHi[i].time,TIME_MINUTES)):"";
      string ls=(i<d.lastLoN)?StringFormat("L %s %s",DoubleToString(d.lastLo[i].price,_Digits),
                 TimeToString(d.lastLo[i].time,TIME_MINUTES)):"";
      g_dash.Line(7+i,"  "+hs+"    "+ls,clrGainsboro);
     }
   g_dash.Line(12,"check: BOS marks only on a bar closing past a pre-existing swing",clrDimGray);
   g_dash.Render();
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   BuildSettingsV2();
   g_fr.Init(g_s,_Symbol);
   g_vis.Init(ChartID(),true);
   g_dash.Init(ChartID());
   PrintFormat("[T2b] Fractals N=%d buffer=%d pts mode=%s ATR=%d",
               InpBosSwingDepth,InpBosBufferPoints,
               InpBosConfirmMode==BC_WICK?"WICK":"CLOSE",InpAtrPeriod);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   g_fr.Deinit();
   g_vis.Destroy();
   g_dash.Destroy();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   bool newBar=IsNewBar();
   RefreshDash();
   if(!newBar) return;

   g_fr.Refresh();
   SBosEvent ev=g_fr.CheckBOS();
   if(ev.valid)
     {
      PushBos(ev);
      if(InpVerbose)
         PrintFormat("[T2b] BOS %s: broke %s (swing @ %s) leg %s @ %s",
                     ev.dir==DIR_LONG?"UP":"DN",DoubleToString(ev.brokenLevel,_Digits),
                     TimeToString(ev.brokenTime,TIME_MINUTES),
                     DoubleToString(ev.legRange,_Digits),
                     TimeToString(ev.barTime,TIME_DATE|TIME_MINUTES));
     }

   DrawFractals();
   DrawBosMarks();
  }
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                                      Visuals.mqh  |
//|  Draws range/session boxes on the chart:                          |
//|   - Prior-day last-4h range (rule 2) + projected high/low lines   |
//|   - Developing Asia session range                                 |
//|   - Developing NY session range                                   |
//|  Each box carries a text label. All session-tied drawings         |
//|  (including the prior-4h range card) are wiped at session end.    |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_VISUALS_MQH
#define SESSIONS_STRATEGY_VISUALS_MQH

#include "Common.mqh"

#define VIS_PREFIX "SSV_"

class CVisuals
  {
private:
   long   m_chart;
   bool   m_show;
   bool   m_showSig;
   color  m_colRange;
   color  m_colAsia;
   color  m_colNY;
   color  m_colChoch;
   color  m_colIfvg;
   color  m_colSweep;
   bool   m_showSwings;
   color  m_colSwingHi;
   color  m_colSwingLo;
   color  m_colFvg;

   string DayTag(const datetime t) const
     {
      MqlDateTime dt; TimeToStruct(t,dt);
      return(StringFormat("%04d%02d%02d",dt.year,dt.mon,dt.day));
     }

   void EnsureRect(const string name,const datetime t1,const double p1,
                   const datetime t2,const double p2,const color clr,
                   const bool fill=true)
     {
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_RECTANGLE,0,t1,p1,t2,p2);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_FILL,fill);
      ObjectSetInteger(m_chart,name,OBJPROP_BACK,fill);     // filled boxes go behind
      ObjectSetInteger(m_chart,name,OBJPROP_WIDTH,fill?1:2);
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectMove(m_chart,name,0,t1,p1);
      ObjectMove(m_chart,name,1,t2,p2);
     }

   void EnsureLine(const string name,const datetime t1,const double p,
                   const datetime t2,const color clr)
     {
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_TREND,0,t1,p,t2,p);
         ObjectSetInteger(m_chart,name,OBJPROP_RAY_RIGHT,true);
         ObjectSetInteger(m_chart,name,OBJPROP_STYLE,STYLE_DOT);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectMove(m_chart,name,0,t1,p);
      ObjectMove(m_chart,name,1,t2,p);
     }

   void EnsureSegment(const string name,const datetime t1,const double p1,
                      const datetime t2,const double p2,const color clr,
                      const int width=2)
     {
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_TREND,0,t1,p1,t2,p2);
         ObjectSetInteger(m_chart,name,OBJPROP_RAY_RIGHT,false);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(m_chart,name,OBJPROP_WIDTH,width);
      ObjectMove(m_chart,name,0,t1,p1);
      ObjectMove(m_chart,name,1,t2,p2);
     }

   void EnsureArrow(const string name,const datetime t,const double p,
                    const int code,const color clr)
     {
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_ARROW,0,t,p);
         ObjectSetInteger(m_chart,name,OBJPROP_ARROWCODE,code);
         ObjectSetInteger(m_chart,name,OBJPROP_WIDTH,2);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectMove(m_chart,name,0,t,p);
     }

   void EnsureText(const string name,const datetime t,const double p,
                   const string text,const color clr)
     {
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_TEXT,0,t,p);
         ObjectSetInteger(m_chart,name,OBJPROP_ANCHOR,ANCHOR_LEFT_LOWER);
         ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,8);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetString (m_chart,name,OBJPROP_TEXT,text);
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectMove(m_chart,name,0,t,p);
     }

public:
   void Init(const long chart_id,const bool show,
             const color cRange,const color cAsia,const color cNY)
     {
      m_chart=chart_id; m_show=show;
      m_colRange=cRange; m_colAsia=cAsia; m_colNY=cNY;
      // sensible defaults; overridden by InitSignals / InitSwings
      m_showSig=true; m_colChoch=clrAqua; m_colIfvg=clrMagenta; m_colSweep=clrYellow;
      m_showSwings=true; m_colSwingHi=clrTomato; m_colSwingLo=clrLimeGreen;
      m_colFvg=clrSlateGray;
     }

   void InitSignals(const bool show,const color cChoch,const color cIfvg,const color cSweep)
     {
      m_showSig=show; m_colChoch=cChoch; m_colIfvg=cIfvg; m_colSweep=cSweep;
     }

   void InitSwings(const bool show,const color cHi,const color cLo)
     {
      m_showSwings=show; m_colSwingHi=cHi; m_colSwingLo=cLo;
     }

   void SetFvgColor(const color c){ m_colFvg=c; }

   //--- A detected swing high/low marker (small dot at the extreme)
   void DrawSwing(const datetime t,const double price,const bool isHigh)
     {
      if(!m_showSwings) return;
      string k=VIS_PREFIX+"SP_"+(isHigh?"H":"L")+(string)(long)t;
      EnsureArrow(k,t,price,159,isHigh?m_colSwingHi:m_colSwingLo);
     }

   void Destroy(){ ObjectsDeleteAll(m_chart,VIS_PREFIX); }

   //--- Wipe every drawing on the chart (called on EA shutdown).
   void ClearAll(){ ObjectsDeleteAll(m_chart,VIS_PREFIX); }

   //--- Wipe every drawing that belongs to a session (sweep target, CHoCH,
   //    IFVG, FVG zones, swing dots, session box, trade levels, and the
   //    Prior-Day 4H range card) the moment that session ends OR a new one
   //    begins. The range card is rebuilt from scratch during the next
   //    20:00->00:00 window (UpdateRangeBox), so nothing needs to survive here.
   void ClearSessionDrawings()
     {
      int total=ObjectsTotal(m_chart,-1,-1);
      for(int i=total-1;i>=0;i--)
        {
         string name=ObjectName(m_chart,i,-1,-1);
         if(StringFind(name,VIS_PREFIX)!=0) continue; // not ours
         ObjectDelete(m_chart,name);
        }
     }

   //--- The single marked low/high to be swept (trails to the newest)
   void DrawSweepTarget(const bool buyBias,const double level,
                        const datetime fromT,const datetime toT,const bool swept)
     {
      if(!m_showSig || level<=0) return;
      string k=VIS_PREFIX+"SWT";
      color c=swept?m_colSweep:clrGold;
      EnsureLine(k+"L",fromT,level,toT,c);
      string t=buyBias?(swept?"low SWEPT":"low to sweep")
                      :(swept?"high SWEPT":"high to sweep");
      EnsureText(k+"T",toT,level,t,c);
     }

   //--- CHoCH: breaking leg + broken structure level + limit price
   void DrawChoch(const string key,const bool isBuy,
                  const datetime legLoT,const double legLo,
                  const datetime legHiT,const double legHi,
                  const datetime structT,const double structLvl,
                  const double limit,const datetime now)
     {
      if(!m_showSig) return;
      string k=VIS_PREFIX+"CH"; // single -> only the newest CHoCH is shown
      // breaking leg, drawn low->high regardless of direction
      EnsureSegment(k+"LEG",legLoT,legLo,legHiT,legHi,m_colChoch,2);
      // broken structure level
      EnsureSegment(k+"STR",structT,structLvl,now,structLvl,m_colChoch,1);
      // limit entry line
      EnsureLine(k+"LIM",now,limit,now+3600,m_colChoch);
      EnsureText(k+"TXT",(isBuy?legHiT:legLoT),(isBuy?legHi:legLo),"CHoCH",m_colChoch);
     }

   //--- Live FVG / IFVG zone (continuous, not tied to a trade)
   void DrawFVG(const int idx,const datetime leftT,const datetime right,
                const double lo,const double hi,const bool inverted,const bool bullish)
     {
      if(!m_showSig) return;
      string k=VIS_PREFIX+"FVG_"+(string)idx;
      color c=inverted?m_colIfvg:m_colFvg;
      EnsureRect(k+"Z",leftT,hi,right,lo,c);
      EnsureText(k+"T",leftT,hi,(inverted?"IFVG":"FVG")+string(bullish?"+":"-"),c);
     }

   void ClearFVGs(const int fromIdx,const int maxIdx)
     {
      for(int i=fromIdx;i<maxIdx;i++)
         ObjectsDeleteAll(m_chart,VIS_PREFIX+"FVG_"+(string)i);
     }

   //--- The level a CHoCH would break next (live watch line)
   void DrawWatch(const bool isBuy,const double level,const datetime fromT,const datetime toT)
     {
      if(!m_showSig || level<=0) return;
      string k=VIS_PREFIX+"WATCH";
      EnsureLine(k+"L",fromT,level,toT,m_colChoch);
      EnsureText(k+"T",toT,level,isBuy?"CHoCH lvl (break up)":"CHoCH lvl (break dn)",m_colChoch);
     }

   //--- IFVG reclaimed zone box
   void DrawIFVG(const string key,const datetime zoneT,const datetime right,
                 const double zoneLo,const double zoneHi)
     {
      if(!m_showSig) return;
      string k=VIS_PREFIX+"IF"; // single -> only the newest IFVG signal is shown
      EnsureRect(k+"Z",zoneT,zoneHi,right,zoneLo,m_colIfvg);
      EnsureText(k+"T",zoneT,zoneHi,"IFVG",m_colIfvg);
     }

   //--- Entry / SL / TP levels + a direction arrow at the fill
   void DrawTrade(const string key,const bool isBuy,const double entry,
                  const double sl,const double tp,const datetime t)
     {
      if(!m_showSig) return;
      string k=VIS_PREFIX+"TR_"+key;
      datetime r=t+3*3600;
      EnsureLine(k+"E",t,entry,r,clrSilver);
      EnsureLine(k+"S",t,sl,r,clrRed);
      EnsureLine(k+"P",t,tp,r,clrLime);
      EnsureArrow(k+"A",t,entry,isBuy?233:234,isBuy?clrLime:clrRed); // up/down arrow
     }

   //--- Prior-day last-4h range box + projected high/low rays
   void DrawPriorRange(const datetime startSrv,const datetime endSrv,
                       const datetime projectTo,const double hi,const double lo)
     {
      if(!m_show || startSrv<=0 || endSrv<=0) return;
      // keyed by the close day so the live build box and the Asia-session
      // redraw share one object (seamless hand-off, no duplicate).
      string tag=DayTag(endSrv);
      // right edge follows the caller: 'now' while building, range-end after.
      // Box only, confined to the 4h window itself - no projected rays, the
      // breakout check against it is the trader's manual job.
      datetime right=(projectTo>startSrv && projectTo<endSrv)?projectTo:endSrv;
      EnsureRect(VIS_PREFIX+"R_"+tag,startSrv,hi,right,lo,m_colRange,false);
      EnsureText(VIS_PREFIX+"RT_"+tag,startSrv,hi,"Prev-Day 4H",m_colRange);
     }

   //--- Developing session range box (Asia/NY)
   void DrawSessionBox(const ENUM_SESSION ses,const datetime startSrv,
                       const datetime rightSrv,const double hi,const double lo)
     {
      if(!m_show || ses==SESSION_NONE || startSrv<=0) return;
      string sn =(ses==SESSION_ASIA)?"ASIA":"NY";
      color  clr=(ses==SESSION_ASIA)?m_colAsia:m_colNY;
      string tag=sn+"_"+DayTag(startSrv);
      EnsureRect(VIS_PREFIX+"S_"+tag,startSrv,hi,rightSrv,lo,clr,false); // outline only
      EnsureText(VIS_PREFIX+"ST_"+tag,startSrv,hi,sn,clr);
     }
  };

#endif // SESSIONS_STRATEGY_VISUALS_MQH

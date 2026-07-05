//+------------------------------------------------------------------+
//|                                                   Dashboard.mqh   |
//|  On-chart status panel: shows live strategy state so the trader   |
//|  can track bias, session, sweep, entry model, caps and position.  |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_DASHBOARD_MQH
#define SESSIONS_STRATEGY_DASHBOARD_MQH

#include "Common.mqh"

#define DASH_PREFIX "SSD_"

class CDashboard
  {
private:
   long   m_chart;
   string m_symbol;
   int    m_digits;
   int    m_x, m_y, m_w, m_lineH, m_rows;

   void Label(const int row,const string text,const color clr)
     {
      string name=DASH_PREFIX+"L"+(string)row;
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_LABEL,0,0,0);
         ObjectSetInteger(m_chart,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,m_x+6);
         ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,m_y+6+row*m_lineH);
         ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,9);
         ObjectSetString (m_chart,name,OBJPROP_FONT,"Consolas");
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetString (m_chart,name,OBJPROP_TEXT,text);
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
     }

   string YN(const bool b) const { return(b?"YES":"no"); }
   string Px(const double p) const { return(p>0?DoubleToString(p,m_digits):"-"); }

public:
   void Init(const long chart_id,const string symbol)
     {
      m_chart=chart_id; m_symbol=symbol;
      m_digits=(int)SymbolInfoInteger(symbol,SYMBOL_DIGITS);
      m_x=10; m_y=70; m_w=300; m_lineH=16; m_rows=10;

      string bg=DASH_PREFIX+"BG";
      ObjectCreate(m_chart,bg,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(m_chart,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chart,bg,OBJPROP_XDISTANCE,m_x);
      ObjectSetInteger(m_chart,bg,OBJPROP_YDISTANCE,m_y);
      ObjectSetInteger(m_chart,bg,OBJPROP_XSIZE,m_w);
      ObjectSetInteger(m_chart,bg,OBJPROP_YSIZE,m_rows*m_lineH+12);
      ObjectSetInteger(m_chart,bg,OBJPROP_BGCOLOR,C'20,20,25');
      ObjectSetInteger(m_chart,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
      ObjectSetInteger(m_chart,bg,OBJPROP_COLOR,clrDimGray);
      ObjectSetInteger(m_chart,bg,OBJPROP_BACK,false);
      ObjectSetInteger(m_chart,bg,OBJPROP_SELECTABLE,false);
     }

   void Destroy(){ ObjectsDeleteAll(m_chart,DASH_PREFIX); }

   void Update(const SStratState &s)
     {
      color cGood=clrLime, cWait=clrGold, cBad=clrTomato, cInfo=clrGainsboro;

      Label(0,"— SESSIONS STRATEGY —",clrWhite);

      string b=(s.bias==BIAS_BUY)?"BUY":(s.bias==BIAS_SELL)?"SELL":"NONE";
      color  bc=(s.bias==BIAS_BUY)?cGood:(s.bias==BIAS_SELL)?cBad:clrSilver;
      Label(1,"Bias        : "+b,bc);

      string ses=(s.session==SESSION_ASIA)?"ASIA":(s.session==SESSION_NY)?"NY":"-";
      Label(2,"Session     : "+ses+"   Window: "+YN(s.inWindow),
            s.session==SESSION_NONE?cInfo:(s.inWindow?cGood:cWait));

      if(s.session==SESSION_ASIA)
         Label(3,"4H Range    : "+(s.rangeValid?Px(s.rangeLo)+" / "+Px(s.rangeHi):"n/a")
               +"  Exit:"+YN(s.rangeExited),
               s.rangeValid?(s.rangeExited?cGood:cWait):cBad);
      else
         Label(3,"4H Range    : "+(s.rangeValid?Px(s.rangeLo)+" / "+Px(s.rangeHi):"n/a")
               +"  (Asia only)",cInfo);

      Label(4,"Sweep       : "+(s.swept?"MET @"+Px(s.sweptLevel):"waiting"),
            s.swept?cGood:cWait);

      string em=s.entryMet?(s.entryModel+" MET"+(s.entryIsLimit?" limit@"+Px(s.entryPrice):" mkt"))
                          :"waiting";
      Label(5,"Entry model : "+em,s.entryMet?cGood:cWait);

      Label(6,"Trades      : "+(string)s.trades+"   Wins: "+(string)s.wins
            +"   CanOpen: "+YN(s.canOpen),s.canOpen?cInfo:cBad);

      string pos=s.positionOpen?StringFormat("OPEN  %.2f%%",s.floatPct):"none";
      Label(7,"Position    : "+pos+(s.pending?"   [LIMIT pending]":""),
            s.positionOpen?cGood:cInfo);

      Label(8,"Note        : "+s.note,cInfo);
      Label(9,"Server "+TimeToString(TimeCurrent(),TIME_DATE|TIME_MINUTES),clrGray);

      ChartRedraw(m_chart);
     }
  };

#endif // SESSIONS_STRATEGY_DASHBOARD_MQH

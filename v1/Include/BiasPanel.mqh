//+------------------------------------------------------------------+
//|                                                    BiasPanel.mqh  |
//|  On-chart BUY / SELL / NONE buttons (charter rule 17).            |
//|                                                                   |
//|  IMPORTANT: the MT5 Strategy Tester does NOT call OnChartEvent,   |
//|  but it DOES toggle a button's pressed-state on click. So we      |
//|  detect clicks by POLLING the button state every tick (PollClicks)|
//|  which works in both the tester and on a live chart.             |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_BIASPANEL_MQH
#define SESSIONS_STRATEGY_BIASPANEL_MQH

#include "Common.mqh"

#define PANEL_PREFIX "SS_"
#define BTN_BUY   PANEL_PREFIX "btnBuy"
#define BTN_SELL  PANEL_PREFIX "btnSell"
#define BTN_NONE  PANEL_PREFIX "btnNone"
#define LBL_STATE PANEL_PREFIX "lblState"

class CBiasPanel
  {
private:
   long      m_chart;
   ENUM_BIAS m_bias;

   void CreateButton(const string name,const int x,const int y,
                     const int w,const string text)
     {
      if(ObjectFind(m_chart,name)<0)
         ObjectCreate(m_chart,name,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(m_chart,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(m_chart,name,OBJPROP_XSIZE,w);
      ObjectSetInteger(m_chart,name,OBJPROP_YSIZE,26);
      ObjectSetString (m_chart,name,OBJPROP_TEXT,text);
      ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,9);
      ObjectSetInteger(m_chart,name,OBJPROP_STATE,false);
      ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(m_chart,name,OBJPROP_ZORDER,10);
     }

   void CreateLabel(const string name,const int x,const int y)
     {
      if(ObjectFind(m_chart,name)<0)
         ObjectCreate(m_chart,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(m_chart,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,x);
      ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,y);
      ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,9);
      ObjectSetString (m_chart,name,OBJPROP_TEXT,"Bias: NONE");
     }

   // selection is shown by COLOUR only; button state is kept un-pressed so a
   // fresh user press (state==true) is unambiguous when polled
   void Style(const string name,const bool selected,const color onColor)
     {
      ObjectSetInteger(m_chart,name,OBJPROP_BGCOLOR,selected?onColor:clrDimGray);
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,  selected?clrWhite:clrSilver);
      ObjectSetInteger(m_chart,name,OBJPROP_STATE,  false);
     }

   bool Pressed(const string name) const
     {
      return((bool)ObjectGetInteger(m_chart,name,OBJPROP_STATE));
     }

   void Highlight()
     {
      Style(BTN_BUY ,m_bias==BIAS_BUY ,clrLimeGreen);
      Style(BTN_SELL,m_bias==BIAS_SELL,clrCrimson);
      Style(BTN_NONE,m_bias==BIAS_NONE,clrSlateGray);
      string t=(m_bias==BIAS_BUY)?"BUY":(m_bias==BIAS_SELL)?"SELL":"NONE";
      color  c=(m_bias==BIAS_BUY)?clrLimeGreen:(m_bias==BIAS_SELL)?clrCrimson:clrSilver;
      ObjectSetString (m_chart,LBL_STATE,OBJPROP_TEXT,"Bias: "+t);
      ObjectSetInteger(m_chart,LBL_STATE,OBJPROP_COLOR,c);
      ChartRedraw(m_chart);
     }

public:
   void Init(const long chart_id)
     {
      m_chart=chart_id;
      m_bias=BIAS_NONE;
      int x=10,y=26,w=72,gap=4;
      CreateLabel(LBL_STATE,x,y-16);
      CreateButton(BTN_BUY ,x,            y,w,"BUY");
      CreateButton(BTN_SELL,x+(w+gap),    y,w,"SELL");
      CreateButton(BTN_NONE,x+2*(w+gap),  y,w,"NONE");
      Highlight();
     }

   void Destroy(){ ObjectsDeleteAll(m_chart,PANEL_PREFIX); }

   //--- Poll button presses (works in the Strategy Tester). Returns
   //    true if the bias changed.
   bool PollClicks()
     {
      ENUM_BIAS nb=m_bias; bool any=false;
      if(Pressed(BTN_BUY)) { nb=BIAS_BUY;  any=true; }
      else if(Pressed(BTN_SELL)){ nb=BIAS_SELL; any=true; }
      else if(Pressed(BTN_NONE)){ nb=BIAS_NONE; any=true; }
      if(!any) return(false);
      bool changed=(nb!=m_bias);
      m_bias=nb;
      Highlight();         // resets all button states to un-pressed
      return(changed);
     }

   //--- Live-chart path (OnChartEvent fires there). Returns true if handled.
   bool OnChartEvent(const int id,const string &sparam)
     {
      if(id!=CHARTEVENT_OBJECT_CLICK) return(false);
      if(sparam==BTN_BUY)       m_bias=BIAS_BUY;
      else if(sparam==BTN_SELL) m_bias=BIAS_SELL;
      else if(sparam==BTN_NONE) m_bias=BIAS_NONE;
      else return(false);
      Highlight();
      return(true);
     }

   void      SetBias(const ENUM_BIAS b){ m_bias=b; Highlight(); }
   ENUM_BIAS Bias() const { return(m_bias); }
  };

#endif // SESSIONS_STRATEGY_BIASPANEL_MQH

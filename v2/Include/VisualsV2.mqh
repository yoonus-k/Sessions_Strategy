//+------------------------------------------------------------------+
//|                                                    VisualsV2.mqh  |
//|  Generic chart-object helpers shared by the v2 test EAs and the   |
//|  integration EA. Ported from v1 Visuals.mqh: every object name is  |
//|  prefixed so a single Destroy()/ClearGroup() wipes cleanly.        |
//|                                                                   |
//|  Higher-level, strategy-specific drawings (bands, zone strip,      |
//|  quality boxes, triggers) are added by the modules/tests that own  |
//|  them; this file only provides the primitives + a few common ones. |
//+------------------------------------------------------------------+
#ifndef V2_VISUALS_MQH
#define V2_VISUALS_MQH

#include "V2Common.mqh"

#define V2V_PREFIX "V2V_"

class CVisualsV2
  {
private:
   long m_chart;
   bool m_on;

public:
   void Init(const long chart_id,const bool enabled=true)
     {
      m_chart=chart_id;
      m_on=enabled;
     }

   void Enable(const bool e){ m_on=e; }
   bool Enabled() const { return(m_on); }

   //--- wipe everything this class ever drew
   void Destroy(){ ObjectsDeleteAll(m_chart,V2V_PREFIX); }

   //--- wipe one named group ("<V2V_PREFIX><group>")
   void ClearGroup(const string group){ ObjectsDeleteAll(m_chart,V2V_PREFIX+group); }

   string Name(const string group,const string id) const { return(V2V_PREFIX+group+"_"+id); }

   //================================================================
   //  PRIMITIVES  (create-once, then update in place)
   //================================================================

   void Rect(const string name,const datetime t1,const double p1,
             const datetime t2,const double p2,const color clr,
             const bool fill=false,const int width=1)
     {
      if(!m_on) return;
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_RECTANGLE,0,t1,p1,t2,p2);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_FILL,fill);
      ObjectSetInteger(m_chart,name,OBJPROP_BACK,fill); // filled -> behind candles; outline -> in front
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(m_chart,name,OBJPROP_WIDTH,width);
      ObjectMove(m_chart,name,0,t1,p1);
      ObjectMove(m_chart,name,1,t2,p2);
     }

   void Segment(const string name,const datetime t1,const double p1,
                const datetime t2,const double p2,const color clr,
                const int width=1,const int style=STYLE_SOLID)
     {
      if(!m_on) return;
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_TREND,0,t1,p1,t2,p2);
         ObjectSetInteger(m_chart,name,OBJPROP_RAY_RIGHT,false);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(m_chart,name,OBJPROP_WIDTH,width);
      ObjectSetInteger(m_chart,name,OBJPROP_STYLE,style);
      ObjectMove(m_chart,name,0,t1,p1);
      ObjectMove(m_chart,name,1,t2,p2);
     }

   void RayH(const string name,const datetime t1,const double p,
             const datetime t2,const color clr,const int style=STYLE_DOT)
     {
      if(!m_on) return;
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_TREND,0,t1,p,t2,p);
         ObjectSetInteger(m_chart,name,OBJPROP_RAY_RIGHT,true);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(m_chart,name,OBJPROP_STYLE,style);
      ObjectMove(m_chart,name,0,t1,p);
      ObjectMove(m_chart,name,1,t2,p);
     }

   void VLine(const string name,const datetime t,const color clr,
              const int style=STYLE_DOT,const int width=1)
     {
      if(!m_on) return;
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_VLINE,0,t,0);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
         ObjectSetInteger(m_chart,name,OBJPROP_BACK,true);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(m_chart,name,OBJPROP_STYLE,style);
      ObjectSetInteger(m_chart,name,OBJPROP_WIDTH,width);
      ObjectMove(m_chart,name,0,t,0);
     }

   void Arrow(const string name,const datetime t,const double p,
              const int code,const color clr,const int width=2,
              const ENUM_ARROW_ANCHOR anchor=ANCHOR_BOTTOM)
     {
      if(!m_on) return;
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_ARROW,0,t,p);
         ObjectSetInteger(m_chart,name,OBJPROP_ARROWCODE,code);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectSetInteger(m_chart,name,OBJPROP_WIDTH,width);
      ObjectSetInteger(m_chart,name,OBJPROP_ANCHOR,anchor);
      ObjectMove(m_chart,name,0,t,p);
     }

   void Text(const string name,const datetime t,const double p,
             const string txt,const color clr,const int fontsize=8,
             const ENUM_ANCHOR_POINT anchor=ANCHOR_LEFT_LOWER)
     {
      if(!m_on) return;
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_TEXT,0,t,p);
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,name,OBJPROP_ANCHOR,anchor);
      ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,fontsize);
      ObjectSetString (m_chart,name,OBJPROP_TEXT,txt);
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
      ObjectMove(m_chart,name,0,t,p);
     }

   //--- current visible price band, for price-independent boxes/labels
   double PriceMin() const { return(ChartGetDouble(m_chart,CHART_PRICE_MIN,0)); }
   double PriceMax() const { return(ChartGetDouble(m_chart,CHART_PRICE_MAX,0)); }

   void Redraw(){ ChartRedraw(m_chart); }
  };

#endif // V2_VISUALS_MQH

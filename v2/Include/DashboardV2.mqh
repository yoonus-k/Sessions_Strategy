//+------------------------------------------------------------------+
//|                                                  DashboardV2.mqh  |
//|  Simple on-chart text panel: a background rectangle + a column of  |
//|  monospaced label rows. The caller writes one row per field it     |
//|  wants shown (Line), then Render() once. Ported/trimmed from v1.   |
//+------------------------------------------------------------------+
#ifndef V2_DASHBOARD_MQH
#define V2_DASHBOARD_MQH

#include "V2Common.mqh"

#define V2D_PREFIX "V2D_"

class CDashboardV2
  {
private:
   long m_chart;
   int  m_x,m_y,m_w,m_lineH,m_rows;
   int  m_maxRowSeen;

   void EnsureBG()
     {
      string bg=V2D_PREFIX+"BG";
      if(ObjectFind(m_chart,bg)<0)
        {
         ObjectCreate(m_chart,bg,OBJ_RECTANGLE_LABEL,0,0,0);
         ObjectSetInteger(m_chart,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chart,bg,OBJPROP_XDISTANCE,m_x);
         ObjectSetInteger(m_chart,bg,OBJPROP_YDISTANCE,m_y);
         ObjectSetInteger(m_chart,bg,OBJPROP_BGCOLOR,C'18,18,22');
         ObjectSetInteger(m_chart,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
         ObjectSetInteger(m_chart,bg,OBJPROP_COLOR,clrDimGray);
         ObjectSetInteger(m_chart,bg,OBJPROP_BACK,false);
         ObjectSetInteger(m_chart,bg,OBJPROP_SELECTABLE,false);
        }
      ObjectSetInteger(m_chart,bg,OBJPROP_XSIZE,m_w);
      ObjectSetInteger(m_chart,bg,OBJPROP_YSIZE,(m_maxRowSeen+2)*m_lineH+10);
     }

public:
   void Init(const long chart_id,const int x=12,const int y=24,
             const int width=430,const int lineH=15)
     {
      m_chart=chart_id;
      m_x=x; m_y=y; m_w=width; m_lineH=lineH; m_rows=0; m_maxRowSeen=0;
      EnsureBG();
     }

   void Destroy(){ ObjectsDeleteAll(m_chart,V2D_PREFIX); }

   //--- write / update one row
   void Line(const int row,const string text,const color clr=clrGainsboro)
     {
      if(row>m_maxRowSeen) m_maxRowSeen=row;
      string name=V2D_PREFIX+"L"+(string)row;
      if(ObjectFind(m_chart,name)<0)
        {
         ObjectCreate(m_chart,name,OBJ_LABEL,0,0,0);
         ObjectSetInteger(m_chart,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chart,name,OBJPROP_XDISTANCE,m_x+8);
         ObjectSetInteger(m_chart,name,OBJPROP_YDISTANCE,m_y+6+row*m_lineH);
         ObjectSetInteger(m_chart,name,OBJPROP_FONTSIZE,9);
         ObjectSetString (m_chart,name,OBJPROP_FONT,"Consolas");
         ObjectSetInteger(m_chart,name,OBJPROP_SELECTABLE,false);
        }
      ObjectSetString (m_chart,name,OBJPROP_TEXT,text);
      ObjectSetInteger(m_chart,name,OBJPROP_COLOR,clr);
     }

   //--- "key : value" convenience (key left-padded to a fixed width)
   void KV(const int row,const string key,const string value,
           const color clr=clrGainsboro,const int keyw=14)
     {
      string k=key;
      while(StringLen(k)<keyw) k+=" ";
      Line(row,k+": "+value,clr);
     }

   void Title(const int row,const string text){ Line(row,text,clrWhite); }

   void Render()
     {
      EnsureBG();
      ChartRedraw(m_chart);
     }
  };

#endif // V2_DASHBOARD_MQH

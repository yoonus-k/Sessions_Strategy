//+------------------------------------------------------------------+
//|                                                 TradeJournal.mqh  |
//|  Excel trade report (charter rule 16).                           |
//|  One row per CLOSED trade: day, session, bias, model, lots,      |
//|  profit/loss, WIN/LOSS, account balance after the trade, and the |
//|  balance as it would be WITHOUT Friday & Monday trades. Two      |
//|  summary blocks (all trades / excluding Fri & Mon).              |
//|                                                                  |
//|  SINGLE file, in the COMMON folder (one fixed path shared by the |
//|  tester and live charts):                                        |
//|   <AppData>/MetaQuotes/Terminal/Common/Files/                    |
//|     SessionsStrategy_Report_<symbol>.xls                         |
//|  Styled Excel XML: real columns, set widths, colored WIN/LOSS.   |
//|  A tester run starts it fresh; a live chart re-reads its own     |
//|  rows on restart and continues the same file.                    |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_TRADEJOURNAL_MQH
#define SESSIONS_STRATEGY_TRADEJOURNAL_MQH

#include "Common.mqh"

class CTradeJournal
  {
private:
   bool   m_enabled;
   string m_excel;
   // closed trades kept in memory; each row = 11 ';'-separated fields:
   // No;Day;Date;Session;Bias;Model;Lots;Profit;Result;Balance;ExBalance
   string m_rows[];
   double m_profits[];
   bool   m_friMon[];
   int    m_count;
   double m_lastBalance;

   void Push(const string row,const double profit,const bool friMon,
             const double balance)
     {
      ArrayResize(m_rows,m_count+1);
      ArrayResize(m_profits,m_count+1);
      ArrayResize(m_friMon,m_count+1);
      m_rows[m_count]=row; m_profits[m_count]=profit; m_friMon[m_count]=friMon;
      m_count++;
      m_lastBalance=balance;
     }

   //--- net P/L of the Friday & Monday trades stored so far
   double FriMonNet() const
     {
      double s=0;
      for(int i=0;i<m_count;i++) if(m_friMon[i]) s+=m_profits[i];
      return(s);
     }

   //--- extract the 11 <Data>values</Data> of one of OUR data rows
   bool ParseXlsRow(const string line,string &f[])
     {
      if(StringFind(line,"<Row><Cell ss:StyleID=\"winS\"")!=0 &&
         StringFind(line,"<Row><Cell ss:StyleID=\"lossS\"")!=0) return(false);
      ArrayResize(f,0); int cnt=0, pos=0;
      while(true)
        {
         int d=StringFind(line,"<Data",pos);          if(d<0)  break;
         int gt=StringFind(line,">",d);               if(gt<0) break;
         int end=StringFind(line,"</Data>",gt);       if(end<0)break;
         ArrayResize(f,cnt+1);
         f[cnt++]=StringSubstr(line,gt+1,end-gt-1);
         pos=end+7;
        }
      return(cnt>=11);
     }

   //--- reload our own rows from the .xls (live restarts keep history)
   void LoadExcel()
     {
      m_count=0; m_lastBalance=0;
      if(!FileIsExist(m_excel,FILE_COMMON)) return;
      int h=FileOpen(m_excel,FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h==INVALID_HANDLE) return;
      while(!FileIsEnding(h))
        {
         string line=FileReadString(h);
         string f[];
         if(!ParseXlsRow(line,f)) continue;
         string row=f[0];
         for(int k=1;k<11;k++) row+=";"+f[k];
         Push(row,StringToDouble(f[7]),
              (f[1]=="Friday"||f[1]=="Monday"),StringToDouble(f[9]));
        }
      FileClose(h);
     }

   //--- one spreadsheet cell
   string Cell(const string v,const bool num,const string style) const
     {
      return("<Cell ss:StyleID=\""+style+"\"><Data ss:Type=\""
             +(num?"Number":"String")+"\">"+v+"</Data></Cell>");
     }

   void WriteSummaryXml(const int h,const string title,const bool exclFriMon)
     {
      int n=0,w=0,l=0; double gw=0,gl=0;
      for(int i=0;i<m_count;i++)
        {
         if(exclFriMon && m_friMon[i]) continue;
         n++;
         if(m_profits[i]>0){ w++; gw+=m_profits[i]; }
         else              { l++; gl+=m_profits[i]; }
        }
      double finalBal=exclFriMon?m_lastBalance-FriMonNet():m_lastBalance;

      FileWriteString(h,"<Row/>\r\n");
      FileWriteString(h,"<Row ss:Height=\"20\"><Cell ss:MergeAcross=\"10\" ss:StyleID=\"sumT\">"
                        "<Data ss:Type=\"String\">"+title+"</Data></Cell></Row>\r\n");
      string lab[6]={"Trades","Wins","Losses","Total profit","Total loss","Net P/L"};
      string val[6]={(string)n,(string)w,(string)l,
                     DoubleToString(gw,2),DoubleToString(gl,2),DoubleToString(gw+gl,2)};
      for(int k=0;k<6;k++)
         FileWriteString(h,"<Row>"+Cell(lab[k],false,"sumL")+Cell(val[k],true,"sumV")+"</Row>\r\n");
      FileWriteString(h,"<Row>"+Cell("Final balance",false,"sumL")
                        +Cell(DoubleToString(finalBal,2),true,"sumV")+"</Row>\r\n");
     }

   void WriteExcel()
     {
      int h=FileOpen(m_excel,FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h==INVALID_HANDLE) return;

      FileWriteString(h,
        "<?xml version=\"1.0\"?>\r\n"
        "<?mso-application progid=\"Excel.Sheet\"?>\r\n"
        "<Workbook xmlns=\"urn:schemas-microsoft-com:office:spreadsheet\"\r\n"
        " xmlns:ss=\"urn:schemas-microsoft-com:office:spreadsheet\">\r\n"
        "<Styles>\r\n"
        " <Style ss:ID=\"hdr\"><Font ss:Bold=\"1\" ss:Color=\"#FFFFFF\"/>"
        "<Interior ss:Color=\"#4472C4\" ss:Pattern=\"Solid\"/>"
        "<Alignment ss:Horizontal=\"Center\" ss:Vertical=\"Center\"/></Style>\r\n"
        " <Style ss:ID=\"winS\"><Interior ss:Color=\"#C6EFCE\" ss:Pattern=\"Solid\"/>"
        "<Font ss:Color=\"#006100\"/><Alignment ss:Horizontal=\"Center\"/></Style>\r\n"
        " <Style ss:ID=\"winN\"><Interior ss:Color=\"#C6EFCE\" ss:Pattern=\"Solid\"/>"
        "<Font ss:Color=\"#006100\"/><NumberFormat ss:Format=\"#,##0.00\"/>"
        "<Alignment ss:Horizontal=\"Center\"/></Style>\r\n"
        " <Style ss:ID=\"lossS\"><Interior ss:Color=\"#FFC7CE\" ss:Pattern=\"Solid\"/>"
        "<Font ss:Color=\"#9C0006\"/><Alignment ss:Horizontal=\"Center\"/></Style>\r\n"
        " <Style ss:ID=\"lossN\"><Interior ss:Color=\"#FFC7CE\" ss:Pattern=\"Solid\"/>"
        "<Font ss:Color=\"#9C0006\"/><NumberFormat ss:Format=\"#,##0.00\"/>"
        "<Alignment ss:Horizontal=\"Center\"/></Style>\r\n"
        " <Style ss:ID=\"sumT\"><Font ss:Bold=\"1\" ss:Size=\"12\" ss:Color=\"#FFFFFF\"/>"
        "<Interior ss:Color=\"#305496\" ss:Pattern=\"Solid\"/>"
        "<Alignment ss:Horizontal=\"Center\"/></Style>\r\n"
        " <Style ss:ID=\"sumL\"><Font ss:Bold=\"1\"/>"
        "<Interior ss:Color=\"#D9E1F2\" ss:Pattern=\"Solid\"/></Style>\r\n"
        " <Style ss:ID=\"sumV\"><Font ss:Bold=\"1\"/>"
        "<Interior ss:Color=\"#D9E1F2\" ss:Pattern=\"Solid\"/>"
        "<NumberFormat ss:Format=\"#,##0.00\"/>"
        "<Alignment ss:Horizontal=\"Center\"/></Style>\r\n"
        "</Styles>\r\n"
        "<Worksheet ss:Name=\"Trades\"><Table ss:DefaultRowHeight=\"18\">\r\n");

      int widths[11]={35,85,80,65,55,65,55,95,60,100,130};
      for(int c=0;c<11;c++)
         FileWriteString(h,StringFormat("<Column ss:Width=\"%d\"/>\r\n",widths[c]));

      string heads[11]={"No","Day","Date","Session","Bias","Model","Lots",
                        "Profit/Loss","Result","Balance","Balance ex Fri&amp;Mon"};
      FileWriteString(h,"<Row ss:Height=\"24\">");
      for(int c=0;c<11;c++)
         FileWriteString(h,Cell(heads[c],false,"hdr"));
      FileWriteString(h,"</Row>\r\n");

      for(int i=0;i<m_count;i++)
        {
         string f[];
         if(StringSplit(m_rows[i],';',f)<11) continue;
         bool win=(f[8]=="WIN");
         string sS=win?"winS":"lossS", sN=win?"winN":"lossN";
         FileWriteString(h,"<Row>"
            +Cell(f[0],true ,sS)   // No
            +Cell(f[1],false,sS)   // Day
            +Cell(f[2],false,sS)   // Date
            +Cell(f[3],false,sS)   // Session
            +Cell(f[4],false,sS)   // Bias
            +Cell(f[5],false,sS)   // Model
            +Cell(f[6],true ,sN)   // Lots
            +Cell(f[7],true ,sN)   // Profit/Loss
            +Cell(f[8],false,sS)   // Result
            +Cell(f[9],true ,sN)   // Balance
            +Cell(f[10],true,sN)   // Balance ex Fri&Mon
            +"</Row>\r\n");
        }

      WriteSummaryXml(h,"SUMMARY - ALL TRADES",false);
      WriteSummaryXml(h,"SUMMARY - EXCLUDING FRIDAY &amp; MONDAY",true);

      FileWriteString(h,"</Table></Worksheet></Workbook>\r\n");
      FileClose(h);
     }

public:
   void Init(const bool enabled,const string symbol)
     {
      m_enabled=enabled;
      m_excel="SessionsStrategy_Report_"+symbol+".xls";
      m_count=0; m_lastBalance=0;
      if(!m_enabled) return;
      // a tester run starts fresh (otherwise every backtest would pile its
      // trades onto the previous run's file); a live chart continues it
      if((bool)MQLInfoInteger(MQL_TESTER))
         FileDelete(m_excel,FILE_COMMON);
      else
         LoadExcel();
     }

   //--- one closed trade -> report row + rewritten totals (Excel file)
   void LogTrade(const string day,const datetime closeTime,const string session,
                 const string bias,const string model,const double lots,
                 const double profitMoney,const double balance)
     {
      if(!m_enabled) return;
      bool friMon=(day=="Friday"||day=="Monday");
      // balance as if Fri & Mon trades never happened (incl. this one)
      double exBal=balance-(FriMonNet()+(friMon?profitMoney:0));
      string row=StringFormat("%d;%s;%s;%s;%s;%s;%.2f;%.2f;%s;%.2f;%.2f",
             m_count+1,day,TimeToString(closeTime,TIME_DATE),session,bias,model,
             lots,profitMoney,profitMoney>0?"WIN":"LOSS",balance,exBal);
      Push(row,profitMoney,friMon,balance);
      WriteExcel();
     }
  };

#endif // SESSIONS_STRATEGY_TRADEJOURNAL_MQH

//+------------------------------------------------------------------+
//|                                                 TradeJournal.mqh  |
//|  CSV journal for end-of-day documentation (charter rule 16).     |
//|  Profit distribution column uses (profit% * 2) per rule 18.      |
//|  File lives in <terminal>/MQL5/Files/.                           |
//+------------------------------------------------------------------+
#ifndef SESSIONS_STRATEGY_TRADEJOURNAL_MQH
#define SESSIONS_STRATEGY_TRADEJOURNAL_MQH

#include "Common.mqh"

class CTradeJournal
  {
private:
   bool   m_enabled;
   string m_file;

   void Append(const string line)
     {
      if(!m_enabled) return;
      int h=FileOpen(m_file,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
      if(h==INVALID_HANDLE) return;
      FileSeek(h,0,SEEK_END);
      FileWriteString(h,line+"\r\n");
      FileClose(h);
     }

public:
   void Init(const bool enabled,const string symbol)
     {
      m_enabled=enabled;
      m_file="SessionsStrategy_"+symbol+".csv";
      if(!m_enabled) return;
      if(!FileIsExist(m_file))
        {
         int h=FileOpen(m_file,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
         if(h!=INVALID_HANDLE)
           {
            FileWriteString(h,"Type,Time,Ticket,Session,Bias,Model,Lots,Entry,SL,Exit,ProfitMoney,ProfitPct,Distribution(x2)\r\n");
            FileClose(h);
           }
        }
     }

   void LogOpen(const ulong ticket,const datetime t,const string session,
                const string bias,const string model,const double lots,
                const double entry,const double sl)
     {
      Append(StringFormat("OPEN,%s,%I64u,%s,%s,%s,%.2f,%.2f,%.2f,,,,",
             TimeToString(t,TIME_DATE|TIME_MINUTES),ticket,session,bias,model,
             lots,entry,sl));
     }

   void LogClose(const ulong ticket,const datetime t,const double exit,
                 const double profitMoney,const double profitPct)
     {
      Append(StringFormat("CLOSE,%s,%I64u,,,,,,,%.2f,%.2f,%.2f,%.2f",
             TimeToString(t,TIME_DATE|TIME_MINUTES),ticket,exit,
             profitMoney,profitPct,profitPct*2.0));
     }
  };

#endif // SESSIONS_STRATEGY_TRADEJOURNAL_MQH

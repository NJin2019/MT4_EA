//+------------------------------------------------------------------+
//|  MultiCondition_EA.mq4                                            |
//|  纯J线反转追踪: J谷→做多  J峰→做空  反转即平仓反手                |
//|  最多1单常持, 不设SL/TP, 靠下一个J反转自然离场                    |
//+------------------------------------------------------------------+
#property copyright "NJin"
#property version   "2.30"
#property strict

//+------------------------------------------------------------------+
//| 参数                                                               |
//+------------------------------------------------------------------+
//--- [1] 交易基础
input double InpLotSize        = 0.01;   // 开仓手数
input int    InpMagicNumber    = 240801; // Magic Number
input int    InpSlippage       = 30;     // 滑点(点数)
input int    InpMaxLong        = 1;      // 最大多单数
input int    InpMaxShort       = 1;      // 最大空单数

//--- [2] KDJ (用于计算J线)
input int    InpKDJK           = 9;      // K周期
input int    InpKDJD           = 3;      // D周期
input int    InpKDJSlowing     = 3;      // 慢速

//--- [3] J线反转参数
input double InpMinReversal    = 15.0;   // 最小反转幅度(J点数, 过滤小波动)
input double InpConfirmPoints   = 5.0;    // 确认点数(j0需超出j1此点数才算确认反转)

//--- [4] 趋势过滤(EMA)
input bool   InpUseEMAFilter   = true;   // 用EMA趋势过滤方向
input int    InpEMAPeriod      = 50;     // EMA周期

//--- [5] 布林带过滤
input bool   InpUseBollFilter  = false;  // 用布林带方向过滤
input int    InpBollPeriod     = 20;     // 布林带周期
input double InpBollDeviation  = 2.0;    // 布林带偏差

//--- [6] 风控
input double InpMaxSpread      = 30;     // 最大点差

//--- [7] 调试
input bool   InpDebugMode      = true;   // 调试模式

//+------------------------------------------------------------------+
//| 全局                                                               |
//+------------------------------------------------------------------+
datetime g_last_bar_time = 0;
bool     g_traded_this_bar = false;    // 本根K线是否已交易过

//+------------------------------------------------------------------+
int OnInit()
{
   Print("╔══════════════════════════════════════╗");
   Print("║  J线反转追踪 v2.30 已启动             ║");
   Print("╚══════════════════════════════════════╝");
   Print("KDJ(", InpKDJK, ",", InpKDJD, ",", InpKDJSlowing, ")  反转幅度≥", InpMinReversal, "  确认≥", InpConfirmPoints);
   Print("EMA趋势过滤:", InpUseEMAFilter ? "ON" : "OFF", "  周期:", InpEMAPeriod);
   Print("持仓上限: 多", InpMaxLong, "单  空", InpMaxShort, "单");
   Print("布林过滤:", InpUseBollFilter ? "ON" : "OFF", "  (", InpBollPeriod, ",", InpBollDeviation, ")");
   Print("手数:", InpLotSize, "  |  不设SL/TP, 反转即离场");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("J线反转追踪 EA 已停止, 代码:", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
   //--- 点差过滤
   if(MarketInfo(_Symbol, MODE_SPREAD) > InpMaxSpread) return;

   //--- 新K线检测(重置本根K线交易标志)
   if(Time[0] != g_last_bar_time)
   {
      g_last_bar_time = Time[0];
      g_traded_this_bar = false;
   }

   //--- 每Tick检查J线反转(已交易过本K线则跳过)
   if(g_traded_this_bar) return;

   double k2, d2, k1, d1, k0, d0;
   double j2 = JValue(2, k2, d2);     // bar[2] 已闭合,不变
   double j1 = JValue(1, k1, d1);     // bar[1] 已闭合,不变
   double j0 = JValue(0, k0, d0);     // bar[0] 随Tick变化

   double diff_12 = j1 - j2;           // bar[1]相对于bar[2]的变动(不变)
   double diff_01 = j0 - j1;           // bar[0]相对于bar[1]的变动(每Tick变)

   // J谷形态(多): bar[2] > bar[1], 且 bar[0]已从bar[1]回升确认点数
   bool valley = (j2 > j1 && diff_01 >= InpConfirmPoints && MathAbs(diff_12) >= InpMinReversal);
   // J峰形态(空): bar[2] < bar[1], 且 bar[0]已从bar[1]回落确认点数
   bool peak   = (j2 < j1 && -diff_01 >= InpConfirmPoints && MathAbs(diff_12) >= InpMinReversal);

   if(InpDebugMode && (valley || peak))
   {
      Print("╔══ [", TimeToStr(TimeCurrent(), TIME_DATE|TIME_MINUTES), "] ═══════════════════════");
      Print("║ J值: bar[2]=", DoubleToStr(j2, 1), "  bar[1]=", DoubleToStr(j1, 1), "  bar[0]=", DoubleToStr(j0, 1));
      Print("║ Δ(1-2)=", DoubleToStr(diff_12, 1), " [阈值", InpMinReversal, "]  Δ(0-1)=", DoubleToStr(diff_01, 1), " [确认", InpConfirmPoints, "]");
      if(valley) Print("║ → J谷反转 触发做多");
      if(peak)   Print("║ → J峰反转 触发做空");
   }

   if(!valley && !peak) return;

   g_traded_this_bar = true;   // 本K线已处理,不再重复触发

   //--- 统计当前持仓
   int long_count = 0, short_count = 0;
   int long_tickets[], short_tickets[];
   ArrayResize(long_tickets, 0);
   ArrayResize(short_tickets, 0);
   int i;
   for(i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()     != _Symbol)        continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() == OP_BUY)
         { long_count++; int s = ArraySize(long_tickets); ArrayResize(long_tickets, s+1); long_tickets[s] = OrderTicket(); }
      else if(OrderType() == OP_SELL)
         { short_count++; int s = ArraySize(short_tickets); ArrayResize(short_tickets, s+1); short_tickets[s] = OrderTicket(); }
   }

   //===== 阶段1: J拐点即平仓 =====
   if(valley)
   {
      for(i = ArraySize(short_tickets) - 1; i >= 0; i--)
         ClosePosition(short_tickets[i], "J谷平空");
   }
   else if(peak)
   {
      for(i = ArraySize(long_tickets) - 1; i >= 0; i--)
         ClosePosition(long_tickets[i], "J峰平多");
   }

   //===== 阶段2: 满足条件开仓 =====
   // 重新统计
   long_count = 0; short_count = 0;
   for(i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()     != _Symbol)        continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() == OP_BUY) long_count++;
      else if(OrderType() == OP_SELL) short_count++;
   }

   bool can_open_long  = valley && long_count < InpMaxLong;
   bool can_open_short = peak   && short_count < InpMaxShort;

   // 布林带方向过滤
   if(InpUseBollFilter && (can_open_long || can_open_short))
   {
      double mid = iBands(_Symbol, 0, InpBollPeriod, InpBollDeviation,
                          0, PRICE_CLOSE, MODE_MAIN, 1);
      double bid = MarketInfo(_Symbol, MODE_BID);
      if(can_open_long && bid > mid)
      {
         if(InpDebugMode) Print("║ 做多被过滤: Bid>Mid");
         can_open_long = false;
      }
      if(can_open_short && bid < mid)
      {
         if(InpDebugMode) Print("║ 做空被过滤: Bid<Mid");
         can_open_short = false;
      }
   }

   // 趋势过滤(EMA)
   if(InpUseEMAFilter && (can_open_long || can_open_short))
   {
      double ema1 = iMA(_Symbol, 0, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
      double ema5 = iMA(_Symbol, 0, InpEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 5);
      bool trend_up   = (ema1 > ema5);    // EMA上升
      bool trend_down = (ema1 < ema5);    // EMA下降

      if(InpDebugMode)
         Print("║ EMA趋势: ema[1]=", DoubleToStr(ema1, 5), "  ema[5]=", DoubleToStr(ema5, 5),
               "  → ", trend_up ? "上升(只做多)" : (trend_down ? "下降(只做空)" : "横盘"));

      if(can_open_long && trend_down)
      {
         if(InpDebugMode) Print("║ 做多被EMA过滤: 趋势向下");
         can_open_long = false;
      }
      if(can_open_short && trend_up)
      {
         if(InpDebugMode) Print("║ 做空被EMA过滤: 趋势向上");
         can_open_short = false;
      }
   }

   if(can_open_long)  OpenLong();
   if(can_open_short) OpenShort();
}

//+------------------------------------------------------------------+
//| 获取 J 线值及 K/D  J = 3*K - 2*D                                   |
//+------------------------------------------------------------------+
double JValue(int bar, double &k_val, double &d_val)
{
   k_val = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                       MODE_SMA, 0, MODE_MAIN, bar);
   d_val = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                       MODE_SMA, 0, MODE_SIGNAL, bar);
   return 3.0 * k_val - 2.0 * d_val;
}

//+------------------------------------------------------------------+
//| 平仓                                                               |
//+------------------------------------------------------------------+
void ClosePosition(int ticket, string reason)
{
   if(!OrderSelect(ticket, SELECT_BY_TICKET)) return;

   RefreshRates();
   double price = (OrderType() == OP_BUY) ? MarketInfo(_Symbol, MODE_BID)
                                          : MarketInfo(_Symbol, MODE_ASK);
   bool res = OrderClose(ticket, OrderLots(), price, InpSlippage, clrYellow);

   if(res)
      Print("━━━ [", reason, "] 平仓 Ticket:", ticket,
            "  盈利:", DoubleToStr(OrderProfit(), 2));
   else
      Print("!!! 平仓失败 Ticket:", ticket, " Error:", GetLastError());
}

//+------------------------------------------------------------------+
//| 开多单                                                             |
//+------------------------------------------------------------------+
void OpenLong()
{
   RefreshRates();
   double ask = MarketInfo(_Symbol, MODE_ASK);
   int ticket = OrderSend(_Symbol, OP_BUY, InpLotSize, ask, InpSlippage,
                          0, 0, "J_Tracker_Long", InpMagicNumber, 0, clrBlue);
   if(ticket > 0)
      Print("━━━ ▶ [J谷做多] Ticket:", ticket,
            "  价格:", DoubleToStr(ask, (int)MarketInfo(_Symbol, MODE_DIGITS)));
   else
      Print("!!! 开多失败 Error:", GetLastError());
}

//+------------------------------------------------------------------+
//| 开空单                                                             |
//+------------------------------------------------------------------+
void OpenShort()
{
   RefreshRates();
   double bid = MarketInfo(_Symbol, MODE_BID);
   int ticket = OrderSend(_Symbol, OP_SELL, InpLotSize, bid, InpSlippage,
                          0, 0, "J_Tracker_Short", InpMagicNumber, 0, clrRed);
   if(ticket > 0)
      Print("━━━ ▶ [J峰做空] Ticket:", ticket,
            "  价格:", DoubleToStr(bid, (int)MarketInfo(_Symbol, MODE_DIGITS)));
   else
      Print("!!! 开空失败 Error:", GetLastError());
}
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//|                                              MACD_Strategy.mq4   |
//|                              MACD 金叉买入 + 差距数组追踪截单策略   |
//|                                                                  |
//| 逻辑说明：                                                         |
//|  1. 检测 MACD 快线和慢线同时在零轴以上，且快线从下向上穿越慢线（金叉）  |
//|  2. 满足条件时打印买入价格，开 0.05 手 Buy 单                        |
//|  3. 设置止盈 200 点                                                |
//|  4. 用 12 元素循环数组追踪快线与慢线的差距（每个 5 分钟 K 线一个值）   |
//|  5. 最新差距为正数 → 继续持有；为负数 → 快慢线交汇，立即平仓截单       |
//|  6. 截单后打印盈利并清空数组                                         |
//+------------------------------------------------------------------+
#property copyright "MACD Strategy EA"
#property version   "1.00"
#property strict

//--- 输入参数
extern double Lots          = 0.05;   // 交易手数
extern int    TakeProfit    = 200;    // 止盈点数（point）
extern int    Slippage      = 3;      // 允许滑点
extern int    MagicNumber   = 20260529; // 订单魔术号

//--- MACD 参数
extern int    FastEMA       = 12;     // 快速 EMA 周期
extern int    SlowEMA       = 26;     // 慢速 EMA 周期
extern int    SignalSMA     = 9;      // 信号线 SMA 周期

//--- 差距追踪数组参数
#define GAP_SIZE 12                    // 差距数组大小（12 个 5 分钟 K 线 = 1 小时）

//--- 全局变量
double   gapArray[GAP_SIZE];           // 循环数组：存放快线与慢线的差距
int      gapIndex      = 0;            // 当前循环数组写入位置
int      gapCount      = 0;            // 已填入的有效元素数量
datetime lastBarTime   = 0;           // 上一根 5 分钟 K 线的时间戳（用于检测新 K 线）

//+------------------------------------------------------------------+
//| EA 初始化函数                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- 清空差距数组
   ResetGapArray();
   lastBarTime = 0;

   Print("MACD 金叉策略 EA 已启动。手数=", Lots,
         " 止盈=", TakeProfit, " 点  差距数组大小=", GAP_SIZE);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| EA 反初始化函数                                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("MACD 金叉策略 EA 已停止。原因代码=", reason);
}

//+------------------------------------------------------------------+
//| 主循环：每个 tick 调用一次                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 仅在新的 5 分钟 K 线开始时处理一次逻辑（防止重复开单/重复计算）
   datetime curBarTime = iTime(Symbol(), PERIOD_M5, 0);
   if(curBarTime == lastBarTime)
      return;                          // 同一根 K 线内，不重复处理
   lastBarTime = curBarTime;

   //--- 读取已完成的上一根 5 分钟 K 线（shift=1）的 MACD 数值
   //    使用已收盘 K 线，避免当前未完成 K 线的数值跳动
   double macdMainPrev = iMACD(Symbol(), PERIOD_M5, FastEMA, SlowEMA, SignalSMA,
                               PRICE_CLOSE, MODE_MAIN, 1);   // 快线（MACD 主线）
   double macdSignPrev = iMACD(Symbol(), PERIOD_M5, FastEMA, SlowEMA, SignalSMA,
                               PRICE_CLOSE, MODE_SIGNAL, 1); // 慢线（信号线）

   //--- 读取再上一根 K 线（shift=2）的 MACD 数值，用于判断金叉穿越
   double macdMainPrev2 = iMACD(Symbol(), PERIOD_M5, FastEMA, SlowEMA, SignalSMA,
                                PRICE_CLOSE, MODE_MAIN, 2);
   double macdSignPrev2 = iMACD(Symbol(), PERIOD_M5, FastEMA, SlowEMA, SignalSMA,
                                PRICE_CLOSE, MODE_SIGNAL, 2);

   //--- 判断当前是否已有本 EA 的持仓
   bool hasPosition = HasOpenOrder();

   //========================================================================
   //  持仓管理：用差距数组追踪截单
   //========================================================================
   if(hasPosition)
   {
      //--- 计算最新差距（快线 - 慢线），并写入循环数组
      double gap = macdMainPrev - macdSignPrev;
      PushGap(gap);

      double latestGap = GetLatestGap();
      Print("追踪差距：快线=", DoubleToString(macdMainPrev, 6),
            " 慢线=", DoubleToString(macdSignPrev, 6),
            " 差距=", DoubleToString(latestGap, 6));

      //--- 最新差距为负数 → 快慢线交汇（死叉）→ 立即平仓截单
      if(latestGap < 0)
      {
         Print("最新差距为负数，快慢线交汇，执行截单平仓。");
         CloseBuyOrder();
      }
      else
      {
         Print("最新差距为正数，继续持有。");
      }
   }
   //========================================================================
   //  开仓逻辑：MACD 金叉买入
   //========================================================================
   else
   {
      //--- 金叉条件：
      //    (1) 快线和慢线同时在零轴以上
      //    (2) 上上根 K 线快线 <= 慢线，上一根 K 线快线 > 慢线（从下向上穿越）
      bool aboveZero = (macdMainPrev > 0 && macdSignPrev > 0);
      bool crossUp   = (macdMainPrev2 <= macdSignPrev2 && macdMainPrev > macdSignPrev);

      if(aboveZero && crossUp)
      {
         double buyPrice = Ask;
         Print("MACD 金叉信号触发！买入价格 = ", DoubleToString(buyPrice, Digits),
               "  快线=", DoubleToString(macdMainPrev, 6),
               "  慢线=", DoubleToString(macdSignPrev, 6));

         OpenBuyOrder();
      }
   }
}

//+------------------------------------------------------------------+
//| 开 Buy 单（带止盈）                                               |
//+------------------------------------------------------------------+
void OpenBuyOrder()
{
   double price = Ask;
   //--- 计算止盈价格：TakeProfit 点（point）转换为价格
   double tp = (TakeProfit > 0) ? (price + TakeProfit * Point) : 0;

   //--- 价格标准化到正确的小数位数
   price = NormalizeDouble(price, Digits);
   tp    = NormalizeDouble(tp, Digits);

   int ticket = OrderSend(Symbol(), OP_BUY, Lots, price, Slippage, 0, tp,
                          "MACD金叉买入", MagicNumber, 0, clrBlue);

   if(ticket > 0)
   {
      Print("Buy 单已开仓成功。订单号=", ticket,
            " 价格=", DoubleToString(price, Digits),
            " 止盈=", DoubleToString(tp, Digits),
            " 手数=", Lots);
      //--- 开新仓时清空差距数组，重新开始追踪
      ResetGapArray();
   }
   else
   {
      Print("Buy 单开仓失败！错误代码=", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| 平掉本 EA 的 Buy 单（截单），并打印盈利                            |
//+------------------------------------------------------------------+
void CloseBuyOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() == Symbol()
         && OrderMagicNumber() == MagicNumber
         && OrderType() == OP_BUY)
      {
         double closePrice = Bid;
         closePrice = NormalizeDouble(closePrice, Digits);

         bool closed = OrderClose(OrderTicket(), OrderLots(), closePrice,
                                  Slippage, clrRed);
         if(closed)
         {
            //--- 重新选中已平仓订单以读取最终盈利
            if(OrderSelect(OrderTicket(), SELECT_BY_TICKET, MODE_HISTORY))
            {
               double profit = OrderProfit() + OrderSwap() + OrderCommission();
               Print("截单平仓成功！订单号=", OrderTicket(),
                     " 平仓价=", DoubleToString(closePrice, Digits),
                     " 本单盈利=", DoubleToString(profit, 2));
            }
            else
            {
               Print("截单平仓成功，但读取历史盈利失败。错误=", GetLastError());
            }
            //--- 截单后清空差距数组
            ResetGapArray();
         }
         else
         {
            Print("截单平仓失败！订单号=", OrderTicket(),
                  " 错误代码=", GetLastError());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| 检查是否存在本 EA 的持仓                                          |
//+------------------------------------------------------------------+
bool HasOpenOrder()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() == Symbol()
         && OrderMagicNumber() == MagicNumber
         && OrderType() == OP_BUY)
      {
         return(true);
      }
   }
   return(false);
}

//+------------------------------------------------------------------+
//| 循环数组：写入一个最新差距值                                      |
//+------------------------------------------------------------------+
void PushGap(double gap)
{
   gapArray[gapIndex] = gap;
   gapIndex = (gapIndex + 1) % GAP_SIZE;   // 循环递增，写满后覆盖最旧的值
   if(gapCount < GAP_SIZE)
      gapCount++;
}

//+------------------------------------------------------------------+
//| 循环数组：获取最新写入的差距值                                    |
//+------------------------------------------------------------------+
double GetLatestGap()
{
   if(gapCount == 0)
      return(0);
   //--- 最新写入位置 = (gapIndex - 1 + GAP_SIZE) % GAP_SIZE
   int latest = (gapIndex - 1 + GAP_SIZE) % GAP_SIZE;
   return(gapArray[latest]);
}

//+------------------------------------------------------------------+
//| 清空差距数组                                                      |
//+------------------------------------------------------------------+
void ResetGapArray()
{
   for(int i = 0; i < GAP_SIZE; i++)
      gapArray[i] = 0;
   gapIndex = 0;
   gapCount = 0;
}
//+------------------------------------------------------------------+

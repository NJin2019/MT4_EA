//+------------------------------------------------------------------+
//|                                              MACD_Strategy.mq4   |
//|                              MACD 金叉买入 + 差距数组追踪截单策略   |
//|                                                                  |
//| 逻辑说明：                                                         |
//|  1. 检测 MACD 快线和慢线同时在零轴以下，且快线从下向上穿越慢线（金叉）  |
//|  2. 满足条件时打印买入价格，开 0.05 手 Buy 单                        |
//|  3. 设置止盈 200 点                                                |
//|  4. 用 12 元素循环数组追踪快线与慢线的差距（每个 5 分钟 K 线一个值）   |
//|  5. 最新差距为正数 → 继续持有；为负数 → 快慢线交汇，立即平仓截单       |
//|  6. 截单后打印盈利并清空数组                                         |
//+------------------------------------------------------------------+
#property copyright "MACD Strategy"
#property version   "1.00"
#property strict

//--- 输入参数
input int    FastEMA      = 12;      // MACD 快线 EMA 周期
input int    SlowEMA      = 26;      // MACD 慢线 EMA 周期
input int    SignalPeriod = 9;       // MACD 信号线（慢线）周期
input double LotSize      = 0.05;   // 开单手数
input int    TakeProfit   = 200;    // 止盈点数
input int    Magic        = 20260528; // EA 魔术数字，用于识别本 EA 的订单

//--- 全局变量
double gDiffArray[12];   // 存储快线与信号线差距的循环数组（12 个元素）
int    gArrayIndex = 0;  // 当前写入位置（0~11 循环）
bool   gArrayFull  = false; // 标记数组是否已存满过一次
bool   gInTrade    = false; // 是否已有持仓
int    gTicket     = -1;    // 当前持仓的订单号

//+------------------------------------------------------------------+
//| EA 初始化                                                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // 清空差距数组
   ArrayInitialize(gDiffArray, 0.0);
   gArrayIndex = 0;
   gArrayFull  = false;
   gInTrade    = false;
   gTicket     = -1;

   Print("MACD Strategy EA 已启动，交易品种：", Symbol(),
         "  时间框架：", EnumToString((ENUM_TIMEFRAMES)Period()));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 每个新 Tick 执行                                                   |
//+------------------------------------------------------------------+
void OnTick()
{
   // 只在新 K 线生成时处理，避免同一根 K 线重复操作
   static datetime lastBarTime = 0;
   datetime currentBarTime = iTime(Symbol(), Period(), 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;

   //----------------------------------------------------------------
   // 1. 读取当前和上一根 K 线的 MACD 值
   //    iMACD 返回的：
   //      MODE_MAIN   = MACD 快线（Main line）
   //      MODE_SIGNAL = MACD 信号线/慢线（Signal line）
   //----------------------------------------------------------------
   double macdMain_curr   = iMACD(Symbol(), Period(), FastEMA, SlowEMA, SignalPeriod, PRICE_CLOSE, MODE_MAIN,   1);
   double macdSignal_curr = iMACD(Symbol(), Period(), FastEMA, SlowEMA, SignalPeriod, PRICE_CLOSE, MODE_SIGNAL, 1);
   double macdMain_prev   = iMACD(Symbol(), Period(), FastEMA, SlowEMA, SignalPeriod, PRICE_CLOSE, MODE_MAIN,   2);
   double macdSignal_prev = iMACD(Symbol(), Period(), FastEMA, SlowEMA, SignalPeriod, PRICE_CLOSE, MODE_SIGNAL, 2);

   // 快线与信号线的当前差距（正数 = 快线在上，负数 = 快线在下）
   double currentDiff = macdMain_curr - macdSignal_curr;

   //----------------------------------------------------------------
   // 2. 如果当前没有持仓，检测金叉买入条件
   //    条件 A：快线和慢线（信号线）都在零轴以下
   //    条件 B：上一根 K 线快线 <= 慢线，当前 K 线快线 > 慢线（上穿/金叉）
   //----------------------------------------------------------------
   if(!gInTrade)
   {
      bool belowZero   = (macdMain_curr < 0.0) && (macdSignal_curr < 0.0);
      bool goldenCross = (macdMain_prev <= macdSignal_prev) && (macdMain_curr > macdSignal_curr);

      if(belowZero && goldenCross)
      {
         double buyPrice = Ask;
         double tp       = buyPrice + TakeProfit * Point;

         Print("【金叉买入信号】买入价格：", DoubleToStr(buyPrice, Digits),
               "  止盈价格：", DoubleToStr(tp, Digits),
               "  止盈点数：", TakeProfit, " 点");

         // 开 Buy 单
         int ticket = OrderSend(
            Symbol(),        // 交易品种
            OP_BUY,          // 买入
            LotSize,         // 手数 0.05
            buyPrice,        // 开仓价
            3,               // 滑点 3 点
            0,               // 不设止损（由数组逻辑控制）
            tp,              // 止盈
            "MACD GoldenCross", // 订单注释
            Magic,           // 魔术数字
            0,               // 到期时间（0 = 不限）
            clrGreen         // 箭头颜色
         );

         if(ticket > 0)
         {
            gTicket     = ticket;
            gInTrade    = true;
            // 重置差距数组，准备追踪本次持仓
            ArrayInitialize(gDiffArray, 0.0);
            gArrayIndex = 0;
            gArrayFull  = false;

            Print("【开单成功】订单号：", ticket,
                  "  手数：", LotSize,
                  "  开仓价：", DoubleToStr(buyPrice, Digits));
         }
         else
         {
            Print("【开单失败】错误码：", GetLastError());
         }
      }
      return; // 没有持仓时不需要执行后续数组追踪逻辑
   }

   //----------------------------------------------------------------
   // 3. 已有持仓时，将本根 K 线的快慢线差距写入循环数组
   //----------------------------------------------------------------
   gDiffArray[gArrayIndex] = currentDiff;

   Print("【数组更新】槽位[", gArrayIndex, "] = ", DoubleToStr(currentDiff, 8),
         "  (快线:", DoubleToStr(macdMain_curr, 8),
         "  信号线:", DoubleToStr(macdSignal_curr, 8), ")");

   // 更新索引，满 12 后循环回 0
   gArrayIndex++;
   if(gArrayIndex >= 12)
   {
      gArrayIndex = 0;
      gArrayFull  = true; // 已存满过一次，进入循环覆盖模式
   }

   //----------------------------------------------------------------
   // 4. 读取最新写入的差距值（即刚写入的 currentDiff）进行判断
   //    正数 → 快线仍在信号线上方，继续持有
   //    负数 → 快线下穿信号线（死叉），立即截单
   //----------------------------------------------------------------
   double latestDiff = currentDiff; // 刚写入数组的就是最新值

   if(latestDiff > 0)
   {
      // 快线仍在上方，继续等待
      Print("【持仓监控】最新差距为正 (", DoubleToStr(latestDiff, 8), ")，继续持有...");
   }
   else
   {
      // 快线下穿，触发截单
      Print("【截单信号】最新差距为负/零 (", DoubleToStr(latestDiff, 8), ")，快慢线交汇，执行平仓...");
      CloseCurrentTrade();
   }
}

//+------------------------------------------------------------------+
//| 平仓函数：关闭当前持仓并打印盈利，然后清空数组                       |
//+------------------------------------------------------------------+
void CloseCurrentTrade()
{
   if(gTicket < 0) return;

   // 选中订单
   if(!OrderSelect(gTicket, SELECT_BY_TICKET))
   {
      Print("【平仓错误】找不到订单号 ", gTicket, "，错误码：", GetLastError());
      ResetTradeState();
      return;
   }

   // 检查订单是否还在（未被 TP 自动平仓）
   if(OrderCloseTime() > 0)
   {
      // 订单已被自动平仓（例如 TP 已触发）
      double profit = OrderProfit() + OrderSwap() + OrderCommission();
      Print("【订单已自动平仓】止盈触发，订单号：", gTicket,
            "  本单盈利：", DoubleToStr(profit, 2), " 货币单位");
      ResetTradeState();
      return;
   }

   double closePrice = Bid; // Buy 单以 Bid 价平仓
   bool   closed     = OrderClose(gTicket, OrderLots(), closePrice, 3, clrRed);

   if(closed)
   {
      // 重新选择订单读取最终盈利
      if(OrderSelect(gTicket, SELECT_BY_TICKET))
      {
         double profit = OrderProfit() + OrderSwap() + OrderCommission();
         Print("【平仓成功】订单号：", gTicket,
               "  平仓价：", DoubleToStr(closePrice, Digits),
               "  本单盈利：", DoubleToStr(profit, 2), " 货币单位");
      }
   }
   else
   {
      Print("【平仓失败】订单号：", gTicket, "  错误码：", GetLastError());
      return; // 平仓失败则不重置状态，下一根 K 线再尝试
   }

   ResetTradeState();
}

//+------------------------------------------------------------------+
//| 重置交易状态并清空数组                                              |
//+------------------------------------------------------------------+
void ResetTradeState()
{
   gInTrade    = false;
   gTicket     = -1;
   // 清空差距数组
   ArrayInitialize(gDiffArray, 0.0);
   gArrayIndex = 0;
   gArrayFull  = false;
   Print("【状态重置】差距数组已清空，等待下一次金叉信号...");
}

//+------------------------------------------------------------------+
//| EA 卸载时处理                                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("MACD Strategy EA 已停止，原因代码：", reason);
}
//+------------------------------------------------------------------+

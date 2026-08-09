//+------------------------------------------------------------------+
//|  MultiCondition_EA.mq4                                            |
//|  多条件开仓策略：MACD + KDJ + Bollinger Bands                      |
//|  不设初始SL/TP，由 TPSL_Manager.mqh 接管管理                        |
//+------------------------------------------------------------------+
#property copyright "NJin"
#property version   "1.11"
#property strict

#include <TPSL_Manager.mqh>

//+------------------------------------------------------------------+
//| 参数分类                                                           |
//+------------------------------------------------------------------+
//--- [1] 交易基础参数
input double InpLotSize        = 0.05;   // 开仓手数
input int    InpMagicNumber    = 240801; // Magic Number
input int    InpSlippage       = 30;     // 滑点(点数)
input int    InpMaxPositions   = 1;      // 最大总持仓数

//--- [2] MACD 参数
input int    InpMACDFast       = 8;      // MACD 快线周期
input int    InpMACDSlow       = 17;     // MACD 慢线周期
input int    InpMACDSignal     = 9;      // MACD 信号线周期

//--- [3] KDJ (Stochastic) 参数
input int    InpKDJK           = 9;      // KDJ K周期
input int    InpKDJD           = 3;      // KDJ D周期
input int    InpKDJSlowing     = 3;      // KDJ 慢速
input int    InpKDJLookback    = 4;      // KDJ交叉回溯K线数(参考范围)

//--- [4] 布林带参数
input int    InpBollPeriod     = 20;     // 布林带周期
input double InpBollDeviation  = 2.0;    // 布林带偏差
input int    InpBollShift      = 0;      // 布林带偏移

//--- [5] 止盈止损参数（传给 TPSL_Manager）
input int    InpSLPoints       = 100;    // 止损点数
input int    InpTPPoints       = 350;    // 止盈点数
input int    InpTrailPoints    = 50;     // 追踪止损距离(点数)
input int    InpTrailStep      = 20;     // 追踪止损步进(点数)
input int    InpBreakevenAt    = 30;     // 盈亏平衡触发点数
input int    InpBreakevenAdd   = 10;     // 盈亏平衡后锁定额外点数
input bool   InpUseTrailing    = true;   // 启用追踪止损
input bool   InpUseBreakeven   = true;   // 启用盈亏平衡

//--- [6] 功能开关
input bool   InpAllowLong      = true;   // 允许多仓
input bool   InpAllowShort     = true;   // 允许空仓
input double InpMaxSpread      = 30;     // 最大允许点差(超过不交易)
input bool   InpDebugMode      = true;   // 调试模式(输出每根K线各条件详细数值)

//+------------------------------------------------------------------+
//| 全局                                                               |
//+------------------------------------------------------------------+
datetime g_last_bar_time = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   Print("╔══════════════════════════════════════╗");
   Print("║  多条件开仓EA v1.11 已启动            ║");
   Print("╚══════════════════════════════════════╝");
   Print("MACD(", InpMACDFast, ",", InpMACDSlow, ",", InpMACDSignal, ")");
   Print("KDJ(", InpKDJK, ",", InpKDJD, ",", InpKDJSlowing, ")  回溯:", InpKDJLookback, "K线");
   Print("Boll(", InpBollPeriod, ",", InpBollDeviation, ")");
   Print("手数:", InpLotSize, "  |  最大持仓:", InpMaxPositions);
   Print("止损:", InpSLPoints, "pts  |  止盈:", InpTPPoints, "pts");
   Print("追踪:", InpTrailPoints, "pts  |  步进:", InpTrailStep, "pts");
   Print("保本触发:", InpBreakevenAt, "pts  |  保本锁利:", InpBreakevenAdd, "pts");
   if(!InpAllowLong)  Print("*** 多仓已禁用 ***");
   if(!InpAllowShort) Print("*** 空仓已禁用 ***");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   string reason_text = "";
   switch(reason)
   {
      case 0:  reason_text = "脚本正常结束(0)";             break;
      case 1:  reason_text = "EA被手动移除图表(REASON_REMOVE)";       break;
      case 2:  reason_text = "EA被重新编译(REASON_RECOMPILE)";       break;
      case 3:  reason_text = "品种或周期变更(REASON_CHARTCHANGE)";    break;
      case 4:  reason_text = "图表被关闭(REASON_CHARTCLOSE)";        break;
      case 5:  reason_text = "输入参数被修改(REASON_PARAMETERS)";     break;
      case 6:  reason_text = "账户变更(REASON_ACCOUNT)";             break;
      case 7:  reason_text = "模板操作导致(REASON_TEMPLATE)";         break;
      case 8:  reason_text = "初始化失败(REASON_INITFAILED)";         break;
      case 9:  reason_text = "终端关闭(REASON_CLOSE)";               break;
      default: reason_text = "未知原因";
   }
   Print("╔══════════════════════════════════════╗");
   Print("║  多条件开仓EA 已停止                   ║");
   Print("║  原因: ", reason_text);
   Print("║  代码: ", reason);
   Print("╚══════════════════════════════════════╝");
}

//+------------------------------------------------------------------+
void OnTick()
{
   //--- 0. 数据充足性检查（避免指标调用时数据不足导致异常）
   int min_bars = InpBollPeriod + InpMACDSlow + InpKDJK + InpKDJLookback + 50;
   if(Bars < min_bars)
   {
      if(InpDebugMode)
         Print("[等待数据] 当前K线数=", Bars, " / 需要≥", min_bars);
      return;
   }

   //--- 1. 点差过滤
   double current_spread = MarketInfo(_Symbol, MODE_SPREAD);
   if(current_spread > InpMaxSpread)
   {
      if(InpDebugMode)
      {
         // 每 60 秒最多打印一次，避免刷屏
         static datetime last_spread_warn = 0;
         if(TimeCurrent() - last_spread_warn >= 60)
         {
            Print("[点差过大] 当前=", current_spread, "pts  >  允许最大=", InpMaxSpread, "pts  → 跳过本Tick");
            last_spread_warn = TimeCurrent();
         }
      }
      return;
   }
   // 打印点差正常（仅在新K线时，减少刷屏）
   static datetime last_spread_ok = 0;
   if(InpDebugMode && Time[0] != last_spread_ok)
   {
      last_spread_ok = Time[0];
      Print("[点差正常] 当前=", current_spread, "pts  ≤  允许最大=", InpMaxSpread, "pts");
   }

   //--- 2. 检测新K线
   bool is_new_bar = false;
   if(Time[0] != g_last_bar_time)
   {
      g_last_bar_time = Time[0];
      is_new_bar = true;
   }

   //--- 3. 只在有新K线时检查开仓信号
   if(is_new_bar)
   {
      if(InpDebugMode)
         DebugPrintBarHeader();

      int long_count = 0, short_count = 0;
      CountPositions(long_count, short_count);
      int total = long_count + short_count;

      if(total < InpMaxPositions)
      {
         // 空单信号
         if(InpAllowShort && short_count == 0 && CheckShortSignal())
         {
            OpenShort();
            // 重新统计（刚开了仓）
            CountPositions(long_count, short_count);
            total = long_count + short_count;
         }

         // 多单信号
         if(InpAllowLong && long_count == 0 && total < InpMaxPositions && CheckLongSignal())
         {
            OpenLong();
         }
      }
   }

   //--- 4. 每Tick管理止损止盈
   ManageAllTPSL(
      _Symbol,
      InpMagicNumber,
      InpSLPoints,
      InpTPPoints,
      InpTrailPoints,
      InpTrailStep,
      InpBreakevenAt,
      InpBreakevenAdd,
      InpUseTrailing,
      InpUseBreakeven,
      true,    // fix_missing_tpsl
      false,   // overwrite_existing_sl
      false    // overwrite_existing_tp
   );
}

//+------------------------------------------------------------------+
//| Debug: 打印新K线信息头                                              |
//+------------------------------------------------------------------+
void DebugPrintBarHeader()
{
   double point  = MarketInfo(_Symbol, MODE_POINT);
   if(point <= 0) return;  // 除零保护

   int    digits = (int)MarketInfo(_Symbol, MODE_DIGITS);
   double bid    = MarketInfo(_Symbol, MODE_BID);
   double ask    = MarketInfo(_Symbol, MODE_ASK);
   double spread = MarketInfo(_Symbol, MODE_SPREAD);
   int    count  = CountTotalPositions();

   Print("");
   Print("╔══════════════════════════════════════════════════════╗");
   Print("║ [新K线] ", TimeToStr(Time[0], TIME_DATE|TIME_MINUTES),
         "  Bid=", DoubleToStr(bid, digits),
         "  Ask=", DoubleToStr(ask, digits),
         "  点差=", DoubleToStr(spread, 0));
   Print("║ 当前持仓=", count, "/", InpMaxPositions,
         "  |  调试模式=ON");
   Print("╚══════════════════════════════════════════════════════╝");
}

//+------------------------------------------------------------------+
//| 统计总持仓数                                                        |
//+------------------------------------------------------------------+
int CountTotalPositions()
{
   int total = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()     != _Symbol)          continue;
      if(OrderMagicNumber() != InpMagicNumber)   continue;
      total++;
   }
   return total;
}

//+------------------------------------------------------------------+
//| 统计持仓数量（按方向）                                              |
//+------------------------------------------------------------------+
void CountPositions(int &long_count, int &short_count)
{
   long_count  = 0;
   short_count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()     != _Symbol)          continue;
      if(OrderMagicNumber() != InpMagicNumber)   continue;

      if(OrderType() == OP_BUY)       long_count++;
      else if(OrderType() == OP_SELL) short_count++;
   }
}

//+==================================================================+
//|                     空单信号检查 (含 Debug)                        |
//+==================================================================+
bool CheckShortSignal()
{
   if(InpDebugMode)
   {
      Print("  ┌─ [空单检查 SELL] ───────────────────────────────");
   }

   //--- 条件1: MACD(8,17,9) 死叉 + 零线上方
   bool c1 = MACDDeadCrossAboveZero();
   if(InpDebugMode) Print("  │  条件1-MACD死叉+零线上方: ", c1 ? "✅ 通过" : "❌ 未通过");
   if(!c1) { if(InpDebugMode) Print("  └─ 空单: 条件1不满足，跳过 ─"); return false; }

   //--- 条件2: 过去N根K线内，KDJ(9,3,3) 死叉 + 75线上方
   bool c2 = KDJDeadCrossAbove(75.0);
   if(InpDebugMode) Print("  │  条件2-KDJ死叉+75线上方: ", c2 ? "✅ 通过" : "❌ 未通过");
   if(!c2) { if(InpDebugMode) Print("  └─ 空单: 条件2不满足，跳过 ─"); return false; }

   //--- 条件3: Bid > 布林带中轨
   double mid = iBands(_Symbol, 0, InpBollPeriod, InpBollDeviation,
                       InpBollShift, PRICE_CLOSE, MODE_MAIN, 1);
   double bid = MarketInfo(_Symbol, MODE_BID);
   bool c3 = (bid > mid);
   if(InpDebugMode)
   {
      int d = (int)MarketInfo(_Symbol, MODE_DIGITS);
      Print("  │  条件3-Bid>Boll中轨: ", c3 ? "✅ 通过" : "❌ 未通过",
            "  Bid=", DoubleToStr(bid, d),
            "  Mid=", DoubleToStr(mid, d),
            "  差值=", DoubleToStr((bid - mid) / MarketInfo(_Symbol, MODE_POINT), 1), "pts");
   }
   if(!c3) { if(InpDebugMode) Print("  └─ 空单: 条件3不满足，跳过 ─"); return false; }

   if(InpDebugMode) Print("  └─ 空单: ✅ 三条件全部满足! ──────────────");
   return true;
}

//+==================================================================+
//|                     多单信号检查 (含 Debug)                        |
//+==================================================================+
bool CheckLongSignal()
{
   if(InpDebugMode)
   {
      Print("  ┌─ [多单检查 BUY] ────────────────────────────────");
   }

   //--- 条件1: MACD(8,17,9) 金叉 + 零线下方
   bool c1 = MACDGoldenCrossBelowZero();
   if(InpDebugMode) Print("  │  条件1-MACD金叉+零线下方: ", c1 ? "✅ 通过" : "❌ 未通过");
   if(!c1) { if(InpDebugMode) Print("  └─ 多单: 条件1不满足，跳过 ─"); return false; }

   //--- 条件2: 过去N根K线内，KDJ(9,3,3) 金叉 + 50线下方
   bool c2 = KDJGoldenCrossBelow(50.0);
   if(InpDebugMode) Print("  │  条件2-KDJ金叉+50线下方: ", c2 ? "✅ 通过" : "❌ 未通过");
   if(!c2) { if(InpDebugMode) Print("  └─ 多单: 条件2不满足，跳过 ─"); return false; }

   //--- 条件3: Bid < 布林带中轨
   double mid = iBands(_Symbol, 0, InpBollPeriod, InpBollDeviation,
                       InpBollShift, PRICE_CLOSE, MODE_MAIN, 1);
   double bid = MarketInfo(_Symbol, MODE_BID);
   bool c3 = (bid < mid);
   if(InpDebugMode)
   {
      int d = (int)MarketInfo(_Symbol, MODE_DIGITS);
      Print("  │  条件3-Bid<Boll中轨: ", c3 ? "✅ 通过" : "❌ 未通过",
            "  Bid=", DoubleToStr(bid, d),
            "  Mid=", DoubleToStr(mid, d),
            "  差值=", DoubleToStr((bid - mid) / MarketInfo(_Symbol, MODE_POINT), 1), "pts");
   }
   if(!c3) { if(InpDebugMode) Print("  └─ 多单: 条件3不满足，跳过 ─"); return false; }

   if(InpDebugMode) Print("  └─ 多单: ✅ 三条件全部满足! ──────────────");
   return true;
}

//+==================================================================+
//| MACD 死叉 + 在零线上方（空单用） [Debug版]                           |
//+==================================================================+
bool MACDDeadCrossAboveZero()
{
   if(InpDebugMode) Print("  │    [MACD(8,17,9) 死叉+零线上方]");

   bool found = false;
   for(int shift = 0; shift <= 1; shift++)
   {
      double main_prev = iMACD(_Symbol, 0, InpMACDFast, InpMACDSlow, InpMACDSignal,
                               PRICE_CLOSE, MODE_MAIN, shift + 1);
      double sig_prev  = iMACD(_Symbol, 0, InpMACDFast, InpMACDSlow, InpMACDSignal,
                               PRICE_CLOSE, MODE_SIGNAL, shift + 1);
      double main_curr = iMACD(_Symbol, 0, InpMACDFast, InpMACDSlow, InpMACDSignal,
                               PRICE_CLOSE, MODE_MAIN, shift);
      double sig_curr  = iMACD(_Symbol, 0, InpMACDFast, InpMACDSlow, InpMACDSignal,
                               PRICE_CLOSE, MODE_SIGNAL, shift);

      // 死叉: 前一根 main > sig, 当前 main < sig, 且 main_curr > 0
      bool is_dead = (main_prev > sig_prev && main_curr < sig_curr);
      bool above_zero = (main_curr > 0);

      if(InpDebugMode)
      {
         Print("  │      bar[", shift + 1, "]->bar[", shift, "]: ",
               "main(", DoubleToStr(main_prev, 6), "->", DoubleToStr(main_curr, 6), ") ",
               "sig(", DoubleToStr(sig_prev, 6), "->", DoubleToStr(sig_curr, 6), ") ",
               "│ 死叉?", is_dead ? "YES" : "NO",
               "  main>0?", above_zero ? "YES" : "NO",
               "  => ", (is_dead && above_zero) ? "✅" : "✗");
      }

      if(is_dead && above_zero)
      {
         found = true;
         break;
      }
   }
   return found;
}

//+==================================================================+
//| MACD 金叉 + 在零线下方（多单用） [Debug版]                           |
//+==================================================================+
bool MACDGoldenCrossBelowZero()
{
   if(InpDebugMode) Print("  │    [MACD(8,17,9) 金叉+零线下方]");

   bool found = false;
   for(int shift = 0; shift <= 1; shift++)
   {
      double main_prev = iMACD(_Symbol, 0, InpMACDFast, InpMACDSlow, InpMACDSignal,
                               PRICE_CLOSE, MODE_MAIN, shift + 1);
      double sig_prev  = iMACD(_Symbol, 0, InpMACDFast, InpMACDSlow, InpMACDSignal,
                               PRICE_CLOSE, MODE_SIGNAL, shift + 1);
      double main_curr = iMACD(_Symbol, 0, InpMACDFast, InpMACDSlow, InpMACDSignal,
                               PRICE_CLOSE, MODE_MAIN, shift);
      double sig_curr  = iMACD(_Symbol, 0, InpMACDFast, InpMACDSlow, InpMACDSignal,
                               PRICE_CLOSE, MODE_SIGNAL, shift);

      // 金叉: 前一根 main < sig, 当前 main > sig, 且 main_curr < 0
      bool is_golden = (main_prev < sig_prev && main_curr > sig_curr);
      bool below_zero = (main_curr < 0);

      if(InpDebugMode)
      {
         Print("  │      bar[", shift + 1, "]->bar[", shift, "]: ",
               "main(", DoubleToStr(main_prev, 6), "->", DoubleToStr(main_curr, 6), ") ",
               "sig(", DoubleToStr(sig_prev, 6), "->", DoubleToStr(sig_curr, 6), ") ",
               "│ 金叉?", is_golden ? "YES" : "NO",
               "  main<0?", below_zero ? "YES" : "NO",
               "  => ", (is_golden && below_zero) ? "✅" : "✗");
      }

      if(is_golden && below_zero)
      {
         found = true;
         break;
      }
   }
   return found;
}

//+==================================================================+
//| KDJ 死叉检测（在过去 lookback 根K线内） + 在 level 线上方 [Debug版] |
//+==================================================================+
bool KDJDeadCrossAbove(double level)
{
   if(InpDebugMode)
      Print("  │    [KDJ(9,3,3) 死叉+J>", level, " 回溯", InpKDJLookback, "根]");

   for(int i = 1; i <= InpKDJLookback; i++)
   {
      double k_prev = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                                  MODE_SMA, 0, MODE_MAIN, i + 1);
      double d_prev = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                                  MODE_SMA, 0, MODE_SIGNAL, i + 1);
      double k_curr = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                                  MODE_SMA, 0, MODE_MAIN, i);
      double d_curr = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                                  MODE_SMA, 0, MODE_SIGNAL, i);

      double j_prev = 3.0 * k_prev - 2.0 * d_prev;

      // 死叉: 前一根 K > D  →  当前 K < D
      bool is_dead = (k_prev > d_prev && k_curr < d_curr);
      bool above_level = (j_prev > level);

      if(InpDebugMode)
      {
         Print("  │      bar[", i + 1, "]->bar[", i, "]: ",
               "K(", DoubleToStr(k_prev, 1), "->", DoubleToStr(k_curr, 1), ") ",
               "D(", DoubleToStr(d_prev, 1), "->", DoubleToStr(d_curr, 1), ") ",
               "J(prev)=", DoubleToStr(j_prev, 1),
               " │ 死叉?", is_dead ? "YES" : "NO",
               "  J>", level, "?", above_level ? "YES" : "NO",
               "  => ", (is_dead && above_level) ? "✅" : "✗");
      }

      if(is_dead && above_level)
         return true;
   }
   return false;
}

//+==================================================================+
//| KDJ 金叉检测（在过去 lookback 根K线内） + 在 level 线下方 [Debug版] |
//+==================================================================+
bool KDJGoldenCrossBelow(double level)
{
   if(InpDebugMode)
      Print("  │    [KDJ(9,3,3) 金叉+J<", level, " 回溯", InpKDJLookback, "根]");

   for(int i = 1; i <= InpKDJLookback; i++)
   {
      double k_prev = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                                  MODE_SMA, 0, MODE_MAIN, i + 1);
      double d_prev = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                                  MODE_SMA, 0, MODE_SIGNAL, i + 1);
      double k_curr = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                                  MODE_SMA, 0, MODE_MAIN, i);
      double d_curr = iStochastic(_Symbol, 0, InpKDJK, InpKDJD, InpKDJSlowing,
                                  MODE_SMA, 0, MODE_SIGNAL, i);

      double j_prev = 3.0 * k_prev - 2.0 * d_prev;

      // 金叉: 前一根 K < D  →  当前 K > D
      bool is_golden = (k_prev < d_prev && k_curr > d_curr);
      bool below_level = (j_prev < level);

      if(InpDebugMode)
      {
         Print("  │      bar[", i + 1, "]->bar[", i, "]: ",
               "K(", DoubleToStr(k_prev, 1), "->", DoubleToStr(k_curr, 1), ") ",
               "D(", DoubleToStr(d_prev, 1), "->", DoubleToStr(d_curr, 1), ") ",
               "J(prev)=", DoubleToStr(j_prev, 1),
               " │ 金叉?", is_golden ? "YES" : "NO",
               "  J<", level, "?", below_level ? "YES" : "NO",
               "  => ", (is_golden && below_level) ? "✅" : "✗");
      }

      if(is_golden && below_level)
         return true;
   }
   return false;
}

//+==================================================================+
//| 开空单                                                             |
//+==================================================================+
void OpenShort()
{
   RefreshRates();
   double bid      = MarketInfo(_Symbol, MODE_BID);
   double lot      = InpLotSize;
   double sl       = 0;   // 由 TPSL_Manager 接管
   double tp       = 0;   // 由 TPSL_Manager 接管

   int ticket = OrderSend(_Symbol, OP_SELL, lot, bid, InpSlippage,
                          sl, tp, "MC_EA_Short", InpMagicNumber, 0, clrRed);

   if(ticket > 0)
   {
      Print("━━━ ▶ 开空单成功  Ticket:", ticket,
            "  价格:", DoubleToStr(bid, (int)MarketInfo(_Symbol, MODE_DIGITS)),
            "  手数:", lot);
   }
   else
      Print("!!! 开空单失败  Error:", GetLastError());
}

//+==================================================================+
//| 开多单                                                             |
//+==================================================================+
void OpenLong()
{
   RefreshRates();
   double ask      = MarketInfo(_Symbol, MODE_ASK);
   double lot      = InpLotSize;
   double sl       = 0;   // 由 TPSL_Manager 接管
   double tp       = 0;   // 由 TPSL_Manager 接管

   int ticket = OrderSend(_Symbol, OP_BUY, lot, ask, InpSlippage,
                          sl, tp, "MC_EA_Long", InpMagicNumber, 0, clrBlue);

   if(ticket > 0)
   {
      Print("━━━ ▶ 开多单成功  Ticket:", ticket,
            "  价格:", DoubleToStr(ask, (int)MarketInfo(_Symbol, MODE_DIGITS)),
            "  手数:", lot);
   }
   else
      Print("!!! 开多单失败  Error:", GetLastError());
}
//+------------------------------------------------------------------+

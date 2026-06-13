//+------------------------------------------------------------------+
//|  FixedPoints_TPSL_EA.mq4                                         |
//|  基于ATR止盈止损EA改造 - 使用固定点数管理TP/SL                       |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "2.00"
#property strict

//--- 输入参数：固定点数
input int      InpSLPoints      = 150;      // 止损点数 (原ATR倍数)
input int      InpTPPoints      = 150;      // 止盈点数 (原ATR倍数)
input int      InpTrailPoints   = 50;      // 追踪止损点数 (原ATR追踪)，开始追踪点
input int      InpTrailStep     = 20;       // 追踪止损步进点数
input int      InpBreakevenAt   = 30;       // 盈亏平衡触发点数
input int      InpBreakevenAdd  = 10;        // 盈亏平衡额外点数(锁定小利润)

//--- 交易参数
input double   InpLotSize       = 0.05;      // 手数
input int      InpMagicNumber   = 20260001; // Magic Number
input int      InpSlippage      = 3;        // 最大滑点
input string   InpComment       = "FixedPts";// 订单注释

//--- 入场信号参数 (可根据实际信号替换)
input int      InpMAPeriodFast  = 10;       // 快速MA周期
input int      InpMAPeriodSlow  = 30;       // 慢速MA周期

//--- 功能开关
input bool     InpUseTrailing   = true;     // 启用追踪止损
input bool     InpUseBreakeven  = true;     // 启用盈亏平衡
input bool     InpModifyExisting= true;     // 修改已有订单TP/SL

//--- 全局变量
double g_point;
int    g_digits_adj; // 用于点数精度适配

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   // 适配5位报价经纪商 (e.g. EURUSD=1.12345 → 1 point = 0.00001)
   // _Digits==5 或 _Digits==3 表示5位/3位小数经纪商
   if(_Digits == 5 || _Digits == 3)
   {
      g_point      = _Point;
      g_digits_adj = 1; // 已经是最小单位
   }
   else
   {
      g_point      = _Point;
      g_digits_adj = 1;
   }
   
   Print("EA初始化成功 | Symbol:", _Symbol,
         " | Digits:", _Digits,
         " | Point:", DoubleToStr(g_point, 8));
   Print("SL=", InpSLPoints, "pts | TP=", InpTPPoints,
         "pts | Trail=", InpTrailPoints, "pts");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("EA已停止，原因代码:", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. 管理已有持仓：追踪止损 & 盈亏平衡
   if(InpUseTrailing || InpUseBreakeven)
      ManageOpenTrades();
   
   // 2. 修正已有订单缺失的TP/SL
   if(InpModifyExisting)
      FixMissingTPSL();
   
   // 3. 检查新入场信号 (每根K线只执行一次)
   static datetime s_last_bar_time = 0;
   datetime cur_bar = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(cur_bar == s_last_bar_time) return;
   s_last_bar_time = cur_bar;
   
   // 4. 无持仓时检查开仓信号
   if(CountMyOrders() == 0)
      CheckEntrySignal();
}

//+------------------------------------------------------------------+
//| 计算固定点数对应的价格距离                                           |
//+------------------------------------------------------------------+
double PointsToPrice(int points)
{
   return points * g_point;
}

//+------------------------------------------------------------------+
//| 入场信号检测 (MA交叉示例 - 可替换为你的实际信号逻辑)                  |
//+------------------------------------------------------------------+
void CheckEntrySignal()
{
   double ma_fast_cur  = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriodFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double ma_fast_prev = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriodFast, 0, MODE_EMA, PRICE_CLOSE, 2);
   double ma_slow_cur  = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriodSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double ma_slow_prev = iMA(_Symbol, PERIOD_CURRENT, InpMAPeriodSlow, 0, MODE_EMA, PRICE_CLOSE, 2);
   
   // 金叉做多
   if(ma_fast_prev <= ma_slow_prev && ma_fast_cur > ma_slow_cur)
      OpenTrade(OP_BUY);
   
   // 死叉做空
   if(ma_fast_prev >= ma_slow_prev && ma_fast_cur < ma_slow_cur)
      OpenTrade(OP_SELL);
}

//+------------------------------------------------------------------+
//| 开仓函数                                                           |
//+------------------------------------------------------------------+
void OpenTrade(int order_type)
{
   double price, sl, tp;
   double sl_dist = PointsToPrice(InpSLPoints);
   double tp_dist = PointsToPrice(InpTPPoints);
   
   RefreshRates();
   
   if(order_type == OP_BUY)
   {
      price = Ask;
      sl    = NormalizeDouble(price - sl_dist, _Digits);
      tp    = NormalizeDouble(price + tp_dist, _Digits);
   }
   else // OP_SELL
   {
      price = Bid;
      sl    = NormalizeDouble(price + sl_dist, _Digits);
      tp    = NormalizeDouble(price - tp_dist, _Digits);
   }
   
   // 检查止损是否满足经纪商最小止损距离
   double min_sl_dist = MarketInfo(_Symbol, MODE_STOPLEVEL) * g_point;
   if(sl_dist < min_sl_dist)
   {
      Print("警告: 止损点数(", InpSLPoints, ")小于经纪商最小止损距离(",
            (int)(min_sl_dist / g_point), "pts)，已跳过开仓");
      return;
   }
   
   int ticket = OrderSend(
      _Symbol,
      order_type,
      InpLotSize,
      price,
      InpSlippage,
      sl,
      tp,
      InpComment,
      InpMagicNumber,
      0,
      order_type == OP_BUY ? clrBlue : clrRed
   );
   
   if(ticket > 0)
      Print("开仓成功 | Ticket:", ticket,
            " | Type:", order_type == OP_BUY ? "BUY" : "SELL",
            " | Price:", DoubleToStr(price, _Digits),
            " | SL:", DoubleToStr(sl, _Digits),
            " | TP:", DoubleToStr(tp, _Digits));
   else
      Print("开仓失败 | Error:", GetLastError());
}

//+------------------------------------------------------------------+
//| 管理持仓：追踪止损 & 盈亏平衡                                        |
//+------------------------------------------------------------------+
void ManageOpenTrades()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != _Symbol)        continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      
      double open_price  = OrderOpenPrice();
      double cur_sl      = OrderStopLoss();
      double cur_tp      = OrderTakeProfit();
      double new_sl      = cur_sl;
      
      RefreshRates();
      
      if(OrderType() == OP_BUY)
      {
         double cur_price = Bid;
         double profit_pts = (cur_price - open_price) / g_point;
         
         // --- 盈亏平衡 ---
         if(InpUseBreakeven && profit_pts >= InpBreakevenAt)
         {
            double be_sl = NormalizeDouble(open_price + PointsToPrice(InpBreakevenAdd), _Digits);
            if(cur_sl < be_sl)
               new_sl = be_sl;
         }
         
         // --- 追踪止损 ---
         if(InpUseTrailing && profit_pts >= InpTrailPoints)
         {
            double trail_sl = NormalizeDouble(cur_price - PointsToPrice(InpTrailPoints), _Digits);
            // 只有当新SL比当前SL高且步进足够时才移动
            if(trail_sl > new_sl + PointsToPrice(InpTrailStep))
               new_sl = trail_sl;
         }
      }
      else // OP_SELL
      {
         double cur_price = Ask;
         double profit_pts = (open_price - cur_price) / g_point;
         
         // --- 盈亏平衡 ---
         if(InpUseBreakeven && profit_pts >= InpBreakevenAt)
         {
            double be_sl = NormalizeDouble(open_price - PointsToPrice(InpBreakevenAdd), _Digits);
            if(cur_sl == 0 || cur_sl > be_sl)
               new_sl = be_sl;
         }
         
         // --- 追踪止损 ---
         if(InpUseTrailing && profit_pts >= InpTrailPoints)
         {
            double trail_sl = NormalizeDouble(cur_price + PointsToPrice(InpTrailPoints), _Digits);
            // 只有当新SL比当前SL低且步进足够时才移动
            if(cur_sl == 0 || trail_sl < new_sl - PointsToPrice(InpTrailStep))
               new_sl = trail_sl;
         }
      }
      
      // 只有SL确实变化时才发送修改请求
      if(MathAbs(new_sl - cur_sl) > g_point / 2.0)
      {
         bool res = OrderModify(OrderTicket(), open_price, new_sl, cur_tp, 0, clrYellow);
         if(!res)
            Print("修改SL失败 | Ticket:", OrderTicket(), " | Error:", GetLastError());
         else
            Print("SL已更新 | Ticket:", OrderTicket(),
                  " | 旧SL:", DoubleToStr(cur_sl, _Digits),
                  " | 新SL:", DoubleToStr(new_sl, _Digits));
      }
   }
}

//+------------------------------------------------------------------+
//| 修复缺失TP/SL的已有订单                                             |
//+------------------------------------------------------------------+
void FixMissingTPSL()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != _Symbol)             continue;
      if(OrderMagicNumber() != InpMagicNumber) continue;
      if(OrderType() != OP_BUY && OrderType() != OP_SELL) continue;
      
      double open_price = OrderOpenPrice();
      double cur_sl     = OrderStopLoss();
      double cur_tp     = OrderTakeProfit();
      bool   need_mod   = false;
      double new_sl     = cur_sl;
      double new_tp     = cur_tp;
      
      if(OrderType() == OP_BUY)
      {
         if(cur_sl == 0)
         {
            new_sl   = NormalizeDouble(open_price - PointsToPrice(InpSLPoints), _Digits);
            need_mod = true;
         }
         if(cur_tp == 0)
         {
            new_tp   = NormalizeDouble(open_price + PointsToPrice(InpTPPoints), _Digits);
            need_mod = true;
         }
      }
      else
      {
         if(cur_sl == 0)
         {
            new_sl   = NormalizeDouble(open_price + PointsToPrice(InpSLPoints), _Digits);
            need_mod = true;
         }
         if(cur_tp == 0)
         {
            new_tp   = NormalizeDouble(open_price - PointsToPrice(InpTPPoints), _Digits);
            need_mod = true;
         }
      }
      
      if(need_mod)
      {
         bool res = OrderModify(OrderTicket(), open_price, new_sl, new_tp, 0, clrOrange);
         if(!res)
            Print("补充TP/SL失败 | Ticket:", OrderTicket(), " | Error:", GetLastError());
         else
            Print("已补充TP/SL | Ticket:", OrderTicket());
      }
   }
}

//+------------------------------------------------------------------+
//| 统计本EA管理的订单数量                                              |
//+------------------------------------------------------------------+
int CountMyOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol()      != _Symbol)         continue;
      if(OrderMagicNumber() != InpMagicNumber)  continue;
      if(OrderType() == OP_BUY || OrderType() == OP_SELL) count++;
   }
   return count;
}
//+------------------------------------------------------------------+

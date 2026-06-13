//+------------------------------------------------------------------+
//|  FixedPoints_TPSL_Manager.mq4                                    |
//|  纯止盈止损管理器 - 不开单不平单，只管理TP/SL位置                    |
//|  v2.20 - 增加StopLevel校验，修复Error 130                         |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "2.20"
#property strict

//--- 固定点数参数
input int    InpSLPoints          = 150;   // 止损点数
input int    InpTPPoints          = 150;   // 止盈点数
input int    InpTrailPoints       = 50;   // 追踪止损距离(点数)，盈利追踪开始点
input int    InpTrailStep         = 20;    // 追踪止损步进(点数)，避免频繁修改
input int    InpBreakevenAt       = 30;    // 盈亏平衡触发点数，保盈利点
input int    InpBreakevenAdd      = 10;     // 盈亏平衡后SL锁定额外点数

//--- 功能开关
input bool   InpUseTrailing           = true;   // 启用追踪止损
input bool   InpUseBreakeven          = true;   // 启用盈亏平衡
input bool   InpFixMissingTPSL        = true;   // 自动补充缺失的TP/SL
input bool   InpOverwriteExistingSL   = false;  // 强制覆盖已有SL(谨慎开启)
input bool   InpOverwriteExistingTP   = false;  // 强制覆盖已有TP(谨慎开启)

//--- 过滤参数
input int    InpMagicFilter   = "";   // Magic Number过滤(-1=管理所有订单)
input string InpSymbolFilter  = "";   // 品种过滤(留空=当前图表品种)

//--- 全局
double g_point;
int    g_digits;
string g_symbol;

//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = (InpSymbolFilter == "") ? _Symbol : InpSymbolFilter;
   g_point  = MarketInfo(g_symbol, MODE_POINT);
   g_digits = (int)MarketInfo(g_symbol, MODE_DIGITS);

   double stop_level = MarketInfo(g_symbol, MODE_STOPLEVEL);

   Print("=== TP/SL Manager v2.20 启动 ===");
   Print("管理品种:", g_symbol,
         " | Digits:", g_digits,
         " | Point:", DoubleToStr(g_point, 8));
   Print("经纪商最小止损距离(StopLevel):", DoubleToStr(stop_level, 0), " pts");
   Print("SL=", InpSLPoints, "pts | TP=", InpTPPoints,
         "pts | Trail=", InpTrailPoints, "pts | Step=", InpTrailStep, "pts");
   Print("BreakevenAt=", InpBreakevenAt, "pts | BreakevenAdd=", InpBreakevenAdd, "pts");
   Print("Magic过滤=", InpMagicFilter == -1 ? "全部" : IntegerToString(InpMagicFilter));

   // 启动时警告参数是否满足StopLevel
   if(InpSLPoints < stop_level)
      Print("*** 警告: InpSLPoints(", InpSLPoints, ") < StopLevel(", (int)stop_level, ")，建议调大 ***");
   if(InpTPPoints < stop_level)
      Print("*** 警告: InpTPPoints(", InpTPPoints, ") < StopLevel(", (int)stop_level, ")，建议调大 ***");
   if(InpTrailPoints < stop_level)
      Print("*** 警告: InpTrailPoints(", InpTrailPoints, ") < StopLevel(", (int)stop_level, ")，建议调大 ***");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("TP/SL Manager 已停止，代码:", reason);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(InpFixMissingTPSL)
      FixMissingTPSL();

   if(InpUseTrailing || InpUseBreakeven)
      ManageTPSL();
}

//+------------------------------------------------------------------+
//| 将点数转换为价格距离                                                |
//+------------------------------------------------------------------+
double Pts(int points)
{
   return points * g_point;
}

//+------------------------------------------------------------------+
//| 判断订单是否在本EA管理范围内（需先OrderSelect）                      |
//+------------------------------------------------------------------+
bool IsManaged()
{
   if(OrderSymbol() != g_symbol) return false;
   if(OrderType() != OP_BUY && OrderType() != OP_SELL) return false;
   if(InpMagicFilter != -1 && OrderMagicNumber() != InpMagicFilter) return false;
   return true;
}

//+------------------------------------------------------------------+
//| StopLevel校验：检查SL/TP是否满足经纪商最小距离要求                   |
//| 返回true=合法可提交，返回false=距离太近需跳过                        |
//+------------------------------------------------------------------+
bool IsStopLevelValid(int order_type, double new_sl, double new_tp)
{
   double min_dist = MarketInfo(g_symbol, MODE_STOPLEVEL) * g_point;
   // 加入点差保护，防止边界情况
   double spread   = MarketInfo(g_symbol, MODE_SPREAD) * g_point;
   double safe_dist = min_dist + spread;

   RefreshRates();
   double bid = MarketInfo(g_symbol, MODE_BID);
   double ask = MarketInfo(g_symbol, MODE_ASK);

   bool sl_ok = true;
   bool tp_ok = true;

   if(order_type == OP_BUY)
   {
      if(new_sl > 0 && (bid - new_sl) < safe_dist)
      {
         Print("SL校验失败(BUY) | Ticket:", OrderTicket(),
               " | SL:", DoubleToStr(new_sl, g_digits),
               " | Bid:", DoubleToStr(bid, g_digits),
               " | 距离:", DoubleToStr((bid-new_sl)/g_point, 1), "pts",
               " | 需要>=", DoubleToStr(safe_dist/g_point, 1), "pts");
         sl_ok = false;
      }
      if(new_tp > 0 && (new_tp - ask) < safe_dist)
      {
         Print("TP校验失败(BUY) | Ticket:", OrderTicket(),
               " | TP:", DoubleToStr(new_tp, g_digits),
               " | Ask:", DoubleToStr(ask, g_digits),
               " | 距离:", DoubleToStr((new_tp-ask)/g_point, 1), "pts",
               " | 需要>=", DoubleToStr(safe_dist/g_point, 1), "pts");
         tp_ok = false;
      }
   }
   else // OP_SELL
   {
      if(new_sl > 0 && (new_sl - ask) < safe_dist)
      {
         Print("SL校验失败(SELL) | Ticket:", OrderTicket(),
               " | SL:", DoubleToStr(new_sl, g_digits),
               " | Ask:", DoubleToStr(ask, g_digits),
               " | 距离:", DoubleToStr((new_sl-ask)/g_point, 1), "pts",
               " | 需要>=", DoubleToStr(safe_dist/g_point, 1), "pts");
         sl_ok = false;
      }
      if(new_tp > 0 && (bid - new_tp) < safe_dist)
      {
         Print("TP校验失败(SELL) | Ticket:", OrderTicket(),
               " | TP:", DoubleToStr(new_tp, g_digits),
               " | Bid:", DoubleToStr(bid, g_digits),
               " | 距离:", DoubleToStr((bid-new_tp)/g_point, 1), "pts",
               " | 需要>=", DoubleToStr(safe_dist/g_point, 1), "pts");
         tp_ok = false;
      }
   }

   return (sl_ok && tp_ok);
}

//+------------------------------------------------------------------+
//| 补充缺失的TP/SL                                                   |
//+------------------------------------------------------------------+
void FixMissingTPSL()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsManaged()) continue;

      double open   = OrderOpenPrice();
      double cur_sl = OrderStopLoss();
      double cur_tp = OrderTakeProfit();
      double new_sl = cur_sl;
      double new_tp = cur_tp;
      bool   need_mod = false;

      if(OrderType() == OP_BUY)
      {
         if(cur_sl == 0 || InpOverwriteExistingSL)
         {
            double calc_sl = NormalizeDouble(open - Pts(InpSLPoints), g_digits);
            if(MathAbs(calc_sl - cur_sl) > g_point / 2.0)
            { new_sl = calc_sl; need_mod = true; }
         }
         if(cur_tp == 0 || InpOverwriteExistingTP)
         {
            double calc_tp = NormalizeDouble(open + Pts(InpTPPoints), g_digits);
            if(MathAbs(calc_tp - cur_tp) > g_point / 2.0)
            { new_tp = calc_tp; need_mod = true; }
         }
      }
      else // OP_SELL
      {
         if(cur_sl == 0 || InpOverwriteExistingSL)
         {
            double calc_sl = NormalizeDouble(open + Pts(InpSLPoints), g_digits);
            if(MathAbs(calc_sl - cur_sl) > g_point / 2.0)
            { new_sl = calc_sl; need_mod = true; }
         }
         if(cur_tp == 0 || InpOverwriteExistingTP)
         {
            double calc_tp = NormalizeDouble(open - Pts(InpTPPoints), g_digits);
            if(MathAbs(calc_tp - cur_tp) > g_point / 2.0)
            { new_tp = calc_tp; need_mod = true; }
         }
      }

      if(need_mod)
      {
         if(IsStopLevelValid(OrderType(), new_sl, new_tp))
            ModifyOrder(new_sl, new_tp, "补充/覆盖TP-SL");
      }
   }
}

//+------------------------------------------------------------------+
//| 追踪止损 & 盈亏平衡管理                                             |
//+------------------------------------------------------------------+
void ManageTPSL()
{
   RefreshRates();

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(!IsManaged()) continue;

      double open   = OrderOpenPrice();
      double cur_sl = OrderStopLoss();
      double cur_tp = OrderTakeProfit();
      double new_sl = cur_sl;

      if(OrderType() == OP_BUY)
      {
         double bid        = MarketInfo(g_symbol, MODE_BID);
         double profit_pts = (bid - open) / g_point;

         // 盈亏平衡
         if(InpUseBreakeven && profit_pts >= InpBreakevenAt)
         {
            double be_sl = NormalizeDouble(open + Pts(InpBreakevenAdd), g_digits);
            if(cur_sl < be_sl)
               new_sl = be_sl;
         }

         // 追踪止损
         if(InpUseTrailing && profit_pts >= InpTrailPoints)
         {
            double trail_sl = NormalizeDouble(bid - Pts(InpTrailPoints), g_digits);
            if(trail_sl >= new_sl + Pts(InpTrailStep))
               new_sl = trail_sl;
         }
      }
      else // OP_SELL
      {
         double ask        = MarketInfo(g_symbol, MODE_ASK);
         double profit_pts = (open - ask) / g_point;

         // 盈亏平衡
         if(InpUseBreakeven && profit_pts >= InpBreakevenAt)
         {
            double be_sl = NormalizeDouble(open - Pts(InpBreakevenAdd), g_digits);
            if(cur_sl == 0 || cur_sl > be_sl)
               new_sl = be_sl;
         }

         // 追踪止损
         if(InpUseTrailing && profit_pts >= InpTrailPoints)
         {
            double trail_sl = NormalizeDouble(ask + Pts(InpTrailPoints), g_digits);
            if(cur_sl == 0 || trail_sl <= new_sl - Pts(InpTrailStep))
               new_sl = trail_sl;
         }
      }

      // SL有变化时才提交，提交前做StopLevel校验
      if(MathAbs(new_sl - cur_sl) > g_point / 2.0)
      {
         if(IsStopLevelValid(OrderType(), new_sl, cur_tp))
            ModifyOrder(new_sl, cur_tp, "追踪/盈亏平衡");
      }
   }
}

//+------------------------------------------------------------------+
//| 统一修改订单接口（需先OrderSelect）                                  |
//+------------------------------------------------------------------+
void ModifyOrder(double new_sl, double new_tp, string reason)
{
   bool res = OrderModify(
      OrderTicket(),
      OrderOpenPrice(),
      new_sl,
      new_tp,
      0,
      clrYellow
   );

   if(res)
      Print("[OK:", reason, "] Ticket:", OrderTicket(),
            " | SL:", DoubleToStr(OrderStopLoss(), g_digits),
            "-->", DoubleToStr(new_sl, g_digits),
            " | TP:", DoubleToStr(new_tp, g_digits));
   else
      Print("[失败:", reason, "] Ticket:", OrderTicket(),
            " | Error:", GetLastError(),
            " | SL:", DoubleToStr(new_sl, g_digits),
            " | TP:", DoubleToStr(new_tp, g_digits));
}
//+------------------------------------------------------------------+

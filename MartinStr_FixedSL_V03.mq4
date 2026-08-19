//+--------------------------------------------------------------------------------+
//|                  Martin Strategy EA (完整集成版)                               |
//|     功能：逐单移动止损、交易量判断方向、加仓、箱体限制、强平                   |
//|     Version：2026-08-16 1.00.004 (修复不交易误开多单)
//|     增加固定点数止损 ---- 27/07/2026
//|     用参数替换趋势判断ADX的设置数值。以提高对趋势行情的判断  ---- 28/07/2026 
//|     启用新的方向判断函数      ---- 29/07/2026
//|     [Ver02] 修复：IsInBox 恒真、ADX 读取未完成K线      ---- 13/08/2026
//|     [Ver03] 方向判断重构：                            ---- 15/08/2026
//|       1) 假突破改为可选"真实破界"模式(RequireTrueBreak)      P0
//|       2) 反转K线过滤改用"收盘位置"，避免误杀长影线反转K线     P0
//|       3) 多空条件同时成立时放弃开仓，避免方向误判             P1
//|       4) 箱体高低点改为分位数计算，减少单根插针影响            P1
//|       5) IsInBox 与方向判断统一箱体窗口，抽公共函数            P1
//|     [Ver04] 修复：GetBoxPositionDirection 返回 0(不交易) 与 OP_BUY(0)
//|             冲突，导致"不交易"被调用方当作做多误开单       ---- 16/08/2026
//+--------------------------------------------------------------------------------+

#property strict
#include <GeneralFunctions.mqh>
#define OP_NO_TRADE -1   // 方向判断专用：表示"不交易"（不能等于 OP_BUY=0）
extern double LotSize = 0.05;
extern int GridStepPoints = 200;      // 加仓点数
extern int MaxOrders = 10;            // 最多加仓次数
extern int BoxBars = 600;             // [Ver03 已弃用] 箱体周期：IsInBox 已与方向判断统一改用 EntryLookbackBars
extern int MagicNumber = 5301001;      // 仅管理本策略订单
extern double TrailStart = 75;
double singal_trade_risk_rate = 0.975;

extern int MaxLongOrders = 2;        // 多单上限
extern int MaxShortOrders = 2;       // 空单上限

// =====  固定止损参数  ===== 
extern bool EnableTrendFixedStop = true;   // 启用趋势固定点数止损
extern int  TrendStopLossPoints = 400;     // 进入趋势后，单笔亏损达到多少点止损

// ===== 趋势行情判断参数  ===== 
extern int    ADXPeriod = 34;          // ADX周期
extern double ADXThreshold = 20.0;     // ADX趋势阈值

// ===== 首单方向判断参数 =====
extern int    EntryLookbackBars = 600;       // 首单箱体回看K线数（IsInBox 与方向判断统一使用此窗口）
extern double BoxEdgePercent = 0.20;         // 顶部/底部区域比例，0.20 = 20%
extern double BoxExtremePercentile = 0.05;   // 箱体高低点分位：0.05=取5%/95%分位抗毛刺；0=绝对最高/最低

extern bool   RequireReversalBar = true;     // 要求K线反转确认：底部阳线 / 顶部阴线
extern bool   RequireFalseBreak = true;      // 要求假突破回归箱体后才开仓
extern bool   RequireTrueBreak = true;       // true=必须跌破/突破箱体真实边界(箱底/箱顶)后收回；false=仅触及边缘区
extern double MinReversalBodyPercent = 0.30; // 最小实体占K线总长度比例，0.30 = 30%
extern double ReversalClosePosition = 0.50;  // 反转收盘位置阈值：多头收盘须在上半区(>=0.5)，空头须在下半区(<=0.5)



string MTag(){ return StringConcatenate("[Magic:", MagicNumber, "] "); }

string F5(double v){ return DoubleToString(v, 5); }

string FormatDuration(datetime fromTime, datetime toTime)
{
    int secs = (int)(toTime - fromTime);
    if(secs < 0) secs = 0;
    int days = secs / 86400;
    int rem  = secs % 86400;
    int hours = rem / 3600;
    int mins  = (rem % 3600) / 60;
    return(StringFormat("%dd %dh %dm", days, hours, mins));
}

int OnInit() {
    //AccountBalanceRickControl(singal_trade_risk_rate);//控制资金风险，一旦下滑10%，就平仓
    return(INIT_SUCCEEDED);
}

void OnTick() {

   // 每根新K线执行一次主要开仓/加仓逻辑
   if (IsNewBar()) 
   {
         RunAlgoPerBar();
       //  AccountBalanceRickControl(0.97);
   }

   // 每 60 秒执行一次移动止损检查
   static datetime lastTrailCheck = 0;
   datetime now = TimeCurrent();
   if (lastTrailCheck == 0 || (now - lastTrailCheck) >= 60)
   {
      UpdateTrailingStopPerOrder();
      lastTrailCheck = now;
   }
}

void RunAlgoPerBar() {
   
   int holds = CountOrders();
   string nowStr = TimeToString(Time[0], TIME_DATE | TIME_MINUTES);
   if(holds == 0)
   {
      Print(MTag(), "时间:", nowStr, "无持仓");
   }
   else
   {
      Print(MTag(), "<-------新K线：", TimeToString(Time[1], TIME_DATE | TIME_MINUTES), "，当前总持仓:：", holds);
      for (int i = OrdersTotal() - 1; i >= 0; i--)
      {
         if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
         if (OrderSymbol() != Symbol()) continue;
         if (OrderMagicNumber() != MagicNumber) continue;
         int type = OrderType();
         double openPrice = OrderOpenPrice();
         double cur = (type == OP_BUY) ? Bid : Ask;
         double priceDiff = (type == OP_BUY) ? (cur - openPrice) : (openPrice - cur);
         double profitPoints = priceDiff / Point;
         string dur = FormatDuration(OrderOpenTime(), TimeCurrent());
         Print(
            MTag(),
            "持仓:",
            " 方向=", (type==OP_BUY?"多":"空"),
            " 开仓价=", F5(openPrice),
            " 当前价=", F5(cur),
            " 差价=", F5(priceDiff),
            " 点数=", F5(profitPoints),
            " 时长=", dur
         );
      }
   }
   if (!IsInBox()) return;

    if (IsTrending()) {
    // Original 2 lines
    //    Print(MTag(), "趋势行情，暂停开仓");
    //    return; // 趋势明显时停止开仓
    
      //配合固定点数止损
      Print(MTag(), "趋势行情，执行固定点数止损检查并暂停开仓");
      TrendFixedStopLoss();
      return; // 趋势明显时停止开仓
    
    
    }

    if (CountOrders() >= MaxOrders) return;

    if (HasLongPositions() && HasShortPositions())
    {
        int totalCnt = CountOrders();
        int longCnt = CountLongOrders();
        int shortCnt = CountShortOrders();

        if (longCnt < MaxLongOrders && totalCnt < MaxOrders)
        {
            double openPriceBuy = 0, lotsBuy = 0, profitPointsBuy = 0; int ticketBuy = -1;
            if (GetExtremeOrderInfo(OP_BUY, openPriceBuy, lotsBuy, ticketBuy, profitPointsBuy))
            {
                if (profitPointsBuy < 0)
                {
                    if (openPriceBuy - Bid >= GridStepPoints * Point && CountOrders() < MaxOrders)
                        OpenPosition(OP_BUY);
                }
            }
        }

        if (shortCnt < MaxShortOrders && CountOrders() < MaxOrders)
        {
            double openPriceSell = 0, lotsSell = 0, profitPointsSell = 0; int ticketSell = -1;
            if (GetExtremeOrderInfo(OP_SELL, openPriceSell, lotsSell, ticketSell, profitPointsSell))
            {
                if (profitPointsSell < 0)
                {
                    if (Ask - openPriceSell >= GridStepPoints * Point && CountOrders() < MaxOrders)
                        OpenPosition(OP_SELL);
                }
            }
        }

        return;
    }

    
    int direction = GetBoxPositionDirection();
    if (direction != OP_BUY && direction != OP_SELL) 
    {
        Print(MTag(), "不属于顶部或者底部，不开仓");
        return;
    }

    // 方向独立上限控制
    if (direction == OP_BUY) {
        int longCnt = CountLongOrders();
        if (longCnt >= MaxLongOrders) {
            Print(MTag(), "多单已达上限(", MaxLongOrders, ")，不再开多");
            return;
        }

        // 如果已经有多单，则加仓必须满足 GridStepPoints 和亏损条件
        if (longCnt > 0) {
            double openPriceBuy = 0, lotsBuy = 0, profitPointsBuy = 0; int ticketBuy = -1;
            if (!GetExtremeOrderInfo(OP_BUY, openPriceBuy, lotsBuy, ticketBuy, profitPointsBuy))
                return;

            if (profitPointsBuy >= 0) return; // 非亏损单，不加仓

            if (openPriceBuy - Bid < GridStepPoints * Point) return; // 距离不够，不加仓
        }
    }
    if (direction == OP_SELL) {
        int shortCnt = CountShortOrders();
        if (shortCnt >= MaxShortOrders) {
            Print(MTag(), "空单已达上限(", MaxShortOrders, ")，不再开空");
            return;
        }

        // 如果已经有空单，则加仓必须满足 GridStepPoints 和亏损条件
        if (shortCnt > 0) {
            double openPriceSell = 0, lotsSell = 0, profitPointsSell = 0; int ticketSell = -1;
            if (!GetExtremeOrderInfo(OP_SELL, openPriceSell, lotsSell, ticketSell, profitPointsSell))
                return;

            if (profitPointsSell >= 0) return; // 非亏损单，不加仓

            if (Ask - openPriceSell < GridStepPoints * Point) return; // 距离不够，不加仓
        }
    }

    OpenPosition(direction);
}


//+------------------------------------------------------------------+
//| 统一计算箱体高低点（分位数法）                                     |
//| 用 5%/95% 分位代替绝对最高/最低，减少单根插针对箱体的影响；        |
//| IsInBox() 与 GetBoxPositionDirection() 共用，避免窗口口径脱节。    |
//+------------------------------------------------------------------+
bool GetBoxRange(int bars, double &boxHigh, double &boxLow)
{
   boxHigh = 0.0;
   boxLow  = 0.0;

   int count = bars;
   if(count < 10)
      count = 10;

   if(Bars < count + 2)
      return false; // 历史K线不足，无法确定箱体

   double pct = BoxExtremePercentile;
   if(pct < 0.0)  pct = 0.0;
   if(pct > 0.25) pct = 0.25;   // 分位最高限制25%，避免顶/底逻辑失效

   double highArr[];
   double lowArr[];
   ArrayResize(highArr, count);
   ArrayResize(lowArr,  count);

   // 从 K[2] 开始，排除作为信号的 K[1] 与未完成的 K[0]
   for(int i = 0; i < count; i++)
   {
      highArr[i] = High[i + 2];
      lowArr[i]  = Low[i + 2];
   }

   ArraySort(highArr);  // 升序
   ArraySort(lowArr);   // 升序

   int topIdx    = (int)MathRound((count - 1) * (1.0 - pct));
   int bottomIdx = (int)MathRound((count - 1) * pct);

   if(topIdx    < 0)      topIdx    = 0;
   if(topIdx    >= count) topIdx    = count - 1;
   if(bottomIdx < 0)      bottomIdx = 0;
   if(bottomIdx >= count) bottomIdx = count - 1;

   boxHigh = highArr[topIdx];
   boxLow  = lowArr[bottomIdx];

   return true;
}

bool IsInBox() {
    // [Ver02 修复] 原代码用 start=1，会把 K[1] 自身纳入统计窗口，
    // 导致 Close[1] 永远落在 [lowest, highest] 内，恒返回 true，箱体过滤完全失效。
    // [Ver03] 改为与方向判断共用 GetBoxRange()（EntryLookbackBars 窗口 + 分位高低点）。
    double highest = 0.0, lowest = 0.0;
    if(!GetBoxRange(EntryLookbackBars, highest, lowest))
        return true; // 历史K线不足，无法确定箱体；此处放行，后续方向判断会因K线不足返回0不开仓

    double price = Close[1];
    return price <= highest && price >= lowest;
}

void OpenPosition(int direction) {
    double price = (direction == OP_BUY) ? Ask : Bid;

    // 查找最近一笔同方向订单
    double lastTime  = 0;
    double lastPrice = 0;
    bool   hasLast   = false;
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderSymbol() != Symbol()) continue;
        if (OrderMagicNumber() != MagicNumber) continue;
        if (OrderType() != direction) continue;

        if (!hasLast || OrderOpenTime() > lastTime) {
            hasLast   = true;
            lastTime  = OrderOpenTime();
            lastPrice = OrderOpenPrice();
        }
    }

    int slippage = 5;
    int ticket = OrderSend(Symbol(), direction, LotSize, price, slippage, 0, 0, "TP1", MagicNumber, 0, clrBlue);

    if (ticket < 0) {
        Print(MTag(), "开仓失败：", GetLastError());
        return;
    }

    if (hasLast) {
        double diffPoints = (direction == OP_BUY)
                           ? (price - lastPrice) / Point
                           : (lastPrice - price) / Point;
        Print(MTag(),
              "新开仓信息: 方向=", (direction == OP_BUY ? "多" : "空"),
              " 新单价=", F5(price),
              " 最近单价=", F5(lastPrice),
              " 价差(点)=", F5(diffPoints));
    } else {
        Print(MTag(),
              "新开仓信息: 方向=", (direction == OP_BUY ? "多" : "空"),
              " 新单价=", F5(price),
              "(无同方向历史单)");
    }

    // 输出当前同方向中极值订单信息：
    // 多单 -> 开仓价最低；空单 -> 开仓价最高
    double extremeOpen = 0, extremeLots = 0, extremeProfitPoints = 0;
    int    extremeTicket = -1;
    if (GetExtremeOrderInfo(direction, extremeOpen, extremeLots, extremeTicket, extremeProfitPoints)) {
        Print(MTag(),
              "极值订单信息: 方向=", (direction == OP_BUY ? "多" : "空"),
              " ticket=", extremeTicket,
              " 开仓价=", F5(extremeOpen),
              " 手数=", F5(extremeLots),
              " 当前盈亏点=", F5(extremeProfitPoints));
    }
}

int CountOrders() {
    int count = 0;
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderSymbol() != Symbol()) continue;
        if (OrderMagicNumber() != MagicNumber) continue;
        count++;
    }
    return count;
}

int CountLongOrders() {
    int count = 0;
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderSymbol() != Symbol()) continue;
        if (OrderMagicNumber() != MagicNumber) continue;
        if (OrderType() == OP_BUY) count++;
    }
    return count;
}

int CountShortOrders() {
    int count = 0;
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderSymbol() != Symbol()) continue;
        if (OrderMagicNumber() != MagicNumber) continue;
        if (OrderType() == OP_SELL) count++;
    }
    return count;
}

bool HasLongPositions() {
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderSymbol() != Symbol()) continue;
        if (OrderMagicNumber() != MagicNumber) continue;
        if (OrderType() == OP_BUY) return true;
    }
    return false;
}

bool HasShortPositions() {
    for (int i = 0; i < OrdersTotal(); i++) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderSymbol() != Symbol()) continue;
        if (OrderMagicNumber() != MagicNumber) continue;
        if (OrderType() == OP_SELL) return true;
    }
    return false;
}

void UpdateTrailingStopPerOrder() {
    static double lastProfitPoint[100]; // 最多支持 100 个订单跟踪
    static int slUpdateCount[100];
    static bool tpSet[100];
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderSymbol() != Symbol()) continue;
        if (OrderMagicNumber() != MagicNumber) continue;
        int ticket = OrderTicket();
        int type = OrderType();
        double openPrice = OrderOpenPrice();
        double currentPrice = (type == OP_BUY) ? Bid : Ask;

        double profitPoints = (type == OP_BUY) ? (currentPrice - openPrice) / Point
                                               : (openPrice - currentPrice) / Point;
        double lots = OrderLots();

        // 如果没有达到 TrailStart，则不设置止损
        int idx = ticket % 100;
        if (profitPoints < TrailStart) {
            lastProfitPoint[idx] = 0; // 重置
            continue;
        }

        double lastUpdate = lastProfitPoint[idx];

        double newSL = (type == OP_BUY) ? openPrice + (currentPrice - openPrice)*0.618
                                        : openPrice - (openPrice - currentPrice)*0.618 ;
        bool needModify = false;
        if (type == OP_BUY && (OrderStopLoss() < newSL || OrderStopLoss() == 0)) needModify = true;
        if (type == OP_SELL && (OrderStopLoss() > newSL || OrderStopLoss() == 0)) needModify = true;

        // 仅当新止损对多单高于开仓价 / 对空单低于开仓价时，才允许设置止损
        if (type == OP_BUY && newSL <= openPrice) needModify = false;
        if (type == OP_SELL && newSL >= openPrice) needModify = false;

        // 若已设置止损3次，则在第4次改为设置止盈（仅设置一次）
        if (slUpdateCount[idx] >= 3 && !tpSet[idx]) {
            double tp = (type == OP_BUY) ? (currentPrice + 100*Point) : (currentPrice - 100*Point);
            bool modifiedTP = OrderModify(ticket, openPrice, OrderStopLoss(), tp, 0, clrYellow);
            if (modifiedTP) {
                tpSet[idx] = true;
                Print(MTag(), "止盈已设置(第4次推进)，订单#", ticket, " TP=", tp);
            }
            continue;
        }

        if (needModify) {
            bool modified = OrderModify(ticket, openPrice, newSL, OrderTakeProfit(), 0, clrYellow);
            if (modified) {
                lastProfitPoint[idx] = profitPoints;
                slUpdateCount[idx]++;
                Print(MTag(), "更新移动止损(第", slUpdateCount[idx], "次)，订单#", ticket, "，当前盈利 ", profitPoints, " 点，新止损：", newSL);
            }
        }
    }
}
bool GetExtremeOrderInfo(int direction, double &openPrice, double &lots, int &ticket, double &profitPoints)
{
    bool found = false;
    double extreme = 0;
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
        if (OrderSymbol() != Symbol()) continue;
        if (OrderMagicNumber() != MagicNumber) continue;
        if (OrderType() != direction) continue;

        double op = OrderOpenPrice();

        if (!found) {
            found   = true;
            extreme = op;
            openPrice = op;
            lots      = OrderLots();
            ticket    = OrderTicket();
        } else {
            if (direction == OP_BUY) {
                // 多单：选开仓价最低
                if (op < extreme) {
                    extreme   = op;
                    openPrice = op;
                    lots      = OrderLots();
                    ticket    = OrderTicket();
                }
            } else if (direction == OP_SELL) {
                // 空单：选开仓价最高
                if (op > extreme) {
                    extreme   = op;
                    openPrice = op;
                    lots      = OrderLots();
                    ticket    = OrderTicket();
                }
            }
        }
    }

    if (!found) return false;

    double cur = (direction == OP_BUY) ? Bid : Ask;
    profitPoints = (direction == OP_BUY)
                   ? (cur - openPrice) / Point
                   : (openPrice - cur) / Point;
    return true;
}

// 添加趋势判断函数
//bool IsTrending(int period=48, double threshold=20) {

bool IsTrending()
{
    // [Ver02 修复] 原代码读取 K[0]（正在形成的K线），ADX 值会随行情跳动，
    // 且新K线首tick时几乎无数据。改为读取已收盘的 K[1]，与EA其它逻辑保持一致。
    //double adx = iADX(NULL,0,period,PRICE_CLOSE,MODE_MAIN,0);
    double adx = iADX(NULL,0,ADXPeriod,PRICE_CLOSE,MODE_MAIN, 1);

    // ADX 取值失败(历史K线不足)时，视为无法确认趋势，返回 false（保持原 fail-open 行为）
    if(adx < 0)
        return false;

    //bool ret = adx > threshold;
    bool ret = adx > ADXThreshold;
    if (ret)
       Print(MTag(), "趋势行情，停止开仓 | ADX=", DoubleToString(adx, 2),
            " 周期=", ADXPeriod,
            " 阈值=", DoubleToString(ADXThreshold, 2));
    
    return ret; 
}

// 判断当前价格是否处于箱体顶部/底部区域
//+------------------------------------------------------------------+
//| 根据已收盘K线判断箱体顶部/底部的反转开仓方向                     |
//| 返回：OP_BUY / OP_SELL / OP_NO_TRADE（不交易）                 |
//+------------------------------------------------------------------+
int GetBoxPositionDirection()
{
   // 至少需要：回看周期 + 当前K线 + 已收盘信号K线
   if(Bars < EntryLookbackBars + 2)
   {
      Print(MTag(), "K线数量不足，无法判断首单方向。Bars=", Bars,
            " 需要至少=", EntryLookbackBars + 2);
      return OP_NO_TRADE;
   }

   // 参数保护
   int lookbackBars = EntryLookbackBars;
   if(lookbackBars < 10)
      lookbackBars = 10;

   double edgePercent = BoxEdgePercent;
   if(edgePercent <= 0.0 || edgePercent >= 0.5)
   {
      Print(MTag(), "BoxEdgePercent 参数无效，自动使用 0.20");
      edgePercent = 0.20;
   }

   double minBodyPercent = MinReversalBodyPercent;
   if(minBodyPercent < 0.0)
      minBodyPercent = 0.0;
   if(minBodyPercent > 1.0)
      minBodyPercent = 1.0;

   double reversalClosePos = ReversalClosePosition;
   if(reversalClosePos < 0.0)
      reversalClosePos = 0.0;
   if(reversalClosePos > 1.0)
      reversalClosePos = 1.0;

   // [Ver03] 统一用 GetBoxRange() 取分位箱体（抗毛刺），并与 IsInBox 口径一致
   double boxHigh = 0.0, boxLow = 0.0;
   if(!GetBoxRange(lookbackBars, boxHigh, boxLow))
   {
      Print(MTag(), "无法取得箱体高低点。");
      return OP_NO_TRADE;
   }

   double range = boxHigh - boxLow;
   if(range <= 0.0)
   {
      Print(MTag(), "箱体区间无效，区间高度=", F5(range));
      return OP_NO_TRADE;
   }

   // 顶部20%与底部20%
   double topZone    = boxHigh - range * edgePercent;
   double bottomZone = boxLow  + range * edgePercent;

   // 只读取已经收盘的上一根K线
   double signalOpen  = Open[1];
   double signalHigh  = High[1];
   double signalLow   = Low[1];
   double signalClose = Close[1];

   double candleRange = signalHigh - signalLow;
   if(candleRange <= 0.0)
   {
      Print(MTag(), "信号K线无有效波幅，不开仓。");
      return OP_NO_TRADE;
   }

   double candleBody = MathAbs(signalClose - signalOpen);
   double bodyRatio  = candleBody / candleRange;

   // [Ver03] 收盘位置：0=最低价，1=最高价。用于判断收盘是否收在K线上/下半区
   double closePos = (signalClose - signalLow) / candleRange;

   bool bullBar = (signalClose > signalOpen);
   bool bearBar = (signalClose < signalOpen);

   // 触及底部 / 顶部区域
   bool touchedBottom = (signalLow <= bottomZone);
   bool touchedTop    = (signalHigh >= topZone);

   // [Ver03] 假突破：可选"真实破界"或"边缘区触及"
   bool buyFalseBreak, sellFalseBreak;
   if(RequireTrueBreak)
   {
      // 真实假跌破：低点刺破箱底(boxLow)后，收盘收回箱底上方
      buyFalseBreak  = (signalLow  < boxLow  && signalClose > boxLow);
      // 真实假突破：高点刺破箱顶(boxHigh)后，收盘收回箱顶下方
      sellFalseBreak = (signalHigh > boxHigh && signalClose < boxHigh);
   }
   else
   {
      // 弱模式：仅触及边缘区后收回
      buyFalseBreak  = (signalLow <= bottomZone && signalClose > bottomZone);
      sellFalseBreak = (signalHigh >= topZone && signalClose < topZone);
   }

   // 若关闭假突破要求，只要K线触及边缘区域即可；
   // 若开启，则必须满足“刺破/触及后收回”的条件。
   bool buyLocationOK = RequireFalseBreak ? buyFalseBreak : touchedBottom;
   bool sellLocationOK = RequireFalseBreak ? sellFalseBreak : touchedTop;

   // [Ver03] 反转K线确认：方向 + 收盘位置（不再只看实体占比）
   bool strongBullClose = (closePos >= reversalClosePos);
   bool strongBearClose = (closePos <= (1.0 - reversalClosePos));

   bool buyCandleOK  = !RequireReversalBar || (bullBar  && strongBullClose);
   bool sellCandleOK = !RequireReversalBar || (bearBar && strongBearClose);

   // [Ver03] 实体过滤放宽：实体占比达标，或收盘位置足够极端(长影线强反转K) 即可通过
   bool buyBodyOK  = (bodyRatio >= minBodyPercent) || (closePos >= 0.70);
   bool sellBodyOK = (bodyRatio >= minBodyPercent) || (closePos <= 0.30);

   bool buyOK  = buyLocationOK  && buyCandleOK  && buyBodyOK;
   bool sellOK = sellLocationOK && sellCandleOK && sellBodyOK;

   // [Ver03] 多空条件同时成立(极端巨K横跨整个箱体)时，方向不明，放弃开仓
   if(buyOK && sellOK)
   {
      Print(MTag(), "方向判定=不交易 | 单根K线同时触及顶底区域，方向不明");
      return OP_NO_TRADE;
   }

   // ===== 底部反转 -> 做多 =====
   if(buyOK)
   {
      Print(MTag(),
            "方向判定=多 | 底部反转确认",
            " 箱体顶=", F5(boxHigh),
            " 箱体底=", F5(boxLow),
            " 底部阈=", F5(bottomZone),
            " K[1] O=", F5(signalOpen),
            " H=", F5(signalHigh),
            " L=", F5(signalLow),
            " C=", F5(signalClose),
            " 实体比例=", DoubleToString(bodyRatio * 100.0, 1), "%",
            " 收盘位置=", DoubleToString(closePos * 100.0, 1), "%",
            " 假跌破=", (buyFalseBreak ? "是" : "否"),
            " 真实破界=", (RequireTrueBreak ? "是" : "否"));

      return OP_BUY;
   }

   // ===== 顶部反转 -> 做空 =====
   if(sellOK)
   {
      Print(MTag(),
            "方向判定=空 | 顶部反转确认",
            " 箱体顶=", F5(boxHigh),
            " 箱体底=", F5(boxLow),
            " 顶部阈=", F5(topZone),
            " K[1] O=", F5(signalOpen),
            " H=", F5(signalHigh),
            " L=", F5(signalLow),
            " C=", F5(signalClose),
            " 实体比例=", DoubleToString(bodyRatio * 100.0, 1), "%",
            " 收盘位置=", DoubleToString(closePos * 100.0, 1), "%",
            " 假突破=", (sellFalseBreak ? "是" : "否"),
            " 真实破界=", (RequireTrueBreak ? "是" : "否"));

      return OP_SELL;
   }

   Print(MTag(),
         "方向判定=不交易",
         " | 箱体顶=", F5(boxHigh),
         " 箱体底=", F5(boxLow),
         " 顶阈=", F5(topZone),
         " 底阈=", F5(bottomZone),
         " | K[1] O=", F5(signalOpen),
         " H=", F5(signalHigh),
         " L=", F5(signalLow),
         " C=", F5(signalClose),
         " 实体比例=", DoubleToString(bodyRatio * 100.0, 1), "%",
         " 收盘位置=", DoubleToString(closePos * 100.0, 1), "%",
         " | 底部触及=", (touchedBottom ? "是" : "否"),
         " 顶部触及=", (touchedTop ? "是" : "否"),
         " 假跌破=", (buyFalseBreak ? "是" : "否"),
         " 假突破=", (sellFalseBreak ? "是" : "否"));

   return OP_NO_TRADE;
}

//固定止损函数
void TrendFixedStopLoss()
{
   if(!EnableTrendFixedStop) return;

   RefreshRates();

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol()) continue;
      if(OrderMagicNumber() != MagicNumber) continue;

      int type = OrderType();
      if(type != OP_BUY && type != OP_SELL) continue;

      double curPrice = (type == OP_BUY) ? Bid : Ask;
      double lossPoints = 0;

      if(type == OP_BUY)
         lossPoints = (OrderOpenPrice() - curPrice) / Point;
      else
         lossPoints = (curPrice - OrderOpenPrice()) / Point;

      if(lossPoints < TrendStopLossPoints) continue;

      bool closed = false;
      int slippage = 5;

      if(type == OP_BUY)
         closed = OrderClose(OrderTicket(), OrderLots(), Bid, slippage, clrRed);
      else
         closed = OrderClose(OrderTicket(), OrderLots(), Ask, slippage, clrRed);

      if(closed)
      {
         Print(MTag(),
               "趋势固定止损触发，订单#", OrderTicket(),
               " 方向=", (type == OP_BUY ? "多" : "空"),
               " 开仓价=", F5(OrderOpenPrice()),
               " 当前价=", F5(curPrice),
               " 亏损点数=", DoubleToString(lossPoints, 1),
               " >= 阈值=", TrendStopLossPoints);
      }
      else
      {
         Print(MTag(),
               "趋势固定止损平仓失败，订单#", OrderTicket(),
               " 错误码=", GetLastError());
      }
   }
}

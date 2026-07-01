//+------------------------------------------------------------------+
//|                  Martin Strategy EA (完整集成版)                |
//|     功能：逐单移动止损、交易量判断方向、加仓、箱体限制、强平   |
//|     Version：2025-11-14 1.00.001
//+------------------------------------------------------------------+

#property strict
#include <GeneralFunctions.mqh>
extern double LotSize = 0.02;
extern int GridStepPoints = 200;      // 加仓点数
extern int MaxOrders = 10;            // 最多加仓次数
extern int BoxBars = 600;             // 箱体周期
extern int MagicNumber = 5301001;      // 仅管理本策略订单
extern double TrailStart = 100;
double singal_trade_risk_rate = 0.975;

extern int MaxLongOrders = 2;        // 多单上限
extern int MaxShortOrders = 2;       // 空单上限


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
    AccountBalanceRickControl(singal_trade_risk_rate);//控制资金风险，一旦下滑10%，就平仓
    return(INIT_SUCCEEDED);
}

void OnTick() {

   // 每根新K线执行一次主要开仓/加仓逻辑
   if (IsNewBar()) 
   {
         RunAlgoPerBar();
         AccountBalanceRickControl(0.97);
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
        Print(MTag(), "趋势行情，暂停开仓");
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
    if (direction != OP_BUY && direction != OP_SELL && CountOrders()==0) 
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


bool IsInBox() {
    double highest = High[iHighest(NULL, 0, MODE_HIGH, BoxBars, 1)];
    double lowest = Low[iLowest(NULL, 0, MODE_LOW, BoxBars, 1)];
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
bool IsTrending(int period=48, double threshold=20) {
    double adx = iADX(NULL,0,period,PRICE_CLOSE,MODE_MAIN,0);

    bool ret = adx > threshold;
    if (ret)
      Print(MTag(), "趋势行情，停止开仓");
    
    return ret; 
}

// 判断当前价格是否处于箱体顶部/底部区域
int GetBoxPositionDirection(string symbol = NULL, int lookbackBars = 100) {
    if (symbol == NULL) symbol = Symbol();

    int totalBars = Bars;
    if (lookbackBars > totalBars - 1) {
        lookbackBars = totalBars - 1;  // 避免越界
    }

    double boxHigh = High[1];
    double boxLow = Low[1];

    for (int i = 1; i <= lookbackBars; i++) {
        if (High[i] > boxHigh) boxHigh = High[i];
        if (Low[i] < boxLow) boxLow = Low[i];
    }

    double range = boxHigh - boxLow;
    if (range <= 0) return -1;

    double topZone = boxHigh - 0.2 * range;
    double bottomZone = boxLow + 0.2 * range;
    double currentPrice = (Ask + Bid)/2.0;

    if (currentPrice >= topZone) {
        Print(MTag(), "方向判定=空 | 价格=", F5(currentPrice), " 顶部阈=", F5(topZone), " 底部阈=", F5(bottomZone), " 区间顶=", F5(boxHigh), " 区间底=", F5(boxLow));
        return OP_SELL; // 顶部区域 → 做空
    }

    if (currentPrice <= bottomZone) {
        Print(MTag(), "方向判定=多 | 价格=", F5(currentPrice), " 顶部阈=", F5(topZone), " 底部阈=", F5(bottomZone), " 区间顶=", F5(boxHigh), " 区间底=", F5(boxLow));
        return OP_BUY; // 底部区域 → 做多
    }

    Print(MTag(), "方向判定=不确定,区间高度:",F5(range));
    return 0; // 中间区域
}

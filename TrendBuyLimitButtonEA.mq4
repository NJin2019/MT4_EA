#property strict
#property version   "1.00"
#property description "Button-activated M15/M5 trend-pullback Buy Limit EA"

input double Lots                       = 0.01;
input int    MagicNumber                = 20260916;
input int    Slippage                   = 5;

input ENUM_TIMEFRAMES TrendTF           = PERIOD_M15;
input ENUM_TIMEFRAMES EntryTF           = PERIOD_M5;
input int    FastEMAPeriod              = 20;
input int    SlowEMAPeriod              = 50;

input int    ATRPeriod                  = 14;
input int    SwingLeftBars              = 2;
input int    SwingRightBars             = 2;
input int    SwingSearchStartShift      = 3;
input int    SwingSearchBars            = 30;
input double InitialSL_ATR_Mult         = 1.0;
input double SpreadBufferMult           = 2.0;
input double MinSL_ATR_Mult             = 0.8;
input double MaxSL_ATR_Mult             = 2.2;

input double EntryATR_PullbackMult      = 0.25;
input int    PendingExpiryMinutes       = 30;
input int    MaxSpreadPoints            = 0;

input bool   EnableTrailing             = true;
input double MoveBE_At_R                = 1.0;
input double BE_Offset_ATR_Mult         = 0.15;
input double StartTrailing_At_R         = 1.5;
input int    TrailHighestBars           = 5;
input double TrailATR_Mult              = 1.8;

input int    ButtonXDistance            = 485;
input int    ButtonYDistance            = 50;
input int    ButtonWidth                = 210;
input int    ButtonHeight               = 32;

string ButtonName;
string StatusName;
bool   StartRequested = false;

datetime LastEntryBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   ButtonName = "TrendBuyLimitEA_Start_" + IntegerToString(MagicNumber);
   StatusName = "TrendBuyLimitEA_Status_" + IntegerToString(MagicNumber);

   CreateStartButton();
   CreateStatusLabel("等待按钮：未启动", clrSilver);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectDelete(0, ButtonName);
   ObjectDelete(0, StatusName);
}

//+------------------------------------------------------------------+
void OnTick()
{
   ManageOpenBuyPositions();

   // 每按一次按钮，只尝试创建一次 Buy Limit。
   if(!StartRequested)
      return;

   datetime currentEntryBar = iTime(Symbol(), EntryTF, 0);
   if(currentEntryBar == 0)
      return;

   if(currentEntryBar == LastEntryBarTime)
      return;

   LastEntryBarTime = currentEntryBar;
   TryPlaceTrendBuyLimit();
}

//+------------------------------------------------------------------+
void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK)
      return;

   if(sparam != ButtonName)
      return;

   ObjectSetInteger(0, ButtonName, OBJPROP_STATE, false);

   if(HasExistingBuySideOrder(Symbol(), MagicNumber))
   {
      StartRequested = false;
      SetButtonText("已有多单/挂单");
      CreateStatusLabel("已有本EA多单或多方向挂单：不创建新单", clrOrange);
      ChartRedraw();
      return;
   }

   StartRequested = true;
   SetButtonText("已启动：等待M5机会");
   CreateStatusLabel("已启动：将在下一根M5新K线检查一次", clrLime);
   ChartRedraw();
}

//+------------------------------------------------------------------+
void CreateStartButton()
{
   if(ObjectFind(0, ButtonName) < 0)
      ObjectCreate(0, ButtonName, OBJ_BUTTON, 0, 0, 0);

   ObjectSetInteger(0, ButtonName, OBJPROP_CORNER, CORNER_RIGHT_LOWER);
   ObjectSetInteger(0, ButtonName, OBJPROP_XDISTANCE, ButtonXDistance);
   ObjectSetInteger(0, ButtonName, OBJPROP_YDISTANCE, ButtonYDistance);
   ObjectSetInteger(0, ButtonName, OBJPROP_XSIZE, ButtonWidth);
   ObjectSetInteger(0, ButtonName, OBJPROP_YSIZE, ButtonHeight);
   ObjectSetString(0, ButtonName, OBJPROP_TEXT, "增长趋势中挂多单开始");
   ObjectSetInteger(0, ButtonName, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, ButtonName, OBJPROP_BGCOLOR, clrForestGreen);
   ObjectSetInteger(0, ButtonName, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(0, ButtonName, OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, ButtonName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, ButtonName, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, ButtonName, OBJPROP_STATE, false);
}

//+------------------------------------------------------------------+
void SetButtonText(string text)
{
   ObjectSetString(0, ButtonName, OBJPROP_TEXT, text);
}

//+------------------------------------------------------------------+
void CreateStatusLabel(string text, color textColor)
{
   if(ObjectFind(0, StatusName) < 0)
      ObjectCreate(0, StatusName, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, StatusName, OBJPROP_CORNER, CORNER_RIGHT_LOWER);
   ObjectSetInteger(0, StatusName, OBJPROP_XDISTANCE, ButtonXDistance);
   ObjectSetInteger(0, StatusName, OBJPROP_YDISTANCE, ButtonYDistance + ButtonHeight + 5);
   ObjectSetString(0, StatusName, OBJPROP_TEXT, text);
   ObjectSetInteger(0, StatusName, OBJPROP_COLOR, textColor);
   ObjectSetInteger(0, StatusName, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, StatusName, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, StatusName, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
bool IsUpTrend()
{
   if(iBars(Symbol(), TrendTF) < SlowEMAPeriod + 5)
      return(false);

   double fast1 = iMA(Symbol(), TrendTF, FastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double slow1 = iMA(Symbol(), TrendTF, SlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
   double close1 = iClose(Symbol(), TrendTF, 1);

   double recentLow = FindRecentSwingLow(Symbol(), TrendTF,
                                          SwingLeftBars, SwingRightBars,
                                          SwingSearchStartShift, SwingSearchBars);

   if(recentLow <= 0)
      return(false);

   // 多头背景：快EMA高于慢EMA、收盘位于快EMA之上，且最近结构低点未被破坏。
   if(fast1 <= slow1)
      return(false);

   if(close1 <= fast1)
      return(false);

   if(Bid <= recentLow)
      return(false);

   return(true);
}

//+------------------------------------------------------------------+
void TryPlaceTrendBuyLimit()
{
   StartRequested = false;

   if(HasExistingBuySideOrder(Symbol(), MagicNumber))
   {
      SetButtonText("已有多单/挂单");
      CreateStatusLabel("已有本EA多单或多方向挂单：跳过", clrOrange);
      return;
   }

   if(!IsTradeAllowed())
   {
      SetButtonText("交易未授权");
      CreateStatusLabel("MT4未允许自动交易或交易上下文忙", clrTomato);
      return;
   }

   RefreshRates();

   int spreadPoints = (int)MarketInfo(Symbol(), MODE_SPREAD);
   if(MaxSpreadPoints > 0 && spreadPoints > MaxSpreadPoints)
   {
      SetButtonText("点差过大：已跳过");
      CreateStatusLabel("当前点差=" + IntegerToString(spreadPoints) + " points", clrOrange);
      return;
   }

   if(!IsUpTrend())
   {
      SetButtonText("非上涨趋势：已跳过");
      CreateStatusLabel("M15趋势条件未满足", clrOrange);
      return;
   }

   double atr = iATR(Symbol(), EntryTF, ATRPeriod, 1);
   double swingLow = FindRecentSwingLow(Symbol(), EntryTF,
                                        SwingLeftBars, SwingRightBars,
                                        SwingSearchStartShift, SwingSearchBars);

   if(atr <= 0 || swingLow <= 0)
   {
      SetButtonText("结构数据不足");
      CreateStatusLabel("未找到有效M5 ATR或Swing Low", clrTomato);
      return;
   }

   // Buy Limit 放在最近M5回撤低点上方一小段距离。
   double entryPrice = swingLow + EntryATR_PullbackMult * atr;

   // 必须低于当前Ask，并满足经纪商的最小挂单距离。
   double minStopDistance = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(minStopDistance < Point)
      minStopDistance = Point;

   if(entryPrice >= Ask - minStopDistance)
   {
      SetButtonText("回撤位太近：已跳过");
      CreateStatusLabel("Buy Limit未满足最小挂单距离", clrOrange);
      return;
   }

   double spreadPrice = Ask - Bid;
   double buffer = MathMax(InitialSL_ATR_Mult * atr,
                           SpreadBufferMult * spreadPrice);
   double stopLoss = swingLow - buffer;

   entryPrice = NormalizeDouble(entryPrice, Digits);
   stopLoss   = NormalizeDouble(stopLoss, Digits);

   double stopDistance = entryPrice - stopLoss;
   if(stopDistance <= 0)
   {
      SetButtonText("止损无效：已跳过");
      CreateStatusLabel("止损必须低于Buy Limit入场价", clrTomato);
      return;
   }

   if(stopDistance < MinSL_ATR_Mult * atr ||
      stopDistance > MaxSL_ATR_Mult * atr)
   {
      SetButtonText("止损距离不合格");
      CreateStatusLabel("SL距离不在ATR过滤范围内", clrOrange);
      return;
   }

   // 对Buy Limit，入场价与SL的距离都必须满足StopLevel。
   if((entryPrice - stopLoss) < minStopDistance)
   {
      SetButtonText("SL低于经纪商要求");
      CreateStatusLabel("SL距离小于MODE_STOPLEVEL", clrTomato);
      return;
   }

   datetime expiry = TimeCurrent() + PendingExpiryMinutes * 60;

   ResetLastError();
   int ticket = OrderSend(Symbol(), OP_BUYLIMIT, Lots, entryPrice, Slippage,
                          stopLoss, 0, "Trend Pullback Buy Limit", MagicNumber,
                          expiry, clrBlue);

   if(ticket < 0)
   {
      int errorCode = GetLastError();
      SetButtonText("下单失败：" + IntegerToString(errorCode));
      CreateStatusLabel("OrderSend失败，Error=" + IntegerToString(errorCode), clrTomato);
      Print("Buy Limit OrderSend failed. Error=", errorCode,
            " Entry=", DoubleToString(entryPrice, Digits),
            " SL=", DoubleToString(stopLoss, Digits));
      return;
   }

   SetButtonText("Buy Limit已创建");
   CreateStatusLabel("Ticket=" + IntegerToString(ticket) +
                     " Entry=" + DoubleToString(entryPrice, Digits) +
                     " SL=" + DoubleToString(stopLoss, Digits), clrLime);
   Print("Buy Limit created. Ticket=", ticket,
         " Entry=", DoubleToString(entryPrice, Digits),
         " SL=", DoubleToString(stopLoss, Digits));
}

//+------------------------------------------------------------------+
bool HasExistingBuySideOrder(string symbol, int magicNumber)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() != symbol)
         continue;

      if(OrderMagicNumber() != magicNumber)
         continue;

      int type = OrderType();
      if(type == OP_BUY || type == OP_BUYLIMIT || type == OP_BUYSTOP)
         return(true);
   }

   return(false);
}

//+------------------------------------------------------------------+
double FindRecentSwingLow(string symbol,
                          int timeframe,
                          int leftBars,
                          int rightBars,
                          int startShift,
                          int maxLookback)
{
   int totalBars = iBars(symbol, timeframe);
   if(totalBars <= leftBars + rightBars + startShift + 2)
      return(0);

   int firstShift = MathMax(startShift, rightBars + 1);
   int lastShift = MathMin(startShift + maxLookback,
                           totalBars - leftBars - 1);

   for(int shift = firstShift; shift <= lastShift; shift++)
   {
      double candidateLow = iLow(symbol, timeframe, shift);
      bool isSwingLow = true;

      // shift+i 是更早K线；shift-i 是更近、已收盘K线。
      for(int i = 1; i <= leftBars; i++)
      {
         if(iLow(symbol, timeframe, shift + i) <= candidateLow)
         {
            isSwingLow = false;
            break;
         }
      }

      if(!isSwingLow)
         continue;

      for(int j = 1; j <= rightBars; j++)
      {
         if(iLow(symbol, timeframe, shift - j) <= candidateLow)
         {
            isSwingLow = false;
            break;
         }
      }

      if(isSwingLow)
         return(candidateLow);
   }

   return(0);
}

//+------------------------------------------------------------------+
void ManageOpenBuyPositions()
{
   if(!EnableTrailing)
      return;

   RefreshRates();

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;

      if(OrderSymbol() != Symbol())
         continue;

      if(OrderMagicNumber() != MagicNumber)
         continue;

      if(OrderType() != OP_BUY)
         continue;

      double entry = OrderOpenPrice();
      double originalSL = OrderStopLoss();
      if(originalSL <= 0 || entry <= originalSL)
         continue;

      double initialRisk = entry - originalSL;
      double profitDistance = Bid - entry;
      if(initialRisk <= 0 || profitDistance <= 0)
         continue;

      double atr = iATR(Symbol(), EntryTF, ATRPeriod, 1);
      if(atr <= 0)
         continue;

      double minStopDistance = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
      if(minStopDistance < Point)
         minStopDistance = Point;

      double newSL = originalSL;

      // 浮盈达到1R后，先移到入场价下方小ATR缓冲。
      if(profitDistance >= MoveBE_At_R * initialRisk)
      {
         double beSL = entry - BE_Offset_ATR_Mult * atr;
         if(beSL > newSL)
            newSL = beSL;
      }

      // 浮盈达到1.5R后，用最近高点减ATR追踪，只允许上移。
      if(profitDistance >= StartTrailing_At_R * initialRisk)
      {
         int highestShift = iHighest(Symbol(), EntryTF, MODE_HIGH,
                                     TrailHighestBars, 1);
         if(highestShift >= 0)
         {
            double highestHigh = iHigh(Symbol(), EntryTF, highestShift);
            double trailSL = highestHigh - TrailATR_Mult * atr;
            if(trailSL > newSL)
               newSL = trailSL;
         }
      }

      newSL = NormalizeDouble(newSL, Digits);

      // 不允许把SL移动到离当前Bid过近的位置。
      if(newSL >= Bid - minStopDistance)
         continue;

      if(newSL <= OrderStopLoss() + Point)
         continue;

      ResetLastError();
      bool modified = OrderModify(OrderTicket(), OrderOpenPrice(), newSL,
                                  OrderTakeProfit(), OrderExpiration(), clrNONE);
      if(!modified)
      {
         Print("OrderModify failed. Ticket=", OrderTicket(),
               " Error=", GetLastError(),
               " NewSL=", DoubleToString(newSL, Digits));
      }
   }
}

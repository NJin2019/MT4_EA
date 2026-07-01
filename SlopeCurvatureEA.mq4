//+------------------------------------------------------------------+
//|                                      SlopeCurvatureTradingEA.mq4 |
//|                        Copyright 2025, MetaQuotes Software Corp. |
//|                                             https://www.metaquotes.net/ |
//+------------------------------------------------------------------+
#property copyright "Copyright 2025, MetaQuotes Software Corp."
#property link      "https://www.metaquotes.net/"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| 错误描述函数                                                    |
//+------------------------------------------------------------------+
string ErrorDescription(int error_code)
{
    string error_string;
    switch(error_code)
    {
        // 常见错误代码
        case 0:   error_string = "没有错误"; break;
        case 1:   error_string = "没有错误，但结果未知"; break;
        case 2:   error_string = "常见错误"; break;
        case 3:   error_string = "无效参数"; break;
        case 4:   error_string = "交易服务器忙"; break;
        case 5:   error_string = "交易服务器版本过时"; break;
        case 6:   error_string = "没有连接"; break;
        case 7:   error_string = "权限不足"; break;
        case 8:   error_string = "请求太频繁"; break;
        case 64:  error_string = "账户被禁用"; break;
        case 65:  error_string = "无效账户"; break;
        case 128: error_string = "交易超时"; break;
        case 129: error_string = "无效价格"; break;
        case 130: error_string = "无效止损或止盈"; break;
        case 131: error_string = "无效手数"; break;
        case 132: error_string = "交易被禁用"; break;
        case 133: error_string = "交易不允许"; break;
        case 134: error_string = "资金不足"; break;
        case 135: error_string = "价格已变化"; break;
        case 136: error_string = "没有价格"; break;
        case 137: error_string = "经纪商忙"; break;
        case 138: error_string = "请求重试"; break;
        case 139: error_string = "订单被锁定"; break;
        case 140: error_string = "只允许买入"; break;
        case 141: error_string = "尝试次数过多"; break;
        case 145: error_string = "交易被修改被禁止"; break;
        case 146: error_string = "交易系统忙"; break;
        case 147: error_string = "交易被禁止"; break;
        case 148: error_string = "订单太多"; break;
        case 149: error_string = "对冲被禁止"; break;
        case 150: error_string = "FIFO规则禁止平仓"; break;
        default:  error_string = "未知错误";
    }
    return(error_string);
}

//--- Input Parameters
extern double Lots = 0.1;              // 交易手数
extern int Slippage = 3;               // 允许的滑点
extern int MagicNumber = 123456;       // 魔术数字，用于标识EA订单
extern int SmoothPeriod = 5;           // EMA平滑周期
extern double EntryThreshold = 0.0006; // 入场阈值
extern double ExitThreshold = 0.0001;  // 平仓阈值

//--- Global Variables
double g_slope_curr = 0;
double g_curvature = 0;
double g_diff = 0;
int g_ticket = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // 确保EA在图表上显示名称
    Comment("Slope-Curvature Trading EA");
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // 只在新的柱开始时检查交易信号
    if(!IsNewBar()) return;
    
    // 计算技术指标
    CalculateIndicators();
    
    // 检查是否有持仓
    if(CountPositions() == 0)
    {
        // 没有持仓，检查入场信号
        CheckForEntry();
    }
    else
    {
        // 有持仓，检查平仓信号
        CheckForExit();
    }
    
    // 更新图表注释，显示当前状态
    UpdateChart();
}

//+------------------------------------------------------------------+
//| 计算斜率、曲率和差值                                            |
//+------------------------------------------------------------------+
void CalculateIndicators()
{
    double s1 = iMA(NULL, 0, SmoothPeriod, 0, MODE_EMA, PRICE_CLOSE, 2);
    double s0 = iMA(NULL, 0, SmoothPeriod, 0, MODE_EMA, PRICE_CLOSE, 1);
    double s_1 = iMA(NULL, 0, SmoothPeriod, 0, MODE_EMA, PRICE_CLOSE, 0);
    
    g_slope_curr = s0 - s_1;
    g_curvature = s1 - 2 * s0 + s_1;
    g_diff = g_slope_curr - g_curvature;
}

//+------------------------------------------------------------------+
//| 检查入场信号                                                    |
//+------------------------------------------------------------------+
void CheckForEntry()
{
    // 做多信号：差值小于负的入场阈值
    if(g_diff < -EntryThreshold)
    {
        double openPrice = Ask;
        
        g_ticket = OrderSend(Symbol(), OP_BUY, Lots, openPrice, Slippage, 0, 0, 
                            "SlopeCurvatureEA", MagicNumber, 0, clrGreen);
        
        if(g_ticket < 0)
            Print("OrderSend 错误: ", GetLastError(), " - ", ErrorDescription(GetLastError()));
        else
            Print("做多入场, 价格: ", openPrice, ", g_diff: ", g_diff);
    }
    // 做空信号：差值大于正的入场阈值
    else if(g_diff > EntryThreshold)
    {
        double openPrice = Bid;
        
        g_ticket = OrderSend(Symbol(), OP_SELL, Lots, openPrice, Slippage, 0, 0, 
                            "SlopeCurvatureEA", MagicNumber, 0, clrRed);
        
        if(g_ticket < 0)
            Print("OrderSend 错误: ", GetLastError(), " - ", ErrorDescription(GetLastError());
        else
            Print("做空入场, 价格: ", openPrice, ", g_diff: ", g_diff);
    }
}

//+------------------------------------------------------------------+
//| 检查平仓信号                                                    |
//+------------------------------------------------------------------+
void CheckForExit()
{
    for(int i = 0; i < OrdersTotal(); i++)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
            {
                int orderType = OrderType();
                int ticket = OrderTicket();
                
                // 检查平仓条件
                // 多单平仓条件：g_diff > -0.0001
                // 空单平仓条件：g_diff < 0.0001
                if((orderType == OP_BUY && g_diff > -0.0001) ||  // 多单平仓条件
                   (orderType == OP_SELL && g_diff < 0.0001))    // 空单平仓条件
                {
                    double closePrice = (orderType == OP_BUY) ? Bid : Ask;
                    bool closeOrder = OrderClose(ticket, OrderLots(), closePrice, Slippage, clrYellow);
                    
                    if(closeOrder)
                        Print("平仓订单 #", ticket, ", 类型: ", (orderType == OP_BUY ? "多单" : "空单"), 
                              ", 价格: ", closePrice, ", g_diff: ", g_diff);
                    else
                        Print("平仓失败 #", ticket, ", 错误: ", GetLastError(), " - ", ErrorDescription(GetLastError()));
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| 更新图表信息                                                    |
//+------------------------------------------------------------------+
void UpdateChart()
{
    string comment = "Slope-Curvature Trading EA\n";
    comment += "当前差值 (g_diff): " + DoubleToString(g_diff, 6) + "\n";
    comment += "入场阈值: ±" + DoubleToString(EntryThreshold, 6) + "\n";
    comment += "平仓阈值: ±" + DoubleToString(ExitThreshold, 6) + "\n";
    comment += "当前持仓: " + (CountPositions() > 0 ? "有持仓" : "无持仓") + "\n";
    comment += "当前时间: " + TimeToStr(TimeCurrent()) + "\n";
    
    Comment(comment);
}

//+------------------------------------------------------------------+
//| 计算当前持仓数量                                                |
//+------------------------------------------------------------------+
int CountPositions()
{
    int count = 0;
    for(int i = 0; i < OrdersTotal(); i++)
    {
        if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
        {
            if(OrderSymbol() == Symbol() && OrderMagicNumber() == MagicNumber)
            {
                count++;
            }
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| 检查是否是新柱                                                  |
//+------------------------------------------------------------------+
bool IsNewBar()
{
    static datetime lastBarTime = 0;
    datetime currentBarTime = iTime(NULL, 0, 0);
    
    if(lastBarTime != currentBarTime)
    {
        lastBarTime = currentBarTime;
        return true;
    }
    return false;
}
//+------------------------------------------------------------------+

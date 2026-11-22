//+------------------------------------------------------------------+
//|                                                  ButtonsOrder.mq4 |
//|   右下角交易面板：下空单 / 下多单 + 手数输入框 + 止盈输入框        |
//|   手数：手动 +/- 或直接输入（默认 0.01）                          |
//|   止盈：ATR(50) 驱动，每 10 秒刷新一次，+/- 调整 ATR 倍数          |
//+------------------------------------------------------------------+
#property copyright "Trae"
#property version   "1.10"
#property strict

//--- 参数 -----------------------------------------------------------
input double InpLots      = 0.01;       // 初始手数
input int    InpATRPeriod = 50;         // ATR 周期
input double InpTPMult    = 1.0;        // ATR 倍数（止盈点数 = ATR/Point × 倍数）
input int    InpUpdateSec = 10;         // ATR 刷新间隔（秒）
input int    InpMagic     = 20261120;   // 魔术号
input int    InpSlippage  = 30;         // 允许滑点（Point）

//--- 控件名（用宏，MQL4 中数组初始化只认常量表达式） ---------------
#define BTN_BUY    "bo_btn_buy"
#define BTN_SELL   "bo_btn_sell"
#define BTN_LOT_UP "bo_btn_lot_up"
#define BTN_LOT_DN "bo_btn_lot_dn"
#define BTN_TP_UP  "bo_btn_tp_up"
#define BTN_TP_DN  "bo_btn_tp_dn"
#define EDIT_LOT   "bo_edit_lot"
#define EDIT_TP    "bo_edit_tp"
#define LBL_LOT    "bo_lbl_lot"
#define LBL_TP     "bo_lbl_tp"

//--- 右下角布局参数（像素，自图表右下角起算） -----------------------
const int BTN_W         = 100;  // 下单按钮宽度
const int BTN_H         = 20;   // 按钮/输入框高度
const int SMALL_W       = 30;   // +/- 按钮宽度
const int EDIT_W        = 40;  // 输入框宽度
const int RIGHT_MARGIN  = 130;   // 距右边界
const int ROW_ORDER_Y   = 150;  // 下单按钮行
const int ROW_LOT_Y     = 90;   // 手数行
const int ROW_TP_Y      = 30;   // 止盈行
const int GAP           = 20;   // 按钮之间的水平间距

//--- 运行时状态 -----------------------------------------------------
double g_lot      = 0.01;   // 当前手数
double g_tpMult   = 1.0;    // 当前 ATR 倍数
double g_tpPoints = 0.0;    // 当前止盈点数（Point）

//+------------------------------------------------------------------+
//| 初始化                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpLots <= 0.0 || InpTPMult <= 0.0)
   {
      Print("参数错误：手数与 ATR 倍数必须大于 0");
      return(INIT_PARAMETERS_INCORRECT);
   }

   g_lot    = InpLots;
   g_tpMult = InpTPMult;

   BuildPanel();
   RecalcTP();

   if(InpUpdateSec > 0)
      EventSetTimer(InpUpdateSec);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 卸载：删除所有控件与定时器                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();

   string names[] = {BTN_BUY, BTN_SELL, BTN_LOT_UP, BTN_LOT_DN,
                     BTN_TP_UP, BTN_TP_DN, EDIT_LOT, EDIT_TP,
                     LBL_LOT, LBL_TP};
   for(int i = 0; i < ArraySize(names); i++)
      ObjectDelete(0, names[i]);

   ChartRedraw();
}

//+------------------------------------------------------------------+
//| 每 10 秒：按 ATR(50) 刷新止盈点数                                 |
//+------------------------------------------------------------------+
void OnTimer()
{
   RecalcTP();
}

//+------------------------------------------------------------------+
//| 图表事件：按钮点击 / 输入框编辑结束                               |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == BTN_BUY)         { ResetBtn(BTN_BUY);    OpenOrder(OP_BUY); }
      else if(sparam == BTN_SELL)   { ResetBtn(BTN_SELL);   OpenOrder(OP_SELL); }
      else if(sparam == BTN_LOT_UP) { ResetBtn(BTN_LOT_UP); ChangeLot(+1); }
      else if(sparam == BTN_LOT_DN) { ResetBtn(BTN_LOT_DN); ChangeLot(-1); }
      else if(sparam == BTN_TP_UP)  { ResetBtn(BTN_TP_UP);  ChangeTPMult(+1); }
      else if(sparam == BTN_TP_DN)  { ResetBtn(BTN_TP_DN);  ChangeTPMult(-1); }
      return;
   }

   if(id == CHARTEVENT_OBJECT_ENDEDIT)
   {
      if(sparam == EDIT_LOT)
      {
         g_lot = NormalizeLots(StringToDouble(ObjectGetString(0, EDIT_LOT, OBJPROP_TEXT)));
         ObjectSetString(0, EDIT_LOT, OBJPROP_TEXT, LotText());
         ChartRedraw();
      }
      else if(sparam == EDIT_TP)
      {
         // 手动输入的点数换算成等效 ATR 倍数，之后仍随 ATR 刷新
         double pts = StringToDouble(ObjectGetString(0, EDIT_TP, OBJPROP_TEXT));
         double atr = iATR(Symbol(), 0, InpATRPeriod, 0);
         if(pts > 0 && atr > 0)
         {
            g_tpMult   = pts * Point / atr;
            g_tpPoints = NormalizeDouble(pts, 1);
         }
         RecalcTP();
      }
   }
}

//+------------------------------------------------------------------+
//| 构建面板                                                          |
//+------------------------------------------------------------------+
void BuildPanel()
{
   //--- 第 1 行：下空单（左）、下多单（右）
   CreateButton(BTN_SELL, "下空单", RIGHT_MARGIN + BTN_W + GAP, ROW_ORDER_Y, BTN_W, clrWhite, clrRed);
   CreateButton(BTN_BUY,  "下多单", RIGHT_MARGIN,               ROW_ORDER_Y, BTN_W, clrWhite, clrGreen);

   //--- 第 2 行：手数  [-] [输入框] [+]
   CreateLabel (LBL_LOT, "手数", RIGHT_MARGIN +  SMALL_W + EDIT_W + 2 * GAP + 1, ROW_LOT_Y -18, clrSilver);
   CreateButton(BTN_LOT_DN, "-", RIGHT_MARGIN + SMALL_W + EDIT_W + GAP, ROW_LOT_Y, SMALL_W, clrWhite, clrDimGray);
   CreateEdit  (EDIT_LOT, LotText(), RIGHT_MARGIN + SMALL_W + GAP, ROW_LOT_Y, EDIT_W, clrBlack, clrWhite);
   CreateButton(BTN_LOT_UP, "+", RIGHT_MARGIN, ROW_LOT_Y, SMALL_W, clrWhite, clrDimGray);

   //--- 第 3 行：止盈  [-] [输入框] [+]
   CreateLabel (LBL_TP, TPText(), RIGHT_MARGIN +  SMALL_W + EDIT_W + 2 * GAP + 1, ROW_TP_Y-18 , clrSilver);
   CreateButton(BTN_TP_DN, "-", RIGHT_MARGIN + SMALL_W + EDIT_W + GAP, ROW_TP_Y, SMALL_W, clrWhite, clrDimGray);
   CreateEdit  (EDIT_TP, "0.0", RIGHT_MARGIN + SMALL_W + GAP, ROW_TP_Y, EDIT_W, clrBlack, clrWhite);
   CreateButton(BTN_TP_UP, "+", RIGHT_MARGIN, ROW_TP_Y, SMALL_W, clrWhite, clrDimGray);
}

//+------------------------------------------------------------------+
//| 按 ATR(50) 重算止盈点数并刷新界面                                 |
//+------------------------------------------------------------------+
void RecalcTP()
{
   double atr = iATR(Symbol(), 0, InpATRPeriod, 0);
   if(atr <= 0.0)
      return;

   g_tpPoints = NormalizeDouble(atr / Point * g_tpMult, 1);

   ObjectSetString(0, EDIT_TP, OBJPROP_TEXT, DoubleToString(g_tpPoints, 1));
   ObjectSetString(0, LBL_TP,  OBJPROP_TEXT, TPText());
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| 手数 +/-（步长取平台 LOTSTEP）                                    |
//+------------------------------------------------------------------+
void ChangeLot(const int dir)
{
   double step = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(step <= 0.0) step = 0.01;

   g_lot = NormalizeLots(g_lot + dir * step);
   ObjectSetString(0, EDIT_LOT, OBJPROP_TEXT, LotText());
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| ATR 倍数 +/-（步长 0.1，范围 0.1 ~ 10）                           |
//+------------------------------------------------------------------+
void ChangeTPMult(const int dir)
{
   g_tpMult += dir * 0.1;
   if(g_tpMult < 0.1) g_tpMult = 0.1;
   if(g_tpMult > 10.0) g_tpMult = 10.0;

   RecalcTP();
}

//+------------------------------------------------------------------+
//| 按钮弹起，避免保持按下状态                                        |
//+------------------------------------------------------------------+
void ResetBtn(const string name)
{
   ObjectSetInteger(0, name, OBJPROP_STATE, false);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| 文案                                                              |
//+------------------------------------------------------------------+
string LotText()
{
   return DoubleToString(g_lot, 2);
}

string TPText()
{
   return "ATR(" + IntegerToString(InpATRPeriod) + ")×" + DoubleToString(g_tpMult, 1);
}

//+------------------------------------------------------------------+
//| 按方向下单：手数取输入框，止盈取 ATR 算出的点数                   |
//+------------------------------------------------------------------+
void OpenOrder(const int type)
{
   if(!IsTradeAllowed())
   {
      Print("下单失败：未允许交易（请检查“允许实时自动交易”和终端 AutoTrading 按钮）");
      return;
   }
   if(g_tpPoints <= 0.0)
   {
      Print("下单失败：止盈点数为 0，请等待 ATR 刷新或增大 ATR 倍数");
      return;
   }

   RefreshRates();

   double lots  = NormalizeLots(g_lot);
   double price = (type == OP_BUY) ? Ask : Bid;
   double tp    = (type == OP_BUY) ? price + g_tpPoints * Point
                                   : price - g_tpPoints * Point;
   tp = NormalizeDouble(tp, Digits);

   //--- 校验止盈距离是否满足平台最小止损距离
   double minStop = MarketInfo(Symbol(), MODE_STOPLEVEL) * Point;
   if(MathAbs(tp - price) < minStop)
   {
      Print("下单失败：止盈距离 ", DoubleToString(g_tpPoints, 1),
            " 点小于平台最小止损距离 ", DoubleToString(minStop / Point, 1), " 点");
      return;
   }

   color  arrow = (type == OP_BUY) ? clrBlue : clrRed;
   string cmt   = (type == OP_BUY) ? "按钮下多单" : "按钮下空单";

   int ticket = OrderSend(Symbol(), type, lots, price, InpSlippage, 0, tp, cmt, InpMagic, 0, arrow);
   if(ticket < 0)
      Print("下单失败，错误码：", GetLastError());
   else
      Print(cmt, " 成功，手数=", DoubleToString(lots, 2),
            " 开仓价=", DoubleToString(price, Digits),
            " 止盈=", DoubleToString(tp, Digits),
            " 订单号=", ticket);
}

//+------------------------------------------------------------------+
//| 手数按平台最小/最大/步长做规范化                                  |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);
   if(lotStep <= 0.0) lotStep = 0.01;

   lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| 创建控件                                                          |
//+------------------------------------------------------------------+
void CreateButton(const string name, const string text, const int x, const int y,
                  const int w, const color clrText, const color clrBg)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_BUTTON, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_RIGHT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,        BTN_H);
   ObjectSetString (0, name, OBJPROP_TEXT,         text);
   ObjectSetString (0, name, OBJPROP_FONT,         "Microsoft YaHei");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,     10);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        clrText);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      clrBg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(0, name, OBJPROP_STATE,        false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,       true);
}

void CreateEdit(const string name, const string text, const int x, const int y,
                const int w, const color clrText, const color clrBg)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,       CORNER_RIGHT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,    x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,    y);
   ObjectSetInteger(0, name, OBJPROP_XSIZE,        w);
   ObjectSetInteger(0, name, OBJPROP_YSIZE,        BTN_H);
   ObjectSetString (0, name, OBJPROP_TEXT,         text);
   ObjectSetString (0, name, OBJPROP_FONT,         "Microsoft YaHei");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,     10);
   ObjectSetInteger(0, name, OBJPROP_COLOR,        clrText);
   ObjectSetInteger(0, name, OBJPROP_BGCOLOR,      clrBg);
   ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrBlack);
   ObjectSetInteger(0, name, OBJPROP_ALIGN,        ALIGN_CENTER);
   ObjectSetInteger(0, name, OBJPROP_READONLY,     false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,   true); // 允许鼠标点入输入
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,       true);
}

void CreateLabel(const string name, const string text, const int x, const int y, const color clrText)
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);

   ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_RIGHT_LOWER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,     ANCHOR_RIGHT_LOWER);
   ObjectSetString (0, name, OBJPROP_TEXT,       text);
   ObjectSetString (0, name, OBJPROP_FONT,       "Microsoft YaHei");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   9);
   ObjectSetInteger(0, name, OBJPROP_COLOR,      clrText);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
}
//+------------------------------------------------------------------+

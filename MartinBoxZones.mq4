//+------------------------------------------------------------------+
//|                                          MartinBoxZones.mq4      |
//|  箱体 / 阈值可视化指标                                            |
//|  与 MartinStr_FixedSL_v1.00.004.mq4 的箱体逻辑保持一致             |
//+------------------------------------------------------------------+
#property strict
#property indicator_chart_window

// ---- 输入参数（对应 EA 的参数）----
input int    BoxLookbackBars      = 600;   // 箱体回看K线数（对应 EntryLookbackBars）
input double BoxEdgePercent       = 0.20;  // 顶/底边缘区比例（对应 BoxEdgePercent）
input double BoxExtremePercentile = 0.05;  // 箱体高低点分位（对应 BoxExtremePercentile，0.05=5%/95%）
input bool   ShowZones            = true;  // 是否显示顶/底阈值线
input bool   ShowPricePos         = true;  // 是否在左上角显示当前价格在箱体中的位置

// ---- 颜色 ----
input color  BoxHighColor    = clrDodgerBlue;  // 箱体顶
input color  BoxLowColor     = clrOrangeRed;   // 箱体底
input color  TopZoneColor    = clrGray;        // 顶部阈值
input color  BottomZoneColor = clrGray;        // 底部阈值

string Prefix = "MBZ_";

//+------------------------------------------------------------------+
int OnInit()
{
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, Prefix);
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // 每根新K线重新计算一次箱体；价格位置文本每个tick刷新
   static datetime lastBarTime = 0;

   if(rates_total < BoxLookbackBars + 2)
   {
      ShowRightText("K线数量不足，无法计算箱体。Bars=" + IntegerToString(rates_total) +
                    " 需要至少=" + IntegerToString(BoxLookbackBars + 2));
      return(rates_total);
   }

   bool isNewBar = (time[0] != lastBarTime);
   if(isNewBar)
   {
      lastBarTime = time[0];
      DrawBoxZones();
   }

   if(ShowPricePos)
      DrawPricePosition();
   else
      ObjectDelete(0, Prefix + "Info");

   return(rates_total);
}

//+------------------------------------------------------------------+
//| 计算箱体高低点（与 EA 的 GetBoxRange 一致：分位数法）             |
//+------------------------------------------------------------------+
bool CalcBox(double &boxHigh, double &boxLow)
{
   boxHigh = 0.0;
   boxLow  = 0.0;

   int count = BoxLookbackBars;
   if(count < 10)
      count = 10;

   if(Bars < count + 2)
      return(false);

   double pct = BoxExtremePercentile;
   if(pct < 0.0)  pct = 0.0;
   if(pct > 0.25) pct = 0.25;   // 与EA一致：分位最高限制25%

   double highArr[];
   double lowArr[];
   ArrayResize(highArr, count);
   ArrayResize(lowArr,  count);

   // 与EA一致：从 K[2] 开始，排除信号K[1]与未完成K[0]
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

   return(boxHigh > boxLow);
}

//+------------------------------------------------------------------+
//| 画箱体和阈值水平线                                               |
//+------------------------------------------------------------------+
void DrawBoxZones()
{
   double boxHigh = 0.0, boxLow = 0.0;
   if(!CalcBox(boxHigh, boxLow))
      return;

   double range = boxHigh - boxLow;

   double edgePercent = BoxEdgePercent;
   if(edgePercent <= 0.0 || edgePercent >= 0.5)
      edgePercent = 0.20;

   double topZone    = boxHigh - range * edgePercent;
   double bottomZone = boxLow  + range * edgePercent;

   DrawHLine(Prefix + "BoxHigh", boxHigh, BoxHighColor, "箱体顶", STYLE_SOLID, 2);
   DrawHLine(Prefix + "BoxLow",  boxLow,  BoxLowColor,  "箱体底", STYLE_SOLID, 2);

   if(ShowZones)
   {
      DrawHLine(Prefix + "TopZone",    topZone,    TopZoneColor,    "顶部阈值", STYLE_DASH, 1);
      DrawHLine(Prefix + "BottomZone", bottomZone, BottomZoneColor, "底部阈值", STYLE_DASH, 1);
   }
}

//+------------------------------------------------------------------+
void DrawHLine(string name, double price, color clr, string label, int style, int width)
{
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
         return;

      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, style);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
      ObjectSetInteger(0, name, OBJPROP_BACK,  true);
   }
   else
   {
      ObjectSetDouble(0, name, OBJPROP_PRICE1, price);
   }

   ObjectSetString(0, name, OBJPROP_TEXT, label + " " + DoubleToString(price, Digits));
}

//+------------------------------------------------------------------+
//| 在屏幕右侧显示文本（多标签分行，规避 OBJ_LABEL 63字符限制）       |
//+------------------------------------------------------------------+
void ShowRightText(string text)
{
   // 删除旧的 Info 标签，避免残留
   ObjectsDeleteAll(0, Prefix + "Info");

   string lines[];
   int lineCount = SplitLines(text, lines);

   int yDist = 25;
   int labelIndex = 0;

   for(int i = 0; i < lineCount; i++)
   {
      string line = lines[i];
      int len = StringLen(line);
      int start = 0;

      // 每行再按63字符拆，确保单个标签不超过63字符
      while(start < len)
      {
         int chunkLen = (int)MathMin(63, len - start);
         string chunk = StringSubstr(line, start, chunkLen);

         CreateInfoLabel(Prefix + "Info" + IntegerToString(labelIndex), chunk, yDist);
         labelIndex++;
         yDist += 25;
         start += chunkLen;
      }
   }
}

//+------------------------------------------------------------------+
//| 按 "\n" 拆分字符串                                                |
//+------------------------------------------------------------------+
int SplitLines(string text, string &lines[])
{
   ArrayResize(lines, 0);
   int count = 0;
   int len = StringLen(text);
   int start = 0;

   while(start < len)
   {
      int pos = StringFind(text, "\n", start);
      string line;

      if(pos < 0)
      {
         line = StringSubstr(text, start);
         start = len;
      }
      else
      {
         line = StringSubstr(text, start, pos - start);
         start = pos + 1;
      }

      ArrayResize(lines, count + 1);
      lines[count] = line;
      count++;
   }

   return(count);
}

//+------------------------------------------------------------------+
//| 创建/更新一个右侧标签                                            |
//+------------------------------------------------------------------+
void CreateInfoLabel(string name, string text, int yDist)
{
   if(ObjectFind(0, name) < 0)
   {
      if(!ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0))
         return;

      ObjectSetInteger(0, name, OBJPROP_CORNER,     CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,  350);
      ObjectSetInteger(0, name, OBJPROP_COLOR,      clrWhite);
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE,   10);
      ObjectSetInteger(0, name, OBJPROP_BACK,       false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN,     true);
   }

   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, yDist);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
}

//+------------------------------------------------------------------+
//| 显示当前价格在箱体中的位置（输出到屏幕右侧）                      |
//+------------------------------------------------------------------+
void DrawPricePosition()
{
   double boxHigh = 0.0, boxLow = 0.0;
   if(!CalcBox(boxHigh, boxLow))
      return;

   double range = boxHigh - boxLow;

   double edgePercent = BoxEdgePercent;
   if(edgePercent <= 0.0 || edgePercent >= 0.5)
      edgePercent = 0.20;

   double topZone    = boxHigh - range * edgePercent;
   double bottomZone = boxLow  + range * edgePercent;

   string posText = "价格 " + DoubleToString(Close[0], Digits);
   if(range > 0.0)
   {
      double pct = (Close[0] - boxLow) / range * 100.0;
      posText = posText + " | 箱体位置 " + DoubleToString(pct, 1) + "%";
   }

   // 关键：必须用 "\n" 分行，不能拼成一整行长文本；
   // OBJ_LABEL 单行过宽时，超出图表右侧的部分会被截断，导致后半段内容不显示。
   string info = posText + "\n" +
                 "箱体顶 " + DoubleToString(boxHigh, Digits) +
                 "｜顶部阈值 " + DoubleToString(topZone, Digits) + "\n" +
                 "底部阈值 " + DoubleToString(bottomZone, Digits) +
                 "｜箱体底 " + DoubleToString(boxLow, Digits);

   ShowRightText(info);
}
//+------------------------------------------------------------------+

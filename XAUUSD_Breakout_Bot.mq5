//+------------------------------------------------------------------+
//| XAUUSD_Breakout_Bot.mq5                                          |
//| XAUUSD Intraday Breakout EA                                      |
//| Converts Python reference strategy to production MQL5             |
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\OrderInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

// -- General --
input string   InpSymbol               = "XAUUSD";        // Symbol to trade
input ENUM_TIMEFRAMES InpEntryTF        = PERIOD_M5;       // Entry timeframe
input ENUM_TIMEFRAMES InpTrendTF        = PERIOD_M15;      // Trend timeframe
input int      InpMagicNumber           = 202603;          // Magic number

// -- Risk --
input double   InpRiskPercent           = 0.5;             // Risk % per trade
input int      InpMaxTradesPerDay       = 3;               // Max trades per day
input double   InpMaxDailyLossPercent   = 2.0;             // Max daily loss % (stop trading)
input double   InpMaxDailyGainPercent   = 3.0;             // Max daily gain % (stop trading)
input double   InpMinLot               = 0.01;             // Minimum lot size
input double   InpMaxLot               = 100.0;            // Maximum lot size

// -- Breakout --
input int      InpBreakoutLookback      = 24;              // Breakout lookback bars (M5)
input double   InpMinBodyRatio          = 0.60;            // Min candle body ratio for breakout

// -- ATR --
input int      InpATRPeriod            = 14;               // ATR period
input double   InpATR_SL_Mult          = 1.5;              // ATR multiplier for SL
input double   InpATR_TP_Mult          = 2.5;              // ATR multiplier for TP
input double   InpMinATR               = 2.0;              // Minimum ATR value
input double   InpMaxATR               = 50.0;             // Maximum ATR value

// -- EMA Trend --
input int      InpEMAFast              = 20;               // Fast EMA period (trend TF)
input int      InpEMASlow              = 50;               // Slow EMA period (trend TF)

// -- RSI Momentum --
input int      InpRSIPeriod            = 14;               // RSI period (entry TF)
input double   InpLongRSIMin           = 55.0;             // Min RSI for BUY
input double   InpShortRSIMax          = 45.0;             // Max RSI for SELL

// -- Position Management --
input double   InpBreakevenAtR         = 1.0;              // Move SL to BE at this R-multiple
input double   InpTrailAfterR          = 1.5;              // Start trailing after this R-multiple
input double   InpPartialCloseAtR      = 1.5;              // Partial close at this R-multiple
input double   InpPartialClosePercent  = 50.0;             // Partial close percentage

// -- Session --
input int      InpSessionStartHour     = 7;                // Session start hour (server time)
input int      InpSessionEndHour       = 17;               // Session end hour (server time)
input int      InpRolloverBlockStart   = 22;               // Rollover block start hour
input int      InpRolloverBlockEnd     = 23;               // Rollover block end hour

// -- Filters --
input int      InpMaxSpreadPoints      = 50;               // Max spread in points
input int      InpCooldownBars         = 3;                // Cooldown bars after trade
input int      InpMaxConsecLosses      = 2;                // Max consecutive losses before pause
input bool     InpUseVolumeFilter      = true;             // Use volume filter
input int      InpVolumeLookback       = 20;               // Volume average lookback
input double   InpVolumeMultiplier     = 1.20;             // Volume must be >= avg * this
input bool     InpUseCompressionFilter = true;             // Use compression filter
input double   InpCompressionATRMult   = 3.0;              // Compression: range < ATR * this
input bool     InpOneTradePerLevel     = true;             // One trade per breakout level
input int      InpMaxSlippagePoints    = 20;               // Max allowed slippage points

// -- Multi-position --
input int      InpMaxConcurrentPos     = 3;                // Max concurrent open positions
input bool     InpAllowMultiplePos     = true;             // Allow multiple positions

// -- Alerts --
input bool     InpEnablePushAlerts     = true;             // Enable push notifications
input bool     InpEnableEmailAlerts    = false;            // Enable email alerts
input bool     InpEnablePopupAlerts    = true;             // Enable popup alerts on chart
input bool     InpEnableTelegram       = true;             // Enable Telegram alerts
input string   InpTelegramBotToken    = "";                // Telegram Bot Token
input string   InpTelegramChatID      = "";                // Telegram Chat ID

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+

CTrade         g_trade;
CSymbolInfo    g_symbolInfo;
CAccountInfo   g_accountInfo;
CPositionInfo  g_posInfo;

// Daily tracking
datetime       g_lastDayReset       = 0;
double         g_dailyStartBalance  = 0;
int            g_tradesToday        = 0;
int            g_consecLosses       = 0;
datetime       g_lastTradeCloseTime = 0;

// Breakout level tracking
double         g_lastLongBreakoutLevel  = 0;
double         g_lastShortBreakoutLevel = 0;

// Bar tracking
datetime       g_lastBarTime = 0;

// Indicator handles
int            g_hATR_Entry    = INVALID_HANDLE;
int            g_hRSI_Entry    = INVALID_HANDLE;
int            g_hEMAFast_Trend = INVALID_HANDLE;
int            g_hEMASlow_Trend = INVALID_HANDLE;

// Partial close tracking (keyed by position ticket)
struct PartialCloseInfo
{
   ulong    ticket;
   bool     partialClosed;
   bool     movedToBE;
   double   initialRisk;     // |entry - original SL|
   double   entryPrice;
};

PartialCloseInfo g_posTrack[];

//+------------------------------------------------------------------+
//| Send alert via all enabled channels                               |
//+------------------------------------------------------------------+
void SendTelegram(string message)
{
   if(!InpEnableTelegram) return;
   if(InpTelegramBotToken == "" || InpTelegramChatID == "") return;

   string url = "https://api.telegram.org/bot" + InpTelegramBotToken +
                "/sendMessage?chat_id=" + InpTelegramChatID +
                "&text=" + message;

   char   post[];
   char   result[];
   string headers = "";
   int    timeout = 5000;

   ResetLastError();
   int res = WebRequest("GET", url, headers, timeout, post, result, headers);
   if(res == -1)
   {
      int err = GetLastError();
      if(err == 4014)
         Print("Telegram: Add https://api.telegram.org to Tools > Options > Expert Advisors > Allow WebRequest for listed URL");
      else
         Print("Telegram send failed. Error: ", err);
   }
}

void SendAlert(string message)
{
   Print(message);

   if(InpEnablePopupAlerts)
      Alert(message);

   if(InpEnablePushAlerts)
      SendNotification(message);

   if(InpEnableEmailAlerts)
      SendMail("XAUUSD Breakout Bot", message);

   SendTelegram(message);
}

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   // Setup trade object
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpMaxSlippagePoints);
   g_trade.SetTypeFilling(ORDER_FILLING_IOC);

   // Initialize symbol info
   if(!g_symbolInfo.Name(InpSymbol))
   {
      Print("ERROR: Symbol ", InpSymbol, " not found");
      return INIT_FAILED;
   }
   g_symbolInfo.Refresh();

   // Create indicator handles
   g_hATR_Entry     = iATR(InpSymbol, InpEntryTF, InpATRPeriod);
   g_hRSI_Entry     = iRSI(InpSymbol, InpEntryTF, InpRSIPeriod, PRICE_CLOSE);
   g_hEMAFast_Trend = iMA(InpSymbol, InpTrendTF, InpEMAFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEMASlow_Trend = iMA(InpSymbol, InpTrendTF, InpEMASlow, 0, MODE_EMA, PRICE_CLOSE);

   if(g_hATR_Entry == INVALID_HANDLE || g_hRSI_Entry == INVALID_HANDLE ||
      g_hEMAFast_Trend == INVALID_HANDLE || g_hEMASlow_Trend == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   // Initialize daily tracking
   g_dailyStartBalance = g_accountInfo.Balance();
   g_lastDayReset = iTime(InpSymbol, PERIOD_D1, 0);

   Print("XAUUSD Breakout Bot initialized. Balance: ", g_accountInfo.Balance());

   // Send startup notification
   SendAlert("XAUUSD Breakout Bot started | Balance: $" +
             DoubleToString(g_accountInfo.Balance(), 2) +
             " | AutoTrading: ON");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hATR_Entry != INVALID_HANDLE)     IndicatorRelease(g_hATR_Entry);
   if(g_hRSI_Entry != INVALID_HANDLE)     IndicatorRelease(g_hRSI_Entry);
   if(g_hEMAFast_Trend != INVALID_HANDLE) IndicatorRelease(g_hEMAFast_Trend);
   if(g_hEMASlow_Trend != INVALID_HANDLE) IndicatorRelease(g_hEMASlow_Trend);
   Print("XAUUSD Breakout Bot removed.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   g_symbolInfo.Refresh();

   // Check for new bar on entry timeframe
   datetime currentBarTime = iTime(InpSymbol, InpEntryTF, 0);
   if(currentBarTime == 0) return;

   // Manage existing positions every tick
   ManageOpenPositions();

   // Only check for new entries on new bars
   if(currentBarTime == g_lastBarTime) return;
   g_lastBarTime = currentBarTime;

   // Reset daily stats if new day
   ResetDailyIfNeeded();

   // Pre-entry checks
   if(!PreEntryChecks()) return;

   // Check for entry signal
   CheckAndEnter();
}

//+------------------------------------------------------------------+
//| Reset daily tracking on new day                                   |
//+------------------------------------------------------------------+
void ResetDailyIfNeeded()
{
   datetime todayStart = iTime(InpSymbol, PERIOD_D1, 0);
   if(todayStart != g_lastDayReset && todayStart != 0)
   {
      g_lastDayReset       = todayStart;
      g_dailyStartBalance  = g_accountInfo.Balance();
      g_tradesToday        = 0;
      g_consecLosses       = 0;
      g_lastLongBreakoutLevel  = 0;
      g_lastShortBreakoutLevel = 0;
      Print("New day reset. Starting balance: ", g_dailyStartBalance);
   }
}

//+------------------------------------------------------------------+
//| Count our open positions                                          |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(g_posInfo.SelectByIndex(i))
      {
         if(g_posInfo.Magic() == InpMagicNumber && g_posInfo.Symbol() == InpSymbol)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Pre-entry validation checks                                       |
//+------------------------------------------------------------------+
bool PreEntryChecks()
{
   // Max trades per day
   if(g_tradesToday >= InpMaxTradesPerDay)
      return false;

   // Max concurrent positions
   int openCount = CountOpenPositions();
   if(!InpAllowMultiplePos && openCount > 0)
      return false;
   if(openCount >= InpMaxConcurrentPos)
      return false;

   // Daily loss guard
   double currentBalance = g_accountInfo.Balance();
   double dailyPnL = currentBalance - g_dailyStartBalance;
   if(g_dailyStartBalance > 0)
   {
      double lossPercent = (-dailyPnL / g_dailyStartBalance) * 100.0;
      if(lossPercent >= InpMaxDailyLossPercent && dailyPnL < 0)
         return false;

      double gainPercent = (dailyPnL / g_dailyStartBalance) * 100.0;
      if(gainPercent >= InpMaxDailyGainPercent && dailyPnL > 0)
         return false;
   }

   // Consecutive losses
   if(g_consecLosses >= InpMaxConsecLosses)
      return false;

   // Cooldown after last trade
   if(g_lastTradeCloseTime > 0)
   {
      int cooldownSeconds = InpCooldownBars * PeriodSeconds(InpEntryTF);
      if((int)(TimeCurrent() - g_lastTradeCloseTime) < cooldownSeconds)
         return false;
   }

   // Session filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour >= InpRolloverBlockStart && dt.hour <= InpRolloverBlockEnd)
      return false;
   if(dt.hour < InpSessionStartHour || dt.hour > InpSessionEndHour)
      return false;

   // Spread filter
   double spreadPoints = g_symbolInfo.Spread();
   if(spreadPoints > InpMaxSpreadPoints)
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| Check for entry signal and place order                            |
//+------------------------------------------------------------------+
void CheckAndEnter()
{
   // Get ATR value
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(g_hATR_Entry, 0, 1, 1, atrBuffer) <= 0) return;
   double atrValue = atrBuffer[0];

   // ATR filter
   if(atrValue < InpMinATR || atrValue > InpMaxATR)
      return;

   // Get RSI value
   double rsiBuffer[];
   ArraySetAsSeries(rsiBuffer, true);
   if(CopyBuffer(g_hRSI_Entry, 0, 1, 1, rsiBuffer) <= 0) return;
   double rsiValue = rsiBuffer[0];

   // Get EMA values for trend
   double emaFastBuf[], emaSlowBuf[];
   ArraySetAsSeries(emaFastBuf, true);
   ArraySetAsSeries(emaSlowBuf, true);
   if(CopyBuffer(g_hEMAFast_Trend, 0, 1, 1, emaFastBuf) <= 0) return;
   if(CopyBuffer(g_hEMASlow_Trend, 0, 1, 1, emaSlowBuf) <= 0) return;
   double emaFast = emaFastBuf[0];
   double emaSlow = emaSlowBuf[0];

   // Get entry candles for breakout levels
   MqlRates entryRates[];
   ArraySetAsSeries(entryRates, true);
   int needed = InpBreakoutLookback + 2;
   if(CopyRates(InpSymbol, InpEntryTF, 0, needed, entryRates) < needed)
      return;

   // Calculate breakout high/low from completed bars (index 1 to lookback)
   double breakoutHigh = -DBL_MAX;
   double breakoutLow  = DBL_MAX;
   for(int i = 1; i <= InpBreakoutLookback; i++)
   {
      if(entryRates[i].high > breakoutHigh) breakoutHigh = entryRates[i].high;
      if(entryRates[i].low  < breakoutLow)  breakoutLow  = entryRates[i].low;
   }

   // Last completed candle (index 1)
   double lastClose = entryRates[1].close;
   double lastOpen  = entryRates[1].open;
   double lastHigh  = entryRates[1].high;
   double lastLow   = entryRates[1].low;

   // Strong breakout candle check
   double candleRange = lastHigh - lastLow;
   double candleBody  = MathAbs(lastClose - lastOpen);
   bool strongCandle = (candleRange > 0 && (candleBody / candleRange) >= InpMinBodyRatio);

   // Volume filter
   if(InpUseVolumeFilter && !VolumeFilterOK(entryRates, needed))
      return;

   // Compression filter
   if(InpUseCompressionFilter && !CompressionFilterOK(entryRates, atrValue))
      return;

   // Determine trend
   bool trendUp   = (emaFast > emaSlow);
   bool trendDown = (emaFast < emaSlow);

   // --- BUY SIGNAL ---
   if(trendUp && rsiValue > InpLongRSIMin && lastClose > breakoutHigh && strongCandle)
   {
      // One trade per breakout level
      if(InpOneTradePerLevel && g_lastLongBreakoutLevel != 0 &&
         MathAbs(g_lastLongBreakoutLevel - breakoutHigh) < g_symbolInfo.Point())
         return;

      double entryPrice = g_symbolInfo.Ask();
      double sl = entryPrice - (atrValue * InpATR_SL_Mult);
      double tp = entryPrice + (atrValue * InpATR_TP_Mult);
      double stopDistPoints = (entryPrice - sl) / g_symbolInfo.Point();
      double lots = CalculateLotSize(stopDistPoints);

      if(lots > 0)
      {
         // Normalize prices
         sl = NormalizeDouble(sl, g_symbolInfo.Digits());
         tp = NormalizeDouble(tp, g_symbolInfo.Digits());

         if(g_trade.Buy(lots, InpSymbol, entryPrice, sl, tp, "XAU Breakout BUY"))
         {
            g_tradesToday++;
            g_lastLongBreakoutLevel = breakoutHigh;
            TrackNewPosition(g_trade.ResultOrder(), entryPrice, MathAbs(entryPrice - sl));
            SendAlert("BUY opened | " + InpSymbol + " | Lots: " + DoubleToString(lots, 2) +
                       " | Entry: " + DoubleToString(entryPrice, 2) +
                       " | SL: " + DoubleToString(sl, 2) +
                       " | TP: " + DoubleToString(tp, 2));
         }
         else
         {
            Print("BUY order failed. Error: ", GetLastError());
         }
      }
   }

   // --- SELL SIGNAL ---
   if(trendDown && rsiValue < InpShortRSIMax && lastClose < breakoutLow && strongCandle)
   {
      if(InpOneTradePerLevel && g_lastShortBreakoutLevel != 0 &&
         MathAbs(g_lastShortBreakoutLevel - breakoutLow) < g_symbolInfo.Point())
         return;

      double entryPrice = g_symbolInfo.Bid();
      double sl = entryPrice + (atrValue * InpATR_SL_Mult);
      double tp = entryPrice - (atrValue * InpATR_TP_Mult);
      double stopDistPoints = (sl - entryPrice) / g_symbolInfo.Point();
      double lots = CalculateLotSize(stopDistPoints);

      if(lots > 0)
      {
         sl = NormalizeDouble(sl, g_symbolInfo.Digits());
         tp = NormalizeDouble(tp, g_symbolInfo.Digits());

         if(g_trade.Sell(lots, InpSymbol, entryPrice, sl, tp, "XAU Breakout SELL"))
         {
            g_tradesToday++;
            g_lastShortBreakoutLevel = breakoutLow;
            TrackNewPosition(g_trade.ResultOrder(), entryPrice, MathAbs(sl - entryPrice));
            SendAlert("SELL opened | " + InpSymbol + " | Lots: " + DoubleToString(lots, 2) +
                       " | Entry: " + DoubleToString(entryPrice, 2) +
                       " | SL: " + DoubleToString(sl, 2) +
                       " | TP: " + DoubleToString(tp, 2));
         }
         else
         {
            Print("SELL order failed. Error: ", GetLastError());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Volume filter                                                     |
//+------------------------------------------------------------------+
bool VolumeFilterOK(const MqlRates &rates[], int count)
{
   if(count < InpVolumeLookback + 2)
      return true;

   long lastVolume = rates[1].tick_volume;
   double avgVolume = 0;
   for(int i = 2; i < InpVolumeLookback + 2 && i < count; i++)
      avgVolume += (double)rates[i].tick_volume;
   avgVolume /= InpVolumeLookback;

   return (lastVolume >= avgVolume * InpVolumeMultiplier);
}

//+------------------------------------------------------------------+
//| Compression filter                                                |
//+------------------------------------------------------------------+
bool CompressionFilterOK(const MqlRates &rates[], double atrValue)
{
   double rangeHigh = -DBL_MAX;
   double rangeLow  = DBL_MAX;
   for(int i = 1; i <= InpBreakoutLookback && i < ArraySize(rates); i++)
   {
      if(rates[i].high > rangeHigh) rangeHigh = rates[i].high;
      if(rates[i].low  < rangeLow)  rangeLow  = rates[i].low;
   }
   double rangeSize = rangeHigh - rangeLow;
   return (rangeSize < InpCompressionATRMult * atrValue);
}

//+------------------------------------------------------------------+
//| Calculate position size based on risk                             |
//+------------------------------------------------------------------+
double CalculateLotSize(double stopDistPoints)
{
   if(stopDistPoints <= 0) return 0;

   double balance    = g_accountInfo.Balance();
   double riskAmount = balance * (InpRiskPercent / 100.0);

   // Get tick value for proper calculation
   double tickValue = g_symbolInfo.TickValue();
   double tickSize  = g_symbolInfo.TickSize();
   double point     = g_symbolInfo.Point();

   if(tickValue <= 0 || tickSize <= 0 || point <= 0) return 0;

   // Convert stop distance in points to monetary value per lot
   double stopMoneyPerLot = stopDistPoints * point * (tickValue / tickSize);
   if(stopMoneyPerLot <= 0) return 0;

   double lots = riskAmount / stopMoneyPerLot;

   // Round down to lot step
   double lotStep = g_symbolInfo.LotsStep();
   if(lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;

   // Clamp to broker limits
   double minLot = MathMax(InpMinLot, g_symbolInfo.LotsMin());
   double maxLot = MathMin(InpMaxLot, g_symbolInfo.LotsMax());

   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;

   // Final check: can we afford this lot size?
   // For very small accounts, use minimum lot if risk allows
   double marginRequired = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, InpSymbol, lots, g_symbolInfo.Ask(), marginRequired))
      return 0;

   if(marginRequired > g_accountInfo.FreeMargin())
   {
      // Try minimum lot
      lots = minLot;
      if(!OrderCalcMargin(ORDER_TYPE_BUY, InpSymbol, lots, g_symbolInfo.Ask(), marginRequired))
         return 0;
      if(marginRequired > g_accountInfo.FreeMargin())
         return 0;
   }

   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//| Track new position for management                                 |
//+------------------------------------------------------------------+
void TrackNewPosition(ulong ticket, double entryPrice, double initialRisk)
{
   int size = ArraySize(g_posTrack);
   ArrayResize(g_posTrack, size + 1);
   g_posTrack[size].ticket        = ticket;
   g_posTrack[size].partialClosed = false;
   g_posTrack[size].movedToBE     = false;
   g_posTrack[size].initialRisk   = initialRisk;
   g_posTrack[size].entryPrice    = entryPrice;
}

//+------------------------------------------------------------------+
//| Find tracking info for a position                                 |
//+------------------------------------------------------------------+
int FindTrackIndex(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_posTrack); i++)
   {
      if(g_posTrack[i].ticket == ticket)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Remove tracking info for closed position                          |
//+------------------------------------------------------------------+
void RemoveTrack(int index)
{
   int last = ArraySize(g_posTrack) - 1;
   if(index < last)
      g_posTrack[index] = g_posTrack[last];
   ArrayResize(g_posTrack, last);
}

//+------------------------------------------------------------------+
//| Manage all open positions (BE, partial close, trailing)           |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!g_posInfo.SelectByIndex(i)) continue;
      if(g_posInfo.Magic() != InpMagicNumber) continue;
      if(g_posInfo.Symbol() != InpSymbol) continue;

      ulong ticket = g_posInfo.Ticket();
      int trackIdx = FindTrackIndex(ticket);

      // If we don't have tracking info, create it from position data
      if(trackIdx < 0)
      {
         double entry = g_posInfo.PriceOpen();
         double sl    = g_posInfo.StopLoss();
         double risk  = MathAbs(entry - sl);
         if(risk <= 0) risk = 1.0; // fallback
         TrackNewPosition(ticket, entry, risk);
         trackIdx = ArraySize(g_posTrack) - 1;
      }

      double entryPrice   = g_posTrack[trackIdx].entryPrice;
      double initialRisk  = g_posTrack[trackIdx].initialRisk;
      bool   partialDone  = g_posTrack[trackIdx].partialClosed;
      bool   beDone       = g_posTrack[trackIdx].movedToBE;

      if(initialRisk <= 0) continue;

      ENUM_POSITION_TYPE posType = g_posInfo.PositionType();
      double currentSL = g_posInfo.StopLoss();
      double currentTP = g_posInfo.TakeProfit();
      double lots      = g_posInfo.Volume();

      // Current market price for this position
      double marketPrice;
      if(posType == POSITION_TYPE_BUY)
         marketPrice = g_symbolInfo.Bid();
      else
         marketPrice = g_symbolInfo.Ask();

      // Calculate R-multiple
      double profitPerUnit;
      if(posType == POSITION_TYPE_BUY)
         profitPerUnit = marketPrice - entryPrice;
      else
         profitPerUnit = entryPrice - marketPrice;

      double rMultiple = profitPerUnit / initialRisk;

      // 1. Move to breakeven
      if(!beDone && rMultiple >= InpBreakevenAtR)
      {
         double newSL = NormalizeDouble(entryPrice, g_symbolInfo.Digits());
         bool shouldMove = false;

         if(posType == POSITION_TYPE_BUY && newSL > currentSL)
            shouldMove = true;
         else if(posType == POSITION_TYPE_SELL && (currentSL == 0 || newSL < currentSL))
            shouldMove = true;

         if(shouldMove)
         {
            if(g_trade.PositionModify(ticket, newSL, currentTP))
            {
               g_posTrack[trackIdx].movedToBE = true;
               SendAlert("SL moved to breakeven | " + InpSymbol + " | Ticket: " + IntegerToString(ticket) +
                          " | BE: " + DoubleToString(entryPrice, 2));
            }
         }
         else
         {
            g_posTrack[trackIdx].movedToBE = true;
         }
      }

      // 2. Partial close
      if(!partialDone && rMultiple >= InpPartialCloseAtR)
      {
         double closeLots = NormalizeDouble(lots * (InpPartialClosePercent / 100.0), 2);
         double lotStep = g_symbolInfo.LotsStep();
         if(lotStep > 0)
            closeLots = MathFloor(closeLots / lotStep) * lotStep;

         double minLot = MathMax(InpMinLot, g_symbolInfo.LotsMin());
         if(closeLots >= minLot && (lots - closeLots) >= minLot)
         {
            if(g_trade.PositionClosePartial(ticket, closeLots))
            {
               g_posTrack[trackIdx].partialClosed = true;
               SendAlert("Partial close | " + InpSymbol + " | Closed " + DoubleToString(closeLots, 2) +
                          " lots | Remaining: " + DoubleToString(lots - closeLots, 2) + " lots");
            }
         }
         else
         {
            g_posTrack[trackIdx].partialClosed = true;
         }
      }

      // 3. Trailing stop
      if(rMultiple >= InpTrailAfterR)
      {
         // Get ATR for trailing
         double atrBuf[];
         ArraySetAsSeries(atrBuf, true);
         if(CopyBuffer(g_hATR_Entry, 0, 1, 1, atrBuf) > 0)
         {
            double atrVal = atrBuf[0];

            // Get recent swing for trailing
            MqlRates rates[];
            ArraySetAsSeries(rates, true);
            if(CopyRates(InpSymbol, InpEntryTF, 0, 7, rates) >= 6)
            {
               double newSL = 0;
               if(posType == POSITION_TYPE_BUY)
               {
                  // Trailing: swing low - 0.5*ATR
                  double swingLow = DBL_MAX;
                  for(int j = 1; j <= 5; j++)
                     if(rates[j].low < swingLow) swingLow = rates[j].low;
                  newSL = NormalizeDouble(swingLow - (0.5 * atrVal), g_symbolInfo.Digits());

                  // Refresh current SL (may have changed from BE move)
                  if(g_posInfo.SelectByTicket(ticket))
                     currentSL = g_posInfo.StopLoss();

                  if(newSL > currentSL && newSL < marketPrice)
                  {
                     g_trade.PositionModify(ticket, newSL, currentTP);
                  }
               }
               else
               {
                  double swingHigh = -DBL_MAX;
                  for(int j = 1; j <= 5; j++)
                     if(rates[j].high > swingHigh) swingHigh = rates[j].high;
                  newSL = NormalizeDouble(swingHigh + (0.5 * atrVal), g_symbolInfo.Digits());

                  if(g_posInfo.SelectByTicket(ticket))
                     currentSL = g_posInfo.StopLoss();

                  if((currentSL == 0 || newSL < currentSL) && newSL > marketPrice)
                  {
                     g_trade.PositionModify(ticket, newSL, currentTP);
                  }
               }
            }
         }
      }
   }

   // Clean up tracking for positions that no longer exist
   CleanupClosedPositions();
}

//+------------------------------------------------------------------+
//| Get profit of a closed position from deal history                 |
//+------------------------------------------------------------------+
double GetClosedProfit(ulong posTicket)
{
   datetime from = TimeCurrent() - 86400;
   datetime to   = TimeCurrent();
   HistorySelect(from, to);

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY)
      {
         double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         double swap   = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         double comm   = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         return profit + swap + comm;
      }
   }
   return 0;
}

//+------------------------------------------------------------------+
//| Remove tracking entries for closed positions                      |
//+------------------------------------------------------------------+
void CleanupClosedPositions()
{
   for(int i = ArraySize(g_posTrack) - 1; i >= 0; i--)
   {
      bool found = false;
      for(int j = PositionsTotal() - 1; j >= 0; j--)
      {
         if(g_posInfo.SelectByIndex(j) && g_posInfo.Ticket() == g_posTrack[i].ticket)
         {
            found = true;
            break;
         }
      }

      if(!found)
      {
         // Position was closed - update tracking
         g_lastTradeCloseTime = TimeCurrent();

         // Check profit from deal history and alert
         double closedProfit = GetClosedProfit(g_posTrack[i].ticket);
         string profitStr = (closedProfit >= 0 ? "+" : "") + DoubleToString(closedProfit, 2);
         SendAlert("Trade closed | " + InpSymbol + " | P/L: $" + profitStr +
                    " | Balance: $" + DoubleToString(g_accountInfo.Balance(), 2));

         // Check if it was a loss using deal history
         UpdateConsecLosses(g_posTrack[i].ticket);

         RemoveTrack(i);
      }
   }
}

//+------------------------------------------------------------------+
//| Check last closed deal to update consecutive losses               |
//+------------------------------------------------------------------+
void UpdateConsecLosses(ulong posTicket)
{
   // Select recent deals
   datetime from = TimeCurrent() - 86400; // last 24h
   datetime to   = TimeCurrent();
   HistorySelect(from, to);

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;

      ulong dealPosId = HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      ENUM_DEAL_ENTRY dealEntry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

      if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_OUT_BY)
      {
         double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         double swap   = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         double comm   = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         double total  = profit + swap + comm;

         if(total < 0)
            g_consecLosses++;
         else
            g_consecLosses = 0;

         break; // Only need the most recent close
      }
   }
}

//+------------------------------------------------------------------+
//| OnTradeTransaction - track when positions close                   |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Nothing extra needed - CleanupClosedPositions handles it
}

//+------------------------------------------------------------------+
//| Chart comment for visual status                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Optional: display status on chart
}

//+------------------------------------------------------------------+

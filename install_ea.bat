@echo off
echo ============================================
echo   XAUUSD Breakout Bot - Auto Installer
echo ============================================
echo.

:: Find MT5 data folder
set "MT5_FOUND=0"

:: Check common MT5 terminal paths
for /d %%D in ("%APPDATA%\MetaQuotes\Terminal\*") do (
    if exist "%%D\MQL5\Experts" (
        set "MT5_DATA=%%D"
        set "MT5_FOUND=1"
    )
)

if "%MT5_FOUND%"=="0" (
    echo ERROR: Could not find MetaTrader 5 data folder.
    echo Please make sure MT5 is installed.
    pause
    exit /b 1
)

echo Found MT5 data folder: %MT5_DATA%
echo.

:: Download the EA source file
echo Downloading XAUUSD_Breakout_Bot.mq5...
powershell -Command "Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/anirudhatalmale6-alt/xauusd-breakout-bot/master/XAUUSD_Breakout_Bot.mq5' -OutFile '%MT5_DATA%\MQL5\Experts\XAUUSD_Breakout_Bot.mq5'"

if not exist "%MT5_DATA%\MQL5\Experts\XAUUSD_Breakout_Bot.mq5" (
    echo ERROR: Download failed. Check internet connection.
    pause
    exit /b 1
)

echo Download complete!
echo.

:: Try to find MetaEditor for compilation
set "EDITOR_FOUND=0"

:: Search Program Files
for /d %%D in ("C:\Program Files\*MetaTrader*") do (
    if exist "%%D\metaeditor64.exe" (
        set "METAEDITOR=%%D\metaeditor64.exe"
        set "EDITOR_FOUND=1"
    )
)

:: Search Program Files x86
if "%EDITOR_FOUND%"=="0" (
    for /d %%D in ("C:\Program Files (x86)\*MetaTrader*") do (
        if exist "%%D\metaeditor64.exe" (
            set "METAEDITOR=%%D\metaeditor64.exe"
            set "EDITOR_FOUND=1"
        )
    )
)

:: Search common broker-specific paths
if "%EDITOR_FOUND%"=="0" (
    for /d %%D in ("C:\*MetaTrader*") do (
        if exist "%%D\metaeditor64.exe" (
            set "METAEDITOR=%%D\metaeditor64.exe"
            set "EDITOR_FOUND=1"
        )
    )
)

if "%EDITOR_FOUND%"=="1" (
    echo Compiling EA with MetaEditor...
    "%METAEDITOR%" /compile:"%MT5_DATA%\MQL5\Experts\XAUUSD_Breakout_Bot.mq5" /log
    timeout /t 10 /nobreak >nul

    if exist "%MT5_DATA%\MQL5\Experts\XAUUSD_Breakout_Bot.ex5" (
        echo.
        echo ============================================
        echo   SUCCESS! EA compiled and installed!
        echo ============================================
        echo.
        echo Now in MT5:
        echo 1. Press Ctrl+N to open Navigator
        echo 2. Expand Expert Advisors
        echo 3. Drag XAUUSD_Breakout_Bot onto your XAUUSD M5 chart
        echo 4. Check "Allow Algo Trading" and click OK
        echo 5. Make sure AutoTrading button is ON (green)
        echo.
    ) else (
        echo.
        echo File copied but compilation may need manual step.
        echo Open MetaEditor, open the file, and press F7 to compile.
        echo.
    )
) else (
    echo.
    echo Could not find MetaEditor automatically.
    echo The .mq5 file has been copied to: %MT5_DATA%\MQL5\Experts\
    echo.
    echo To compile manually:
    echo 1. Open MetaEditor from MT5 (Tools menu)
    echo 2. Open XAUUSD_Breakout_Bot.mq5
    echo 3. Press F7 to compile
    echo.
)

pause

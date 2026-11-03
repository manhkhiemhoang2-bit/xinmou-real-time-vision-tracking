@echo off
chcp 65001 >nul
cd /d "%~dp0"

echo ============================================
echo  win3x3_96 仿真波形查看器
echo ============================================
echo.

rem ---- 1. 没有 WLF 就自动从 VCD 转 ----
if not exist "win3x3.wlf" (
    if exist "win3x3.vcd" (
        echo [1/2] 正在把 VCD 转成 WLF（ModelSim 只认 WLF）...
        "D:\modelsim\modelsim_ase\win32aloem\vcd2wlf.exe" "win3x3.vcd" "win3x3.wlf"
        echo.
    ) else (
        echo [错误] 找不到 win3x3.vcd，也没有 win3x3.wlf。
        echo        请先跑一次仿真：vsim -c -do run.do tb_win3x3
        pause
        exit /b 1
    )
) else (
    echo [1/2] 已有 win3x3.wlf，跳过转换。
)

rem ---- 2. 打开 ModelSim 并加载波形 ----
echo [2/2] 正在启动 ModelSim...
echo.
start "" "D:\modelsim\modelsim_ase\win32aloem\modelsim.exe" -view "win3x3.wlf" -do "view.do"

echo 已启动。ModelSim 窗口里应该能看到波形。
echo 如果左边的 Structure 窗口是空的，在下面 Transcript 窗口里敲：
echo     vsim -view win3x3.wlf
echo 然后 Structure 里展开 win3x3 -^> tb_win3x3 -^> dut，选信号右键 Add Wave。
echo.
timeout /t 8 >nul

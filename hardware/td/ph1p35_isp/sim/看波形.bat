@echo off
chcp 65001 >nul
title win3x3_96 波形查看器
set PATH=D:\modelsim\modelsim_ase\win32aloem;%PATH%
cd /d "%~dp0"

echo ================================================
echo   win3x3_96  仿真波形查看器
echo ================================================
echo.

echo [1/3] 建库...
vlib work >nul 2>&1

echo [2/3] 编译...
vlog tb_win3x3.v win3x3_96_sim.v

echo.
echo [3/3] 启动 ModelSim 并加载波形...
start "" "D:\modelsim\modelsim_ase\win32aloem\modelsim.exe" tb_win3x3 -do "waves.do"

echo.
echo 已启动。ModelSim 打开后波形会自动加好并跑完。
echo 点工具栏的 Zoom Full（放大镜带方框那个图标）看全貌。
echo.
echo 如果没有自动加波形，在 ModelSim 底部 Transcript 窗口里手敲：
echo     cd {C:/Users/29072/deepseek_harness_workspace/sim_win3x3}
echo     do waves.do
echo.
timeout /t 8 >nul

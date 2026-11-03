#==============================================================================
# run_ext_ctrl.ps1 —— ext_ctrl 一键验证（vlib + vlog + vsim -c + checker）
#
# 用法（在 sim 目录下）：
#     .\run_ext_ctrl.ps1                          # 跑 src\ext_ctrl.v（基线）
#     .\run_ext_ctrl.ps1 -ExtSrc _mut_ext\x.v     # 跑指定变异源文件
#     .\run_ext_ctrl.ps1 -ExtSrc xxx.v -Lib work_mut -Tag M1
#
# 说明：只用 `vsim -c -do "run -all; quit -f"`，跑完必定 quit，不留残留 vsim。
#==============================================================================
param(
    [string]$ExtSrc = "..\src\ext_ctrl.v",
    [string]$Lib    = "work_ext",
    [string]$Tag    = "base"
)
$ErrorActionPreference = "Stop"
$MS = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'

$logDir = Join-Path $PWD ("_extlog")
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# ---- 1. 生成激励 ----
& $PY gen_stim_ext_ctrl.py *> (Join-Path $logDir "gen_$Tag.log")
if ($LASTEXITCODE -ne 0) { "FAIL: 激励生成失败，见 $logDir\gen_$Tag.log"; exit 1 }

# ---- 2. 干净重建库 ----
if (Test-Path $Lib) { Remove-Item -Recurse -Force $Lib }
& "$MS\vlib.exe" $Lib *> (Join-Path $logDir "vlib_$Tag.log")

# ---- 3. 编译 ----
& "$MS\vlog.exe" -work $Lib -quiet tb_ext_ctrl.v $ExtSrc *> (Join-Path $logDir "vlog_$Tag.log")
if ($LASTEXITCODE -ne 0) { "FAIL: vlog 失败，见 $logDir\vlog_$Tag.log"; exit 1 }

# ---- 4. 仿真（跑完 quit）----
& "$MS\vsim.exe" -c -lib $Lib -do "run -all; quit -f" tb_ext_ctrl *> (Join-Path $logDir "vsim_$Tag.log")
Get-Process vsim -ErrorAction SilentlyContinue | Where-Object { $_.CPU -eq 0 } | Stop-Process -Force -ErrorAction SilentlyContinue

# ---- 5. checker ----
& $PY check_ext_ctrl.py dump_ext.txt *> (Join-Path $logDir "check_$Tag.log")
$rc = $LASTEXITCODE
Get-Content (Join-Path $logDir "check_$Tag.log")
exit $rc

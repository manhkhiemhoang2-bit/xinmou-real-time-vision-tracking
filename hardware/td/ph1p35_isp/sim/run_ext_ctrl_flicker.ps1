#==============================================================================
# run_ext_ctrl_flicker.ps1 —— ext_ctrl v2 的"抖动 + 包络不可重触发"专项验证
#
#   三个 run（同一份 TB，-gP / -gNCYC 覆盖）：
#     抖动 run  : P=600       NCYC=72100      → checker --mode flicker --p 600
#     重触发 run: P=100       NCYC=2500000    → checker --mode retrig  --p 100
#     真实帧率  : P=1237500   NCYC=92812500   → checker --mode real    --p 1237500  ← 2026-09-28 新增
#
#   ⚠ 前两跑的帧周期都**远小于** beep 包络（400000 拍），而真实帧周期比包络还长 3 倍。
#     只测小帧周期会漏掉"帧周期 >> 包络"这一整类行为，所以补了第三跑。
#
#   用法（在 sim 目录下）： .\run_ext_ctrl_flicker.ps1
#   一律 `vsim -c -do "run -all; quit -f"`，跑完即 quit。
#==============================================================================
param(
    [string]$ExtSrc = "..\src\ext_ctrl.v",
    [string]$Lib    = "work_flk",
    [string]$Tag    = "v2"
)
$ErrorActionPreference = "Stop"
$MS = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'

$logDir = Join-Path $PWD "_extlog"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

if (Test-Path $Lib) { Remove-Item -Recurse -Force $Lib }
& "$MS\vlib.exe" $Lib *> (Join-Path $logDir "vlib_flk_$Tag.log")
& "$MS\vlog.exe" -work $Lib -quiet tb_ext_ctrl_flicker.v $ExtSrc *> (Join-Path $logDir "vlog_flk_$Tag.log")
if ($LASTEXITCODE -ne 0) { "FAIL: vlog 失败，见 $logDir\vlog_flk_$Tag.log"; exit 1 }

$rcAll = 0

# ---- run 1：抖动 ----
& "$MS\vsim.exe" -c -lib $Lib -gP=600 -gNCYC=72100 -do "run -all; quit -f" tb_ext_ctrl_flicker *> (Join-Path $logDir "vsim_flk1_$Tag.log")
Copy-Item dump_flk.txt (Join-Path $logDir "dump_flk_flicker_$Tag.txt") -Force
& $PY check_ext_ctrl_flicker.py (Join-Path $logDir "dump_flk_flicker_$Tag.txt") --mode flicker --p 600 *> (Join-Path $logDir "check_flk1_$Tag.log")
if ($LASTEXITCODE -ne 0) { $rcAll = 1 }
Get-Content (Join-Path $logDir "check_flk1_$Tag.log") | Where-Object { $_ -notmatch '^RESULT' }

# ---- run 2：不可重触发 ----
& "$MS\vsim.exe" -c -lib $Lib -gP=100 -gNCYC=2500000 -do "run -all; quit -f" tb_ext_ctrl_flicker *> (Join-Path $logDir "vsim_flk2_$Tag.log")
Copy-Item dump_flk.txt (Join-Path $logDir "dump_flk_retrig_$Tag.txt") -Force
& $PY check_ext_ctrl_flicker.py (Join-Path $logDir "dump_flk_retrig_$Tag.txt") --mode retrig --p 100 *> (Join-Path $logDir "check_flk2_$Tag.log")
if ($LASTEXITCODE -ne 0) { $rcAll = 1 }
Get-Content (Join-Path $logDir "check_flk2_$Tag.log") | Where-Object { $_ -notmatch '^RESULT' }

# ---- run 3：真实帧周期（2026-09-28 新增）----
#   P = 1,237,500 拍/帧（60MHz 域 ⇒ ≈48.5fps），75 帧 ≈ 92.8M 拍，
#   覆盖 f0..f74 全部激励段（含倒置框 f70..73），所以 F3~F9 全都能判。
#   为什么必须补这一跑：原来只有 P=600 与 P=100 两个**很小**的帧周期，
#   而**真实帧周期比 beep 包络（400000 拍）还长约 3 倍** —— 量级完全不同。
#   "帧周期 >> 包络"正是"包络可被重装"类缺陷最容易藏身的地方。
$swR = [Diagnostics.Stopwatch]::StartNew()
& "$MS\vsim.exe" -c -lib $Lib -gP=1237500 -gNCYC=92812500 -do "run -all; quit -f" tb_ext_ctrl_flicker *> (Join-Path $logDir "vsim_flk3_$Tag.log")
$swR.Stop()
Write-Host ("[real] vsim exit={0}  墙钟 {1:N1}s" -f $LASTEXITCODE, $swR.Elapsed.TotalSeconds)
if ($LASTEXITCODE -ne 0) { $rcAll = 1 }
Copy-Item dump_flk.txt (Join-Path $logDir "dump_flk_real_$Tag.txt") -Force
& $PY check_ext_ctrl_flicker.py (Join-Path $logDir "dump_flk_real_$Tag.txt") --mode real --p 1237500 *> (Join-Path $logDir "check_flk3_$Tag.log")
if ($LASTEXITCODE -ne 0) { $rcAll = 1 }
Get-Content (Join-Path $logDir "check_flk3_$Tag.log") | Where-Object { $_ -notmatch '^RESULT' }

Get-Process vsim -ErrorAction SilentlyContinue | Where-Object { $_.CPU -eq 0 } | Stop-Process -Force -ErrorAction SilentlyContinue
exit $rcAll

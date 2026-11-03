#==============================================================================
# run_bubble.ps1 -- alg_top 行消隐（气泡）鲁棒性测试
#
#   0) 编译进 work_bub
#   1) 回归：默认跑法（含行消隐 + 按键）→ check_alg_top.py 必须 PASS
#      （金标准在**真实工况**下验过；这条以前跑的是"帧间无气泡"的假工况）
#   2) 参考跑：+nokey +noblank      → dump_top_ref.txt（无行消隐，对照组）
#   3) 消隐跑：+nokey（默认含消隐）   → dump_top_bub.txt
#   4) 判据：check_bubble.py（有效拍输出序列必须逐位相同，口径不放宽）
#   5) 判据自身变异自证：check_bubble.py --selftest
#      （含防空转断言：每个变异 dump 必须与基线 dump 逐字节不同）
#
#   ASCII only -- GBK 控制台显示不了中文。
#==============================================================================
$ErrorActionPreference = "Stop"
$MS   = "D:\modelsim\modelsim_ase\win32aloem"
$SRC  = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) "src"
$PY   = "C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$fail = 0
function Step($t) { Write-Host ""; Write-Host ("=" * 70); Write-Host "== $t"; Write-Host ("=" * 70) }

Step "0/5  compile into work_bub"
if (Test-Path work_bub) { Remove-Item -Recurse -Force work_bub }
& "$MS\vlib.exe" work_bub | Out-Null
& "$MS\vlog.exe" -work work_bub `
    "$SRC\gray_bt601_96.v" "$SRC\win3x3_96.v" "$SRC\alg_binarize_96.v" `
    "$SRC\alg_sobel_96.v" "$SRC\alg_smooth_96.v" "$SRC\alg_color_detect_96.v" `
    "$SRC\alg_framediff_96.v" `
    "$SRC\alg_region_fill_96.v" `
    "$SRC\rgb_row_delay_96.v" "$SRC\alg_top.v" tb_alg_top.v | Select-String "Errors:"
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "1/5  regression: default run (line blanking ON + key) -> check_alg_top.py must PASS"
& "$MS\vsim.exe" -c -lib work_bub tb_alg_top -do "run -all; quit -f" | Select-String "TB:|blank=|Errors"
& $PY check_alg_top.py | Select-Object -Last 14
if ($LASTEXITCODE -ne 0) { Write-Host "REGRESSION FAILED"; $fail++ }

Step "2/5  reference run (+nokey +noblank: no line blanking)"
& "$MS\vsim.exe" -c -lib work_bub tb_alg_top +nokey +noblank -do "run -all; quit -f" | Select-String "TB:|blank=|Errors"
Copy-Item dump_top.txt dump_top_ref.txt -Force
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "3/5  blanking run (+nokey: default = line blanking ON)"
& "$MS\vsim.exe" -c -lib work_bub tb_alg_top +nokey -do "run -all; quit -f" | Select-String "TB:|blank=|Errors"
Copy-Item dump_top.txt dump_top_bub.txt -Force
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "4/5  criterion: ref vs blanking runs (out beats must be bit-identical)"
& $PY check_bubble.py dump_top_ref.txt dump_top_bub.txt
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "5/5  criterion self-proof (mutations must be caught)"
& $PY check_bubble.py --selftest
if ($LASTEXITCODE -ne 0) { $fail++ }

Write-Host ""
Write-Host ("=" * 70)
if ($fail -eq 0) { Write-Host "ALL STEPS PASS" } else { Write-Host "FAILED STEPS: $fail" }
Write-Host ("=" * 70)
exit $fail

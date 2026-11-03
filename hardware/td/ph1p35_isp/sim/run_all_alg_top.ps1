#==============================================================================
# run_all_alg_top.ps1 -- alg_top integration: one-command rerun
#   usage (from the sim directory):
#       powershell -ExecutionPolicy Bypass -File run_all_alg_top.ps1
#   prerequisites: D:\modelsim\modelsim_ase\win32aloem\  (free ASE)
#   ASCII echo only -- the GBK console mangles Chinese; Chinese text lives in
#   the Python checker output and the report.
#==============================================================================
$ErrorActionPreference = "Stop"
$MS   = "D:\modelsim\modelsim_ase\win32aloem"
$SRC  = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) "src"
$PY   = "C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$fail = 0
function Step($t) { Write-Host ""; Write-Host ("=" * 70); Write-Host "== $t"; Write-Host ("=" * 70) }

Step "1/4  generate stimulus (stim_top.hex)"
& $PY gen_stim_top.py
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "2/4  ModelSim compile + run"
if (Test-Path work_top) { Remove-Item -Recurse -Force work_top }
& "$MS\vlib.exe" work_top | Out-Null
& "$MS\vlog.exe" -work work_top `
    "$SRC\gray_bt601_96.v" "$SRC\win3x3_96.v" "$SRC\alg_binarize_96.v" `
    "$SRC\alg_sobel_96.v" "$SRC\alg_smooth_96.v" "$SRC\alg_color_detect_96.v" `
    "$SRC\alg_framediff_96.v" `
    "$SRC\alg_region_fill_96.v" `
    "$SRC\rgb_row_delay_96.v" "$SRC\alg_top.v" tb_alg_top.v | Select-String "Errors:"
if ($LASTEXITCODE -ne 0) { $fail++ }
& "$MS\vsim.exe" -c -lib work_top tb_alg_top -do "run -all; quit -f" | Select-String "TB:|Errors"
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "3/4  checks A-F (delay / 6 modes / mask / mode latch / M3 src row)"
& $PY check_alg_top.py
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "4/4  mutation self-proof: wrong expectations + wrong RTL"
& $PY check_alg_top.py --selftest
if ($LASTEXITCODE -ne 0) { $fail++ }
& $PY rtl_mutation_top.py
if ($LASTEXITCODE -ne 0) { $fail++ }

Write-Host ""
Write-Host ("=" * 70)
if ($fail -eq 0) { Write-Host "ALL STEPS PASS" } else { Write-Host "FAILED STEPS: $fail" }
Write-Host ("=" * 70)
exit $fail

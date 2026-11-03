#==============================================================================
# run_all_second_batch.ps1 —— 第二批两个模块的一键验证（ModelSim 真仿真 + 校验 + 变异自证 + 规范门禁）
#
# 用法（在 sim 目录下）：
#     powershell -ExecutionPolicy Bypass -File run_all_second_batch.ps1
#
# 前置：D:\modelsim\modelsim_ase\win32aloem\ 已安装（免 license 的 ASE 版）
# 说明：本文件用英文打印，避免 GBK 控制台把中文 echo 打乱；中文结论在各 Python 校验器里。
#==============================================================================

$ErrorActionPreference = "Stop"
$MS   = "D:\modelsim\modelsim_ase\win32aloem"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$fail = 0

function Step($title) { Write-Host ""; Write-Host ("=" * 70); Write-Host "== $title"; Write-Host ("=" * 70) }

# ---------------------------------------------------------------------------
Step "1/7  rgb_row_delay_96: regenerate stimulus"
python gen_stim_row_delay.py
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "2/7  rgb_row_delay_96: ModelSim compile + run + check (valid-beat contract C1..C4)"
& "$MS\vlog.exe" -quiet tb_rgb_row_delay.v "..\src\rgb_row_delay_96.v"
if ($LASTEXITCODE -ne 0) { $fail++ }
& "$MS\vsim.exe" -c -do run_rd.do tb_rgb_row_delay | Select-String "TB:|Errors"
if ($LASTEXITCODE -ne 0) { $fail++ }
python check_row_delay.py
if ($LASTEXITCODE -ne 0) { $fail++ }
python check_row_delay.py --selftest
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "3/7  rgb_row_delay_96: real-RTL mutation self-proof (M1 = old clock semantics)"
python rtl_mutation_row_delay.py
if ($LASTEXITCODE -ne 0) { $fail++ }

# ---------------------------------------------------------------------------
Step "4/7  alg_color_detect_96: regenerate stimulus"
python gen_stim_color_detect.py
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "5/7  alg_color_detect_96: ModelSim compile + run + check"
& "$MS\vlog.exe" -quiet tb_alg_color_detect_96.v "..\src\alg_color_detect_96.v"
if ($LASTEXITCODE -ne 0) { $fail++ }
& "$MS\vsim.exe" -c -do run_cd.do tb_alg_color_detect | Select-String "TB:|Errors"
if ($LASTEXITCODE -ne 0) { $fail++ }
python check_color_detect.py
if ($LASTEXITCODE -ne 0) { $fail++ }
python check_color_detect.py --selftest
if ($LASTEXITCODE -ne 0) { $fail++ }

# ---------------------------------------------------------------------------
Step "6/7  spec gate lint (ports / banned constructs / BOM / latch)"
python lint_second_batch.py
if ($LASTEXITCODE -ne 0) { $fail++ }

Step "7/7  src -> prj\_fullchip\alg sync check (MD5, 11 files)"
python sync_src_check.py
if ($LASTEXITCODE -ne 0) { $fail++ }

Write-Host ""
Write-Host ("=" * 70)
if ($fail -eq 0) { Write-Host "ALL PASS (failures = 0)" } else { Write-Host "FAILURES = $fail" }
Write-Host ("=" * 70)
exit $fail

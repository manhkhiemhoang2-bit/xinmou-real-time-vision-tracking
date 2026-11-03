# =============================================================================
# run_gim_vis.ps1 -- gim_vis_ctl（pan/tilt 视觉伺服控制律）的模块级回归
#
# 被测：src\gim_vis_ctl.v
# 测试：sim\tb_gim_vis_ctl.v  ->  sim\_gim_vis\dump_gim_vis.txt（逐帧表）
# 判据：sim\check_gim_vis_ctl.py 的 N0~N5 + 变异自证
#
# 判据一览（详见 check_gim_vis_ctl.py 文件头）：
#   N0 逐帧对独立的 Python 参考模型
#   N1 死区内脉宽不变
#   N2 每帧变化量 <= SLEW_MAX
#   N3 脉宽落在 [PULSE_MIN, PULSE_MAX]
#   N4 目标丢失时脉宽保持（不回中）
#   N5 锁定：连续 LOCK_N 帧在死区内置 1 并保持；出死区立刻 0
#
# ⚠ 输出一律重定向到文件再读（原生命令直接接 Select-Object 会杀进程）。
# =============================================================================
param(
    [switch]$SkipSelftest
)
$ErrorActionPreference = 'Stop'
$R  = 'D:\TD\bin\work_for_all\ph1p35_isp'
$S  = "$R\sim"
$W  = "$S\_gim_vis"
$MV = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$fail = 0

$rtl = @('gim_vis_ctl.v')

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $W | Out-Null
foreach ($f in $rtl) { Copy-Item "$S\..\src\$f" "$W\$f" -Force }
Copy-Item "$S\tb_gim_vis_ctl.v" "$W\tb_gim_vis_ctl.v" -Force
Write-Host "拷贝完成：$($rtl.Count) 个 RTL + TB"

Push-Location $W
& "$MV\vlib.exe" work 2>&1 | Out-File -Encoding utf8 "$W\vlib.log"
$vlogArgs = @('-work','work') + ($rtl | ForEach-Object { "$W\$_" }) + @("$W\tb_gim_vis_ctl.v")
& "$MV\vlog.exe" @vlogArgs 2>&1 | Out-File -Encoding utf8 "$W\vlog_vis.log"
$vlogExit = $LASTEXITCODE
Write-Host "vlog exit=$vlogExit"
Get-Content "$W\vlog_vis.log" -Encoding utf8 | Select-String -Pattern 'Error|errors|Warning' | Select-Object -First 10

if ($vlogExit -eq 0) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & "$MV\vsim.exe" -c -lib work tb_gim_vis_ctl -do "run -all; quit -f" 2>&1 |
      Out-File -Encoding utf8 "$W\vsim_vis.log"
  $vsimExit = $LASTEXITCODE
  $sw.Stop()
  Write-Host ("vsim exit=$vsimExit   仿真墙钟 {0:N1} s" -f $sw.Elapsed.TotalSeconds)
  Get-Content "$W\vsim_vis.log" -Encoding utf8 |
      Select-String -Pattern 'TB:|Errors:|FATAL|done' | Select-Object -Last 6
  if ($vsimExit -ne 0) { $fail++ }
  if (Test-Path "$W\dump_gim_vis.txt") {
    Write-Host ("dump 大小 {0:N0} 字节" -f (Get-Item "$W\dump_gim_vis.txt").Length)
  } else { Write-Host "!! 没有 dump 文件"; $fail++ }
} else { $fail++ }
Pop-Location

if ($fail -eq 0) {
  Push-Location $S
  Write-Host "`n===== 判据 N0~N5 ====="
  & $PY -u check_gim_vis_ctl.py --dump "$W\dump_gim_vis.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_vis.log" | Out-Null
  $rc1 = $LASTEXITCODE
  Write-Host "checker exit=$rc1"
  Get-Content "$W\check_vis.log" -Encoding utf8 | Select-Object -Last 22
  if ($rc1 -ne 0) { $fail++ }

  if (-not $SkipSelftest) {
    Write-Host "`n===== 变异自证（--selftest）====="
    & $PY -u check_gim_vis_ctl.py --dump "$W\dump_gim_vis.txt" --selftest 2>&1 |
        Tee-Object -FilePath "$W\selftest_vis.log" | Out-Null
    $rc2 = $LASTEXITCODE
    Write-Host "selftest exit=$rc2"
    Get-Content "$W\selftest_vis.log" -Encoding utf8 | Select-Object -Last 14
    if ($rc2 -ne 0) { $fail++ }
  }
  Pop-Location
}

Write-Host ""
if ($fail -eq 0) { Write-Host "gim_vis_ctl 回归：ALL PASS" } else { Write-Host "gim_vis_ctl 回归：FAILED STEPS $fail" }
exit $fail

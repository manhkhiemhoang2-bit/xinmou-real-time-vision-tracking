# =============================================================================
# run_gim_pwm3.ps1 -- gim_pwm3（三路舵机 PWM）的模块级回归
#
# 被测：src\gim_pwm3.v
# 测试：sim\tb_gim_pwm3.v  ->  sim\_gim_pwm3\dump_gim_pwm3.txt（只写变化沿）
# 判据：sim\check_gim_pwm3.py 的 J1~J5 + 变异自证
#
# 判据一览（详见 check_gim_pwm3.py 文件头）：
#   J1 周期 = PWM_PER 拍（20ms）
#   J2 脉宽 = 限幅后的命令值
#   J3 命令超上限/超下限时被夹住
#   J4 O_boot_done 在 T_RST_END+BOOT_MUTE 附近拉高，之前三路恒 0
#   J5 en=0 期间三路恒 0，且 en 恢复后重新出脉冲
#
# 时间：整个过程约 1950 万拍（其中 1000 万拍是 200ms 的真实静默期）。
#       只 dump 变化沿，dump 很小；仿真墙钟取决于机器，可能几分钟。
#
# ⚠ 输出一律重定向到文件再读（原生命令直接接 Select-Object 会杀进程）。
# =============================================================================
param(
    [switch]$SkipSelftest
)
$ErrorActionPreference = 'Stop'
$R  = 'D:\TD\bin\work_for_all\ph1p35_isp'
$S  = "$R\sim"
$W  = "$S\_gim_pwm3"
$MV = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$fail = 0

$rtl = @('gim_pwm3.v')

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $W | Out-Null
foreach ($f in $rtl) { Copy-Item "$S\..\src\$f" "$W\$f" -Force }
Copy-Item "$S\tb_gim_pwm3.v" "$W\tb_gim_pwm3.v" -Force
Write-Host "拷贝完成：$($rtl.Count) 个 RTL + TB"

Push-Location $W
& "$MV\vlib.exe" work 2>&1 | Out-File -Encoding utf8 "$W\vlib.log"
$vlogArgs = @('-work','work') + ($rtl | ForEach-Object { "$W\$_" }) + @("$W\tb_gim_pwm3.v")
& "$MV\vlog.exe" @vlogArgs 2>&1 | Out-File -Encoding utf8 "$W\vlog_gim.log"
$vlogExit = $LASTEXITCODE
Write-Host "vlog exit=$vlogExit"
Get-Content "$W\vlog_gim.log" -Encoding utf8 | Select-String -Pattern 'Error|errors' | Select-Object -First 8

if ($vlogExit -eq 0) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & "$MV\vsim.exe" -c -lib work tb_gim_pwm3 -do "run -all; quit -f" 2>&1 |
      Out-File -Encoding utf8 "$W\vsim_gim.log"
  $vsimExit = $LASTEXITCODE
  $sw.Stop()
  Write-Host ("vsim exit=$vsimExit   仿真墙钟 {0:N1} s" -f $sw.Elapsed.TotalSeconds)
  Get-Content "$W\vsim_gim.log" -Encoding utf8 |
      Select-String -Pattern 'TB:|Errors:|FATAL|PASS|FAIL|done' | Select-Object -Last 8
  if ($vsimExit -ne 0) { $fail++ }
  if (Test-Path "$W\dump_gim_pwm3.txt") {
    Write-Host ("dump 大小 {0:N0} 字节" -f (Get-Item "$W\dump_gim_pwm3.txt").Length)
  } else { Write-Host "!! 没有 dump 文件"; $fail++ }
} else { $fail++ }
Pop-Location

if ($fail -eq 0) {
  Push-Location $S
  Write-Host "`n===== 判据 J1~J5 ====="
  & $PY -u check_gim_pwm3.py --dump "$W\dump_gim_pwm3.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_gim.log" | Out-Null
  $rc1 = $LASTEXITCODE
  Write-Host "checker exit=$rc1"
  Get-Content "$W\check_gim.log" -Encoding utf8 | Select-Object -Last 24
  if ($rc1 -ne 0) { $fail++ }

  if (-not $SkipSelftest) {
    Write-Host "`n===== 变异自证（--selftest）====="
    & $PY -u check_gim_pwm3.py --dump "$W\dump_gim_pwm3.txt" --selftest 2>&1 |
        Tee-Object -FilePath "$W\selftest_gim.log" | Out-Null
    $rc2 = $LASTEXITCODE
    Write-Host "selftest exit=$rc2"
    Get-Content "$W\selftest_gim.log" -Encoding utf8 | Select-Object -Last 12
    if ($rc2 -ne 0) { $fail++ }
  }
  Pop-Location
}

Write-Host ""
if ($fail -eq 0) { Write-Host "gim_pwm3 回归：ALL PASS" } else { Write-Host "gim_pwm3 回归：FAILED STEPS $fail" }
exit $fail

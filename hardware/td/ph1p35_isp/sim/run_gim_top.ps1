# =============================================================================
# run_gim_top.ps1 -- gim_top（三轴云台子系统）**集成级**回归
#
# 被测：src\gim_top.v（顶层）
#       + gim_vis_ctl.v / gim_pwm3.v / gim_imu_i2c.v / gim_imu_roll.v
#       + 厂商 uii2c.v（从板级工程拷进来，不复制到 src\）
# 测试：sim\tb_gim_top.v + sim\mpu6050_slave_bfm.v
# 判据：sim\check_gim_top.py 的 G1~G3 + 变异自证
#
# 两跑：
#   ① 正常   -> dump_gim_top.txt          IMU 在，roll 应由姿态驱动
#   ② +imufail -> dump_gim_top_imufail.txt IMU 不回 ACK，roll 必须回中位，
#                                          且 pan/tilt **逐位不受影响**
#
# 判据一览：
#   G1 视觉链路仍然通：pan/tilt 脉宽 == 独立重算的控制律（Stage 1 没被破坏）
#   G2 roll 由 IMU 驱动：角度离开 0、脉宽离开中位
#   G3 IMU 失效回退：roll 回中位 + imu_err 置位 + pan/tilt 两次跑逐位相同
#
# ⚠ 本 TB 的时序参数按比例缩小（真实值已由各自的模块级回归用真实参数验过）。
#
# ⚠ 输出一律重定向到文件再读（原生命令直接接 Select-Object 会杀进程）。
# =============================================================================
param(
    [switch]$SkipSelftest
)
$ErrorActionPreference = 'Stop'
$R  = 'D:\TD\bin\work_for_all\ph1p35_isp'
$S  = "$R\sim"
$W  = "$S\_gim_top"
$MV = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$UII2C = "$R\prj\board\lab_ex3_osd\user_source\hdl_source\uics500_cfg\uii2c.v"
$fail = 0

$rtl = @('gim_top.v','gim_vis_ctl.v','gim_pwm3.v','gim_imu_i2c.v','gim_imu_roll.v')

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $W | Out-Null
Copy-Item $UII2C "$W\uii2c.v" -Force
foreach ($f in $rtl) { Copy-Item "$R\src\$f" "$W\$f" -Force }
Copy-Item "$S\mpu6050_slave_bfm.v" "$W\" -Force
Copy-Item "$S\tb_gim_top.v"        "$W\" -Force
Write-Host "拷贝完成：$($rtl.Count) 个 RTL + uii2c + 从机模型 + TB"

Push-Location $W
& "$MV\vlib.exe" work 2>&1 | Out-File -Encoding utf8 "$W\vlib.log"
$vlogArgs = @('-work','work', "$W\uii2c.v") + ($rtl | ForEach-Object { "$W\$_" }) +
            @("$W\mpu6050_slave_bfm.v", "$W\tb_gim_top.v")
& "$MV\vlog.exe" @vlogArgs 2>&1 | Out-File -Encoding utf8 "$W\vlog_top.log"
$vlogExit = $LASTEXITCODE
Write-Host "vlog exit=$vlogExit"
Get-Content "$W\vlog_top.log" -Encoding utf8 | Select-String -Pattern 'Error|Warning' | Select-Object -First 12

if ($vlogExit -eq 0) {
  foreach ($imufail in @($false, $true)) {
    $tag = if ($imufail) { "imufail" } else { "normal" }
    # ⚠ 顶层名和 +plusarg 必须作为**两个独立参数**传
    $vargs = @('tb_gim_top')
    if ($imufail) { $vargs += '+imufail' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & "$MV\vsim.exe" -c -lib work @vargs -do "run -all; quit -f" 2>&1 |
        Out-File -Encoding utf8 "$W\vsim_$tag.log"
    $sw.Stop()
    Write-Host ("[{0}] vsim exit={1}  墙钟 {2:N1}s" -f $tag, $LASTEXITCODE, $sw.Elapsed.TotalSeconds)
    Get-Content "$W\vsim_$tag.log" -Encoding utf8 |
        Select-String -Pattern 'TB:|Errors:|FATAL' | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { $fail++ }
  }
  if (-not (Test-Path "$W\dump_gim_top.txt"))         { Write-Host "!! 缺正常跑 dump";   $fail++ }
  if (-not (Test-Path "$W\dump_gim_top_imufail.txt")) { Write-Host "!! 缺失效跑 dump";   $fail++ }
} else { $fail++ }
Pop-Location

if ($fail -eq 0) {
  Push-Location $S
  Write-Host "`n===== 判据 G1~G3 ====="
  & $PY -u check_gim_top.py --dump "$W\dump_gim_top.txt" --imufail-dump "$W\dump_gim_top_imufail.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_top.log" | Out-Null
  $rc1 = $LASTEXITCODE
  Write-Host "checker exit=$rc1"
  Get-Content "$W\check_top.log" -Encoding utf8 | Select-Object -Last 18
  if ($rc1 -ne 0) { $fail++ }

  if (-not $SkipSelftest) {
    Write-Host "`n===== 变异自证（--selftest）====="
    & $PY -u check_gim_top.py --dump "$W\dump_gim_top.txt" --imufail-dump "$W\dump_gim_top_imufail.txt" --selftest 2>&1 |
        Tee-Object -FilePath "$W\selftest_top.log" | Out-Null
    $rc2 = $LASTEXITCODE
    Write-Host "selftest exit=$rc2"
    Get-Content "$W\selftest_top.log" -Encoding utf8 | Select-Object -Last 10
    if ($rc2 -ne 0) { $fail++ }
  }
  Pop-Location
}

Write-Host ""
if ($fail -eq 0) { Write-Host "gim_top 集成回归：ALL PASS" } else { Write-Host "gim_top 集成回归：FAILED STEPS $fail" }
exit $fail

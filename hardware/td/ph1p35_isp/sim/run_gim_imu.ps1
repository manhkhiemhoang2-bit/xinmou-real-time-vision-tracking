# =============================================================================
# run_gim_imu.ps1 -- gim_imu_i2c（MPU6050 配置序列 + 256Hz 周期读）的模块级回归
#
# 被测：src\gim_imu_i2c.v（内含厂商 uii2c 主机）
# 测试：sim\tb_gim_imu_i2c.v + sim\mpu6050_slave_bfm.v（已被厂商已知good主机反证过）
# 判据：sim\check_gim_imu_i2c.py 的 K1~K5 + 变异自证
#
# 两跑：
#   ① 正常   -> dump_gim_imu.txt       验配置序列 / WHO_AM_I / 拆包 / 采样间隔
#   ② +noack -> dump_gim_imu_noack.txt 故障注入：从机不回 ACK，必须报错停住
#
# ⚠ SCL 用真实 CLK_DIV=498（≈100kHz）、周期用真实 CYC_DLY=195312（256Hz），
#   只有上电/复位/配置间隔三个延时被缩小（它们的唯一作用就是"等够时间"）。
#
# ⚠ 输出一律重定向到文件再读（原生命令直接接 Select-Object 会杀进程）。
# =============================================================================
param(
    [switch]$SkipSelftest
)
$ErrorActionPreference = 'Stop'
$R  = 'D:\TD\bin\work_for_all\ph1p35_isp'
$S  = "$R\sim"
$W  = "$S\_gim_imu"
$MV = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$UII2C = "$R\prj\board\lab_ex3_osd\user_source\hdl_source\uics500_cfg\uii2c.v"
$fail = 0

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $W | Out-Null
Copy-Item $UII2C "$W\uii2c.v" -Force
Copy-Item "$R\src\gim_imu_i2c.v"    "$W\" -Force
Copy-Item "$S\mpu6050_slave_bfm.v"  "$W\" -Force
Copy-Item "$S\tb_gim_imu_i2c.v"     "$W\" -Force
Write-Host "拷贝完成：uii2c + gim_imu_i2c + 从机模型 + TB"

Push-Location $W
& "$MV\vlib.exe" work 2>&1 | Out-File -Encoding utf8 "$W\vlib.log"
& "$MV\vlog.exe" -work work "$W\uii2c.v" "$W\gim_imu_i2c.v" "$W\mpu6050_slave_bfm.v" "$W\tb_gim_imu_i2c.v" 2>&1 |
    Out-File -Encoding utf8 "$W\vlog_imu.log"
$vlogExit = $LASTEXITCODE
Write-Host "vlog exit=$vlogExit"
Get-Content "$W\vlog_imu.log" -Encoding utf8 | Select-String -Pattern 'Error|Warning' | Select-Object -First 10

if ($vlogExit -eq 0) {
  foreach ($noack in @($false, $true)) {
    $tag = if ($noack) { "noack" } else { "normal" }
    # ⚠ 顶层名和 +plusarg 必须作为**两个独立参数**传：拼成一个字符串会被 vsim
    #   当成一个顶层名 "tb_gim_imu_i2c +noack" ⇒ Error loading design（踩过一次）
    $vargs = @('tb_gim_imu_i2c')
    if ($noack) { $vargs += '+noack' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & "$MV\vsim.exe" -c -lib work @vargs -do "run -all; quit -f" 2>&1 |
        Out-File -Encoding utf8 "$W\vsim_$tag.log"
    $sw.Stop()
    Write-Host ("[{0}] vsim exit={1}  墙钟 {2:N1}s" -f $tag, $LASTEXITCODE, $sw.Elapsed.TotalSeconds)
    Get-Content "$W\vsim_$tag.log" -Encoding utf8 |
        Select-String -Pattern 'TB:|Errors:|FATAL' | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { $fail++ }
  }
  if (-not (Test-Path "$W\dump_gim_imu.txt"))        { Write-Host "!! 缺正常跑 dump"; $fail++ }
  if (-not (Test-Path "$W\dump_gim_imu_noack.txt"))  { Write-Host "!! 缺故障注入 dump"; $fail++ }
} else { $fail++ }
Pop-Location

if ($fail -eq 0) {
  Push-Location $S
  Write-Host "`n===== 判据 K1~K5 ====="
  & $PY -u check_gim_imu_i2c.py --dump "$W\dump_gim_imu.txt" --noack-dump "$W\dump_gim_imu_noack.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_imu.log" | Out-Null
  $rc1 = $LASTEXITCODE
  Write-Host "checker exit=$rc1"
  Get-Content "$W\check_imu.log" -Encoding utf8 | Select-Object -Last 20
  if ($rc1 -ne 0) { $fail++ }

  if (-not $SkipSelftest) {
    Write-Host "`n===== 变异自证（--selftest）====="
    & $PY -u check_gim_imu_i2c.py --dump "$W\dump_gim_imu.txt" --selftest 2>&1 |
        Tee-Object -FilePath "$W\selftest_imu.log" | Out-Null
    $rc2 = $LASTEXITCODE
    Write-Host "selftest exit=$rc2"
    Get-Content "$W\selftest_imu.log" -Encoding utf8 | Select-Object -Last 12
    if ($rc2 -ne 0) { $fail++ }
  }
  Pop-Location
}

Write-Host ""
if ($fail -eq 0) { Write-Host "gim_imu_i2c 回归：ALL PASS" } else { Write-Host "gim_imu_i2c 回归：FAILED STEPS $fail" }
exit $fail

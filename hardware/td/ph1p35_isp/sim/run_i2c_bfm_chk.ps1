# =============================================================================
# run_i2c_bfm_chk.ps1 -- **验证 mpu6050_slave_bfm 自己是对的**
#
# 为什么单独一条：
#   手写的从机模型去验手写的主机，最危险的失败是"两个一起错、还互相吻合"。
#   所以先拿**已知good的主机** uii2c（米联客的，摄像头配置正在用、已在硬件上跑通）
#   去反证从机模型。这条过了，mpu6050_slave_bfm 才有资格验 gim_imu_i2c。
#
# 被测/被验：
#   sim\mpu6050_slave_bfm.v        从机行为模型（本次要验的对象）
#   sim\tb_i2c_bfm_chk.v           测试平台
#   厂商 uii2c（从板级工程 hdl_source\uics500_cfg\ 拷进来当"标准主机"）
#
# 判据：sim\check_i2c_bfm_chk.py 的 B1~B4 + 变异自证
#   B1 配置写 (0x6B,0x00)   B2 14 字节连读逐字节相符
#   B3 总线健康             B4 读起始寄存器 = 0x3B
#
# 顺带钉死 uii2c 的字节序（gim_imu_i2c 依赖它）：
#   写 I_wr_data[7:0] 先发；读 O_rd_data[7:0] 是第一个收到的字节。
#
# ⚠ 输出一律重定向到文件再读（原生命令直接接 Select-Object 会杀进程）。
# =============================================================================
param(
    [switch]$SkipSelftest
)
$ErrorActionPreference = 'Stop'
$R  = 'D:\TD\bin\work_for_all\ph1p35_isp'
$S  = "$R\sim"
$W  = "$S\_i2c_bfm_chk"
$MV = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$UII2C = "$R\prj\board\lab_ex3_osd\user_source\hdl_source\uics500_cfg\uii2c.v"
$fail = 0

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $W | Out-Null
Copy-Item $UII2C "$W\uii2c.v" -Force
Copy-Item "$S\mpu6050_slave_bfm.v" "$W\" -Force
Copy-Item "$S\tb_i2c_bfm_chk.v"    "$W\" -Force
Write-Host "拷贝完成：uii2c(厂商主机) + mpu6050_slave_bfm + TB"

Push-Location $W
& "$MV\vlib.exe" work 2>&1 | Out-File -Encoding utf8 "$W\vlib.log"
& "$MV\vlog.exe" -work work "$W\uii2c.v" "$W\mpu6050_slave_bfm.v" "$W\tb_i2c_bfm_chk.v" 2>&1 |
    Out-File -Encoding utf8 "$W\vlog_chk.log"
$vlogExit = $LASTEXITCODE
Write-Host "vlog exit=$vlogExit"
Get-Content "$W\vlog_chk.log" -Encoding utf8 | Select-String -Pattern 'Error|Warning' | Select-Object -First 8

if ($vlogExit -eq 0) {
  & "$MV\vsim.exe" -c -lib work tb_i2c_bfm_chk -do "run -all; quit -f" 2>&1 |
      Out-File -Encoding utf8 "$W\vsim_chk.log"
  $vsimExit = $LASTEXITCODE
  Write-Host "vsim exit=$vsimExit"
  Get-Content "$W\vsim_chk.log" -Encoding utf8 |
      Select-String -Pattern 'Errors:|FATAL|TIMEOUT|done' | Select-Object -Last 4
  if ($vsimExit -ne 0) { $fail++ }
  if (-not (Test-Path "$W\dump_i2c_bfm_chk.txt")) { Write-Host "!! 没有 dump"; $fail++ }
} else { $fail++ }
Pop-Location

if ($fail -eq 0) {
  Push-Location $S
  Write-Host "`n===== 判据 B1~B4 ====="
  & $PY -u check_i2c_bfm_chk.py --dump "$W\dump_i2c_bfm_chk.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_chk.log" | Out-Null
  $rc1 = $LASTEXITCODE
  Write-Host "checker exit=$rc1"
  Get-Content "$W\check_chk.log" -Encoding utf8 | Select-Object -Last 18
  if ($rc1 -ne 0) { $fail++ }

  if (-not $SkipSelftest) {
    Write-Host "`n===== 变异自证（--selftest）====="
    & $PY -u check_i2c_bfm_chk.py --dump "$W\dump_i2c_bfm_chk.txt" --selftest 2>&1 |
        Tee-Object -FilePath "$W\selftest_chk.log" | Out-Null
    $rc2 = $LASTEXITCODE
    Write-Host "selftest exit=$rc2"
    Get-Content "$W\selftest_chk.log" -Encoding utf8 | Select-Object -Last 12
    if ($rc2 -ne 0) { $fail++ }
  }
  Pop-Location
}

Write-Host ""
if ($fail -eq 0) { Write-Host "I2C 从机模型验证：ALL PASS" } else { Write-Host "I2C 从机模型验证：FAILED STEPS $fail" }
exit $fail

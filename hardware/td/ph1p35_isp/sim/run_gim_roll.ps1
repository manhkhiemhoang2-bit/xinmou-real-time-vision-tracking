# =============================================================================
# run_gim_roll.ps1 -- gim_imu_roll（零偏标定 + 互补滤波）的模块级回归
#
# 被测：src\gim_imu_roll.v
# 测试：sim\tb_gim_imu_roll.v  ->  sim\_gim_roll\dump_gim_roll.txt
# 判据：sim\check_gim_imu_roll.py 的 R1~R7 + 变异自证
#
# 核心手段：判据里有一份**独立的 Python 浮点金标准**，按同一个差分方程
#   （但用浮点、不做定点截断）重算一遍，再和定点 RTL 逐样本比对。
#   这样既能验"方程实现对了没有"，又能量出"定点化丢了多少精度"。
#
# 判据一览：
#   R1 零偏标定：标定后静止段 roll 基本不动
#   R2 roll 逐样本对浮点金标准（容差 = 角度的 2%）
#   R3 互补滤波两个半边都起作用：短时跟陀螺 / 长时收敛到倾角（按指数解析算期望）
#   R4 角度限幅在工作范围 ±25° 内，且限幅路径**真的被走到过**
#   R5 角度→脉宽：按公式比对 + 单调性 + 限幅真的被触发
#   R6 en=0 时输出回中位
#   R7 标定期间 roll 恒为 0
#
# ⚠ 输出一律重定向到文件再读（原生命令直接接 Select-Object 会杀进程）。
# =============================================================================
param(
    [switch]$SkipSelftest
)
$ErrorActionPreference = 'Stop'
$R  = 'D:\TD\bin\work_for_all\ph1p35_isp'
$S  = "$R\sim"
$W  = "$S\_gim_roll"
$MV = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$fail = 0

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $W | Out-Null
Copy-Item "$R\src\gim_imu_roll.v" "$W\" -Force
Copy-Item "$S\tb_gim_imu_roll.v"  "$W\" -Force
Write-Host "拷贝完成：gim_imu_roll.v + TB"

Push-Location $W
& "$MV\vlib.exe" work 2>&1 | Out-File -Encoding utf8 "$W\vlib.log"
& "$MV\vlog.exe" -work work "$W\gim_imu_roll.v" "$W\tb_gim_imu_roll.v" 2>&1 |
    Out-File -Encoding utf8 "$W\vlog_roll.log"
$vlogExit = $LASTEXITCODE
Write-Host "vlog exit=$vlogExit"
Get-Content "$W\vlog_roll.log" -Encoding utf8 | Select-String -Pattern 'Error|Warning' | Select-Object -First 10

if ($vlogExit -eq 0) {
  # ⚠ 两跑：
  #   ① 正常       —— 陀螺激励放在 gx（模块默认该读的那根）
  #   ② +wrongaxis —— 故意放在 gy（模块不该读的那根）
  #   第②跑是为了证明"轴选择参数真接到了逻辑上"，不是声明了一个没人用的参数。
  foreach ($wrong in @($false, $true)) {
    $tag = if ($wrong) { "wrongaxis" } else { "normal" }
    $vargs = @('tb_gim_imu_roll')
    if ($wrong) { $vargs += '+wrongaxis' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & "$MV\vsim.exe" -c -lib work @vargs -do "run -all; quit -f" 2>&1 |
        Out-File -Encoding utf8 "$W\vsim_$tag.log"
    $sw.Stop()
    Write-Host ("[{0}] vsim exit={1}  墙钟 {2:N1}s" -f $tag, $LASTEXITCODE, $sw.Elapsed.TotalSeconds)
    Get-Content "$W\vsim_$tag.log" -Encoding utf8 |
        Select-String -Pattern 'TB:|Errors:|FATAL' | Select-Object -Last 2
    if ($LASTEXITCODE -ne 0) { $fail++ }
  }
  if (-not (Test-Path "$W\dump_gim_roll.txt"))           { Write-Host "!! 缺正常跑 dump";     $fail++ }
  if (-not (Test-Path "$W\dump_gim_roll_wrongaxis.txt")) { Write-Host "!! 缺轴选择跑 dump";   $fail++ }

  # ③ 生产值跑（2026-09-28 新增）----------------------------------------------
  #   为什么必须单独跑一遍：上面两个跑都用 1200 覆盖了 PULSE_PER_DEG，
  #   于是 gim_top.v 里真正下载到板子上的那个值从来没被测过 ——
  #   它曾经是 1000（大 3.6 倍，会让舵机转 ±90°、可能拧断摄像头软排线）。
  #   ⇒ 这一跑用生产值（278），只验"脉宽不会超出排线安全预算"。
  #   ⚠ 参数：-gPULSE_PER_DEG 必须放在顶层名**之前**；+prodppd 是给 TB 的 plusarg。
  $pv = @('-gPULSE_PER_DEG=278', 'tb_gim_imu_roll', '+prodppd')
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & "$MV\vsim.exe" -c -lib work @pv -do "run -all; quit -f" 2>&1 |
      Out-File -Encoding utf8 "$W\vsim_prod.log"
  $sw.Stop()
  Write-Host ("[prodppd] vsim exit={0}  墙钟 {1:N1}s" -f $LASTEXITCODE, $sw.Elapsed.TotalSeconds)
  Get-Content "$W\vsim_prod.log" -Encoding utf8 |
      Select-String -Pattern 'TB:|Errors:|FATAL' | Select-Object -Last 2
  if ($LASTEXITCODE -ne 0) { $fail++ }
  if (-not (Test-Path "$W\dump_gim_roll_prod.txt")) { Write-Host "!! 缺生产值跑 dump"; $fail++ }
} else { $fail++ }
Pop-Location

if ($fail -eq 0) {
  Push-Location $S
  Write-Host "`n===== 判据 R1~R8 ====="
  & $PY -u check_gim_imu_roll.py --dump "$W\dump_gim_roll.txt" --wrongaxis-dump "$W\dump_gim_roll_wrongaxis.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_roll.log" | Out-Null
  $rc1 = $LASTEXITCODE
  Write-Host "checker exit=$rc1"
  Get-Content "$W\check_roll.log" -Encoding utf8 | Select-Object -Last 20
  if ($rc1 -ne 0) { $fail++ }

  if (-not $SkipSelftest) {
    Write-Host "`n===== 变异自证（--selftest）====="
    & $PY -u check_gim_imu_roll.py --dump "$W\dump_gim_roll.txt" --wrongaxis-dump "$W\dump_gim_roll_wrongaxis.txt" --selftest 2>&1 |
        Tee-Object -FilePath "$W\selftest_roll.log" | Out-Null
    $rc2 = $LASTEXITCODE
    Write-Host "selftest exit=$rc2"
    Get-Content "$W\selftest_roll.log" -Encoding utf8 | Select-Object -Last 12
    if ($rc2 -ne 0) { $fail++ }
  }

  # ---- 生产值专项判据（2026-09-28 新增）----
  Write-Host "`n===== 生产值 PULSE_PER_DEG 安全判据（排线预算）====="
  & $PY -u check_roll_ppd_prod.py --dump "$W\dump_gim_roll_prod.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_ppd_prod.log" | Out-Null
  $rc3 = $LASTEXITCODE
  Write-Host "checker(prod) exit=$rc3"
  Get-Content "$W\check_ppd_prod.log" -Encoding utf8 | Select-Object -Last 14
  if ($rc3 -ne 0) { $fail++ }

  if (-not $SkipSelftest) {
    Write-Host "`n===== 生产值判据的变异自证 ====="
    & $PY -u check_roll_ppd_prod.py --dump "$W\dump_gim_roll_prod.txt" --selftest 2>&1 |
        Tee-Object -FilePath "$W\selftest_ppd_prod.log" | Out-Null
    $rc4 = $LASTEXITCODE
    Write-Host "selftest(prod) exit=$rc4"
    Get-Content "$W\selftest_ppd_prod.log" -Encoding utf8 | Select-Object -Last 8
    if ($rc4 -ne 0) { $fail++ }
  }
  Pop-Location
}

Write-Host ""
if ($fail -eq 0) { Write-Host "gim_imu_roll 回归：ALL PASS" } else { Write-Host "gim_imu_roll 回归：FAILED STEPS $fail" }
exit $fail

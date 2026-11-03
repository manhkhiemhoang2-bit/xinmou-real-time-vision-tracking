# =============================================================================
# run_gim_all.ps1 -- 三轴云台**全套回归**（五个回归依次跑）
#
# 为什么要有这个：
#   单跑一个只能证明"这个模块现在是对的"。Stage 1 做完、Stage 2 又把 gim_top
#   改了一遍，必须**整套重跑**才能证明"新加的东西没把旧功能弄坏"。
#
# 跑什么（ModelSim 只能单实例，所以是串行的）：
#   1. run_gim_pwm3.ps1   三路舵机波形（周期/脉宽/限幅/静默/en）
#   2. run_gim_vis.ps1    pan/tilt 视觉伺服控制律
#   3. run_gim_imu.ps1    MPU6050 配置序列 + 256Hz 读（含故障注入）
#   4. run_gim_roll.ps1   零偏标定 + 互补滤波（对浮点金标准）
#   5. run_gim_top.ps1    子系统集成（视觉链路 / roll 由 IMU 驱动 / 失效回退）
#
# ⚠ 输出一律重定向到文件再读（原生命令直接接 Select-Object 会杀进程）。
# =============================================================================
$ErrorActionPreference = 'Stop'
$S    = 'D:\TD\bin\work_for_all\ph1p35_isp\sim'
$list = @(
    @{ n = "1/5 gim_pwm3   舵机波形";     f = "run_gim_pwm3.ps1" },
    @{ n = "2/5 gim_vis    视觉伺服";     f = "run_gim_vis.ps1"  },
    @{ n = "3/5 gim_imu    IMU 配置+读取"; f = "run_gim_imu.ps1"  },
    @{ n = "4/5 gim_roll   姿态解算";     f = "run_gim_roll.ps1" },
    @{ n = "5/5 gim_top    子系统集成";   f = "run_gim_top.ps1"  }
)
$res  = @()
$bad  = 0
foreach ($e in $list) {
    $log = "$S\_all_$($e.f).log"
    $sw  = [Diagnostics.Stopwatch]::StartNew()
    & "$S\$($e.f)" *> $log
    $rc  = $LASTEXITCODE
    $sw.Stop()
    $tail = (Get-Content $log -Encoding UTF8 -ErrorAction SilentlyContinue |
             Select-String -Pattern '合计断言|变异自证' |
             ForEach-Object { $_.Line.Trim() }) -join '  |  '
    $res += [pscustomobject]@{ 项 = $e.n; 退出码 = $rc; 秒 = [int]$sw.Elapsed.TotalSeconds; 摘要 = $tail }
    if ($rc -ne 0) { $bad++ }
    Write-Host ("[{0}] exit={1}  {2:N0}s  {3}" -f $e.n, $rc, $sw.Elapsed.TotalSeconds, $tail)
}
Write-Host ""
$res | Format-Table -AutoSize | Out-String -Width 400 | Write-Host
if ($bad -eq 0) { Write-Host "云台全套回归：ALL PASS（5/5）" } else { Write-Host "云台全套回归：$bad 项失败" }
exit $bad

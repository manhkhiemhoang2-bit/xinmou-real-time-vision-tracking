#==============================================================================
# run_all_regression.ps1 —— **总回归**：一条命令把所有回归依次跑完
#
# 为什么要有这个文件（2026-09-28 新建）：
#   sim 目录下原本有 18 个 run_*.ps1，但**没有总入口**，于是出现了"孤儿脚本"：
#     · run_ext_ctrl.ps1          —— 没有任何脚本调用它
#     · run_ext_ctrl_flicker.ps1  —— 同上（**蜂鸣器抖动/不可重触发判据就在里面**）
#   孤儿脚本等于放在抽屉里：判据写得再好，没人跑就等于没测。
#   更糟的是 run_full_algtop.ps1 有 4 处语法错（PS 5.1 不认"续行以 -f 开头"）却一直没人发现。
#
# 用法（在 sim 目录下）：
#   .\run_all_regression.ps1              # 默认：全部（含全尺寸，约 20~25 分钟）
#   .\run_all_regression.ps1 -Quick       # 跳过全尺寸长跑，只跑模块级（约 5 分钟）
#   .\run_all_regression.ps1 -Only gim    # 只跑名字里含 gim 的
#
# ⚠ 纪律：
#   1. ModelSim **同时只能跑一个实例**，所以本脚本严格**串行**，不要并行开两个。
#   2. 一律重定向到文件再读 —— 原生命令直接接 Select-Object 会杀进程。
#   3. 每个子脚本自己返回退出码；本脚本只汇总，不改它们的判据。
#==============================================================================
param(
    [switch]$Quick,
    [string]$Only = ""
)
$ErrorActionPreference = 'Continue'
$S = $PSScriptRoot
if (-not $S) { $S = $PWD.Path }
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$logDir = Join-Path $S "_allreg"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }

# ---- 回归清单 ----------------------------------------------------------------
#   kind: "mod" = 模块级/专项（快）    "full" = 全尺寸长跑（慢）
#   ⚠ 顺序有意安排：先快后慢，早失败早停手。
$REG = @(
    @{ n = "ext_ctrl        外部控制(LED/蜂鸣)"; f = "run_ext_ctrl.ps1";         kind = "mod" }
    @{ n = "ext_ctrl_flk    蜂鸣抖动+不可重触发+真实帧率"; f = "run_ext_ctrl_flicker.ps1"; kind = "mod" }
    @{ n = "gim_all         三轴云台全套(5 项)"; f = "run_gim_all.ps1";          kind = "mod" }
    @{ n = "i2c_bfm         IMU 从机模型自检";    f = "run_i2c_bfm_chk.ps1";    kind = "mod" }
    @{ n = "all_second_batch 第二批算子";         f = "run_all_second_batch.ps1"; kind = "mod" }
    @{ n = "hdmi_mixer      HDMI 混合器";         f = "run_hdmi_mixer.ps1";     kind = "mod" }
    @{ n = "all_alg_top     alg_top 小图集成";    f = "run_all_alg_top.ps1";   kind = "mod" }
    @{ n = "adv_regression  对抗性审查独立 TB";   f = "run_adv_regression.ps1"; kind = "mod" }
    @{ n = "bubble          行消隐鲁棒性";        f = "run_bubble.ps1";         kind = "full" }
    @{ n = "l1_full         全尺寸 12 帧 M0~M5";  f = "run_l1_full.ps1";       kind = "full" }
    @{ n = "m67_full        全尺寸 M6/M7 专项";   f = "run_m67_full.ps1";      kind = "full" }
    @{ n = "m7out_full      全尺寸 M7 切出";      f = "run_m7out_full.ps1";    kind = "full" }
)

$results = @()
$t0 = Get-Date

# ⚠ 子脚本里大量使用相对路径（tb_xxx.v / dump_xxx.txt / _extlog\），
#   必须在 sim 目录下执行，否则会找不到文件 —— 所以这里统一 Push 一次。
Push-Location $S

foreach ($r in $REG) {
    if ($Only -ne "" -and $r.f -notmatch $Only) { continue }
    if ($Quick -and $r.kind -eq "full") {
        $results += [pscustomobject]@{ 项 = $r.n; 退出码 = "跳过"; 秒 = 0 }
        continue
    }
    $path = Join-Path $S $r.f
    if (-not (Test-Path $path)) {
        Write-Host ("[{0}] 缺文件，跳过" -f $r.n)
        $results += [pscustomobject]@{ 项 = $r.n; 退出码 = "缺文件"; 秒 = 0 }
        continue
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $log = Join-Path $logDir (($r.f -replace '\.ps1$','') + ".log")
    & $path *> $log
    $rc = $LASTEXITCODE
    $sw.Stop()
    Write-Host ("[{0}] exit={1}  墙钟 {2:N0}s" -f $r.n, $rc, $sw.Elapsed.TotalSeconds)
    # 回显该子脚本的结论行（不打印全文，避免刷屏）
    Get-Content $log -Encoding utf8 -ErrorAction SilentlyContinue |
        Select-String -Pattern 'ALL PASS|ALLPASS|结论|VERDICT|PASS$|FAIL' |
        Select-Object -Last 2 | ForEach-Object { "        " + $_.Line.Trim() }
    $results += [pscustomobject]@{ 项 = $r.n; 退出码 = $rc; 秒 = [int]$sw.Elapsed.TotalSeconds }
}

Pop-Location

# ---- 汇总 --------------------------------------------------------------------
$t1 = Get-Date
Write-Host ""
Write-Host "======================================================================"
Write-Host ("  总回归汇总（总墙钟 {0:N0} 秒，日志在 _allreg\）" -f ($t1 - $t0).TotalSeconds)
Write-Host "======================================================================"
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$nfail = @($results | Where-Object { $_.退出码 -is [int] -and $_.退出码 -ne 0 }).Count
$nskip = @($results | Where-Object { $_.退出码 -eq "跳过" }).Count
if ($nfail -eq 0) {
    Write-Host ("总回归：ALL PASS（{0} 项，跳过 {1} 项）" -f $results.Count, $nskip)
    exit 0
} else {
    Write-Host ("总回归：**FAILED {0} 项**（跳过 {1} 项）" -f $nfail, $nskip)
    exit 1
}

# L1 全尺寸回归（1280x720 / 12 帧 / M0..M5 + 帧中换档 + 按键路径）—— 独立工作目录，避免踩旧脚本的路径坑
# 依据 G4 报告 §6.7/§6.8：旧 runner 的 Step3 用相对路径而 cwd 不对、Step4/5 不传 --dump
# 会读到 9/16 的旧 dump。
#
# ⚠ 2026-09-24 改：帧数 6 -> 12。
#   原来跑 6 帧的理由是"全尺寸 12 帧会因 TB 按键窗口 bug 报红"。**那个 bug 已修**：
#     · tb_alg_top_full.v 的按键窗口原来用 `bil_k = bil/BPL`，而 bil ∈ 0..319、BPL=320
#       ⇒ bil_k 恒为 0 ⇒ 按键脉冲从来没发出来过 ⇒ 帧 8/9/10 的档位全停在 M0。
#     · 已改为用帧内拍号 `bif`；同时 gen_stim_top_full.py 的档位表尾巴 [5,0] 修正为 [2,2]。
#   修后实测：12 帧跑通（2,764,800 拍，TB 自检 PASS），判据 A~L 全过（4135 万条断言），
#   变异自证 21/21。⇒ **12 帧现在应该作为常规回归**，否则按键路径会再次悄悄退化。
#   代价：一轮约 8 分钟仿真 + 2 分钟判据（原来是 3~4 分钟）。
#   临时想跑快点可用：.\run_l1_full.ps1 -Frames 6
param([int]$Frames = 12)
$ErrorActionPreference = 'Stop'
$R  = 'D:\TD\bin\work_for_all\ph1p35_isp'
$S  = "$R\sim"
$W  = "$S\_l1_full"
$MV = 'D:\modelsim\modelsim_ase\win32aloem'

$rtl = @('alg_top.v','gray_bt601_96.v','win3x3_96.v','rgb_row_delay_96.v',
         'alg_binarize_96.v','alg_sobel_96.v','alg_smooth_96.v',
         'alg_color_detect_96.v','alg_framediff_96.v','alg_region_fill_96.v')

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $W | Out-Null
foreach ($f in $rtl) { Copy-Item "$S\..\src\$f" "$W\$f" -Force }
Copy-Item "$S\tb_alg_top_full.v"   "$W\tb_alg_top_full.v" -Force
Copy-Item "$S\stim_top_full.hex"   "$W\stim_top_full.hex" -Force
Write-Host "拷贝完成：$($rtl.Count) 个 RTL + TB + stim"

Push-Location $W
& "$MV\vlib.exe" work 2>&1 | Out-File -Encoding utf8 "$W\vlib.log"
$vlogArgs = @('-work','work') + ($rtl | ForEach-Object { "$W\$_" }) + @("$W\tb_alg_top_full.v")
& "$MV\vlog.exe" @vlogArgs 2>&1 | Out-File -Encoding utf8 "$W\vlog_l1.log"
$vlogExit = $LASTEXITCODE
Write-Host "vlog exit=$vlogExit"
Get-Content "$W\vlog_l1.log" -Encoding utf8 | Select-String -Pattern 'Error|Warning|errors' | Select-Object -First 8

if ($vlogExit -eq 0) {
  & "$MV\vsim.exe" -c -lib work tb_alg_top_full -do "run -all; quit -f" "+frames=$Frames" 2>&1 |
      Out-File -Encoding utf8 "$W\vsim_l1.log"
  Write-Host "vsim exit=$LASTEXITCODE"
  Get-Content "$W\vsim_l1.log" -Encoding utf8 | Select-String -Pattern 'TB:|Errors:|FATAL|PASS|FAIL|done' | Select-Object -Last 12
  if (Test-Path "$W\dump_top_full.txt") {
    Write-Host ("dump 大小 {0:N1} MB" -f ((Get-Item "$W\dump_top_full.txt").Length/1MB))
  } else { Write-Host "!! 没有 dump 文件" }
}
Pop-Location

# ---------------------------------------------------------------------------
# 2026-09-20 补：判据 + 变异自证。
#   原脚本只跑 ModelSim、判据要手工敲，而手工敲最容易犯的错就是**不传 --dump**
#   —— 那会读到别的目录里的旧 dump（上一版 runner 正是这么翻车的）。
#   这里一并跑掉，并显式指定 dump 路径。
#   ⚠ 本跑用**冻结的 12 帧表**（默认 $Frames=12 ⇒ M0..M5 + 帧中换档 + 按键路径），
#     所以环境变量 ALG_MSCHED 必须是**未设置**状态；设了 m67 会让档位表与 TB 不一致，
#     判据 D 立刻报红。
# ---------------------------------------------------------------------------
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$fail = 0
if (Test-Path "$W\dump_top_full.txt") {
  if ($env:ALG_MSCHED) { Write-Host "!! 警告：ALG_MSCHED=$env:ALG_MSCHED 已设置，本跑应为空"; $fail++ }
  Push-Location $S
  Write-Host "`n===== 判据 A~P（1280x720 / $Frames 帧 / M0..M5 + 换档 + 按键）====="
  & $PY -u check_alg_top_full.py --frames $Frames --dump "$W\dump_top_full.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_l1.log" | Out-Null
  $rc1 = $LASTEXITCODE
  Write-Host "checker exit=$rc1"
  Get-Content "$W\check_l1.log" -Encoding utf8 | Select-Object -Last 30
  if ($rc1 -ne 0) { $fail++ }

  Write-Host "`n===== 变异自证：改期望值（--selftest）====="
  & $PY -u check_alg_top_full.py --frames $Frames --dump "$W\dump_top_full.txt" --selftest 2>&1 |
      Tee-Object -FilePath "$W\selftest_l1.log" | Out-Null
  $rc2 = $LASTEXITCODE
  Write-Host "selftest exit=$rc2"
  Get-Content "$W\selftest_l1.log" -Encoding utf8 |
      Select-String -Pattern '基线|筛掉|覆盖不到|漏掉|鉴别力' | ForEach-Object { $_.Line }
  if ($rc2 -ne 0) { $fail++ }
  Pop-Location
}
Write-Host ""
$tag = if ($Frames -eq 12) { "M0..M5 + 帧中换档 + 按键路径（frame 8/9/10 走按键）" } else { "前 $Frames 帧" }
if ($fail -eq 0) { Write-Host "L1 全尺寸回归（$tag）：ALL PASS" } else { Write-Host "L1 全尺寸回归：FAILED STEPS $fail" }
exit $fail

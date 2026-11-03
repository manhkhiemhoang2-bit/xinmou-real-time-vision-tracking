# =============================================================================
# run_m67_full.ps1 -- 全尺寸 1280x720 的 **M6/M7 专项回归**（4 帧：f0=M0、f1=M1、f2=M6、f3=M7）
#
# 为什么要这一条（2026-09-20 补的覆盖缺口）：
#   全尺寸那套冻结档位表是 f0..f5 = M0..M5、f6 测"帧内换档"，**没有 M6/M7 帧**。
#   所以 M6（帧差运动检测）和 M7（区域填充）至今只在 160x64 小图上验过。
#   板子快到（HX1P35A 9-22 后发），万一上板 M7 花屏，分不清是 RTL 错还是板子问题。
#   这一轮就是把这个歧义消掉。
#
# 档位顺序为什么是 [M0, M1, M6, M7]（第一版排 [M0, M6, M7] 实测报红，教训记下来）：
#   判据 L 的原文是 check_alg_top_full.py:1187
#       box_nonempty = (mb[fr-1] is not None)
#   即"M6 帧显示的红框 = **上一帧**的运动框"。而第 0 帧的运动图恒为全 0，
#   所以 M6 一旦落在第 1 帧，红框必然为空 —— 那是正常行为，不是 RTL bug。
#   ⇒ M6 必须 ≥ 第 2 帧；f1 用 M1 当垫帧（前一帧是哪一档都行）。
#
# 不动冻结表，只走开关（三方一致）：
#   · Python 侧：环境变量 ALG_MSCHED=m67  -> gen_stim_top_full.py 的 MODE_SCHED
#                （check_alg_top_full.py 是 import 它，自动跟着走）
#   · Verilog 侧：+m67 plusarg               -> tb_alg_top_full.v 的 4 帧表
#   不一致时判据 D（整帧内 O_mode 恒定 + 等于期望档位）会立刻报红，不会静默通过。
#
# 不用重新生成激励：stim_top_full.hex 里只有像素、与档位无关，磁盘上已是 12 帧。
#
# 先决可行性（开跑前已验，纯 CPU 几秒）：sim\_m67_full_feasible.py
#   M6 帧 2 非空：378 个运动格子，且上一帧运动框 mb[1]=(160,519,272,631) 非空
#   M7 帧 3 非空：白 74.06%（没全黑也没几乎全白），掩蔽区 6708 像素全黑
#
# ⚠ 输出一律重定向到文件再读（不要把原生命令直接接 Select-Object，会杀进程）。
# =============================================================================
param(
    [switch]$SkipSelftest
)
$ErrorActionPreference = 'Stop'
$R  = 'D:\TD\bin\work_for_all\ph1p35_isp'
$S  = "$R\sim"
$W  = "$S\_m67_full"
$MV = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$FRAMES = 4
$fail = 0

$rtl = @('alg_top.v','gray_bt601_96.v','win3x3_96.v','rgb_row_delay_96.v',
         'alg_binarize_96.v','alg_sobel_96.v','alg_smooth_96.v',
         'alg_color_detect_96.v','alg_framediff_96.v','alg_region_fill_96.v')

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $W | Out-Null
foreach ($f in $rtl) { Copy-Item "$S\..\src\$f" "$W\$f" -Force }
Copy-Item "$S\tb_alg_top_full.v" "$W\tb_alg_top_full.v" -Force
Copy-Item "$S\stim_top_full.hex" "$W\stim_top_full.hex" -Force
Write-Host "拷贝完成：$($rtl.Count) 个 RTL + TB + stim（$FRAMES 帧）"

Push-Location $W
& "$MV\vlib.exe" work 2>&1 | Out-File -Encoding utf8 "$W\vlib.log"
$vlogArgs = @('-work','work') + ($rtl | ForEach-Object { "$W\$_" }) + @("$W\tb_alg_top_full.v")
& "$MV\vlog.exe" @vlogArgs 2>&1 | Out-File -Encoding utf8 "$W\vlog_m67.log"
$vlogExit = $LASTEXITCODE
Write-Host "vlog exit=$vlogExit"
Get-Content "$W\vlog_m67.log" -Encoding utf8 | Select-String -Pattern 'Error|errors' | Select-Object -First 8

if ($vlogExit -eq 0) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & "$MV\vsim.exe" -c -lib work tb_alg_top_full -do "run -all; quit -f" `
      "+frames=$FRAMES" "+m67" 2>&1 | Out-File -Encoding utf8 "$W\vsim_m67.log"
  $vsimExit = $LASTEXITCODE
  $sw.Stop()
  Write-Host ("vsim exit=$vsimExit   仿真墙钟 {0:N1} s" -f $sw.Elapsed.TotalSeconds)
  Get-Content "$W\vsim_m67.log" -Encoding utf8 |
      Select-String -Pattern 'TB:|Errors:|FATAL|PASS|FAIL|done' | Select-Object -Last 12
  if ($vsimExit -ne 0) { $fail++ }
  if (Test-Path "$W\dump_top_full.txt") {
    Write-Host ("dump 大小 {0:N1} MB" -f ((Get-Item "$W\dump_top_full.txt").Length/1MB))
  } else { Write-Host "!! 没有 dump 文件"; $fail++ }
} else { $fail++ }
Pop-Location

if ($fail -eq 0) {
  Push-Location $S
  $env:ALG_MSCHED = 'm67'          # ⚠ 必须在 python 启动前设：三方一致的前提
  Write-Host "`n===== 判据 A~M（全尺寸 / M6+M7 帧）====="
  & $PY -u check_alg_top_full.py --frames $FRAMES --dump "$W\dump_top_full.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_m67.log" | Out-Null
  $rc1 = $LASTEXITCODE
  Write-Host "checker exit=$rc1"
  Get-Content "$W\check_m67.log" -Encoding utf8 | Select-Object -Last 32
  if ($rc1 -ne 0) { $fail++ }

  if (-not $SkipSelftest) {
    Write-Host "`n===== 变异自证：改期望值（--selftest）====="
    & $PY -u check_alg_top_full.py --frames $FRAMES --dump "$W\dump_top_full.txt" --selftest 2>&1 |
        Tee-Object -FilePath "$W\selftest_m67.log" | Out-Null
    $rc2 = $LASTEXITCODE
    Write-Host "selftest exit=$rc2"
    Get-Content "$W\selftest_m67.log" -Encoding utf8 | Select-Object -Last 20
    if ($rc2 -ne 0) { $fail++ }
  }
  Remove-Item Env:\ALG_MSCHED -ErrorAction SilentlyContinue
  Pop-Location
}

Write-Host ""
if ($fail -eq 0) { Write-Host "M6/M7 全尺寸回归：ALL PASS" } else { Write-Host "M6/M7 全尺寸回归：FAILED STEPS $fail" }
exit $fail

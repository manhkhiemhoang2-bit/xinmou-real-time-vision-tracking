# =============================================================================
# run_m7out_full.ps1 -- 全尺寸 1280x720 的 **M7 切出专项回归**
#                        （5 帧：f0=M0、f1=M1、f2=M3、f3=M7、f4=M0）
#
# 为什么要这一条（2026-09-22 补的覆盖缺口）：
#   alg_top.v:679 那条换档沿是**不对称**的：
#       wire w_mode_sw = w_sof_a0 || (w_sof_pre && (w_mode_nx == MODE_REGIONFILL));
#   注释 671~677 行只说清了「**切进** M7 必须提前 1 拍」（因为 u_rf 控制相位晚 3 拍，
#   不提前会多吐 1 拍 + 1 个 tuser），但「**切出** M7」没有对应处理。
#   M7 支路延迟 7 拍、其余档 4 拍：切出时 r_mode 要到 w_sof_a0 的下一拍才变，
#   那一拍 MUX 仍按 M7 选源 = IN(T-3)，而新档通路手中的 IN(T)
#   （= 新帧第 0 拍、携带 tuser）就被整个跳过 ⇒ 该帧输出侧**没有 tuser**。
#
#   为什么现有激励都抓不到：小图表 = [0..7] + [7]*N（M7 之后一直是 M7），
#   全尺寸 m67 表 = [0,1,6,7] + 尾部（M7 又是最后一个）。
#   **两条表里 M7 都是终点**，"M7 -> 别的档"这一步从未出现在任何激励里。
#   而按键循环是 M7 -> MODE_RAW（alg_top.v:776），按第 9 下必然触发。
#
# 档位顺序为什么是 [M0, M1, M3, M7, M0]：
#   f0=M0  判据 K（M0 直通 = LAT 拍）要一帧 M0
#   f1=M1  垫帧
#   f2=M3  **必须留一帧 M3**：check_alg_top_full.py:993 用的是
#          MODE_SCHED.index(A.MODE_EDGE)，表里没有 M3 会直接抛 ValueError
#          ⇒ 带上它，checker 一个字都不用改
#   f3=M7  切进 M7（有 w_sof_pre 保护，应当干净）
#   f4=M0  ← **切出 M7 就在 f3->f4 这个帧边界**，要验的就是它
#
# 不动冻结表，只走开关（三方一致）：
#   · Python 侧：环境变量 ALG_MSCHED=m7out -> gen_stim_top_full.py 的 MODE_SCHED
#                （check_alg_top_full.py 是 import 它，自动跟着走）
#   · Verilog 侧：+m7out plusarg              -> tb_alg_top_full.v 的 5 帧表
#   不一致时判据 D（整帧内 O_mode 恒定 + 等于期望档位）会立刻报红，不会静默通过。
#
# 不用重新生成激励：stim_top_full.hex 里只有像素、与档位无关，磁盘上已是 12 帧。
#
# 预期结果（两种都算有信息）：
#   · 判据 J/D 在 f4 报红  -> 缺陷坐实，要修 alg_top.v:679
#   · 全绿                 -> 我的寄存器级推算有误，那条"缺陷"不存在
#
# ⚠ 输出一律重定向到文件再读（不要把原生命令直接接 Select-Object，会杀进程）。
# =============================================================================
param(
    [switch]$SkipSelftest
)
$ErrorActionPreference = 'Stop'
$R  = 'D:\TD\bin\work_for_all\ph1p35_isp'
$S  = "$R\sim"
$W  = "$S\_m7out_full"
$MV = 'D:\modelsim\modelsim_ase\win32aloem'
$PY = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$FRAMES = 5
$fail = 0

$rtl = @('alg_top.v','gray_bt601_96.v','win3x3_96.v','rgb_row_delay_96.v',
         'alg_binarize_96.v','alg_sobel_96.v','alg_smooth_96.v',
         'alg_color_detect_96.v','alg_framediff_96.v','alg_region_fill_96.v')

Remove-Item -Recurse -Force $W -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $W | Out-Null
foreach ($f in $rtl) { Copy-Item "$S\..\src\$f" "$W\$f" -Force }
Copy-Item "$S\tb_alg_top_full.v" "$W\tb_alg_top_full.v" -Force
Copy-Item "$S\stim_top_full.hex" "$W\stim_top_full.hex" -Force
Write-Host "拷贝完成：$($rtl.Count) 个 RTL + TB + stim（$FRAMES 帧，档位 [0,1,3,7,0]）"

Push-Location $W
& "$MV\vlib.exe" work 2>&1 | Out-File -Encoding utf8 "$W\vlib.log"
$vlogArgs = @('-work','work') + ($rtl | ForEach-Object { "$W\$_" }) + @("$W\tb_alg_top_full.v")
& "$MV\vlog.exe" @vlogArgs 2>&1 | Out-File -Encoding utf8 "$W\vlog_m7out.log"
$vlogExit = $LASTEXITCODE
Write-Host "vlog exit=$vlogExit"
Get-Content "$W\vlog_m7out.log" -Encoding utf8 | Select-String -Pattern 'Error|errors' | Select-Object -First 8

if ($vlogExit -eq 0) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & "$MV\vsim.exe" -c -lib work tb_alg_top_full -do "run -all; quit -f" `
      "+frames=$FRAMES" "+m7out" 2>&1 | Out-File -Encoding utf8 "$W\vsim_m7out.log"
  $vsimExit = $LASTEXITCODE
  $sw.Stop()
  Write-Host ("vsim exit=$vsimExit   仿真墙钟 {0:N1} s" -f $sw.Elapsed.TotalSeconds)
  Get-Content "$W\vsim_m7out.log" -Encoding utf8 |
      Select-String -Pattern 'TB:|Errors:|FATAL|PASS|FAIL|done' | Select-Object -Last 12
  if ($vsimExit -ne 0) { $fail++ }
  if (Test-Path "$W\dump_top_full.txt") {
    Write-Host ("dump 大小 {0:N1} MB" -f ((Get-Item "$W\dump_top_full.txt").Length/1MB))
  } else { Write-Host "!! 没有 dump 文件"; $fail++ }
} else { $fail++ }
Pop-Location

if ($fail -eq 0) {
  Push-Location $S
  $env:ALG_MSCHED = 'm7out'        # ⚠ 必须在 python 启动前设：三方一致的前提
  Write-Host "`n===== 判据 A~M（全尺寸 / M7 切出专项）====="
  & $PY -u check_alg_top_full.py --frames $FRAMES --dump "$W\dump_top_full.txt" 2>&1 |
      Tee-Object -FilePath "$W\check_m7out.log" | Out-Null
  $rc1 = $LASTEXITCODE
  Write-Host "checker exit=$rc1"
  Get-Content "$W\check_m7out.log" -Encoding utf8 | Select-Object -Last 34
  if ($rc1 -ne 0) { $fail++ }

  if (-not $SkipSelftest) {
    Write-Host "`n===== 变异自证：改期望值（--selftest）====="
    & $PY -u check_alg_top_full.py --frames $FRAMES --dump "$W\dump_top_full.txt" --selftest 2>&1 |
        Tee-Object -FilePath "$W\selftest_m7out.log" | Out-Null
    $rc2 = $LASTEXITCODE
    Write-Host "selftest exit=$rc2"
    Get-Content "$W\selftest_m7out.log" -Encoding utf8 | Select-Object -Last 20
    if ($rc2 -ne 0) { $fail++ }
  }
  Remove-Item Env:\ALG_MSCHED -ErrorAction SilentlyContinue
  Pop-Location
}

Write-Host ""
if ($fail -eq 0) { Write-Host "M7 切出全尺寸回归：ALL PASS" } else { Write-Host "M7 切出全尺寸回归：FAILED STEPS $fail" }
exit $fail

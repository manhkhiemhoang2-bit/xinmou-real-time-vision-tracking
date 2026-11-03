#==============================================================================
# run_adv_regression.ps1 —— 把对抗性审查员的**独立 TB** 当回归跑（v2 RTL）
#
# 纪律：只读审查员目录下的 .v / .py，**绝不改写**；
#       所有新产物写到 _adv_ext\rerun_v2\ 下的新文件里（不覆盖任何原始日志）。
#       check_adv_boundary.py 是**逐字节复制**到 rerun_v2 后再跑的 ——
#       它按 __file__ 所在目录找 adv1_boundary.log，所以在那里放新日志即可，
#       原文件与其证据日志都不动。
#
# 用法（在 sim 目录下）： .\run_adv_regression.ps1
#==============================================================================
param(
    [string]$ExtSrc = "..\src\ext_ctrl.v",
    [string]$Tag    = "v2"
)
$ErrorActionPreference = "Stop"
$MS  = 'D:\modelsim\modelsim_ase\win32aloem'
$PY  = 'C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe'
$ADV = Join-Path $PWD '_adv_ext'
$OUT = Join-Path $ADV ('rerun_' + $Tag)
$LIB = Join-Path $OUT 'work_new'

if (-not (Test-Path $OUT)) { New-Item -ItemType Directory -Path $OUT | Out-Null }
if (Test-Path $LIB) { Remove-Item -Recurse -Force $LIB }
& "$MS\vlib.exe" $LIB *> (Join-Path $OUT "vlib.log")

$srcs = @('tb_adv_boundary.v','tb_adv_beep_fast.v','tb_adv_flicker_rst.v',
          'tb_adv_cliff.v','tb_adv_frame.v') | ForEach-Object { Join-Path $ADV $_ }
& "$MS\vlog.exe" -work $LIB -quiet @srcs $ExtSrc *> (Join-Path $OUT "vlog.log")
if ($LASTEXITCODE -ne 0) { "FAIL: vlog，见 $OUT\vlog.log"; exit 1 }

function Run-One([string]$top, [string[]]$gens, [string]$logname) {
    $args = @('-c', '-lib', $LIB) + $gens + @('-do', 'run -all; quit -f', $top)
    & "$MS\vsim.exe" @args *> (Join-Path $OUT $logname)
}

Run-One 'tb_adv_boundary'    @()                                                  'adv1_boundary.log'
Run-One 'tb_adv_beep_fast'   @()                                                  'adv2_beep_fast.log'
Run-One 'tb_adv_flicker_rst' @()                                                  'adv3_flicker.log'
Run-One 'tb_adv_cliff'       @('-gP=15000','-gNCYC=2500000')                      'adv4a_cliff15000.log'
Run-One 'tb_adv_cliff'       @('-gP=22000','-gNCYC=2500000')                      'adv4b_cliff22000.log'
Run-One 'tb_adv_cliff'       @('-gP=1237500','-gNCYC=26600000')                   'adv5_realrate.log'
Run-One 'tb_adv_frame'       @()                                                  'adv7_frame.log'

# 逐字节复制审查员的 checker 到新目录再跑（原文件不动）
Copy-Item (Join-Path $ADV 'check_adv_boundary.py') (Join-Path $OUT 'check_adv_boundary.py') -Force

Get-Process vsim -ErrorAction SilentlyContinue | Where-Object { $_.CPU -eq 0 } | Stop-Process -Force -ErrorAction SilentlyContinue

"================= 每个 TB 的关键输出 ================="
foreach ($f in @('adv1_boundary.log','adv2_beep_fast.log','adv3_flicker.log',
                 'adv4a_cliff15000.log','adv4b_cliff22000.log','adv5_realrate.log','adv7_frame.log')) {
    "---- $f ----"
    Select-String -Path (Join-Path $OUT $f) -Pattern 'ADV1 DONE|ADV2 |ADV3 |CLIFF |BEEP rise|LEDCHG|FRM |FROZEN|ADV7 ' |
        ForEach-Object { $_.Line } | Select-Object -First 25
}
"================= 审查员自己的 boundary checker（未改一字）================="
& $PY (Join-Path $OUT 'check_adv_boundary.py') 2>&1 | Out-String -Width 200

#==============================================================================
# run_hdmi_mixer.ps1 -- hdmi_mixer(rewrite) vs hdmi_mixer_official: one-command rerun
#
#   usage (from the sim directory):
#       pwsh -ExecutionPolicy Bypass -File run_hdmi_mixer.ps1
#
#   ModelSim: D:\modelsim\modelsim_ase\win32aloem\  (Altera Starter 10.3c)
#
#   The official OSD cone (anlogic_logo_rom / osd_char_lib) is compiled straight
#   from the archive folder _removed_official_osd\ -- nothing is restored into
#   the project source tree, nothing in the RTL is modified.
#
#   ASCII console echo only; the Chinese parts of the report are printed by the
#   Python prep script (which writes its own UTF-8 log).
#==============================================================================
$ErrorActionPreference = "Stop"
$MS   = "D:\modelsim\modelsim_ase\win32aloem"
$PY   = "C:\Users\29072\PycharmProjects\PythonProject8\.venv\Scripts\python.exe"
$HDL  = "D:\TD\bin\work_for_all\ph1p35_isp\prj\board\lab_ex3_osd\user_source\hdl_source"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

$ROM = Join-Path $HDL "_removed_official_osd\anlogic_logo_rom.v"
$LIB = Join-Path $HDL "_removed_official_osd\osd_char_lib.v"
if (-not (Test-Path $ROM)) { $ROM = Join-Path $HDL "anlogic_logo_rom.v" }
if (-not (Test-Path $LIB)) { $LIB = Join-Path $HDL "osd_char_lib.v" }

$fail = 0
function Step($t) { Write-Host ""; Write-Host ("=" * 70); Write-Host "== $t"; Write-Host ("=" * 70) }

Step "1/4 prep: official rename copy + premises (prep_hdmi_mixer.py)"
& $PY prep_hdmi_mixer.py
if ($LASTEXITCODE -ne 0) { Write-Host "PREP FAILED -- simulation would be meaningless, aborting"; exit 1 }

Step "2/4 vlog: compile rewrite + official copy + logo rom + char lib + tb"
if (Test-Path work_mixer) { Remove-Item -Recurse -Force work_mixer }
& "$MS\vlib.exe" work_mixer | Out-Null
& "$MS\vlog.exe" -work work_mixer `
    (Join-Path $HDL "hdmi_mixer.v") `
    "hdmi_mixer_official.v" `
    $ROM $LIB `
    "tb_hdmi_mixer.v"
if ($LASTEXITCODE -ne 0) { Write-Host "VLOG FAILED"; exit 1 }

Step "3/4 vsim -c: 2 frames, 200x200 active pixels, both DUTs on the same stimulus"
& "$MS\vsim.exe" -c -lib work_mixer -wlf hdmi_mixer.wlf -l vsim_hdmi_mixer.log `
    tb_hdmi_mixer -do run_hdmi_mixer.do
if ($LASTEXITCODE -ne 0) { Write-Host "VSIM exited non-zero"; $fail++ }

Step "4/4 verdict + artifacts"
$log = Join-Path $here "vsim_hdmi_mixer.log"
if (Test-Path $log) {
    Write-Host "--- assertion summary (from vsim_hdmi_mixer.log) ---"
    Get-Content $log | Select-String -Pattern "RESULT:|A1a|A1b|A2 |A3 |A4v|A4h|A5 |A6a|A6b|A6x|counterexamples|transitions|classification|hit cycles|S_osd_hit ==" |
        ForEach-Object { $_.Line }
    if (-not (Select-String -Path $log -Pattern "RESULT: PASS" -Quiet)) { $fail++ }
} else {
    Write-Host "no transcript: $log"
    $fail++
}
Write-Host ""
Write-Host "--- preserved artifacts ---"
foreach ($a in @("hdmi_mixer.vcd", "hdmi_mixer.wlf", "vsim_hdmi_mixer.log", "prep_hdmi_mixer.log", "hdmi_mixer_official.v")) {
    $p = Join-Path $here $a
    if (Test-Path $p) { Write-Host ("  {0,-26} {1,12} bytes" -f $a, (Get-Item $p).Length) }
    else              { Write-Host ("  {0,-26} MISSING" -f $a) }
}

Write-Host ""
Write-Host ("=" * 70)
if ($fail -eq 0) { Write-Host "RUN+CHECK: PASS" } else { Write-Host "RUN+CHECK: FAIL ($fail)"; }
Write-Host ("=" * 70)
exit $fail

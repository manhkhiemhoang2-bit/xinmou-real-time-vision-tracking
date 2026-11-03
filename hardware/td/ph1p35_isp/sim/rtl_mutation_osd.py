"""Real-RTL mutation gate for osd_mixer.

Each mutation is applied to the actual RTL, recompiled, re-simulated, and the
INDEPENDENT checker (ground-truth coordinates from the stimulus) must FAIL.
A mutation that the checker does not catch means the test is blind.
"""
import os, shutil, subprocess, sys, json
sys.stdout.reconfigure(encoding="utf-8")

SIM = r"D:\TD\bin\work_for_all\ph1p35_isp\sim"
SRC = r"D:\TD\bin\work_for_all\ph1p35_isp\src"
MS = r"D:\modelsim\modelsim_ase\win32aloem"
PY = sys.executable
LOG = os.path.join(SIM, "_mut.log")

MUTS = {
    "R1_text_within_beat_mirror": [
        ("w_mix0 = w_pix_text_hit[0]", "w_mix0 = w_pix_text_hit[3]"),
        ("w_mix1 = w_pix_text_hit[1]", "w_mix1 = w_pix_text_hit[2]"),
        ("w_mix2 = w_pix_text_hit[2]", "w_mix2 = w_pix_text_hit[1]"),
        ("w_mix3 = w_pix_text_hit[3]", "w_mix3 = w_pix_text_hit[0]"),
    ],
    "R2_logo_onebeat_late": [
        ("w_logo_dy = {1'b0, w_y_base}", "w_logo_dy = {1'b0, r_y}"),
        ("w_logo_dx = {1'b0, w_x_base}",
         "w_logo_dx = {1'b0, {r_x[8:0], 2'b00}}"),
    ],
    "R3_text_onebeat_late": [
        ("w_txt_dx_txt = {1'b0, w_x_base} -",
         "w_txt_dx_txt = {1'b0, {r_x[8:0], 2'b00}} -"),
        ("w_txt_row    = (w_y_base - TEXT_Y)",
         "w_txt_row    = (r_y - TEXT_Y)"),
        ("w_txt_inrow  = (w_y_base >= TEXT_Y) && (w_y_base < (TEXT_Y + TEXT_H))",
         "w_txt_inrow  = (r_y >= TEXT_Y) && (r_y < (TEXT_Y + TEXT_H))"),
        ("w_txt_incol  = (w_x_base >= TEXT_X) &&\n"
         "                           (w_x_base < (TEXT_X + (N_CHAR_MAX * TEXT_W)))",
         "w_txt_incol  = (r_x >= TEXT_X) &&\n"
         "                           (r_x < (TEXT_X + (N_CHAR_MAX * TEXT_W)))"),
    ],
    "R4_logo_hit_inverted": [
        # 2026-09-16：v1.3 删掉 r_vld2/r_tlast2/r_tuser2 后原锚点不存在了（会报 VACUOUS），
        # 改挂在 r_pix_data_p1 声明行后面 —— 该行在有/无对齐修复时都在。
        ("reg [95:0] r_pix_data_p1;",
         "reg [95:0] r_pix_data_p1;\n"
         "wire r_logo_hit0n = ~r_logo_hit0_p1, r_logo_hit1n = ~r_logo_hit1_p1;\n"
         "wire r_logo_hit2n = ~r_logo_hit2_p1, r_logo_hit3n = ~r_logo_hit3_p1;"),
        ("(r_logo_hit0_p1   ? r_logo_col0_p1", "(r_logo_hit0n     ? r_logo_col0_p1"),
        ("(r_logo_hit1_p1   ? r_logo_col1_p1", "(r_logo_hit1n     ? r_logo_col1_p1"),
        ("(r_logo_hit2_p1   ? r_logo_col2_p1", "(r_logo_hit2n     ? r_logo_col2_p1"),
        ("(r_logo_hit3_p1   ? r_logo_col3_p1", "(r_logo_hit3n     ? r_logo_col3_p1"),
    ],
}


def _prio_swap():
    """Swap text/logo priority so the LOGO wins where both hit.

    2026-09-16：osd_mixer v1.2 把混合级搬到第 2 级之后，这里的锚点同步改成
    寄存后的写法（r_logo_hit*_p1 / r_pix_data_p1），否则会报 VACUOUS。
    2026-09-17（G1）：v1.4 在文字与自研 Logo 之间插了安路官方 Logo 面，w_mix 从
    两段变成三段 —— 锚点与替换式同步跟着改成三段（安路那一段原样保留在中间）。
    """
    out = []
    for k in range(4):
        hi, lo = 95 - 24 * k, 72 - 24 * k
        out.append((
            "wire [23:0] w_mix%d = w_pix_text_hit[%d] ? OSD_TEXT_COLOR :\n"
            "                     (r_an_hit%d_p1     ? r_an_col%d_p1 :\n"
            "                     (r_logo_hit%d_p1   ? r_logo_col%d_p1 : r_pix_data_p1[%d:%d]));"
            % (k, k, k, k, k, k, hi, lo),
            "wire [23:0] w_mix%d = r_logo_hit%d_p1 ? r_logo_col%d_p1 :\n"
            "                     (r_an_hit%d_p1     ? r_an_col%d_p1 :\n"
            "                     (w_pix_text_hit[%d] ? OSD_TEXT_COLOR : r_pix_data_p1[%d:%d]));"
            % (k, k, k, k, k, k, hi, lo),
        ))
    return out


# 优先级规则只有在文字带与 Logo 带**重叠**时才可能被测到（TB 的 TEXT_Y 已挪进 Logo 带）
MUTS["R5_text_logo_priority_swapped"] = _prio_swap()


def run(args):
    with open(LOG, "a", encoding="utf-8", errors="replace") as f:
        f.write("\n$ " + " ".join(args) + "\n")
        f.flush()
        return subprocess.run(args, cwd=SIM, stdout=f,
                              stderr=subprocess.STDOUT).returncode


def compile_with(rtl_path):
    return run([os.path.join(MS, "vlog.exe"), "-sv", "tb_osd_mixer.v",
                rtl_path, os.path.join(SRC, "my_logo_rom.v"),
                os.path.join(SRC, "my_charlib.v")])


def simulate():
    return run([os.path.join(MS, "vsim.exe"), "-c", "-do", "run_osd.do",
                "tb_osd_mixer"])


def check(dump):
    r = subprocess.run([PY, os.path.join(SIM, "check_osd.py"), dump],
                       cwd=SIM, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    tail = [l for l in (r.stdout or "").splitlines()
            if "plane bad" in l or l.strip().startswith(("PASS", "FAIL"))]
    return r.returncode, tail


orig = open(os.path.join(SRC, "osd_mixer.v"), encoding="utf-8").read()
if os.path.exists(LOG):
    os.remove(LOG)

# ---- baseline (unmutated) --------------------------------------------------
print("== baseline ==")
assert compile_with(os.path.join(SRC, "osd_mixer.v")) == 0, "baseline vlog failed"
assert simulate() == 0, "baseline vsim failed"
shutil.copy(os.path.join(SIM, "dump_osd.txt"),
            os.path.join(SIM, "dump_osd_good.txt"))
rc, tail = check("dump_osd_good.txt")
print("   rc=%d %s" % (rc, " | ".join(tail)))
assert rc == 0, "BASELINE FAILED -- fix is not actually clean"

results = {}
for name, subs in MUTS.items():
    txt = orig
    ok = True
    for a, b in subs:
        if txt.count(a) != 1:
            print("   !! anchor %r occurs %d times -- mutation is VACUOUS"
                  % (a[:60], txt.count(a)))
            ok = False
            break
        txt = txt.replace(a, b)
    if not ok:
        results[name] = "VACUOUS"
        continue
    mp = os.path.join(SIM, "_mut_%s.v" % name)
    with open(mp, "w", encoding="utf-8", newline="\n") as f:
        f.write(txt)
    crc = compile_with(mp)
    if crc != 0:
        results[name] = "COMPILE_FAIL"
        print("== %s == COMPILE FAILED (see _mut.log)" % name)
        continue
    simulate()
    dst = "dump_mut_%s.txt" % name
    shutil.copy(os.path.join(SIM, "dump_osd.txt"), os.path.join(SIM, dst))
    rc, tail = check(dst)
    caught = rc != 0
    results[name] = "CAUGHT" if caught else "MISSED"
    print("== %-28s == %s   (%s)" % (name, results[name], " | ".join(tail)))

# ---- restore good build ---------------------------------------------------
print("\n== restore ==")
assert compile_with(os.path.join(SRC, "osd_mixer.v")) == 0
simulate()
rc, tail = check("dump_osd.txt")
print("   rc=%d %s" % (rc, " | ".join(tail)))

print("\nsummary: " + json.dumps(results, ensure_ascii=False))
bad = [k for k, v in results.items() if v != "CAUGHT"]
print("VERDICT: " + ("ALL MUTATIONS CAUGHT" if not bad
                     else "BLIND SPOTS: %s" % bad))
sys.exit(0 if (not bad and rc == 0) else 1)

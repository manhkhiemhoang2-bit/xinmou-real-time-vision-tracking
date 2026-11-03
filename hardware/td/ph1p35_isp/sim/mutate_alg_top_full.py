#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mutate_alg_top_full.py —— **真 RTL 变异**自证

check_alg_top_full.py --selftest 改的是**期望值**；本脚本反过来改**被测 RTL 本体**，
重编译重仿真，看判据是否报红。抓不住的测试等于没测。

两种尺寸模式（`--size WxH`）：
  · `160x64`（**变异自证默认**）：40 拍/行、**7 帧**，一轮几秒。
    帧 i 用档位 i（M0..M6，见 gen_stim_top_full.py 的 MODE_SCHED）——
    M6 是 2026-09-17 新增档位，它必须有一整帧"带运动"的激励，小尺寸的红块
    逐帧右移 5 列 ⇒ 每帧都有运动格子（见 sim/_m6_probe.py 实测）。
    小尺寸仍满足：>= 4 帧（判据 E/G 需要多帧与 M3 帧）、>= 64 行（掩蔽要 y>=2、
    3x3 窗口要 3 行缓存）、7 档全走到、行+帧消隐都在。
    ⚠ 小尺寸只用来证明"checker 会报错"，**不能**当成功能验证结论。
  · `1280x720`：正式尺寸，一轮约 2.5 分钟/条；只用来复核小尺寸漏抓的变异。
    ⚠ 该尺寸的档位时序保持既有 12 帧不变（含帧内换档与按键路径），
      所以全尺寸跑里**没有 M6 帧**（M6 覆盖在小尺寸 7 帧里，见上）。

防空转（历史事故：变异正则命中注释行 / 替换是空操作 / 基线本来就红）：
    · 基线必须先全绿，否则直接退出（基线红时"任何变异都被抓住"毫无意义）；
    · 每条变异都要求替换原文命中**非注释代码**（去掉 // 注释后仍能匹配），
      且改完后文件字节确实变了；
    · 每条变异都实测【变异后 dump 与基线 dump 逐字节不同】，相同 = 空操作 = 判漏掉。

用法：
    python mutate_alg_top_full.py --size 160x64          # 小尺寸跑全部（默认）
    python mutate_alg_top_full.py --size 1280x720        # 全尺寸（慢）
    python mutate_alg_top_full.py --size 160x64 --only 2 # 冒烟
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "src"))
WORK = os.path.join(HERE, "_mut_full")
MS = r"D:\modelsim\modelsim_ase\win32aloem"

# ⚠ 必须在 import check_alg_top_full **之前**把尺寸塞进环境变量：
#   gen_stim_top_full / check_alg_top_full 都是在 import 时按 ALG_W/ALG_H 定几何的。
_SIZE = "160x64"
if "--size" in sys.argv:
    _SIZE = sys.argv[sys.argv.index("--size") + 1]
_W, _H = (int(x) for x in _SIZE.split("x"))
os.environ["ALG_W"], os.environ["ALG_H"] = str(_W), str(_H)

sys.path.insert(0, HERE)
from check_alg_top_full import (         # noqa: E402
    parse, run_all, expected_frames, W as CHK_W, H as CHK_H,
)
assert (CHK_W, CHK_H) == (_W, _H), \
    "checker 几何 (%d,%d) 与 --size %s 不一致（环境变量没生效）" % (CHK_W, CHK_H, _SIZE)

RTLS = ["gray_bt601_96.v", "win3x3_96.v", "alg_binarize_96.v", "alg_sobel_96.v",
        "alg_smooth_96.v", "alg_color_detect_96.v", "alg_framediff_96.v",
        "alg_region_fill_96.v",
        "rgb_row_delay_96.v", "alg_top.v"]

# (说明, 期望抓哪条判据, [(文件, 原文, 替换), ...])
MUTS = [
    # ---- 延迟/对齐（判据 K = M0 逐周期直通；判据 J = tlast/tuser 位置）----
    ("M0 对齐 4 拍 -> 3 拍（全链延迟变 4）", "K",
     [("alg_top.v", "wire [95:0] w_a0_dat = r_m0_dat[3];",
       "wire [95:0] w_a0_dat = r_m0_dat[2];"),
      ("alg_top.v", "wire [2:0]  w_a0_ctl = r_m0_ctl[3];",
       "wire [2:0]  w_a0_ctl = r_m0_ctl[2];")]),
    ("tlast/tuser 打包接反（O_tlast 位置全错）", "J",
     [("alg_top.v", "r_m0_ctl[0] <= {I_tvalid, I_tlast, I_tuser};",
       "r_m0_ctl[0] <= {I_tvalid, I_tuser, I_tlast};")]),
    # ---- M1/M5 补拍（判据 B）----
    ("M1 补拍 3 拍 -> 2 拍", "B",
     [("alg_top.v", "wire [95:0] w_a1_dat = r_m1_dat[2];",
       "wire [95:0] w_a1_dat = r_m1_dat[1];"),
      ("alg_top.v", "wire [2:0]  w_a1_ctl = r_m1_ctl[2];",
       "wire [2:0]  w_a1_ctl = r_m1_ctl[1];")]),
    ("M5 补拍 2 拍 -> 1 拍", "B",
     [("alg_top.v", "wire [95:0] w_a5_dat = r_m5_dat[1];",
       "wire [95:0] w_a5_dat = r_m5_dat[0];"),
      ("alg_top.v", "wire [2:0]  w_a5_ctl = r_m5_ctl[1];",
       "wire [2:0]  w_a5_ctl = r_m5_ctl[0];")]),
    # ---- 掩蔽（判据 C）----
    # ⚠ 2026-09-18：`w_masked_dat` 改成"M7 例外"的三目之后，下面两条的**原文**跟着改
    #   （只改被替换的那段三目子表达式；变异语义与之前一字不差：取反 / 换成灰度流）。
    ("掩蔽取反（mask ? mux : 原图 -> 反过来）", "C",
     [("alg_top.v",
       "                             : (r_mask_d ? w_mux_dat : w_a0_dat);",
       "                             : (r_mask_d ? w_a0_dat : w_mux_dat);")]),
    ("掩蔽期'原图'改成喂灰度流 w_w_dat", "C",
     [("alg_top.v",
       "                             : (r_mask_d ? w_mux_dat : w_a0_dat);",
       "                             : (r_mask_d ? w_mux_dat : w_w_dat);")]),
    ("掩蔽条件去掉 'y>=2'（前两行也走算法）", "C",
     [("win3x3_96.v", "wire w_window_valid = (r_y >= 11'd2) && (r_x != 11'd0) && (!r_tuser);",
       "wire w_window_valid = (r_y >= 11'd0) && (r_x != 11'd0) && (!r_tuser);")]),
    ("掩蔽条件去掉 'x != 0'（每行第 0 拍也走算法）", "C",
     [("win3x3_96.v", "wire w_window_valid = (r_y >= 11'd2) && (r_x != 11'd0) && (!r_tuser);",
       "wire w_window_valid = (r_y >= 11'd2) && (!r_tuser);")]),
    # ---- 帧边界 / 档位（判据 D）----
    # ⚠ 2026-09-18：换档条件被抽成 w_mode_sw（M7 要提前 1 拍），原文随之改；
    #   变异语义不变 = "按输入的 I_tuser 早 4 拍换档"。
    ("档位锁存改用输入 I_tuser（早 4 拍换档）", "D",
     [("alg_top.v", "else if (w_mode_sw)",
       "else if (w_a0_ctl[2] && I_tuser)")]),
    # ---- 全行宽（320 拍/行）才暴露的寻址（判据 B）----
    ("行缓存深度 320 -> 8（把小图尺寸混进全尺寸）", "B",
     [("win3x3_96.v", "localparam BEATS_PER_LINE = IMG_WIDTH >> 2;",
       "localparam BEATS_PER_LINE = 8;")]),
    ("行内拍号回绕点 319 -> 318（行内计数错 1 拍）", "B",
     [("win3x3_96.v", "localparam [XW-1:0] LAST_BEAT = BEATS_PER_LINE - 1;",
       "localparam [XW-1:0] LAST_BEAT = BEATS_PER_LINE - 2;")]),
    ("行缓存读地址 x_grp+1 -> x_grp+2（横向邻居错位）", "B",
     [("win3x3_96.v",
       "wire [XW-1:0] w_rd_addr = (r_x_grp == LAST_BEAT) ? {XW{1'b0}} : (r_x_grp + 1'b1);",
       "wire [XW-1:0] w_rd_addr = (r_x_grp == LAST_BEAT) ? {XW{1'b0}} : (r_x_grp + 2'd2);")]),
    ("M3 提亮增量 K 128 -> 64", "B",
     [("alg_top.v", "parameter [8:0]   EDGE_K   = 9'd128,",
       "parameter [8:0]   EDGE_K   = 9'd64,")]),
    ("M5 画框改用本帧 bbox（而不是上一帧）", "B",
     [("alg_color_detect_96.v", "wire w_frame_start = r_vld1 && r_tu_d1;",
       "wire w_frame_start = 1'b0;")]),
    ("窗口拍号计数器不再按 I_tvalid 门控（停顿会错位）", "B",
     [("win3x3_96.v", "    end else if (I_tvalid) begin\n        if (I_tuser) begin",
       "    end else if (1'b1) begin\n        if (I_tuser) begin")]),
    # ---- M3 的 src 行（判据 E，需要 >= 4 帧）----
    ("u_rgb3 改喂 w_w_dat（灰度，规格记的坑）", "E",
     [("alg_top.v", "            r_rgb3_dat[0] <= I_tdata;",
       "            r_rgb3_dat[0] <= w_w_dat;")]),
    ("行延迟阵列读地址 +2 -> +1（M3 的 src 错一拍）", "E",
     [("rgb_row_delay_96.v",
       "wire [XW-1:0] w_rd_addr = (r_x_grp <= RD_NO_WRAP) ? (r_x_grp + 2'd2)",
       "wire [XW-1:0] w_rd_addr = (r_x_grp <= RD_NO_WRAP) ? (r_x_grp + 2'd1)")]),
    # ---- M6 帧差运动检测（2026-09-17 新增；判据 L = M6 对齐/拍数/非空，B/G = 像素与统计）----
    ("M6 上一帧存储器从不写入（prev 恒 X/0）", "B",
     [("alg_framediff_96.v", "    if (r_wr_en)\n        r_prev_mem[r_wr_addr] <= r_cur;",
       "    if (1'b0)\n        r_prev_mem[r_wr_addr] <= r_cur;")]),
    ("M6 上一帧读值恒 0（差分退化成灰度本身）", "B",
     [("alg_framediff_96.v", "        r_prev <= r_prev_mem[w_smp_addr];",
       "        r_prev <= 8'd0;")]),
    ("M6 差分不取绝对值（只认变亮方向）", "B",
     [("alg_framediff_96.v",
       "wire [7:0] w_diff   = (r_cur >= r_prev) ? (r_cur - r_prev) : (r_prev - r_cur);",
       "wire [7:0] w_diff   = (r_cur >= r_prev) ? (r_cur - r_prev) : 8'd0;")]),
    ("M6 阈值比较取反（diff < TH 算运动）", "B",
     [("alg_framediff_96.v", "wire       w_motion = r_mem_full && (w_diff > DIFF_TH);",
       "wire       w_motion = r_mem_full && (w_diff < DIFF_TH);")]),
    ("M6 采样行基址不递增（每行都写第 0 行）", "B",
     [("alg_framediff_96.v",
       ": (w_smp_row_start ? (r_row_base + CX_AW) : r_row_base);",
       ": (w_smp_row_start ? r_row_base : r_row_base);")]),
    ("M6 格子计数器不按 tuser 复位（行基址也不归零）", "B",
     [("alg_framediff_96.v",
       "        if (I_tuser) begin",
       "        if (1'b0)       begin"),
      ("alg_framediff_96.v",
       "wire [AW-1:0] w_row_base = I_tuser ? {AW{1'b0}}",
       "wire [AW-1:0] w_row_base = 1'b0 ? {AW{1'b0}}")]),
    ("M6 bbox 用格子坐标当像素坐标（不乘 8）", "B",
     [("alg_framediff_96.v", "        r_smp_x <= {r_x_grp, 2'b00};",
       "        r_smp_x <= {{(11-XW){1'b0}}, r_x_grp};")]),
    ("M6 帧边界不锁存运动统计（bbox/计数永不更新）", "G",
     [("alg_framediff_96.v", "    else if (w_frame_start)\n        O_motion_cnt <= r_cnt;",
       "    else if (1'b0)\n        O_motion_cnt <= r_cnt;"),
      ("alg_framediff_96.v", "    else if (w_frame_start)\n        O_motion_bbox_x0 <= r_min_x;",
       "    else if (1'b0)\n        O_motion_bbox_x0 <= r_min_x;"),
      ("alg_framediff_96.v", "    else if (w_frame_start)\n        O_motion_bbox_y1 <= r_max_y;",
       "    else if (1'b0)\n        O_motion_bbox_y1 <= r_max_y;")]),
    ("M6 运动格子不累加（O_frame_motion_cnt 恒 0）", "G",
     [("alg_framediff_96.v", "    else if (r_smp_d1 && w_motion)\n        r_cnt <= r_cnt + 32'd1;",
       "    else if (1'b0)\n        r_cnt <= r_cnt + 32'd1;")]),
    ("M6 白点涂到整拍 4 个像素（不是 pix0）", "B",
     [("alg_top.v", "            wire w_m6_wht = r_m6_mot && (g6 == 0);",
       "            wire w_m6_wht = r_m6_mot;")]),
    ("M6 红框画成实心矩形（不是 1 像素边框）", "B",
     [("alg_top.v",
       "            wire w_m6_on_row = ((r_m6_y_d[3] == r_bb_y0) || (r_m6_y_d[3] == r_bb_y1))",
       "            wire w_m6_on_row = (1'b1)")]),
    ("M6 白点通路断开（运动点不叠加）", "B",
     [("alg_top.v", "            r_m6_mot <= w_mot_pix0;",
       "            r_m6_mot <= 1'b0;")]),
    ("M6 白点用未补拍的运动点（早 1 拍）", "B",
     [("alg_top.v", "            wire w_m6_wht = r_m6_mot && (g6 == 0);",
       "            wire w_m6_wht = w_mot_pix0 && (g6 == 0);")]),
    # ---- M7 区域填充（2026-09-18 新增）----
    #   任务书点名要的 5 类：① 阈值明显不对（两种失败形态都造）② 接错支路（吃实心图）
    #   ③ 按键上限没改到 M7 ④ 输出 mux 漏掉 M7 一支 ⑤ 档位常量写成别的值。
    #   另加 3 条钉本次实测定位的两个坑（输入可信范围掩蔽 / 进 M7 提前换档 / 不叠顶层掩蔽）。
    ("M7 阈值 128 -> 255（三字节全 0xFF，填不出东西）", "B",
     [("alg_top.v", "    parameter [7:0]   RF_TH    = 8'd128,",
       "    parameter [7:0]   RF_TH    = 8'd255,")]),
    ("M7 阈值 128 -> 8（大片误判成白，近似全屏填满）", "B",
     [("alg_top.v", "    parameter [7:0]   RF_TH    = 8'd128,",
       "    parameter [7:0]   RF_TH    = 8'd8,")]),
    ("M7 填充模块改吃**二值化支路**（实心图，接错支路）", "B",
     [("alg_top.v", "        .I_tdata  (w_rf_bin), .I_tvalid (w_s_val),",
       "        .I_tdata  (w_b_dat),  .I_tvalid (w_s_val),")]),
    ("M7 填充模块吃未阈值化的提亮彩图（不二值化）", "B",
     [("alg_top.v", "        .I_tdata  (w_rf_bin), .I_tvalid (w_s_val),",
       "        .I_tdata  (w_s_dat),  .I_tvalid (w_s_val),")]),
    ("按键循环上限只到 M6（M7 永远切不到）", "D",
     [("alg_top.v",
       "            r_mode_hold <= (r_mode_hold == MODE_REGIONFILL) ? MODE_RAW : (r_mode_hold + 3'd1);",
       "            r_mode_hold <= (r_mode_hold == MODE_MOTION) ? MODE_RAW : (r_mode_hold + 3'd1);")]),
    ("输出 mux 漏掉 M7 一支（回落到 default 直通）", "B",
     [("alg_top.v",
       "            MODE_REGIONFILL : begin w_mux_dat = w_rf_dat;\n"
       "                                    w_mux_ctl = {w_rf_val, w_rf_lst, w_rf_usr}; end\n",
       "            // MUT: M7 分支从 mux 里删掉（落到 default 直通）\n")]),
    ("档位常量 M7 写成 3'd6（与 MODE_MOTION 撞号）", "D",
     [("alg_top.v", "    localparam [2:0] MODE_REGIONFILL = 3'd7;",
       "    localparam [2:0] MODE_REGIONFILL = 3'd6;")]),
    ("M7 输入不与 r_mask_d 相与（第 0 拍未定义值漏进膨胀）", "B",
     [("alg_top.v", "            wire w_rf_wht = r_mask_d && (w_rf_src[23:16] >= RF_TH) &&",
       "            wire w_rf_wht = (w_rf_src[23:16] >= RF_TH) &&")]),
    ("切进 M7 不提前 1 拍换档（边界多吐 1 拍）", "A",
     [("alg_top.v",
       "    wire w_mode_sw = w_sof_a0 || (w_sof_pre && (w_mode_nx == MODE_REGIONFILL));",
       "    wire w_mode_sw = w_sof_a0;")]),
    ("M7 也叠顶层掩蔽（掩蔽区整体挪 3 拍）", "B",
     [("alg_top.v",
       "    wire [95:0] w_masked_dat = (r_mode == MODE_REGIONFILL) ? w_mux_dat\n"
       "                             : (r_mask_d ? w_mux_dat : w_a0_dat);",
       "    wire [95:0] w_masked_dat = (r_mask_d ? w_mux_dat : w_a0_dat);")]),
]

CKEY = {"A": "A 延迟5拍", "B": "B 七档对金标准", "C": "C 掩蔽区=原图",
        "D": "D 档位锁存", "E": "E M3的src行", "J": "J 每行/每帧拍数",
        "K": "K M0直通=LAT拍", "G": "G bbox(按档选族)", "L": "L M6对齐/拍数/非空",
        "F": "F X/Z泄漏"}


def run(cmd, cwd):
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    return p.returncode, (p.stdout or "") + (p.stderr or "")


SIZE = _SIZE             # 变异自证默认小尺寸；正式尺寸用 --size 1280x720
FRAMES = 8               # 8 帧 = MODE_SCHED[0..7] 恰好走完 M0..M7（2026-09-18 起 M7）


def setup():
    if os.path.isdir(WORK):
        shutil.rmtree(WORK)
    os.makedirs(WORK)
    for f in RTLS:
        shutil.copy(os.path.join(SRC, f), os.path.join(WORK, f))
    shutil.copy(os.path.join(HERE, "tb_alg_top_full.v"), os.path.join(WORK, "tb_alg_top_full.v"))
    # 尺寸对应的激励：由 gen_stim_top_full.py 在 ALG_W/ALG_H 环境变量下生成
    w, h = (int(x) for x in SIZE.split("x"))
    hexname = "stim_top_full.hex" if (w, h) == (1280, 720) else "stim_top_%dx%d.hex" % (w, h)
    src = os.path.join(HERE, hexname)
    if not os.path.isfile(src):
        print("  !! 找不到激励 %s —— 先用 ALG_W=%d ALG_H=%d 跑 gen_stim_top_full.py"
              % (hexname, w, h))
        raise SystemExit(2)
    # TB 固定读 stim_top_full.hex；checker 在 dump 同目录找 hexname ⇒ 两个名字都放
    shutil.copy(src, os.path.join(WORK, "stim_top_full.hex"))
    if hexname != "stim_top_full.hex":
        shutil.copy(src, os.path.join(WORK, hexname))


def build_and_run(frames):
    w, h = (int(x) for x in SIZE.split("x"))
    rc, out = run([os.path.join(MS, "vlib.exe"), "work"], WORK)
    if rc != 0:
        return False, out
    defines = []
    if (w, h) != (1280, 720):
        defines = ["+define+ALG_IMG_W=%d" % w, "+define+ALG_IMG_H=%d" % h]
    rc, out = run([os.path.join(MS, "vlog.exe"), "-work", "work"] + defines + RTLS
                  + ["tb_alg_top_full.v"], WORK)
    if rc != 0 or "Errors: 0" not in out:
        return False, out
    dump = os.path.join(WORK, "dump_top_full.txt")
    if os.path.isfile(dump):
        os.remove(dump)
    rc, out = run([os.path.join(MS, "vsim.exe"), "-c", "-lib", "work", "tb_alg_top_full",
                   "-do", "run -all; quit -f", "+frames=%d" % frames], WORK)
    ok = os.path.isfile(dump) and "TB: done" in out
    return ok, out


def judge(dump, frames):
    """用**与正式校验同一套判据**给 dump 打红/绿。"""
    d = parse(dump, quiet=True)
    exp_img, exp_pack, bb = expected_frames(frames, None)
    c, _f = run_all(d, frames, exp_img, exp_pack, bb, None, verbose=False)
    return {k: v[1] for k, v in c.items()}, d["ncycles"]


def strip_comments(txt):
    return re.sub(r"//[^\n]*", "", txt)


def main():
    global SIZE
    frames = FRAMES
    if "--frames" in sys.argv:
        frames = int(sys.argv[sys.argv.index("--frames") + 1])
    if "--size" in sys.argv:
        SIZE = sys.argv[sys.argv.index("--size") + 1]
    muts = MUTS
    if "--only" in sys.argv:                 # 冒烟用：只跑前 N 条变异
        muts = MUTS[:int(sys.argv[sys.argv.index("--only") + 1])]
    t0 = time.time()
    print("=" * 88)
    print("真 RTL 变异自证：改错 RTL -> 重编译重仿真 -> 指定判据必须报红   size=%s frames=%d"
          % (SIZE, frames))
    print("=" * 88, flush=True)
    setup()
    ok, out = build_and_run(frames)
    if not ok:
        print("基线编译/仿真失败：\n" + out[-3000:])
        return 2
    base_dump = os.path.join(WORK, "dump_top_full.txt")
    base_bytes = open(base_dump, "rb").read()
    bad, ncyc = judge(base_dump, frames)
    red = {k: v for k, v in bad.items() if v}
    print("  基线（未变异）  dump %d 拍 / %d 字节  报错判据：%s  %s"
          % (ncyc, len(base_bytes), red if red else "无",
             "PASS" if not red else "!! 基线就不对，先查基线"), flush=True)
    if red:
        return 2

    caught = 0
    for name, who, subs in muts:
        setup()
        hit = True
        touched = []
        for fn, a, b in subs:
            p = os.path.join(WORK, fn)
            txt = open(p, encoding="utf-8").read()
            if a not in txt:
                print("  %-44s !! 替换原文没找到 -> 变异未生效 -> 算漏掉" % name, flush=True)
                hit = False
                break
            (code_only,) = (strip_comments(txt),)
            if a not in code_only:
                print("  %-44s !! 原文只出现在注释里 -> 变异是空操作 -> 算漏掉" % name,
                      flush=True)
                hit = False
                break
            new = txt.replace(a, b, 1)
            if new == txt:
                print("  %-44s !! 替换后文件未变 -> 算漏掉" % name, flush=True)
                hit = False
                break
            open(p, "w", encoding="utf-8", newline="").write(new)
            if fn not in touched:
                touched.append(fn)
        if not hit:
            continue
        ok, out = build_and_run(frames)
        if not ok:
            print("  %-44s 编译/仿真失败（%s）—— 算抓住" % (name, ",".join(touched)), flush=True)
            caught += 1
            continue
        mut_bytes = open(os.path.join(WORK, "dump_top_full.txt"), "rb").read()
        if mut_bytes == base_bytes:
            print("  %-44s !! 空操作变异：dump 与基线逐字节相同 -> 算漏掉 !!" % name, flush=True)
            continue
        bad, _n = judge(os.path.join(WORK, "dump_top_full.txt"), frames)
        red = {k: v for k, v in bad.items() if v}
        good = bad.get(CKEY[who], 0) > 0
        caught += 1 if good else 0
        print("  %-44s 改 %-22s dump %9d->%9d B  报红: %-40s %s"
              % (name, ",".join(touched), len(base_bytes), len(mut_bytes),
                 ",".join("%s(%d)" % (k.split()[0], v) for k, v in red.items()) if red else "无",
                 "抓住" if good else "!! 漏掉 !!"), flush=True)
    print("-" * 88)
    print("  全尺寸真 RTL 变异鉴别力：%d/%d  -> %s   （总耗时 %.0f s）"
          % (caught, len(muts), "PASS" if caught == len(muts) else "FAIL", time.time() - t0))
    print("=" * 88)
    return 0 if caught == len(muts) else 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
gen_stim_top_full.py —— `alg_top` **全尺寸 1280x720** 集成验证的
                        图像 / 档位时序 / 激励 唯一定义源

与 gen_stim_top.py 的关系（这是"扩展"，不是"另起炉灶"）：
  · 几何、档位时序、位序、颜色框、EDGE_K、BLANK_LEN 全部沿用 gen_stim_top.py 的约定；
  · 图像生成按 (H/8, W/32) 整数倍**平铺**小图图案 —— 1280x720 = 32x8 的 40x90 倍，
    所以小图的每一个结构性特征（平坦段/硬边/棋盘/强梯度/行号唯一编码）在全尺寸里
    逐点保留，只是重复 3600 次。参考模型对两者的处理是同一套 numpy 代码。
  · 红块（M5 目标）**按比例放大**成 180 行 x 160 列，这样 bbox 统计在 1280x720 下
    仍然有非平凡的数值（小图的 4x8 红块放大后 bbox=(c0,300,c1,479)）。

⚠ 这一维度上真正新增的覆盖（小图 32x8 / BPL=8 **根本碰不到**的）：
  · 行缓存寻址：win3x3_96 / rgb_row_delay_96 的 320 深阵列、
    读地址 x_grp+1 / x_grp+2 的取模回绕（LAST_BEAT=319、RD_NO_WRAP=317）；
  · 行内拍号 XW=9 位计数器的整行回绕（小图 BPL=8 时只需 3 位）；
  · 行首/行尾边界：列 1279 的右邻居(列 1280)补 0、列 0 的左邻居补 0；
  · 掩蔽的第 0 拍只屏蔽 4 个像素（不是 1/4 行）；
  · 单帧 230400 拍 = 250 万级拍序上的帧边界与帧消隐。

输出：stim_top_full.hex（每行 24 个十六进制字符 = 1 个 96bit 彩色拍，共 NBEAT 行）

用法：
    python gen_stim_top_full.py                 # 默认 FRAMES_ALL=12 帧
    python gen_stim_top_full.py --frames 2      # 只写前 2 帧（冒烟/快速回归）
"""
from __future__ import annotations

import os
import sys

sys.stdout.reconfigure(encoding="utf-8")

# ---- 金标准 alg_ref.py 的位置（可用环境变量 ALG_REF_DIR 覆盖）----
for _d in (os.environ.get("ALG_REF_DIR", ""),
           r"C:\Users\29072\PycharmProjects\PythonProject8",
           os.path.dirname(os.path.abspath(__file__))):
    if _d and os.path.isfile(os.path.join(_d, "alg_ref.py")):
        if _d not in sys.path:
            sys.path.insert(0, _d)
        break
else:  # pragma: no cover
    raise SystemExit("找不到 alg_ref.py，请设 ALG_REF_DIR 指向金标准所在目录")

import numpy as np       # noqa: E402
import alg_ref as A      # noqa: E402

# 小图定义源：图案与颜色框**只在这里定义一次**，全尺寸复用（避免两处各写一遍）
from gen_stim_top import (   # noqa: E402
    COL_G, COL_B, build_image as build_image_small, W as W_SMALL, H as H_SMALL,
    MODE_SCHED as MODE_SCHED_SMALL, MODE_SET_SCHED as MODE_SET_SCHED_SMALL,
)

# ---------------------------------------------------------------------------
# DUT 参数（必须与 tb_alg_top_full.v 的 alg_top 例化 + alg_ref.target_hit 一致）
#
#   ⚠⚠ 这里**不能**照抄小图 gen_stim_top.py 的 `TGT_COLOR = 0xFF0000`，也不能照抄
#      它算出来的 RLO/GLO/BLO。原因（实测踩到过）：
#        · alg_top.v 的默认参数是 `TGT_COLOR = 24'hFF0000` = **(R=255,G=0,B=0) 纯红**；
#          而 gen_stim_top.py 写的 `0xFF0000` 是 **(R=0,G=0,B=255) 纯蓝** —— 两者不是
#          同一个颜色。小图能过，是因为 alg_top **没有覆盖** TGT_COLOR，金标准
#          AlgPipeline 用的也是自己的默认框，两边"碰巧一致"，而 gen_stim_top.py
#          打印出来的 R[215,295] G[-40,40] B[-40,40] 从来没参与过判定。
#        · RTL 的判色是 |c - tgt| <= tol（对称容差），alg_ref.target_hit 是
#          `rlo <= c <= rhi`（钳位框）；两者等价 ⟺ 框 = [clamp(c-tol,0,255),
#          clamp(c+tol,0,255)]。RTL 端 tol=40 会**单独**作用于每个通道。
#      所以本文件把真值写对：目标色 = alg_top 默认的 24'hFF0000，容差 40，
#      框 = R[215,255] G[0,40] B[0,40]。
#      红块用 (R=255, G=块内行号 0..40, B=12) ⇒ 同时满足三个通道且逐行唯一。
# ---------------------------------------------------------------------------
TGT_COLOR = 0xFF0000
TGT_TOL = 40


def _box(c, tol):
    return max(0, c - tol), min(255, c + tol)


RLO, RHI = _box((TGT_COLOR >> 16) & 0xFF, TGT_TOL)   # 215, 255
GLO, GHI = _box((TGT_COLOR >> 8) & 0xFF, TGT_TOL)    # 0, 40
BLO, BHI = _box(TGT_COLOR & 0xFF, TGT_TOL)           # 0, 40
EDGE_K = 128
C_OFF = 0

# ---------------------------------------------------------------------------
# 几何（必须与 tb_alg_top_full.v 的 localparam 一致）
#
# ⚠ 可用环境变量改尺寸：ALG_W / ALG_H（TB 侧用 vlog +define+ALG_IMG_W/ALG_IMG_H）。
#   小尺寸的唯一用途是**变异自证**：证明 checker 改坏 RTL 会报错。
#   正式验证一律 1280x720（默认值），产物文件名也随尺寸区分，互不覆盖。
# ---------------------------------------------------------------------------
W = int(os.environ.get("ALG_W", "1280"))
H = int(os.environ.get("ALG_H", "720"))
BPL = W // 4                 # 1280 -> 320 拍/行
FRAMES_ALL = 12              # 最大帧数（档位时序表长度）
BPF = BPL * H                # 1280x720 -> 230400 拍/帧
NBEAT_ALL = BPF * FRAMES_ALL
HEX_NAME = "stim_top_full.hex" if (W, H) == (1280, 720) \
    else "stim_top_%dx%d.hex" % (W, H)

# ---------------------------------------------------------------------------
# M6（帧差运动检测）几何与阈值 —— 判定侧（check_alg_top_full.py）的黄金模型
# 与这里**同源**取参，避免"RTL 参数改了、判据没跟着改"这种假绿。
#   DS：8x8 降采样；采样点 = (x=8*cx, y=8*cy)，cx∈[0,CX)、cy∈[0,CY)
#   M6_DIFF_TH：与 alg_top 例化 alg_framediff_96 的 DIFF_TH 默认值一致（严格大于）
# ---------------------------------------------------------------------------
DS = 8
CX = W // DS
CY = H // DS
M6_DIFF_TH = 24

# ---------------------------------------------------------------------------
# M7（区域填充）输入硬阈值 —— 三处写死同一份（RTL alg_top.v 的 parameter RF_TH、
# 这里的 RF_TH、判定侧 check_alg_top_full.py 的 m7_frame）：
#     白 ⟺ 三个字节都 >= RF_TH（默认 128），其余一律黑。
# ⚠ 默认值 128 是**实测**选的（sim/_m7_thresh_probe.py）：
#   · 提亮后边缘像素 out_min = min(min(src)+EDGE_K,255) 恒 >= 128
#     ⇒ 阈值 <= 128 时一个真边缘都不漏（取 129 时 1280x720 第 0 帧漏 28575 个）；
#   · 非边缘像素 out = src 原样，实测 min(R,G,B) 最大 12（160x64）/120（1280x720）
#     ⇒ 取 128 时一个非边缘像素都不会误判成白。
#   于是"三字节都 >= 128"在**本套激励**上逐像素等价于 Sobel 的 edge 掩码。
# ⚠ 与 alg_top 的 EDGE_K 是一对：改 K 必须复核 RF_TH（见 alg_top.v §四·补2）。
# ---------------------------------------------------------------------------
RF_TH = 128
assert W % W_SMALL == 0 and W >= 2 * W_SMALL, "W 必须是 %d 的整数倍且 >= %d" % (W_SMALL,
                                                                               2 * W_SMALL)
assert H % H_SMALL == 0 and H >= 8 * H_SMALL, "H 必须是 %d 的整数倍且 >= %d" % (H_SMALL,
                                                                                8 * H_SMALL)

# ---------------------------------------------------------------------------
# 档位时序（长度必须 == FRAMES_ALL）
#
# 【正式尺寸 1280x720】：与小图 gen_stim_top.py 前 10 帧逐项相同 + 尾巴 [2, 2]
#   frame 0..5 : 六档各一帧（M0..M5），每个帧边界换档
#   frame 6    : 帧内 bif=24 处把 I_mode_sel 从 3 改成 5 —— 本帧必须仍是 M3
#   frame 7    : M5（承接上一条：换档只发生在帧边界）
#   frame 8/9  : I_mode_set=0，靠按键脉冲走 r_mode_hold（帧 8 内按一下 -> 1；帧 9 内再按 -> 2）
#   frame 10   : M2（hold 停在 2，不再按键）
#   frame 11   : M2（同上；红块继续右移 -> bbox 每帧都在变，判据 G 有鉴别力）
#   ⚠ 2026-09-24 更正：本段原写 "尾巴 [5, 0]"、"frame 10 = M5"、"frame 11 = M0"，
#     **三处都错**。原因是 TB 的按键路径从来没工作过（`bil_k` 恒 0），
#     旧表是照"设计意图"猜的、不是照实测。现在表与实测一致（12 帧全尺寸已复跑核对）。
#   ⚠ **帧结构（帧数/画幅/红块位置）一个字节都不许动** —— 它对应磁盘上已生成的
#     stim_top_full.hex（1280x720 / 12 帧 / 65.9MB）。**动档位表不受此限**
#     （hex 里只有像素，档位由 TB 实时驱动）。
#
# 【小尺寸（变异自证用，2026-09-17 M6 起 / 2026-09-18 扩到 M7）】：frame i 用档位 i
#   frame 0..6 : M0..M6 各一帧（I_mode_set 恒 1、档位恒定，无帧内换档）
#   frame 7    : **M7 走按键路径**（I_mode_set=1→0；frame 6 内按 7 下键 ⇒ r_mode_hold=7）
#   frame 8..11: 继续 M7（只跑 7/8 帧时用不到）
#   为什么小尺寸要换一套：M6/M7 是新增档位，小尺寸是变异自证的唯一几何，
#   必须让它们各有一整帧激励（160x64 的红块逐帧右移 5 列 ⇒ 逐帧都有运动格子，
#   见 sim/_m6_probe.py 的实测）。而 1280x720 那套时序里第 6 帧要测"帧内换档"，
#   不能改成 M6/M7。
#   ⚠ 2026-09-18：frame 7 特意**不用** I_mode_sel 强制指定，而是让按键循环去走 ——
#     因为"按键循环上限改到 M7"这条 RTL 改动只有这样才被激励到。若上限忘了改，
#     frame 7 会停在 M0（实测 hold 7 下按 7 下 = 0），判据 D/B 立刻报红。
#   激励文件（stim_top_160x64.hex）与档位无关（hex 里只有像素），所以**不用重新生成**。
# ---------------------------------------------------------------------------
_SMALL_GEOM = (W, H) != (1280, 720)
if _SMALL_GEOM:
    MODE_SCHED = [0, 1, 2, 3, 4, 5, 6, 7] + [7] * (FRAMES_ALL - 8)
    MODE_SET_SCHED = [1] * 7 + [0] * (FRAMES_ALL - 7)
else:
    # ⚠ 2026-09-24 修正尾巴：原为 [5, 0]，**两项都错**，应为 [2, 2]。
    #
    #   依据（12 帧全尺寸实测 + RTL 逻辑）：TB 的按键路径原来根本发不出脉冲
    #   （`bil_k = bil/BPL` 恒 0，见 tb_alg_top_full.v:174 附近的注释），
    #   修好之后的真实轨迹是：
    #
    #     帧 6  : I_mode_sel 帧中 3->5，但本帧标称仍是 3        -> M3
    #     帧 7  : I_mode_sel = 5（mset 仍为 1）                  -> M5
    #     帧 8  : mset=0，进入按键路径；帧内按一下 hold 0->1      -> M1
    #     帧 9  : 帧内再按一下 hold 1->2                         -> M2
    #     帧 10 : 不再按键，hold 停在 2                          -> M2   （原写 5，错）
    #     帧 11 : 同样不再按键，hold 仍是 2                      -> M2   （原写 0，错）
    #
    #   为什么帧 10/11 不会"回到 M0"：`r_mode_hold` 只在按键脉冲上递增/回绕
    #   （alg_top.v:792 `r_mode_hold <= (r_mode_hold == MODE_REGIONFILL) ? MODE_RAW : +1`），
    #   **没有任何"自动回 0"的逻辑**。旧注释里"frame 11 回到 M0"是旧设计残留。
    #   TB 侧 frame 10/11 的 `drv_msel` 是 don't-care（mset=0 时根本不看它）。
    #
    #   ⚠ 改本表**不影响** stim_top_full.hex —— hex 里只有像素，
    #     档位是 TB 实时驱动的（drv_msel/drv_mset/drv_key）。已核：
    #     MODE_SCHED 只用于打印与 +m67/+m7out 分支，不参与 stim_beats()。
    MODE_SCHED = list(MODE_SCHED_SMALL) + [2, 2]
    MODE_SET_SCHED = list(MODE_SET_SCHED_SMALL) + [0, 0]
assert len(MODE_SCHED) == FRAMES_ALL, len(MODE_SCHED)
assert len(MODE_SET_SCHED) == FRAMES_ALL, len(MODE_SET_SCHED)

# ---------------------------------------------------------------------------
# 2026-09-20：全尺寸 M6/M7 专项跑 —— **不动上面那张冻结表**，只加一个开关。
#
#   背景：1280x720 那套冻结时序里 f0..f5 是 M0..M5、f6 要测"帧内换档"，
#   所以 M6/M7 至今**只在小图 160x64 上验过**，全尺寸是空白。
#
#   ALG_MSCHED=m67 ⇒ 前 4 帧 = [M0, M1, M6, M7]、I_mode_set 恒 1（走 I_mode_sel，不靠按键）。
#     · f0 = M0：给 M6 当参考帧（M6 内部参考的是**原图的灰度**，与 f0 显示哪一档无关），
#       同时让判据 K（M0 直通 = LAT 拍）有帧可跑。
#     · f1 = M1：**M6 不能排在第 1 帧**（第一版排成 [M0, M6, M7] 实测判据 L 报红）。
#       判据 L 原文 check_alg_top_full.py:1187 是
#           box_nonempty = (mb[fr-1] is not None)
#       即"M6 帧显示的红框 = **上一帧**的运动框"。而第 0 帧的运动图恒为全 0，
#       所以 M6 落在第 1 帧时红框必然为空 —— 那是**正常行为**，不是 RTL bug。
#       ⇒ M6 必须 ≥ 第 2 帧，前一帧随便哪一档都行（M1 只是顺手的垫帧）。
#     · f2 = M6、f3 = M7。
#     · 三方必须一致：本表的 MODE_SCHED / tb_alg_top_full.v 的 `+m67` 表 /
#       check_alg_top_full.py（它 import 本文件）。不一致时判据 D 会立刻报红。
#
#   为什么不用重新生成激励：hex 里只有像素、与档位无关（同上面 §小尺寸 那条注），
#   而且磁盘上的 stim_top_full.hex 已经是 12 帧，跑 4 帧绰绰有余。
#
#   开跑前的先决可行性判据（不花仿真时间，几秒）：sim\_m67_full_feasible.py ——
#   实测 M6 在 f2 非空（378 个运动格子，|Δ灰度| max=111 >> DIFF_TH=24，
#   且 mb[1]=(160,519,272,631) 非空）、M7 非空（白 74.06%，掩蔽区 6708 像素全黑）。
# ---------------------------------------------------------------------------
if os.environ.get("ALG_MSCHED", "").strip().lower() == "m67" and not _SMALL_GEOM:
    assert FRAMES_ALL >= 4, FRAMES_ALL
    MODE_SCHED = [0, 1, 6, 7] + list(MODE_SCHED[4:])
    MODE_SET_SCHED = [1, 1, 1, 1] + list(MODE_SET_SCHED[4:])

# ---------------------------------------------------------------------------
# 2026-09-22：全尺寸 **M7 切出专项**（ALG_MSCHED=m7out）
#
#   要验的是 alg_top.v:679 那条换档沿的**不对称**：
#       wire w_mode_sw = w_sof_a0 || (w_sof_pre && (w_mode_nx == MODE_REGIONFILL));
#   注释 671~677 行只说清了"**切进** M7 必须提前 1 拍"（因为 u_rf 控制相位晚 3 拍），
#   但"**切出** M7"没有对应处理。M7 支路在延迟 7 拍、其余在 4 拍，切出时 r_mode 到
#   w_sof_a0 的下一拍才变，那一拍 MUX 仍按 M7 选源 = IN(T-3)，而新档通路手中的
#   IN(T)（新帧第 0 拍、携带 tuser）就被整个跳过 ⇒ 该帧输出侧**没有 tuser**。
#
#   为什么现有激励都抓不到：小图表 = [0..7] + [7]*N（M7 之后一直是 M7），
#   全尺寸 m67 表 = [0,1,6,7] + 尾部（M7 又是最后一个）——**两条表里 M7 都是终点**，
#   "M7 -> 别的档"这一步从未出现在任何激励里。
#
#   本表 [0, 1, 3, 7, 0] 的排布理由：
#     f0 = M0  给判据 K（M0 直通 = LAT 拍）留帧
#     f1 = M1  垫帧
#     f2 = M3  **必须留一帧 M3**：check_alg_top_full.py:993 用的是
#              MODE_SCHED.index(A.MODE_EDGE)，表里没有 M3 会直接抛 ValueError
#              ⇒ 带上它，checker 一个字都不用改
#     f3 = M7  切进 M7（这一步有 w_sof_pre 保护，应当干净）
#     f4 = M0  ← **切出 M7 就在 f3->f4 这个帧边界**，要验的就是它
#
#   I_mode_set 恒 1、按键始终松开（与 m67 同款，不靠按键路径）。
#   预期：若缺陷成立，判据 J（每行/每帧拍数）或 D（档位锁存）会在 f4 报红。
#
#   不需要重新生成激励：hex 里只有像素、与档位无关。
# ---------------------------------------------------------------------------
if os.environ.get("ALG_MSCHED", "").strip().lower() == "m7out" and not _SMALL_GEOM:
    assert FRAMES_ALL >= 5, FRAMES_ALL
    MODE_SCHED = [0, 1, 3, 7, 0] + list(MODE_SCHED[5:])
    MODE_SET_SCHED = [1, 1, 1, 1, 1] + list(MODE_SET_SCHED[5:])

MODE_SEL_MIDF = 24           # frame 6 帧内改 I_mode_sel 的拍号
MODE_SEL_MIDV = 5
KEY_FRAMES = (7, 8)          # 这两帧内按键（每帧一次脉冲）
KEY_BIF, KEY_LEN = 20, 48    # 起始拍号 / 按住长度（> KEY_DIV 才产生 1 个脉冲）

# ---- 小尺寸专用按键序列（必须与 tb_alg_top_full.v 的 `ifdef ALG_IMG_W 分支逐条一致）----
#   frame 6 内按 7 下 ⇒ r_mode_hold 走 0→1→…→7 ⇒ frame 7 生效 M7（按键路径）
KEY_FRAME_S = 6              # 在这一帧内按键
KEY_N_S     = 7              # 按 7 下
KEY_BIF_S   = 40             # 第 1 次按下的起始拍号（帧内）
KEY_PERIOD  = 160            # 相邻两次按下的间隔（拍）
KEY_LOW     = 40             # 每次按住的长度（拍，> KEY_DIV_SIM=32 才出 1 个脉冲）

# 行消隐长度（真实链路值）：每行行末 tvalid=0 的拍数。
# 必须与 tb_alg_top_full.v 的 `pause_len <= 5'd20` 一致；判定侧由判据 I 使用。
# 依据：官方 zhenghe.v:137-146 —— rd_valid 是 x_cnt 的函数、x_cnt 在非有效期清零。
BLANK_LEN = 20

# 帧消隐长度（每帧最后一个行消隐之后再补的拍数）—— 全尺寸新增：
# 真实链路里一帧结束到下一帧开始之间还有场消隐，这里用 TB 的 EOF_BLANK 表达。
EOF_BLANK = 100

# ---------------------------------------------------------------------------
# 红块几何（M5 的目标色块；每帧都在图内固定的行/列区段）
#   ⚠ 为什么行数取 90 而不是小图那样的 4 行同比放大到 360 行：
#     命中容差把红块的可用色彩空间压得很小（R∈[215,255]、G∈[0,110]、B∈[0,110]），
#     而判据 E 要求**逐行唯一**（否则反解多解）。360 行放不进这个空间，
#     90 行可以：G = 2*r（r=0..89 -> 0,2,..,178 —— 等等，178 > 110）。
#     ⇒ 红块内 G = 2*r 只到 178，超出 GHI=110；所以再拆成 2 个列带是不可能的。
#     最终：G = r（r=0..89 <= 110，逐行唯一），R = 255（命中且不饱和），B = 12。
#   ⇒ 几何：90 行 x 320 列的红块，M5 的 bbox=(160, 270, 479, 359)。
# ---------------------------------------------------------------------------
RED_ROWS = min(360, H - 3 * (H // H_SMALL) - 8)   # 随 H 缩放（1280x720 -> 360 不变）
RED_BLK = 41                  # 每个 R 分块的行数（G = 块内行号，必须 <= GHI+1）
RED_B = 12                    # 红块的 B 通道（在 [0,40] 内）
RED_ROW0 = 3 * (H // H_SMALL)                      # 270
RED_ROW1 = RED_ROW0 + RED_ROWS - 1                 # 629
RED_COL_W = 8 * (W // W_SMALL) - 1                 # 319
RED_COL0 = 4 * (W // W_SMALL)                      # 160


# ---------------------------------------------------------------------------
# 图像：小图列图案平铺（G 通道）+ **逐行唯一的三通道编码**（判据 E 的前提）
#
#   G = 小图列图案平铺（COL_G 等距重复；红块内换成 (5y+2)&0xFF）
#   R = 8*(y % 16)                  （16 个值：0..120）
#   B = 4*(y // 16)                 （45 个值：0..176）
#   ⇒ (R,B) 是 (y%16, y//16) 的单射 ⇒ 逐行唯一；且两个通道都 <192，
#     +128 后仍 <256 不饱和（这一步让 key∩keyk=∅ 可证）。
#
# 为什么必须是这种"双通道联合"编码（推导，不是凑的）：
#   判据 E 要从 M3 的输出**反解 src 来自哪一行**，而 M3 的每个有效像素等于
#   "原值"或"原值 +128 饱和"（Sobel 命中时提亮）。所以第 y 行可解 ⟺
#   key(y) 与所有 key(y')、keyk(y') 都不相等。
#   若两个通道都取 <128 的值，则 |{keyk}| 最多 2^9=512 < 720——**结构上不可能**
#   做到 720 行无歧义（穷举 a/mult/P 的搜索实测 0 解）。
#   上述编码实测：uniq(key)=720、key∩keyk=∅ ⇒ 每个像素候选行恰好 1 个。
#   （selfcheck 逐条实测，不靠这段推导。）
#
# 红块：R = 255 - 2*b（b=块号 0..8）、G = r（块内行号 0..39）、B = 12
#   —— (R,G) 在红块内**逐行唯一**，且三个通道都落在命中容差内
#      （R∈{239..255}⊂[215,255]、G∈[0,39]⊂[0,40]、B=12∈[0,40]）。
#   ⚠ 为什么 R 不是常数 255：命中容差把可用色空间压到 R 41 个值、G 41 个值，
#     而 G 落在 [0,40] 里最多只能给 41 行做逐行编码。360 行的红块必须用 (R,G)
#     联合编码；R 只用 9 个值（255-2b，全为奇数）⇒ 与列编码的偶数 R 天然不冲突。
#   ⚠ R 与 G 的取值在非红块区不会出现：非红块 G 取列图案值中 <=40 的只有 20/30，
#     而红块的 G 会扫过 0..39；不过非红块的 R 是 8*(y%16) ∈ {0,8,...,120}，
#     与红块的 R ∈ {239,...,255} 不相交 ⇒ (R,G,B) 不会相撞（selfcheck 全列实测）。
# ---------------------------------------------------------------------------
def build_image(f=0):
    """第 f 帧的彩色测试图 (H, W, 3) uint8。

    ⚠ 红块**逐帧右移一个列图案周期**（W/W_SMALL = 40 列），沿用小图
      "红块逐帧移动 ⇒ M5 画上一帧还是本帧可分辨" 的设计意图。
      不移动的话逐帧 bbox 完全相同，"画上一帧 bbox" 与 "画本帧 bbox" 无法区分
      —— 判据 G 会退化成空跑（selfcheck 直接 assert 拦下来）。
      12 帧最大右移到列 160+11*40+319 = 919 < 1280，始终在图内；
      移动量是列图案周期的整数倍 ⇒ 与列图案平铺对齐，不破坏任何结构性特征。
    """
    col_g = np.tile(COL_G.astype(np.uint16), W // W_SMALL).astype(np.uint8)[:W]
    y = np.arange(H, dtype=np.int64)[:, None]
    img = np.empty((H, W, 3), dtype=np.uint8)
    img[:, :, 1] = col_g[None, :]
    img[:, :, 0] = (8 * (y % 16)).astype(np.uint8)
    img[:, :, 2] = (4 * (y // 16)).astype(np.uint8)
    r0, r1, c0, c1 = red_block(f)
    sl = (slice(r0, r1 + 1), slice(c0, c1 + 1))
    r = np.arange(RED_ROWS, dtype=np.int64)
    img[sl + (0,)] = (255 - 2 * (r // RED_BLK)).astype(np.uint8)[:, None]
    img[sl + (1,)] = (r % RED_BLK).astype(np.uint8)[:, None]
    img[sl + (2,)] = RED_B
    return np.ascontiguousarray(img)


def build_images(frames=None):
    return [build_image(f) for f in range(FRAMES_ALL if frames is None else frames)]


def red_block(f=0):
    """第 f 帧红块的 (r0, r1, c0, c1)（闭区间）。"""
    c0 = RED_COL0 + (W // W_SMALL) * f
    return (RED_ROW0, RED_ROW1, c0, c0 + RED_COL_W)


# ---------------------------------------------------------------------------
# 激励拍流
# ---------------------------------------------------------------------------
def frame_beats(img):
    """(H,W,3) -> (BPF, 2) uint64 的 96bit 拍流（行优先）。"""
    return A.frame_to_beats(img).reshape(BPF, 2)


def stim_beats(frames=None):
    """frames 帧连成一串（帧间不留气泡；行消隐由 TB 按"每行行末"插，拍序不变）。"""
    imgs = build_images(frames)
    return np.concatenate([frame_beats(im) for im in imgs], axis=0)


def nbeat(frames):
    return BPF * frames


def _write_hex(path, beats):
    # ⚠ newline="\n" 必须显式给：Windows 上文本模式会把 \n 翻成 \r\n，于是每行多一个
    #   CR（实测 230400 行全部带 \r）。ModelSim 的 $readmemh 容忍 CRLF，但
    #   "每行 24 个字符"的契约会被破坏，检查器的行宽自检会先报错。
    with open(path, "w", encoding="ascii", newline="\n") as fh:
        for w in A.beats_to_hex(beats):
            fh.write(w + "\n")


# ---------------------------------------------------------------------------
# 自检：几何/图案/行号唯一性（判据 E 的前提）
# ---------------------------------------------------------------------------
def selfcheck(frames=FRAMES_ALL):
    imgs = build_images(FRAMES_ALL)
    img0 = imgs[0]
    msg = []

    # ---- 1a) G 通道 = 小图的列图案等距平铺（水平方向结构覆盖）----
    smrow = build_image_small(0)[0, :, 1].astype(np.int64)      # 小图第 0 行的 G 列图案
    g_tile = np.concatenate([smrow] * (W // W_SMALL))           # (W,) 列图案等距平铺
    for x in (0, 5, 31, min(32, W - 1), min(63, W - 1), min(100, W - 1), W - 1):
        assert img0[0, x, 1] == g_tile[x], "G 平铺不一致 x=%d" % x
    # ⚠ 红块区域被故意换成 (5y+2) 序列，所以整体平铺只在**非红块行**成立
    okl = np.ones((H,), dtype=bool)
    okl[RED_ROW0:RED_ROW1 + 1] = False
    nbad_noned = int((img0[okl][:, :, 1].astype(np.int64)
                      != g_tile[None, :]).sum())
    nbad_red = int((img0[RED_ROW0:RED_ROW1 + 1][:, :, 1].astype(np.int64)
                    == g_tile[None, :]).sum())
    assert nbad_noned == 0, "G 通道非红块区不是列图案平铺（%d 处不符）" % nbad_noned
    msg.append("G 通道 = 小图列图案整帧平铺（红块区除外）：PASS")

    # ---- 1b) 行编码是双通道联合的（见 build_image 的推导）----
    y = np.arange(H)[:, None]
    assert np.array_equal(img0[:, 0, 0], (8 * (y % 16)).astype(np.uint8).ravel()), "R 编码不符"
    assert np.array_equal(img0[okl][:, 0, 2],
                          (4 * (np.arange(H)[okl] // 16)).astype(np.uint8)), "B 编码不符"
    msg.append("行编码 R=8*(y%%16)/%d  B=4*(y//16)/%d：(R,B) = (y%%16, y//16) 单射：PASS"
               % (int(img0[okl][:, :, 0].max()), int(img0[okl][:, :, 2].max())))

    # ---- 2) 全列实测：key 唯一 且 key∩keyk=∅（判据 E 反解的唯一性前提）----
    #   ⚠ 不假设"提亮不饱和"：饱和由 np.minimum(.,255) 显式建模，直接实测不变式。
    #   （R=8*(y%16)<=120<128 与 B=4*(y//16)<=176 让 R 永不饱和、B 只在 y>=512 饱和，
    #     而 G 的列图案含 255/240 -> 会饱和。所以只认实测，不认"不饱和"的推断。）
    allkey = np.empty((H, 0), dtype=np.int64)
    for x in range(W):
        c = img0[:, x, :].astype(np.int64)
        ck = np.minimum(c + EDGE_K, 255)
        key = (c[:, 0] << 16) | (c[:, 1] << 8) | c[:, 2]
        keyk = (ck[:, 0] << 16) | (ck[:, 1] << 8) | ck[:, 2]
        assert np.unique(key).size == H, \
            "列 x=%d 的 key 只有 %d/%d 个唯一值" % (x, np.unique(key).size, H)
        assert np.intersect1d(key, keyk).size == 0, \
            "列 x=%d 的 key∩keyk 非空（反解会多解）" % x
        allkey = np.concatenate([allkey, key[:, None]], axis=1)
    msg.append("全 %d 列实测：key 唯一(%d) 且 key∩keyk=∅（反解恒为单解）：PASS"
               % (W, H))

    # ---- 4) RGB != 灰度（区分 src=彩色 / src=灰度）----
    nz = 0
    for im in imgs[:frames]:
        g = A.gray_bt601(im)
        nz += int((im[:, :, 0].astype(int) != g).sum())
    assert nz > 0
    msg.append("RGB != 灰度 的通道数 = %d（M3 的 src 彩色/灰度可区分）" % nz)

    # ---- 5) 红块命中（M5 的 bbox 判据 G 必须非空）----
    hit = A.target_hit(img0, RLO, RHI, GLO, GHI, BLO, BHI)
    hit = A.hit_vote(hit) & A.window_valid_mask(H, W)
    bb = A.bbox_stats(hit)
    assert bb["bbox"] is not None and bb["count"] > 0, "红块没命中，判据 G 会空跑"
    msg.append("红块命中 %d 像素，bbox=%s" % (bb["count"], bb["bbox"]))

    # ---- 6) 逐帧 bbox 必须逐帧不同（否则"画上一帧 / 画本帧"没有鉴别力）----
    bbs = []
    for f in range(frames):
        h = A.target_hit(imgs[f], RLO, RHI, GLO, GHI, BLO, BHI)
        h = A.hit_vote(h) & A.window_valid_mask(H, W)
        bbs.append(A.bbox_stats(h)["bbox"])
    if frames > 1:
        assert len(set(bbs)) > 1, "逐帧 bbox 完全相同 —— 判据 G 对帧间差异没有鉴别力"
    msg.append("逐帧 bbox（前 %d 帧）= %s" % (min(frames, 4), bbs[:4]))

    # ---- 7) 提亮不会饱和（沿用小图的前提）----
    assert 8 + 8 * (H_SMALL - 1) + EDGE_K < 256, "R 行号编码 + EDGE_K 会饱和"
    return msg


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    frames = FRAMES_ALL
    if "--frames" in sys.argv:
        frames = int(sys.argv[sys.argv.index("--frames") + 1])
        assert 1 <= frames <= FRAMES_ALL, "--frames 必须 1..%d" % FRAMES_ALL

    msgs = selfcheck(frames)
    beats = stim_beats(frames)
    assert beats.shape[0] == nbeat(frames), beats.shape
    out = os.path.join(here, HEX_NAME)
    _write_hex(out, beats)

    print("已生成 stim_top_full.hex（%d 帧）" % frames)
    print("  W=%d H=%d 行 %d 拍 帧 %d 总拍 %d" % (W, H, BPL, frames, nbeat(frames)))
    print("  档位时序 MODE_SCHED=%s" % (MODE_SCHED[:frames],))
    print("  I_mode_set=%s   按键帧=%s(拍 %d..%d)" %
          (MODE_SET_SCHED[:frames], KEY_FRAMES, KEY_BIF, KEY_BIF + KEY_LEN))
    print("  颜色框 R[%d,%d] G[%d,%d] B[%d,%d]  EDGE_K=%d  C_OFF=%d" %
          (RLO, RHI, GLO, GHI, BLO, BHI, EDGE_K, C_OFF))
    print("  行消隐 BLANK_LEN=%d 拍/行   帧消隐 EOF_BLANK=%d 拍/帧" % (BLANK_LEN, EOF_BLANK))
    print("  预计周期数 ≈ %d 拍（≈ %.1f 万）"
          % (frames * (BPF + H * BLANK_LEN + EOF_BLANK) + 2000,
             (frames * (BPF + H * BLANK_LEN + EOF_BLANK) + 2000) / 10000.0))
    for m in msgs:
        print("  · %s" % m)
    print("  hex 文件大小 ≈ %.1f MB" % (os.path.getsize(out) / 1e6))


if __name__ == "__main__":
    main()

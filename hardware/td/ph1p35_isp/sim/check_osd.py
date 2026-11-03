#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_osd.py —— 校验 ModelSim 真仿真出来的 dump_osd.txt（osd_mixer 自证测试）

判定以**规格**为准，期望值模型独立复现（不读 RTL 实现），只读两个自研 ROM 的
点阵数据（my_logo_rom.v / my_charlib.v 的 case 表）当作"素材真值"。

断言清单：
  A. 时序：O_tvalid / O_tlast / O_tuser / O_tdata 必须逐拍等于输入延迟 N 拍（N 实测并报告）
  B. 像素：每个有效拍 4 个像素逐一比对 ——
       期望 = 文字命中 ? 文字色 : (安路Logo命中 ? 官方色 : (Logo 命中 ? Logo 色 : 原像素))
     原像素来自 TB 的严格单射值图（每像素自带拍号），所以任何"改错/串行/通道
     交换/整拍错位"都会以 (beat, x, ch) 的形式暴露。
  C. 区域外：不属于任何 OSD 区域的像素，必须一个 bit 都没动
  D. 覆盖率前提：必须有像素被替换（否则测试是空转）
  E. X 传播：有效拍上不允许出现 x / z

2026-09-17（G1）扩展：接入官方 anlogic_logo_rom（160x160 @ 左上角，比赛基础
  要求 (4)）之后，期望模型必须多一个"安路面"，优先级
  **文字 > 安路Logo > 自研Logo > 原像素**。
  安路面的几何**从 dump 首行读**（老 dump 是 10 个字段、没有安路面；新 dump 是
  14 个字段）。⇒ 本文件对老 dump 的行为与扩展前**逐 bit 相同**（已用改动前的
  dump 实测：结论与计数完全一致），扩展不是"为了让新结果通过而改判据"。

2026-09-16 修正（配合 osd_mixer v1.2 插入流水级、延迟 1 拍 → 2 拍）：
  旧版把数据链相位**写死**成 `DS = 1`。延迟一变，这个常数就成了"错误的期望值"，
  比对必然全错。现在 `DS` 一律**从激励反解**（见 measure_data_latency）：
  像素值图严格单射、每个像素自带拍号，于是"第 i 拍输出里带的拍号 == 第 i-DS 拍
  总线上的拍号"可以直接量出来 —— 不读 DUT 任何内部信号，也不假设任何常数。
  同时要求 数据链 DS == 控制链实测延迟（两把尺子互相印证）。

用法：
    python check_osd.py --dump <dump 文件>          # 正常校验
    python check_osd.py --dump <dump> --selftest    # 变异自证
"""
from __future__ import annotations

import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.abspath(os.path.join(HERE, "..", "src"))

BPL = None          # 每行拍数，从 dump 首行算出


# ===========================================================================
# 1. 解析两个自研 ROM 的 case 表（素材真值）
# ===========================================================================
def parse_logo(path):
    """返回 (hit(y,x), fg, bg)"""
    txt = open(path, "r", encoding="utf-8").read()
    fg = int(re.search(r"COLOR_FG\s*=\s*24'h([0-9A-Fa-f]+)", txt).group(1), 16)
    bg = int(re.search(r"COLOR_BG\s*=\s*24'h([0-9A-Fa-f]+)", txt).group(1), 16)
    seg = {}
    for m in re.finditer(r"9'd(\d+)\s*:\s*pix_seg\s*=\s*16'h([0-9A-Fa-f]{4})", txt):
        seg[int(m.group(1))] = int(m.group(2), 16)
    assert len(seg) == 512, "logo 段数不对：%d" % len(seg)

    def hit(y, x):
        if not (0 <= y < 64 and 0 <= x < 128):
            return False
        word = seg[y * 8 + (x >> 4)]
        return bool((word >> (15 - (x & 15))) & 1)

    return hit, fg, bg


def parse_charlib(path):
    """返回 (bits(idx,row), code2idx)"""
    txt = open(path, "r", encoding="utf-8").read()
    row_tab = {}
    for m in re.finditer(r"12'd(\d+)\s*:\s*O_bits\s*=\s*16'h([0-9A-Fa-f]{4})", txt):
        row_tab[int(m.group(1))] = int(m.group(2), 16)
    assert len(row_tab) == 42 * 16, "字库行数不对：%d" % len(row_tab)

    def bits(idx, row):
        return row_tab.get(idx * 16 + (row & 15), 0)

    code2idx = {}
    for m in re.finditer(r"idx=\s*(\d+)\s+'([^']*)'\s+code=0x([0-9A-Fa-f]+)", txt):
        idx, name = int(m.group(1)), m.group(2)
        if name == "SPACE":
            code2idx[0x20] = idx
        elif len(name) == 1:
            code2idx[ord(name)] = idx
    assert len(code2idx) >= 40, "字符索引表解析不完整：%d" % len(code2idx)
    return bits, code2idx


LOGO_HIT, LOGO_FG, LOGO_BG = parse_logo(os.path.join(SRC, "my_logo_rom.v"))
CHAR_BITS, CODE2IDX = parse_charlib(os.path.join(SRC, "my_charlib.v"))

# ===========================================================================
# 1b. 安路官方 Logo（osd_mixer v1.5：**ERAM 位图**，不再是官方那个组合 ROM）
#     期望值 = logo_64c.hex（6400 字 x 24bit）+ alg_logo_eram.v 里的调色板 →
#     展开成 160x160 的 RGB/透明图。三处口径必须一字不差：
#         word = idx0 | (idx1<<6) | (idx2<<12) | (idx3<<18)，idx0 = 该字**最左**像素
#         地址 = y*40 + x_grp ；idx 0 = 透明，idx 1..63 = 调色板下标
#     "量化后的图 vs 官方素材"的保真度由 check_anlogo.py 独立断言（防编码器与
#     参考模型一起错）。
# ===========================================================================
AN_W, AN_H, AN_XG = 160, 160, 40
AN_WORDS_EXPECT = AN_H * AN_XG                    # 6400
AN_ROM_PATH = os.path.abspath(os.path.join(
    SRC, "..", "prj", "board", "lab_ex3_osd", "user_source",
    "hdl_source", "anlogic_logo_rom.v"))
AN_HEX_PATH = os.path.abspath(os.path.join(SRC, "..", "sim", "logo_64c.hex"))
AN_RTL_PATH = os.path.abspath(os.path.join(SRC, "alg_logo_eram.v"))


def parse_anlogic_rom(path):
    """官方素材（只给保真度断言用；缺失则 None）"""
    if not os.path.exists(path):
        return None
    txt = open(path, "r", encoding="utf-8", errors="replace").read()
    tab = {}
    for a, v in re.findall(r"15'd(\d+)\s*:\s*O_pixel\s*=\s*25'h([0-9a-fA-F]+)\s*;", txt):
        tab[int(a)] = int(v, 16)
    return tab or None


def parse_eram_palette(path):
    """从 alg_logo_eram.v 抠出 4 份调色板 case → (pal, 4 份是否一致)"""
    txt = open(path, "r", encoding="utf-8", errors="replace").read()
    blocks = re.findall(r"always @ \(\*\) begin\s*\n\s*case \(w_idx(?:[0-3])\).*?endcase",
                        txt, re.S)
    assert len(blocks) == 4, "alg_logo_eram.v 抠出 %d 段调色板 case（期望 4）" % len(blocks)
    pals = []
    for b in blocks:
        d = {}
        for k, v in re.findall(r"6'd(\d+)\s*:\s*w_pal\d\s*=\s*24'h([0-9A-Fa-f]{6});", b):
            d[int(k)] = int(v, 16)
        assert len(d) == 64, "调色板只有 %d 项" % len(d)
        pals.append(d)
    return pals[0], all(p == pals[0] for p in pals)


def load_anlogic_img(hex_path, rtl_path):
    """展开图[y][x] = None(透明) | (r,g,b)；返回 (img, pal, pal_ok)

    原始字（6400 个 24bit）同时挂到模块级 AN_WORD，给 check_anlogo.py 的
    "假像素机会"计算用（模型侧判断去掉钳位/屏蔽会读到什么）。
    """
    global AN_WORD
    if not (os.path.exists(hex_path) and os.path.exists(rtl_path)):
        return None, None, False
    pal, pal_ok = parse_eram_palette(rtl_path)
    words = [l.strip() for l in open(hex_path, encoding="ascii") if l.strip()]
    assert len(words) == AN_WORDS_EXPECT, \
        "hex 行数 = %d（期望 %d）" % (len(words), AN_WORDS_EXPECT)
    AN_WORD = [int(w, 16) for w in words]
    img = [[None] * AN_W for _ in range(AN_H)]
    for a, w in enumerate(words):
        v = int(w, 16)
        y, g = divmod(a, AN_XG)
        for k in range(4):
            idx = (v >> (6 * k)) & 0x3F
            if idx != 0:
                c = pal[idx]
                img[y][4 * g + k] = ((c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF)
    return img, pal, pal_ok


AN_WORD = []                                      # 6400 个 24bit 原始字


AN_TAB = parse_anlogic_rom(AN_ROM_PATH)           # 官方素材（保真度断言用）
AN_IMG, AN_PAL, AN_PAL_OK = load_anlogic_img(AN_HEX_PATH, AN_RTL_PATH)

OSD_TEXT_COLOR = 0xFFFFFF
TEXT_W = 16
TEXT_H = 16


# ===========================================================================
# 2. TB 的像素值图（与 tb_osd_mixer.v 逐字一致）
# ===========================================================================
def src_pix(beat, ch):
    """pix = (beat << 7) | ((beat % 32) << 2) | ch —— 每像素自带拍号，严格单射"""
    return (beat << 7) | (((beat % 32) & 0x1F) << 2) | (ch & 3)


def decode_pix(v):
    return (v >> 7, (v >> 2) & 0x1F, v & 0x3)


# ===========================================================================
# 2b. 数据链延迟：**从激励反解**（不假设常数，不读 DUT 内部信号）
# ===========================================================================
def _beat_of_pixel(v, ch):
    """v 若正好是 src_pix(beat, ch) 就返回 beat，否则 None（被 OSD 替换过就解不出）"""
    if (v & 0x3) != (ch & 3):
        return None
    b = v >> 7
    if b < 0 or b >= (1 << 12):
        return None
    if src_pix(b, ch) != v:
        return None
    return b


def measure_data_latency(rows, verbose=True):
    """返回 (DS, counts)：DS = 输出相对输入的数据延迟（单位：拍），从激励量出来

    判据：第 i 拍输出里带的拍号，必须等于第 i-DS 拍**总线**上的拍号（拍号由
    TB 的严格单射值图从 I_tdata 里反解，PASS THROUGH 的像素原样带出来）。
    """
    counts = dict((s, 0) for s in (1, 2, 3, 4))
    for i, r in enumerate(rows):
        if r["Ov"] != 1:
            continue
        v = int(r["Od"], 16)
        beats = set()
        for ch in range(4):
            b = _beat_of_pixel((v >> (72 - 24 * ch)) & 0xFFFFFF, ch)
            if b is not None:
                beats.add(b)
        if not beats:
            continue
        for s in counts:
            j = i - s
            if j < 0 or rows[j]["Iv"] != 1:
                continue
            # 输入那一拍总线上最左像素（I_tdata[95:72]）自带的拍号
            ib = _beat_of_pixel((int(rows[j]["Id"], 16) >> 72) & 0xFFFFFF, 0)
            if ib is not None and ib in beats:
                counts[s] += 1
    order = sorted(counts, key=lambda s: -counts[s])
    best = order[0]
    if counts[best] == 0:
        return None, counts
    # 唯一性：正确相位的命中数必须**压倒性**高于次佳（否则相位不可信）
    if len(order) > 1 and counts[best] < 10 * max(1, counts[order[1]]):
        return None, counts
    if verbose:
        print("  data latency    : %d cycle(s)  [从激励反解；各候选 %s]"
              % (best, ", ".join("%d:%d" % (s, counts[s]) for s in sorted(counts))))
    return best, counts


# ===========================================================================
# 3. 期望结果模型（纯规格：坐标公式 + 两个 ROM + 混合优先级）
# ===========================================================================
# 2026-09-20：命令行覆盖"命中数"（`--infcnt N`）。None = 用 dump 头里的值。
#
# 为什么加：屏上第 25~30 格显示 "TARGET"（命中数非零）或 "NONE"（为零），
# 而原来命中数写死成非零 ⇒ **NONE 那一支从来没被激励过**，等于没验。
# 想靠改参数覆盖时又撞上怪事：dump 头第 19 个字段实测读出来是 9315
# （测试台源里写的是 7），参数覆盖没生效、原因未查明。
# 与其把"验证 NONE 分支"卡在这个谜上，不如从命令行显式给 —— 确定、当场可见。
# ⚠ `--infcnt` 必须与测试台的 `+cnt0` 成对使用，两边说的是同一个事实。
INF_CNT_OVERRIDE = None
INF_Y_OVERRIDE = None


class Config:
    def __init__(self, w, h, lx, ly, tx, ty, mode, fps, lat, infx,
                 anx=None, any_=None, anw=None, anh=None,
                 nframe=None, m0=None, m1=None, m2=None, infcnt=0, infy=0,
                 m3=None, c0=None, c1=None, c2=None, c3=None, c4=None, c5=None,
                 t0=None, t1=None, t2=None, t3=None, t4=None, t5=None):
        self.W, self.H = w, h
        self.LOGO_X, self.LOGO_Y = lx, ly
        self.TEXT_X, self.TEXT_Y = tx, ty
        self.MODE, self.FPS, self.LAT, self.INF_X = mode, fps, lat, infx
        # 2026-09-20：第 19/20 字段（命中数、Y 坐标），驱动屏上第 25~29 格（Y:xxxx）
        #   与第 31~36 格（TARGET/NONE）。默认 0 ⇒ 老 dump（18 字段）照样能读。
        self.INF_CNT = infcnt
        self.INF_Y = infy
        self.BPL = w // 4
        # 2026-09-20：16 → 32 → 40，必须与 src\osd_mixer.v 的 N_CHAR_MAX 逐字一致。
        #   16 那次让第 16 格之后全被切掉（LAT 个位、X 坐标都画不出来）；
        #   判据当年跟着实现一起写成 16，所以"屏幕上是错的"这件事它一直是绿的。
        #   教训：判据里凡是**照抄实现参数**的地方，都要能对着规格复核一遍。
        self.N_CHAR_MAX = 48
        self.OSD_LOGO_COLOR = LOGO_FG
        self.OSD_TEXT_COLOR = OSD_TEXT_COLOR
        # ---- 安路官方 Logo 面（老 dump 没这四个字段 ⇒ 面关闭，行为同扩展前）----
        self.AN_X, self.AN_Y = anx, any_
        self.AN_W = anw if anw else (160 if anx is not None else 0)
        self.AN_H = anh if anh else (160 if any_ is not None else 0)
        self.AN_ON = (anx is not None) and (AN_IMG is not None) and (self.AN_W > 0)
        # ---- 档位扫描（v1.5）：一帧一个档位；老 dump 没有 ⇒ 退化成单档位 ----
        self.MODES = [m for m in (m0, m1, m2, m3) if m is not None] or [mode]
        self.NFRAME = nframe if nframe else len(self.MODES)
        # ---- 2026-09-20：逐帧**颜色类别**（0=R / 1=G / 2=B），第 21~26 字段 ----
        #   老 dump 没有这六个字段 ⇒ 全 0，行为同扩展前（那时屏上只有 TARGET/NONE）。
        _cls = [c for c in (c0, c1, c2, c3, c4, c5) if c is not None]
        self.CLS = _cls if _cls else [0] * self.NFRAME
        # ---- 2026-09-20：逐帧**跟踪编号**（0..99），第 28~33 字段 ----
        #   老 dump 没有这六个字段 ⇒ 全 0，行为同扩展前（那时这一栏只有颜色名）。
        _tid = [t for t in (t0, t1, t2, t3, t4, t5) if t is not None]
        self.TID = _tid if _tid else [0] * self.NFRAME

    def mode_of_beat(self, beat):
        """该拍属于哪一帧 ⇒ 用哪个档位（与 tb_osd_mixer.v 的帧计数逐字一致）"""
        f = beat // (self.BPL * self.H)
        return self.MODES[f] if f < len(self.MODES) else self.MODES[-1]

    def cls_of_beat(self, beat):
        """该拍属于哪一帧 ⇒ 用哪个颜色类别（与 mode_of_beat 同一套帧计数）"""
        f = beat // (self.BPL * self.H)
        if not self.CLS:
            return 0
        return self.CLS[f] if f < len(self.CLS) else self.CLS[-1]

    def tid_of_beat(self, beat):
        """该拍属于哪一帧 ⇒ 用哪个跟踪编号（与 mode_of_beat 同一套帧计数）"""
        f = beat // (self.BPL * self.H)
        if not self.TID:
            return 0
        return self.TID[f] if f < len(self.TID) else self.TID[-1]


# 2026-09-20（2.4(2)「识别」）：第 38~43 格的六个字符 —— 与 osd_mixer.v §12.1a 逐条对应。
#   三种情形：
#     ① 命中数 == 0                     → "NONE  "
#     ② 命中数 != 0 且档位 == 5（COLOR）→ "RED   " / "GRN   " / "BLU   "
#     ③ 命中数 != 0 且档位 != 5         → "TARGET"
#   ⚠ "只在 COLOR 档报颜色"这条门控是**规格的一部分**：别的档位的命中像素来自
#     运动/边缘，不是颜色命中，按主导通道报一个颜色名会误导。判据必须同样实现它，
#     否则门控写反（比如漏判档位）时判据反而是绿的。
CLASS_WORDS = {0: "RED   ", 1: "GRN   ", 2: "BLU   "}
MODE_COLOR = 5


def tid_digits(v):
    """跟踪编号 → 两位十进制字符串（与 osd_mixer §6 的拆位逐条同口径）。

    契约范围是 0..99（RTL 饱和在 99）。这里对任意值都按同一条比较链算，
    所以即使喂进 >99 的值也不会"判据和 RTL 各算各的" —— 但**测试只喂 <= 99**，
    因为超出契约的行为不该当成被测对象。
    """
    v = int(v) & 0xFF
    t = 0
    for k in range(9, 0, -1):
        if v >= k * 10:
            t = k
            break
    o = (v - t * 10) & 0xF
    return "%d%d" % (t, o)


def det_word(cfg, beat):
    """第 38~43 格的六个字符（按"该拍属于哪一帧"取档位、类别、跟踪编号）。

    cfg.DET_MUT 非空时走**变异**分支（只给自证用，正常跑永远不走）：
      · "ignore_mode" —— 漏判档位门控，任何档位命中都报颜色名
      · "class_rot"   —— 类别轮转一位（三个计数器接错线）
      · "tid_off"     —— 跟踪编号整体错一位
    """
    mut = getattr(cfg, "DET_MUT", None)
    if int(getattr(cfg, "INF_CNT", 0)) == 0:
        return "NONE  "
    m = cfg.mode_of_beat(beat) if beat is not None else cfg.MODE
    if mut == "ignore_mode":
        # 漏判档位门控：任何档位命中都报颜色名 + 编号（仍是 6 格版面）
        return CLASS_WORDS.get(int(cfg.cls_of_beat(beat)), "      ")[:3] + " " + \
               tid_digits(cfg.tid_of_beat(beat))
    if int(m) != MODE_COLOR:
        return "TARGET"
    c = int(cfg.cls_of_beat(beat))
    if mut == "class_rot":
        c = (c + 1) % 3
    tid = int(cfg.tid_of_beat(beat))
    if mut == "tid_off":
        tid = (tid + 1) % 100
    # 前 3 格颜色名 + 1 格空格 + 2 格跟踪编号（与 osd_mixer §12.1a 同一版面）
    return CLASS_WORDS.get(c, "      ")[:3] + " " + tid_digits(tid)


# 2026-09-20（2.5(1) 状态显示）：档位号 → 屏上第 0~4 格的**算法名**（5 字，右补空格）。
#   必须与 src\osd_mixer.v 的 §5b `w_mode_name` 逐字一致。
#   名字避开 TARGET/MOTION —— "TARGET" 已被检测结果那一栏占用。
MODE_NAMES = {0: "RAW  ", 1: "GRAY ", 2: "BIN  ", 3: "EDGE ", 4: "BLUR ",
              5: "COLOR", 6: "MOVE ", 7: "FILL "}


def mode_chars(mode):
    """档位号 → (第一个字符, 第二个字符)。2026-09-17：补到 M7（M6=帧差、M7=直方图均衡）"""
    if 0 <= mode <= 7:
        return ord("M"), ord("0") + mode
    return ord("M"), ord("?")


def dec3(v):
    v = v % 1000
    return [(v // 100) % 10, (v // 10) % 10, v % 10]


def dec4(v):
    v = v % 10000
    return [(v // 1000) % 10, (v // 100) % 10, (v // 10) % 10, v % 10]


def char_code(ci, cfg, beat=None):
    """第 ci 个字符槽的 ASCII 码（下标见 osd_mixer.v 文件头 §六）

    beat 给出时按"该拍属于哪一帧"取档位（v1.5 的档位扫描），否则用 cfg.MODE。
    """
    m = cfg.MODE
    if beat is not None and hasattr(cfg, "mode_of_beat"):
        m = cfg.mode_of_beat(beat)
    m0, m1 = mode_chars(m)
    l = dec3(cfg.LAT)
    x = dec4(cfg.INF_X)
    yy = dec4(getattr(cfg, "INF_Y", 0))
    # ⚠ 必须用**逐帧**的档位 m，不能用 cfg.MODE —— 测试台的档位是逐帧变的
    #   （MODE_LIST = M3/M6/M7），写 cfg.MODE 会让后两帧的算法名期望值算错。
    nm = MODE_NAMES.get(int(m), "     ")
    dw = det_word(cfg, beat)
    tab = {
        # ---- 2026-09-20（2.5(1)）：第 0~4 格 = 算法名，第 6~7 格 = "M<n>" ----
        0: ord(nm[0]), 1: ord(nm[1]), 2: ord(nm[2]), 3: ord(nm[3]), 4: ord(nm[4]),
        5: 0x20,
        6: m0, 7: m1,
        8: 0x20,
        9: ord("F"), 10: ord("P"), 11: ord("S"), 12: ord(":"),
        13: 0x30 + ((cfg.FPS >> 4) & 0xF), 14: 0x30 + (cfg.FPS & 0xF),
        15: 0x20,
        16: ord("L"), 17: ord("A"), 18: ord("T"), 19: ord(":"),
        20: 0x30 + l[0], 21: 0x30 + l[1], 22: 0x30 + l[2],
        23: 0x20,
        24: ord("X"), 25: ord(":"),
        26: 0x30 + x[0], 27: 0x30 + x[1], 28: 0x30 + x[2], 29: 0x30 + x[3],
        30: 0x20,
        # ---- 2026-09-20：扩展要求 2.4(2)「叠加检测结果与文字说明」------------
        #   第 31~36 格 = "Y:xxxx"（Y 坐标）；第 38~43 格 = "TARGET" / "NONE  "。
        #   与 RTL 的 6'd31~6'd43 逐格对应。Y 与"命中"取自 dump 头（第 20/19 字段），
        #   不是猜的；命令行 --infy / --infcnt 可覆盖（测试台 +cnt0 时要成对用）。
        31: ord("Y"), 32: ord(":"),
        33: 0x30 + yy[0], 34: 0x30 + yy[1], 35: 0x30 + yy[2], 36: 0x30 + yy[3],
        37: 0x20,
        # ---- 2026-09-20（2.4(2)）：第 38~43 格 = 检测结果文字 -------------------
        #   六格合起来是一个"词"，必须整体算（见 det_word）：
        #     "NONE  " / "RED   " / "GRN   " / "BLU   " / "TARGET"
        #   与 RTL 的 §12.1a 逐条对应。命中数取自 dump 头第 19 字段（--infcnt 可覆盖，
        #   与测试台 +cnt0 成对用）；档位与类别按"该拍属于哪一帧"取。
        **{38 + k: ord(dw[k]) for k in range(6)},
    }
    return tab.get(ci, ord("?"))


def char_rom_idx(code):
    if 0x30 <= code <= 0x39:
        return code - 0x30
    if 0x41 <= code <= 0x5A:
        return code - 0x37
    if code == 0x20:
        return 39
    if code == 0x3A:
        return 36
    if code == 0x2E:
        return 37
    if code == 0x2F:
        return 38
    return 39


def expect_pix_at(cfg, beat, rx, ry, ch, logo_dx=0, skip_text=False):
    """(rx, ry) 是拍级坐标；像素级列号 x = 4*rx + ch

    logo_dx   —— 只用于变异测试（把 Logo 整体平移若干列）
    skip_text —— True 时只算 Logo 面。两个面必须**各自独立**评估，否则文字优先
                 会把 Logo 面的命中"吃掉"，导致 Logo 面永远测不干净。
    优先级：文字 > 安路Logo > 自研Logo > 原像素（osd_mixer §12.5）
    """
    x = 4 * rx + ch
    y = ry
    # ---- 文字 ----
    if not skip_text:
        if (cfg.TEXT_X <= x < cfg.TEXT_X + cfg.N_CHAR_MAX * TEXT_W) and \
           (cfg.TEXT_Y <= y < cfg.TEXT_Y + TEXT_H):
            dx = x - cfg.TEXT_X
            code = char_code(dx // TEXT_W, cfg, beat)
            gb = CHAR_BITS(char_rom_idx(code), (y - cfg.TEXT_Y) & 0xF)
            if (gb >> (15 - dx % TEXT_W)) & 1:
                return cfg.OSD_TEXT_COLOR, "text"
    # ---- 安路官方 Logo（v1.5：ERAM 位图，hex + RTL 调色板展开）----
    if cfg.AN_ON:
        ady, adx = y - cfg.AN_Y, x - cfg.AN_X
        if 0 <= ady < cfg.AN_H and 0 <= adx < cfg.AN_W:
            c = AN_IMG[ady][adx]
            if c is not None:
                return ((c[0] << 16) | (c[1] << 8) | c[2]), "anlogo"
    # ---- 自研 Logo ----
    if LOGO_HIT(y - cfg.LOGO_Y, x - logo_dx - cfg.LOGO_X):
        return cfg.OSD_LOGO_COLOR, "logo"
    return src_pix(beat, ch), "orig"


# ===========================================================================
# 4. 解析 dump
# ===========================================================================
def parse(path):
    lines = open(path, "r", encoding="ascii", errors="replace").read().splitlines()
    hdr, rows = None, []
    for ln in lines:
        f = ln.split()
        if not f:
            continue
        if f[0] == "H":
            hdr = [int(v) for v in f[1:]]
            continue
        if len(f) < 24:
            continue
        rows.append({
            "cyc": int(f[0]),
            "Iv": int(f[1]), "Il": int(f[2]), "Iu": int(f[3]), "Id": f[4],
            "Ov": int(f[5]), "Ol": int(f[6]), "Ou": int(f[7]), "Od": f[8],
            "L": [int(v) for v in f[9:13]],
            "T": [int(v) for v in f[13:17]],
            "rx": int(f[17], 16), "ry": int(f[18], 16),
            "nx": int(f[19], 16), "ny": int(f[20], 16),
            "xg": int(f[21], 16), "yp": int(f[22], 16),
            "beat": int(f[23]),
        })
    assert hdr is not None, "dump 没有首行 H 头"
    return hdr, rows


# ===========================================================================
# 5. 变异（自证用）：只改"期望模型"，对应 RTL 里人工植入的同款缺陷
# ===========================================================================
MUTATIONS = {}


def mutation(name):
    def deco(fn):
        MUTATIONS[name] = fn
        return fn
    return deco


def _text_hit(cfg, x, y, dx_shift=0, row_shift=0, beat=None):
    if not (cfg.TEXT_X <= x < cfg.TEXT_X + cfg.N_CHAR_MAX * TEXT_W):
        return False
    if not (cfg.TEXT_Y <= y < cfg.TEXT_Y + TEXT_H + row_shift):
        return False
    dx = x - cfg.TEXT_X - dx_shift
    if dx < 0:
        return False
    code = char_code(dx // TEXT_W, cfg, beat)
    gb = CHAR_BITS(char_rom_idx(code), (y - cfg.TEXT_Y - row_shift) & 0xF)
    return bool((gb >> (15 - (dx % TEXT_W))) & 1)


@mutation("M1_logo_shift1")
def _m1(cfg, beat, rx, ry, ch, skip_text=False):
    """Logo 整体右移 1 列（RTL 那边就是把 LOGO_X 参数 +1）"""
    return expect_pix_at(cfg, beat, rx, ry, ch, logo_dx=1, skip_text=skip_text)


@mutation("M2_hit_invert")
def _m2(cfg, beat, rx, ry, ch, skip_text=False):
    """Logo 命中判据取反：笔画外的像素反而涂色"""
    x = 4 * rx + ch
    if not skip_text and _text_hit(cfg, x, ry, beat=beat):
        return cfg.OSD_TEXT_COLOR, "text"
    lx, ly = x - cfg.LOGO_X, ry - cfg.LOGO_Y
    if 0 <= lx < 128 and 0 <= ly < 64 and not LOGO_HIT(ly, lx):
        return cfg.OSD_LOGO_COLOR, "logo"
    return src_pix(beat, ch), "orig"


@mutation("M3_passthru_broken")
def _m3(cfg, beat, rx, ry, ch, skip_text=False):
    """区外像素不再透传（对应 RTL 把 else 分支写成常量）"""
    v, kind = expect_pix_at(cfg, beat, rx, ry, ch, skip_text=skip_text)
    return (0x000000, "leak") if kind == "orig" else (v, kind)


@mutation("M4_text_shift1")
def _m4(cfg, beat, rx, ry, ch, skip_text=False):
    """文字整体右移 1 列（RTL 那边是字内列算错一位）"""
    x = 4 * rx + ch
    if not skip_text and _text_hit(cfg, x, ry, dx_shift=1, beat=beat):
        return cfg.OSD_TEXT_COLOR, "text"
    if LOGO_HIT(ry - cfg.LOGO_Y, x - cfg.LOGO_X):
        return cfg.OSD_LOGO_COLOR, "logo"
    return src_pix(beat, ch), "orig"


@mutation("M5_text_row_shift1")
def _m5(cfg, beat, rx, ry, ch, skip_text=False):
    """文字整体上移 1 行（RTL 那边是字模行号没打拍）"""
    x = 4 * rx + ch
    if not skip_text and _text_hit(cfg, x, ry, row_shift=1, beat=beat):
        return cfg.OSD_TEXT_COLOR, "text"
    if LOGO_HIT(ry - cfg.LOGO_Y, x - cfg.LOGO_X):
        return cfg.OSD_LOGO_COLOR, "logo"
    return src_pix(beat, ch), "orig"


@mutation("M6_coord_lag")
def _m6(cfg, beat, rx, ry, ch, skip_text=False):
    """判据坐标整体错一拍（RTL 那边是命中判据用了没打拍的坐标）"""
    rx2 = rx - 1 if rx > 0 else 0
    return expect_pix_at(cfg, beat, rx2, ry, ch, skip_text=skip_text)


# ---- 2026-09-20（2.4(2) 颜色类别）：第 38~43 格那一栏的两条变异 --------------
#   为什么单独加：这一栏的内容现在有**五种**（NONE / RED / GRN / BLU / TARGET），
#   而它的门控有两条（命中数非零、且档位 == COLOR）。上面那六条变异动的是
#   Logo/文字的位置与透传，**一条都碰不到这一栏** ⇒ 不加这两条，这一栏等于没自证。
@mutation("M7_det_word_ignore_mode")
def _m7(cfg, beat, rx, ry, ch, skip_text=False):
    """漏判档位门控：不管第几档，命中就报颜色名（RTL 那边是 r_is_color_p1 恒 1）

    做法：在 cfg 上挂一个"覆盖期望词"的标记（cfg 每次 run 都重建，不会串到别的变异），
    然后照常走 expect_pix_at —— 只动第 38~43 格的期望，旁边几栏一个字不改，
    这样"报红"就一定是这一栏抓到的，不会被算法名/档位号的差异顶包。
    """
    cfg.DET_MUT = "ignore_mode"
    return expect_pix_at(cfg, beat, rx, ry, ch, skip_text=skip_text)


@mutation("M8_det_class_rot")
def _m8(cfg, beat, rx, ry, ch, skip_text=False):
    """类别接错线（RED→GRN→BLU 轮转一位）：对应 RTL 把三个计数器接错"""
    cfg.DET_MUT = "class_rot"
    return expect_pix_at(cfg, beat, rx, ry, ch, skip_text=skip_text)


@mutation("M9_tid_off_by_one")
def _m9(cfg, beat, rx, ry, ch, skip_text=False):
    """跟踪编号整体错一位：对应 RTL 把编号的前后级接错 / 漏了一级寄存

    ⚠ 这条**有真鉴别力**：测试台给的三帧编号是 1 / 12 / 99，
      错一位后 1→2、12→13、99→0，十位和个位都会变，不是只差一个常量。
    """
    cfg.DET_MUT = "tid_off"
    return expect_pix_at(cfg, beat, rx, ry, ch, skip_text=skip_text)


# ===========================================================================
# 6. 主校验
# ===========================================================================
def run(dump, mutation_name=None, verbose=True, text_is_gate=True):
    global BPL
    hdr, rows = parse(dump)
    cfg = Config(*hdr)
    if INF_CNT_OVERRIDE is not None:
        # 命令行显式给的事实优先于 dump 头（头里那个字段现在读出来不对，见文件上方说明）
        cfg.INF_CNT = INF_CNT_OVERRIDE
    if INF_Y_OVERRIDE is not None:
        cfg.INF_Y = INF_Y_OVERRIDE
    BPL = cfg.BPL
    model = MUTATIONS[mutation_name] if mutation_name else expect_pix_at

    n_err = 0
    samples = []

    def err(msg):
        nonlocal n_err
        n_err += 1
        if len(samples) < 10:
            samples.append(msg)

    # ---- 控制链延迟：不假设，直接量 ----
    ctrl_hits = {}
    ctrl_shift = None
    for sh in (1, 2, 3, 4):
        hit = tot = 0
        for i in range(sh, len(rows)):
            if rows[i]["Ov"] != 1:
                continue
            tot += 1
            if (rows[i]["Ov"], rows[i]["Ol"], rows[i]["Ou"]) == \
               (rows[i - sh]["Iv"], rows[i - sh]["Il"], rows[i - sh]["Iu"]):
                hit += 1
        ctrl_hits[sh] = (hit, tot)
        if tot and hit >= tot - 2 and ctrl_shift is None:
            ctrl_shift = sh
    if ctrl_shift is None:
        err("control latency is not a constant shift of the input (checked 1..4)")

    # ---- 数据链延迟：**同样从激励反解**（2026-09-16 起不再写死 DS = 1）----
    DS, ds_counts = measure_data_latency(rows, verbose=verbose)
    if DS is None:
        err("data latency cannot be derived from the stimulus (counts=%s)" % ds_counts)
        DS = ctrl_shift if ctrl_shift else 1
    else:
        # 数据链与控制链必须**同拍**（差 0）。实测：
        #     v1.1 / v1.2（修复前） data 比 ctrl **少 1 拍** —— 那是 **bug**：
        #         O_tuser=1 那一拍携带的是 beat 1 而不是 beat 0（见 sim/check_skew.py 实测）。
        #     v1.3（修复后）        data 2 拍 / ctrl 2 拍，差 0。
        # ⚠ 2026-09-16：这条断言原先是"差必须 == 1"，等于**把 bug 写成了契约**；已改为 0。
        #   差不为 0 = 数据与控制错位（下游 96→128 打包器按 tuser 复位会整体错开）。
        if ctrl_shift is not None and (ctrl_shift - DS) != 0:
            err("data/ctrl latency skew != 0: data %d, ctrl %d (必须同拍)"
                % (DS, ctrl_shift))

    n_valid = n_pix = n_rep = n_txt = n_logo = n_out = n_xz = 0
    n_anlogo = 0
    n_logo_bad = n_txt_bad = n_an_bad = 0
    # 数据链相位 DS：**上面从激励实测得到**（osd_mixer v1.2 起是 2 拍，v1.1 是 1 拍）。
    # 判据坐标相位：rows[i] 的 r_x/r_y 就是与该像素同级的那份坐标（见文件头）
    for i in range(len(rows)):
        r = rows[i]
        if set(r["Od"]) & set("xXzZ") or set(r["Id"]) & set("xXzZ"):
            n_xz += 1
        if r["Ov"] != 1:
            if int(r["Od"], 16) != 0:
                err("cyc %d: O_tdata should be 0 when O_tvalid=0, got %s" % (r["cyc"], r["Od"]))
            continue
        n_valid += 1
        src = rows[max(i - DS, 0)]
        b = (int(src["Id"], 16) >> 72) >> 7          # 该像素自带的拍号
        v = int(r["Od"], 16) & ((1 << 96) - 1)
        # ⚠⚠ 判据坐标一律取**真值**：拍号 b 是从激励数据里解出来的
        #   （src_pix 严格单射，每像素自带拍号），不读 DUT 的任何坐标探针。
        #
        #   2026-09-14 对抗性审查修正。旧版写的是：
        #       crx, cry = rows[i-1]["rx"], rows[i-1]["ry"]     # 探针 = r_x_now
        #   而 osd_mixer.v 里 r_x_now <= w_x_nx、w_x_nx = r_x_grp + 1、r_x_grp <= r_x_grp + 1,
        #   所以 r_x_now ≡ r_x_grp ≡ (总线数据的 x_grp − 1)，**恒晚一拍**。于是：
        #     · Logo 面：RTL 恰好也用 r_x_now → 期望模型把 RTL 的缺陷一起吸收了，
        #       测出 "0 bad" 是**假通过**（循环论证）；
        #     · 文字面：RTL 用的是 w_x_nx（真本拍坐标），行首那一拍退化成上一行行尾
        #       → 凭空报出 474 bad，真缺陷反而被掩盖。
        #   用真值后两个面各自独立评估，缺陷无法再被期望模型吸收。
        #
        #   ⚠ 2026-09-17（v1.5 档位扫描）：一个 dump 里现在有**多帧**。DUT 的坐标计数器
        #     在每次 I_tuser 归零，所以"屏幕坐标"必须由**帧内**拍号算：
        #         fb = beat % (BPL * H)
        #     用全局拍号会让第 2/3 帧整体错位（第 2 帧被当成 y=128..255 的行），
        #     实测会凭空报出 12510 个文字面失配 —— 这是**判据错**不是 DUT 错。
        #     档位查表用的仍是**全局** beat（char_code(…, beat) 按帧选档位）。
        fb = b % (BPL * cfg.H)
        crx, cry = fb % BPL, fb // BPL
        lrx, lry = crx, cry
        for ch in range(4):
            got = (v >> (72 - 24 * ch)) & 0xFFFFFF
            n_pix += 1
            _vt, kt = model(cfg, b, crx, cry, ch)
            _vl, kl = model(cfg, b, lrx, lry, ch, skip_text=True)
            # 优先级：**文字 > Logo > 原像素**（与 osd_mixer.v §12 和 expect_pix_at
            # 的内部次序一致）。⚠ 2026-09-14 修正：这里原先写成 `if kl == "logo"`
            # 优先，是**反的**。文字带与 Logo 带不重叠时永远碰不到，把 TB 的 TEXT_Y
            # 挪进 Logo 带之后立刻暴露（46 个重叠像素意见相左）。
            if kt == "text":
                want, kind = _vt, "text"
            elif kl == "logo":
                want, kind = _vl, "logo"
            else:
                want, kind = _vt, kt
            if got != want:
                # 分成三个面统计：安路面（比赛基础要求 (4)）、自研 Logo 面（FR-4）、
                # 文字面。三面都必须零错。
                if kind == "anlogo":
                    n_an_bad += 1
                    if n_an_bad <= 4:
                        err("ANLOGO plane cyc %d (x=%d y=%d ch=%d): got %06X want %06X"
                            % (r["cyc"], 4 * crx + ch, cry, ch, got, want))
                elif kind == "logo" or got == cfg.OSD_LOGO_COLOR or \
                        want == cfg.OSD_LOGO_COLOR:
                    n_logo_bad += 1
                    if n_logo_bad <= 4:
                        err("LOGO plane cyc %d (x=%d y=%d ch=%d): got %06X want %06X"
                            % (r["cyc"], 4 * crx + ch, cry, ch, got, want))
                else:
                    n_txt_bad += 1
                    if n_txt_bad <= 4:
                        err("TEXT plane cyc %d (x=%d y=%d ch=%d): got %06X want %06X"
                            % (r["cyc"], 4 * crx + ch, cry, ch, got, want))
                continue
            if kind == "text":
                n_rep += 1; n_txt += 1
            elif kind == "anlogo":
                n_rep += 1; n_anlogo += 1
            elif kind == "logo":
                n_rep += 1; n_logo += 1
            else:
                n_out += 1
        # 通道顺序自检：只在**没被 OSD 替换**的通道上做（被替换的像素已经不含
        # 原激励编码，拿它反解通道号没有意义）。
        dec = []
        for ch in range(4):
            gv = (v >> (72 - 24 * ch)) & 0xFFFFFF
            gb2, gx2, gc2 = decode_pix(gv)
            if not (gx2 == (4 * crx + ch) % 32 and gb2 == (cry * BPL + crx)):
                continue        # 被替换过，跳过
            dec.append(gc2)
        if dec and dec != sorted(dec):
            err("cyc %d: channel order broken: %s" % (r["cyc"], dec))

    # ---- F. 档位字形（v1.5 档位扫描）：把屏上那个数字的字形整个抠出来比对 ----
    #   为什么单独做一条：像素级比对其实已经覆盖它，但"档位号打成空白/别的数字"
    #   值得一条**指名道姓**的断言 —— M6/M7 曾经因为没有 case 而只显示一个 "M"
    #   （'?'(0x3F) 在 ASCII→字库索引里落到"未定义 → 空格"，不是打成 '?' 字形）。
    out_row_of_beat = {}
    for i in range(len(rows)):
        if rows[i]["Ov"] != 1:
            continue
        j = i - DS
        if j < 0 or rows[j]["Iv"] != 1:
            continue
        b = ((int(rows[j]["Id"], 16) >> 72) & 0xFFFFFF) >> 7
        out_row_of_beat.setdefault(b, i)

    glyph_stats = {}
    BPF = cfg.BPL * cfg.H
    for m in sorted(set(cfg.MODES)):
        npx = nbad = nblank = 0
        exp_code = ord("0") + m if 0 <= m <= 7 else ord("?")
        for fi, mm in enumerate(cfg.MODES):
            if mm != m:
                continue
            for row in range(TEXT_H):
                y = cfg.TEXT_Y + row
                exp_gb = CHAR_BITS(char_rom_idx(exp_code), row)
                spa_gb = CHAR_BITS(char_rom_idx(ord("?")), row)   # '?' → 38/39 → 空白
                for col in range(TEXT_W):
                    # 2026-09-20：档位数字从**字符槽 1** 挪到**字符槽 7**
                    #   （算法名占了 0~4 格，"M" 在 6、数字在 7）。这里不跟着改，
                    #   检查就会去抠一格空白，报"打成空白"——那是判据过期，不是 RTL 错。
                    x = cfg.TEXT_X + 7 * TEXT_W + col      # 字符槽 7 = 档位数字
                    if x >= cfg.W:
                        continue
                    # ⚠ 全局拍号 = 帧号 × 每帧拍数 + 帧内拍号（多帧 dump）
                    beat = fi * BPF + y * cfg.BPL + x // 4
                    i = out_row_of_beat.get(beat)
                    if i is None:
                        continue
                    got = (int(rows[i]["Od"], 16) >> (72 - 24 * (x % 4))) & 0xFFFFFF
                    bit = 1 if got == OSD_TEXT_COLOR else 0
                    ebit = (exp_gb >> (15 - col)) & 1
                    sbit = (spa_gb >> (15 - col)) & 1
                    npx += 1
                    if bit != ebit:
                        nbad += 1
                    if bit == sbit and ebit != sbit:
                        nblank += 1        # 屏上是空白，期望是笔画 ⇒ 打成了空白
        glyph_stats[m] = (npx, nbad, nblank)

    if verbose:
        print("  ctrl latency    : %s cycle(s) (measured on tvalid/tlast/tuser; hits %s)"
              % (ctrl_shift, ", ".join("%d:%d/%d" % (s, ctrl_hits[s][0], ctrl_hits[s][1])
                                       for s in sorted(ctrl_hits))))
        print("  valid beats     : %d" % n_valid)
        print("  pixels checked  : %d" % n_pix)
        print("  replaced (OSD)  : %d  (text %d / anlogo %d / mylogo %d)"
              % (n_rep, n_txt, n_anlogo, n_logo))
        print("  passed through  : %d" % n_out)
        print("  X/Z on valid    : %d" % n_xz)
        print("  ANLOGO plane bad: %d%s" % (n_an_bad, "" if cfg.AN_ON else "  (本 dump 无安路面)"))
        print("  LOGO plane bad  : %d" % n_logo_bad)
        print("  TEXT plane bad  : %d" % n_txt_bad)
        for m in sorted(glyph_stats):
            npx, nbad, nblank = glyph_stats[m]
            print("  MODE %d 字形     : 检查 %d px / 失配 %d / 打成空白 %d  -> '%s'"
                  % (m, npx, nbad, nblank, chr(ord("0") + m) if 0 <= m <= 7 else "?"))

    # ---- 判据 ----
    # 硬门禁（必须全过）：
    #   · Logo 面零错  —— FR-4 的硬性要求，这一项没有任何商量余地
    #   · 区外透传零错
    #   · 控制链延迟恒定
    #   · 有实际替换（测试不空转）
    # 单独报告（已知未解决，见验证报告）：
    #   · 文字面的字模取位偏差（不影响 Logo，也不影响"区外不动"这两条硬结论）
    if n_logo_bad:
        err("LOGO plane has %d mismatched pixels (must be 0)" % n_logo_bad)
    if n_an_bad:
        err("ANLOGO plane has %d mismatched pixels (must be 0)" % n_an_bad)
    # 档位字形：每个档位都必须被检查过，且不许打错、不许打成空白（M6/M7 回归护栏）
    for m in sorted(glyph_stats):
        npx, nbad, nblank = glyph_stats[m]
        if npx == 0:
            err("MODE %d 字形：一次都没检查到（测试空转）" % m)
        if nbad:
            err("MODE %d 字形：%d/%d 个像素与字库不符" % (m, nbad, npx))
        if nblank:
            err("MODE %d 字形：%d 个像素被打成**空白**（档位号没显示出来，例如缺 case）"
                % (m, nblank))
    if n_rep == 0:
        err("NO pixel was replaced at all -- the test is vacuous")
    if n_logo == 0:
        err("NO logo pixel replaced -- logo plane never exercised")
    if cfg.AN_ON and n_anlogo == 0:
        err("NO anlogic-logo pixel replaced -- anlogo plane never exercised")
    if n_txt == 0:
        err("NO text pixel replaced -- text plane never exercised")
    if n_out == 0:
        err("NO passthrough pixel -- outside-region passthrough never exercised")
    if n_xz:
        err("X/Z found on %d valid beats" % n_xz)
    if n_txt_bad:
        # 2026-09-14：文字面缺陷已修（拍内像素镜像 + 判据坐标相位），不再属于
        # "已知未解决"，与 Logo 面同为**硬门禁**。text_is_gate 形参仅为兼容旧调用。
        err("text plane has %d mismatches (strict mode)" % n_txt_bad)

    if n_err:
        print("  FAIL: %d error(s)" % n_err)
        for s in samples:
            print("    " + s)
        return False
    print("  PASS: %d pixels bit-exact; ctrl latency %s / data latency %s cycle(s)"
          % (n_pix, ctrl_shift, DS))
    return True


# ===========================================================================
# 7. 变异自证
# ===========================================================================
# 适用性判据：某些变异在**特定激励下本来就是空操作**，这时"抓不住"不代表测试无效，
#   而是这条变异没被激励到。规矩是：**不适用的必须打印原因**，不能混进"漏掉"里，
#   也不能悄悄算通过 —— 前者会把测试说得比实际差，后者会把测试说得比实际好。
# 判据入参：cfg（本次跑的配置，已含 --infcnt 覆盖）与帧档位表。
#   返回 None = 适用；返回字符串 = 不适用的**原因**。
def _na_m7(cfg):
    """M7（漏判档位门控）只在"命中数非零、且存在非 COLOR 档"时才动得了像素。

    命中数为 0 ⇒ 第 38~43 格恒为 "NONE  "，与档位无关；
    全是 COLOR 档 ⇒ 正确期望本来就是颜色名，漏判门控的输出与它一模一样。
    """
    if int(getattr(cfg, "INF_CNT", 0)) == 0:
        return "命中数为 0（INF_CNT=%d）：第 38~43 格恒为 NONE，与档位无关" % cfg.INF_CNT
    n_other = sum(1 for m in cfg.MODES if int(m) != MODE_COLOR)
    if n_other == 0:
        return "逐帧档位全是 COLOR（%s）：正确期望本就是颜色名，漏判门控输出不变" % (cfg.MODES,)
    return None


def _na_m8(cfg):
    """M8（类别轮转）只在"命中数非零、且存在 COLOR 档"时才动得了像素。"""
    if int(getattr(cfg, "INF_CNT", 0)) == 0:
        return "命中数为 0（INF_CNT=%d）：第 38~43 格恒为 NONE，类别不参与显示" % cfg.INF_CNT
    n_col = sum(1 for m in cfg.MODES if int(m) == MODE_COLOR)
    if n_col == 0:
        return "逐帧档位里没有 COLOR（%s）：颜色名一次都不上屏" % (cfg.MODES,)
    return None


def _na_m9(cfg):
    """M9（编号错一位）只在"命中数非零、且存在 COLOR 档"时才动得了像素。

    ⚠ 另外还要求**逐帧编号不是全同**：如果六帧编号都写成同一个值，
      "错一位"仍然会改变显示的两位数字，所以其实还是有鉴别力；这里只挡前两个条件。
    """
    if int(getattr(cfg, "INF_CNT", 0)) == 0:
        return "命中数为 0（INF_CNT=%d）：第 38~43 格恒为 NONE，编号不参与显示" % cfg.INF_CNT
    n_col = sum(1 for m in cfg.MODES if int(m) == MODE_COLOR)
    if n_col == 0:
        return "逐帧档位里没有 COLOR（%s）：编号一次都不上屏" % (cfg.MODES,)
    return None


NOT_APPLICABLE = {
    "M7_det_word_ignore_mode": _na_m7,
    "M8_det_class_rot": _na_m8,
    "M9_tid_off_by_one": _na_m9,
}


def mutation_applicability(dump):
    """读 dump 头建 cfg，算出每个变异在本次激励下适不适用。"""
    hdr, _rows = parse(dump)
    cfg = Config(*hdr)
    if INF_CNT_OVERRIDE is not None:
        cfg.INF_CNT = INF_CNT_OVERRIDE
    if INF_Y_OVERRIDE is not None:
        cfg.INF_Y = INF_Y_OVERRIDE
    out = {}
    for name, fn in NOT_APPLICABLE.items():
        try:
            out[name] = fn(cfg)
        except Exception as exc:                      # pragma: no cover
            out[name] = "适用性判据自身出错：%r" % (exc,)
    return out


def selftest(dump):
    print("=" * 72)
    print("变异自证：每个变异**必须被抓住**（抓不住说明测试无效）")
    print("=" * 72)
    na = mutation_applicability(dump)
    caught = missed = nna = 0
    for name in MUTATIONS:
        if na.get(name):
            print("[mut] %-20s -> N/A（%s）" % (name, na[name]))
            nna += 1
            continue
        ok = run(dump, mutation_name=name, verbose=False)
        print("[mut] %-20s -> %s" % (name, "NOT CAUGHT (测试无效!)" if ok else "caught"))
        if ok:
            missed += 1
        else:
            caught += 1
    print("[base] 基线模型（应当通过）")
    base_ok = run(dump, verbose=False)
    print("        -> %s" % ("PASS" if base_ok else "FAIL"))
    print("-" * 72)
    print("变异自证：%d/%d 被抓住，%d 条不适用（原因已逐条打印）；基线 %s"
          % (caught, len(MUTATIONS) - nna, nna, "通过" if base_ok else "失败"))
    if caught == 0:
        print("** 一条都没抓住 = 本测试对任何实现缺陷都不敏感，必须当成失败")
        return False
    return missed == 0 and base_ok


def main():
    global INF_CNT_OVERRIDE, INF_Y_OVERRIDE
    argv = sys.argv[1:]
    dump = os.path.join(HERE, "dump_osd.txt")
    if "--dump" in argv:
        dump = argv[argv.index("--dump") + 1]
    if "--infcnt" in argv:
        # 与测试台的 `+cnt0` 成对使用：+cnt0 ⇒ --infcnt 0
        INF_CNT_OVERRIDE = int(argv[argv.index("--infcnt") + 1])
    if "--infy" in argv:
        INF_Y_OVERRIDE = int(argv[argv.index("--infy") + 1])
    if "--selftest" in argv:
        sys.exit(0 if selftest(dump) else 1)
    print("check_osd.py  dump=%s" % dump)
    sys.exit(0 if run(dump) else 1)


if __name__ == "__main__":
    main()

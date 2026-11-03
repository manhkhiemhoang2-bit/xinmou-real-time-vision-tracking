#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""prep_hdmi_mixer.py —— 为 tb_hdmi_mixer.v 准备仿真输入（只读 RTL，绝不修改 RTL）

做四件事：

 1) 生成 sim\\hdmi_mixer_official.v
    官方原版 hdmi_mixer.v.official-backup 的**改名副本**：全文件恰好把
    "module hdmi_mixer #(" 换成 "module hdmi_mixer_official #("，其余逐字节原样。
    （它引用的 anlogic_logo_rom / osd_char_lib 由 run_hdmi_mixer.ps1 一起编译。）

 2) 校验端口表：改写版与官方版的参数名、端口（方向/位宽/名字/顺序）必须完全一致。

 3) 校验断言 A6(b) 的前提（这一条是"必不同"能成立的关键）：
    TB 的像素图案高字节恒落在 [TOP_LO, TOP_HI]，必须与官方 OSD 可能输出的
    **任何**颜色的高字节不相交。官方 OSD 颜色只有两个来源：
      a) anlogic_logo_rom 的 O_pixel[23:0]（透明位 bit24=1 时才是颜色）
      b) localparam COLOR_DYN_TEXT = 0xfff200
    这里把 ROM 全部 case 项解析出来，取颜色高字节的最小值，与 [TOP_LO,TOP_HI] 比对。

 4) 打印关键文件 SHA256，便于事后核对"跑的到底是哪一版"。

用法： python prep_hdmi_mixer.py
退出码：0 = 全部前提成立；非 0 = 前提不成立（仿真结果不可信，不要继续）
"""
import hashlib
import re
import sys
from pathlib import Path

sys.stdout.reconfigure(encoding="utf-8")

SIM = Path(__file__).resolve().parent


class _Tee:
    """stdout 同时落盘：日志用 utf-8 自己写，避免 PowerShell 重定向把中文搅乱。"""

    def __init__(self, path):
        self.f = open(path, "w", encoding="utf-8", newline="\n")

    def write(self, s):
        sys.__stdout__.write(s)
        self.f.write(s)

    def flush(self):
        sys.__stdout__.flush()
        self.f.flush()


sys.stdout = _Tee(SIM / "prep_hdmi_mixer.log")

HDL = SIM.parent / "prj" / "board" / "lab_ex3_osd" / "user_source" / "hdl_source"
OSD = HDL / "_removed_official_osd"          # 官方 OSD 存档（README 明确"不要恢复"）

REWRITE = HDL / "hdmi_mixer.v"               # 改写版
OFFICIAL = HDL / "hdmi_mixer.v.official-backup"
OUT = SIM / "hdmi_mixer_official.v"          # 生成的官方改名副本
ROM = OSD / "anlogic_logo_rom.v"
CHARLIB = OSD / "osd_char_lib.v"

TOP_LO, TOP_HI = 0x01, 0x10                  # TB 像素图案高字节取值区间
COLOR_DYN_TEXT = 0xFFF200

fail = []


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def check(cond, ok_msg, bad_msg):
    if cond:
        print("  [OK]   " + ok_msg)
    else:
        print("  [FAIL] " + bad_msg)
        fail.append(bad_msg)


def split_top(s: str) -> list:
    """按顶层逗号切分（方括号内的逗号不切；本工程的端口/参数表里没有花括号）。"""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "[":
            depth += 1
        elif ch == "]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return [x.strip() for x in out if x.strip()]


def parse_ports(text: str):
    m = re.search(r"module\s+(\w+)\s*#\s*\((.*?)\)\s*\((.*?)\)\s*;", text, re.S)
    if not m:
        raise RuntimeError("cannot parse module header")
    name, params, ports = m.group(1), m.group(2), m.group(3)
    # 去掉行尾注释（端口表里带中文注释，注释里还可能有逗号）
    params = re.sub(r"//[^\n]*", "", params)
    ports = re.sub(r"//[^\n]*", "", ports)
    plist = []
    for p in split_top(params):
        p = re.sub(r"\s+", " ", p)
        pname = p.split("=")[0].strip().split()[-1]
        plist.append(pname)
    olist = []
    for p in split_top(ports):
        p = re.sub(r"\s+", " ", p)
        mm = re.match(r"(input|output|inout)\s*(wire|reg)?\s*(\[[^\]]*\])?\s*(\w+)$", p)
        if not mm:
            raise RuntimeError("cannot parse port: %r" % p)
        olist.append((mm.group(1), (mm.group(3) or "").replace(" ", ""), mm.group(4)))
    return name, plist, olist


print("=" * 74)
print("prep_hdmi_mixer.py")
print("=" * 74)

# ---------------------------------------------------------------- 1) 生成副本
print("\n[1] 生成官方原版改名副本")
src = OFFICIAL.read_text(encoding="utf-8")
needle = "module hdmi_mixer #("
n = src.count(needle)
check(n == 1, "official-backup 中 'module hdmi_mixer #(' 出现 %d 次" % n,
      "official-backup 中 'module hdmi_mixer #(' 出现 %d 次（期望 1）" % n)
if fail:
    sys.exit(1)
out = src.replace(needle, "module hdmi_mixer_official #(")
check("module hdmi_mixer " not in out and "module hdmi_mixer#" not in out,
      "改写后全文件再无 'module hdmi_mixer' 残留", "改写后仍有 'module hdmi_mixer' 残留")
# 除模块名外逐字节相同
check(out.replace("module hdmi_mixer_official #(", "module hdmi_mixer #(") == src,
      "除模块名外逐字节与 official-backup 一致", "副本与 official-backup 存在其它差异")
OUT.write_bytes(out.encode("utf-8"))          # UTF-8 无 BOM；official 原本就是纯 ASCII
check(OUT.read_bytes()[:3] != b"\xef\xbb\xbf", "生成文件无 BOM", "生成文件带 BOM")
print("  -> %s  (%d bytes)" % (OUT, OUT.stat().st_size))

# ------------------------------------------------------------- 2) 端口表校验
print("\n[2] 端口表 / 参数表一致性")
nr, pr, por = parse_ports(REWRITE.read_text(encoding="utf-8"))
no, po, poo = parse_ports(OFFICIAL.read_text(encoding="utf-8"))
print("  改写版 module 名 = %s, 官方版 = %s" % (nr, no))
check(nr == "hdmi_mixer", "改写版顶层名 hdmi_mixer", "改写版顶层名异常: %s" % nr)
check(pr == po, "参数名与顺序一致: %s" % pr, "参数表不一致:\n    rewrite=%s\n    official=%s" % (pr, po))
check(por == poo, "端口方向/位宽/名字/顺序一致（共 %d 个）" % len(por),
      "端口表不一致:\n    rewrite =%s\n    official=%s" % (por, poo))

# ------------------------------------------------- 3) A6(b) 前提：颜色不相交证明
print("\n[3] A6(b) 前提：像素高字节区间 [0x%02x,0x%02x] 与官方 OSD 颜色不相交" % (TOP_LO, TOP_HI))
rom = ROM.read_text(encoding="utf-8", errors="replace")
vals = re.findall(r"15'd(\d+)\s*:\s*O_pixel\s*=\s*25'h([0-9a-fA-F]+)\s*;", rom)
check(len(vals) > 0, "解析到 anlogic_logo_rom 的 %d 条 case 项" % len(vals),
      "anlogic_logo_rom 解析失败")
if not vals:
    sys.exit(1)
v25 = [int(v, 16) for _, v in vals]
addrs = [int(a) for a, _ in vals]
check(all((v >> 24) & 1 for v in v25),
      "全部 %d 条 ROM 项的 bit24(透明位) 均为 1" % len(v25),
      "存在 bit24=0 的 ROM 项，透明逻辑前提不成立")
tops = sorted({((v & 0xFFFFFF) >> 16) for v in v25})
dyn_top = (COLOR_DYN_TEXT >> 16) & 0xFF
print("  ROM 项数=%d  distinct 24bit 颜色=%d  地址范围=[%d,%d]"
      % (len(v25), len(set(v25)), min(addrs), max(addrs)))
print("  ROM 颜色高字节 min=0x%02x max=0x%02x" % (tops[0], tops[-1]))
print("  COLOR_DYN_TEXT=0x%06x 高字节=0x%02x" % (COLOR_DYN_TEXT, dyn_top))
check(tops[0] > TOP_HI,
      "ROM 颜色高字节最小值 0x%02x > 0x%02x => 与像素高字节区间不相交" % (tops[0], TOP_HI),
      "ROM 颜色高字节最小值 0x%02x 落入像素区间 [0x%02x,0x%02x]" % (tops[0], TOP_LO, TOP_HI))
check(not (TOP_LO <= dyn_top <= TOP_HI),
      "COLOR_DYN_TEXT 高字节 0x%02x 不在像素区间内" % dyn_top,
      "COLOR_DYN_TEXT 高字节 0x%02x 落入像素区间" % dyn_top)
# Logo 区确实有非透明像素（否则 A6(b) 集合会空）
hits = [(a // 160, a % 160) for a in addrs if a < 160 * 160]
check(len(hits) > 0, "ROM 非透明像素 %d 个落在 LOGO 区(160x160)内, y范围=[%d,%d] x范围=[%d,%d]"
      % (len(hits), min(h[0] for h in hits), max(h[0] for h in hits),
         min(h[1] for h in hits), max(h[1] for h in hits)),
      "ROM 非透明像素不在 LOGO 区内")

# ------------------------------------------------------------------ 4) 指纹
print("\n[4] SHA256 指纹")
for p in (REWRITE, OFFICIAL, OUT, ROM, CHARLIB, SIM / "tb_hdmi_mixer.v"):
    if p.exists():
        print("  %s  %s" % (sha256(p)[:32], p))

print("\n" + "=" * 74)
if fail:
    print("PREP RESULT: FAIL  (%d 项前提不成立)" % len(fail))
    sys.exit(1)
print("PREP RESULT: PASS")
sys.exit(0)

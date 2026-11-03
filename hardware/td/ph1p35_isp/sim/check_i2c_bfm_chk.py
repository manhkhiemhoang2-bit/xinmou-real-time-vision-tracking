#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_i2c_bfm_chk.py -- 验证 mpu6050_slave_bfm 自己是对的

为什么要有这一层：
    手写的从机模型去验手写的主机，最危险的失败是"两个一起错、还互相吻合"。
    所以先拿一个**已知good的主机**（uii2c，摄像头配置正在用它、已在硬件上跑通）
    去反证从机模型。这条过了，mpu6050_slave_bfm 才有资格去验 gim_imu_i2c。

输入：sim\\_i2c_bfm_chk\\dump_i2c_bfm_chk.txt
用法：
    python check_i2c_bfm_chk.py --dump sim\\_i2c_bfm_chk\\dump_i2c_bfm_chk.txt
    python check_i2c_bfm_chk.py --dump ... --selftest

判据：
    B1  配置写：从机记录到 (0x6B, 0x00) 且只写了 1 个数据字节
    B2  随机读：14 字节与注入值**逐字节相符、同序**
        （注入值每一字节都不一样，所以顺序错、字节错位、高低字节颠倒都能一眼看出）
    B3  总线健康：bus_err=0、ack_err=0、rd_bytes=14
    B4  读的起始寄存器地址 = 0x3B

这条同时钉死了 uii2c 的字节序（gim_imu_i2c 依赖它）：
    写 I_wr_data[7:0] 先发；读 O_rd_data[7:0] 是第一个收到的字节。
"""
from __future__ import annotations

import argparse
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")


HEX_KEYS = {"AX", "AY", "AZ", "TP", "GX", "GY", "GZ"}   # 这些在 dump 头里是十六进制


def parse(path):
    hdr, W, R = {}, [], None
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            if ln.startswith("#"):
                for k, v in re.findall(r"([A-Za-z_]\w*)=([0-9a-fA-F]+)", ln):
                    # ⚠ 不能按"是不是大写"判进制：CLK_DIV 是大写但是十进制。
                    hdr[k] = int(v, 16) if k in HEX_KEYS else int(v)
                continue
            p = ln.split()
            if p[0] == "W" and len(p) == 3:
                W.append((int(p[1]), int(p[2])))
            elif p[0] == "R":
                R = [int(x) for x in p[1:]]
            else:
                raise ValueError("不认识的 dump 行：%r" % ln)
    return hdr, W, R


def judge(hdr, W, R, mut=None, verbose=True):
    mut = mut or {}
    nass = nbad = 0

    def chk(cond, label, detail=""):
        nonlocal nass, nbad
        nass += 1
        if not cond:
            nbad += 1
            if verbose:
                print("    FAIL %s  %s" % (label, detail))

    # ---- 由注入值算期望的 14 字节 ----
    AX, AY, AZ = hdr["AX"], hdr["AY"], hdr["AZ"]
    TP, GX, GY, GZ = hdr["TP"], hdr["GX"], hdr["GY"], hdr["GZ"]
    exp = []
    for w in (AX, AY, AZ, TP, GX, GY, GZ):
        exp += [(w >> 8) & 0xFF, w & 0xFF]
    if mut.get("swap_nib"):
        exp = [((b << 4) & 0xF0) | ((b >> 4) & 0x0F) for b in exp]
    if mut.get("swap_bytes"):
        # 每个 16 位字内高低字节对调 —— 这条正对着 BFM 早先写错的"奇偶地址映射"
        exp = [exp[i + 1] if i % 2 == 0 else exp[i - 1] for i in range(len(exp))]
    if mut.get("rot"):
        exp = exp[1:] + exp[:1]
    if "corrupt_idx" in mut:
        k = mut["corrupt_idx"]
        if k < len(exp):
            exp[k] = (exp[k] + 1) & 0xFF

    # ---- B1 配置写 ----
    chk(len(W) == 1 and W[0] == (0x6B, 0x00), "B1 配置写 (0x6B,0x00)",
        "从机记录到 %r" % (W,))
    if verbose:
        print("  B1 配置写：从机记录到 %r（期望 [(107, 0)]）" % (W,))

    # ---- B2 14 字节连读 ----
    R = R or []
    chk(len(R) == 14, "B2 读到 14 字节", "实际 %d 字节" % len(R))
    for i in range(min(len(R), len(exp))):
        chk(R[i] == exp[i], "B2[第%d字节]" % i,
            "实测 0x%02X，期望 0x%02X" % (R[i], exp[i]))
    if verbose:
        print("  B2 连读 14 字节：比对 %d 字节" % min(len(R), len(exp)))

    # ---- B3 总线健康 ----
    chk(hdr.get("bus_err", -1) == 0, "B3 总线无错", "bus_err=%s" % hdr.get("bus_err"))
    chk(hdr.get("ack_err", -1) == 0, "B3 无地址不匹配", "ack_err=%s" % hdr.get("ack_err"))
    chk(hdr.get("rd_bytes", -1) == 14, "B3 从机报告读了 14 字节",
        "rd_bytes=%s" % hdr.get("rd_bytes"))
    if verbose:
        print("  B3 总线健康：bus_err=%s ack_err=%s rd_bytes=%s wr_bytes=%s"
              % (hdr.get("bus_err"), hdr.get("ack_err"),
                 hdr.get("rd_bytes"), hdr.get("wr_bytes")))

    # ---- B4 读的起始寄存器 ----
    chk(hdr.get("last_addr", -1) == 0x3B, "B4 读起始寄存器 = 0x3B",
        "last_addr=%s(0x%02X)" % (hdr.get("last_addr", -1), hdr.get("last_addr", 0)))
    if verbose:
        print("  B4 读起始寄存器：last_addr=0x%02X（期望 0x3B）" % hdr.get("last_addr", 0))

    return nass, nbad


MUTATIONS = [
    ("14 字节整体左旋 1",   {"rot": True}),
    ("每个字高低字节对调",   {"swap_bytes": True}),
    ("每字节半字节交换",     {"swap_nib": True}),
    ("第 0 字节改 1",       {"corrupt_idx": 0}),
    ("第 13 字节改 1",      {"corrupt_idx": 13}),
]


def selftest(hdr, W, R):
    a0, b0 = judge(hdr, W, R, None, verbose=False)
    print("  基线：断言 %d / 不符 %d" % (a0, b0))
    if b0 != 0:
        print("  ⚠ 基线本身就不符，变异自证无意义")
        return 1
    ok = 0
    for label, mut in MUTATIONS:
        a, b = judge(hdr, W, R, mut, verbose=False)
        caught = b > 0
        print("  [mut] %-22s -> %s（断言 %d / 不符 %d）"
              % (label, "抓住" if caught else "**漏掉**", a, b))
        ok += 1 if caught else 0
    print("------------------------------------------------------------------------")
    print("变异自证：%d/%d 被抓住" % (ok, len(MUTATIONS)))
    return 0 if ok == len(MUTATIONS) else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump", required=True)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    hdr, W, R = parse(args.dump)
    print("=" * 78)
    print("check_i2c_bfm_chk.py  dump=%s" % args.dump)
    print("  CLK_DIV=%s  注入 AX=%04X AY=%04X AZ=%04X TP=%04X GX=%04X GY=%04X GZ=%04X"
          % (hdr.get("CLK_DIV"), hdr.get("AX", 0), hdr.get("AY", 0), hdr.get("AZ", 0),
             hdr.get("TP", 0), hdr.get("GX", 0), hdr.get("GY", 0), hdr.get("GZ", 0)))
    print("=" * 78)

    if args.selftest:
        rc = selftest(hdr, W, R)
        print("=" * 78)
        print("结论：%s" % ("PASS" if rc == 0 else "FAIL"))
        return rc

    nass, nbad = judge(hdr, W, R, None, verbose=True)
    print("=" * 78)
    print("合计断言 %d / 不符 %d" % (nass, nbad))
    print("结论：%s" % ("PASS" if nbad == 0 else "FAIL —— %d 条不符" % nbad))
    return 0 if nbad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

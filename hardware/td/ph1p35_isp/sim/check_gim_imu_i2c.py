#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
check_gim_imu_i2c.py -- gim_imu_i2c（MPU6050 配置序列 + 256Hz 周期读）的判据

输入：sim\\_gim_imu\\dump_gim_imu.txt（正常跑）
      sim\\_gim_imu\\dump_gim_imu_noack.txt（+noack 故障注入跑，可选）
用法：
    python check_gim_imu_i2c.py --dump sim\\_gim_imu\\dump_gim_imu.txt
    python check_gim_imu_i2c.py --dump ... --noack-dump sim\\_gim_imu\\dump_gim_imu_noack.txt
    python check_gim_imu_i2c.py --dump ... --selftest

判据：
    K1  配置序列：**恰好 6 条**，地址/数据/顺序全对
        （0x6B←0x80, 0x6B←0x01, 0x19←0x00, 0x1A←0x03, 0x1B←0x00, 0x1C←0x00）
        ⚠ 这条是踩过坑的：第一版"由 r_cfg_i 组合出 cfg_*"，六条整体错位、最后一条丢了。
    K2  WHO_AM_I 判 bits[6:1]（= 0x34）⇒ O_imu_ok=1 且 O_imu_err=0
    K3  14 字节拆包正确：每个 16 位量的**高低字节没反**，且每个周期都取到"当时"的值
    K4  采样间隔 ≈ CYC_DLY（±1%）—— 踩过坑：写成"事务后再延时"会变成 CYC_DLY+事务时间
    K5  故障注入（从机不回 ACK）时 O_imu_err 必须置位、不能默默跑到天亮

反循环：本脚本只读 dump，不读 DUT 内部信号，也不 import RTL。
"""
from __future__ import annotations

import argparse
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

CFG_EXPECT = [
    (0x6B, 0x80),   # PWR_MGMT_1 器件复位
    (0x6B, 0x01),   # PWR_MGMT_1 唤醒 + X 陀螺 PLL
    (0x19, 0x00),   # SMPLRT_DIV
    (0x1A, 0x03),   # CONFIG：DLPF 42Hz
    (0x1B, 0x00),   # GYRO_CONFIG：±250°/s
    (0x1C, 0x00),   # ACCEL_CONFIG：±2g
]
WHO_ADDR_6B = 0x34


def parse(path):
    hdr, W, D, exp = {}, [], [], {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            if ln.startswith("#"):
                m = re.match(r"#\s*exp\s+k(\d+)\s+(.*)$", ln)
                if m:
                    exp[int(m.group(1))] = [int(x, 16) for x in m.group(2).split()]
                    continue
                for k, v in re.findall(r"([A-Za-z_]\w*)=(-?\d+)", ln):
                    hdr[k] = int(v)
                continue
            p = ln.split()
            if p[0] == "W" and len(p) == 3:
                W.append((int(p[1]), int(p[2])))
            elif p[0] == "D" and len(p) == 10:
                D.append(tuple(int(x) for x in p[1:]))
            else:
                raise ValueError("不认识的 dump 行：%r" % ln)
    return hdr, W, D, exp


def judge(hdr, W, D, exp, mut=None, verbose=True, noack_hdr=None):
    mut = mut or {}
    nass = nbad = 0

    def chk(cond, label, detail=""):
        nonlocal nass, nbad
        nass += 1
        if not cond:
            nbad += 1
            if verbose:
                print("    FAIL %s  %s" % (label, detail))

    # ---- K1 配置序列 ----
    wl = list(W)
    if mut.get("cfg_shift"):
        # 模拟"配置表错位一位"那个 bug：第二条写成第一条、最后一条丢
        wl = [wl[0]] + wl[0:len(wl) - 1] if wl else wl
    chk(len(wl) == len(CFG_EXPECT), "K1 配置写恰好 6 条",
        "实际 %d 条：%r" % (len(wl), wl))
    for i in range(min(len(wl), len(CFG_EXPECT))):
        chk(wl[i] == CFG_EXPECT[i], "K1[第%d条]" % i,
            "实测 (0x%02X,0x%02X)，期望 (0x%02X,0x%02X)"
            % (wl[i][0], wl[i][1], CFG_EXPECT[i][0], CFG_EXPECT[i][1]))
    if verbose:
        print("  K1 配置序列：%d 条（期望 6 条）%s" % (len(wl), "" if wl == CFG_EXPECT else "有出入"))

    # ---- K2 WHO_AM_I ----
    who = hdr.get("who", -1)
    chk((who >> 1) & 0x3F == WHO_ADDR_6B, "K2 WHO_AM_I bits[6:1] = 0x34",
        "读回 0x%02X，bits[6:1]=0x%02X" % (who, (who >> 1) & 0x3F))
    chk(hdr.get("imu_ok", 0) == 1, "K2 O_imu_ok 置位", "imu_ok=%s" % hdr.get("imu_ok"))
    if verbose:
        print("  K2 WHO_AM_I：读回 0x%02X（bits[6:1]=0x%02X），imu_ok=%s"
              % (who, (who >> 1) & 0x3F, hdr.get("imu_ok")))

    # ---- K3 拆包 ----
    n3 = min(len(D), len(exp))
    for row in D:
        cyc, k = row[0], row[1]
        got = list(row[2:])
        e = exp.get(k)
        if e is None:
            continue
        if mut.get("swap_bytes"):
            e = [((b >> 8) | ((b & 0xFF) << 8)) & 0xFFFF for b in e]
        if mut.get("rot"):
            e = e[1:] + e[:1]
        for j in range(len(e)):
            chk(got[j] == e[j], "K3[k%d 第%d个量]" % (k, j),
                "实测 0x%04X，期望 0x%04X" % (got[j], e[j]))
    chk(n3 >= 3, "K3 至少检查到 3 个读周期", "只有 %d 个" % n3)
    if verbose:
        print("  K3 拆包：%d 个周期 × 7 个 16 位量" % n3)

    # ---- K4 采样间隔 ----
    cyc_dly = hdr.get("CYC_DLY", 0)
    gaps = [D[i + 1][0] - D[i][0] for i in range(len(D) - 1)]
    if mut.get("period_plus_txn"):
        cyc_dly = cyc_dly + 80000          # 模拟"事务后再延时"那个 bug
    for i, g in enumerate(gaps):
        chk(abs(g - cyc_dly) <= cyc_dly // 100, "K4 第%d个间隔" % i,
            "实测 %d 拍，期望 %d±1%%" % (g, cyc_dly))
    chk(len(gaps) >= 2, "K4 至少量到 2 个间隔", "只有 %d 个" % len(gaps))
    if verbose:
        print("  K4 采样间隔：CYC_DLY=%d，实测 %r（%.2f Hz）"
              % (cyc_dly, gaps, 50000000.0 / (sum(gaps) / len(gaps)) if gaps else 0))

    # ---- K5 故障注入（可选）----
    if noack_hdr is not None:
        chk(noack_hdr.get("imu_err", 0) == 1, "K5 无 ACK 时 O_imu_err 置位",
            "imu_err=%s" % noack_hdr.get("imu_err"))
        chk(noack_hdr.get("imu_ok", 0) == 0, "K5 无 ACK 时 O_imu_ok 不置位",
            "imu_ok=%s" % noack_hdr.get("imu_ok"))
        chk(len(noack_hdr.get("_D", [])) == 0, "K5 无 ACK 时读不到数据",
            "竟然读到 %d 个周期" % len(noack_hdr.get("_D", [])))
        if verbose:
            print("  K5 故障注入：imu_err=%s imu_ok=%s 读到周期数=%d"
                  % (noack_hdr.get("imu_err"), noack_hdr.get("imu_ok"),
                     len(noack_hdr.get("_D", []))))

    return nass, nbad


MUTATIONS = [
    ("配置序列错位一位",   {"cfg_shift": True}),
    ("每个量高低字节对调", {"swap_bytes": True}),
    ("7 个量整体左旋 1",   {"rot": True}),
    ("周期按 CYC_DLY+事务", {"period_plus_txn": True}),
]


def selftest(hdr, W, D, exp):
    a0, b0 = judge(hdr, W, D, exp, None, verbose=False)
    print("  基线：断言 %d / 不符 %d" % (a0, b0))
    if b0 != 0:
        print("  ⚠ 基线本身就不符，变异自证无意义")
        return 1
    ok = 0
    for label, mut in MUTATIONS:
        a, b = judge(hdr, W, D, exp, mut, verbose=False)
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
    ap.add_argument("--noack-dump", default=None)
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    hdr, W, D, exp = parse(args.dump)
    nh = None
    if args.noack_dump:
        nh2, _w2, d2, _e2 = parse(args.noack_dump)
        nh2["_D"] = d2
        nh = nh2

    print("=" * 78)
    print("check_gim_imu_i2c.py  dump=%s" % args.dump)
    print("  CYC_DLY=%s CLK_DIV=%s；配置写 %d 条，读周期 %d 个"
          % (hdr.get("CYC_DLY"), hdr.get("CLK_DIV"), len(W), len(D)))
    print("=" * 78)

    if args.selftest:
        rc = selftest(hdr, W, D, exp)
        print("=" * 78)
        print("结论：%s" % ("PASS" if rc == 0 else "FAIL"))
        return rc

    nass, nbad = judge(hdr, W, D, exp, None, verbose=True, noack_hdr=nh)
    print("=" * 78)
    print("合计断言 %d / 不符 %d" % (nass, nbad))
    print("结论：%s" % ("PASS" if nbad == 0 else "FAIL —— %d 条不符" % nbad))
    return 0 if nbad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())

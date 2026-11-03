# -*- coding: utf-8 -*-
"""check_ext_ctrl_wiring.py —— ext_ctrl 板级接入的**静态一致性检查**

板级工程带 TD IP，命令行跑不了综合，所以这里做不依赖 TD 的静态核对：
  1) isp_top 的端口表 vs design_top_wrapper 里 isp_top 例化的具名连接
     —— 连接名必须都是真端口；每个端口都必须被连到（含新增的 7 个检测结果输出）
  2) ext_ctrl 的端口表 vs wrapper 里 ext_ctrl 例化的具名连接（必须全连）
  3) wrapper 的顶层端口 O_led / O_buzzer 已声明、且由 ext_ctrl 驱动
  4) pin.adc 里 O_led[0..3] / O_buzzer 五条引脚约束齐全且不重复
  5) .al 工程文件里列到了 alg/ext_ctrl.v
  6) 两份 isp_top（_fullchip 与板级）逐字节一致；ext_ctrl 正本与板级副本逐字节一致

用法： python check_ext_ctrl_wiring.py
"""
import os
import re
import sys

sys.stdout.reconfigure(encoding="utf-8")

ROOT = r"D:\TD\bin\work_for_all\ph1p35_isp"
ISP_A = os.path.join(ROOT, r"prj\_fullchip\isp_top_alg.v")
ISP_B = os.path.join(ROOT, r"prj\board\lab_ex3_osd\user_source\hdl_source\isp\isp_top.v")
WRAP = os.path.join(ROOT, r"prj\board\lab_ex3_osd\user_source\hdl_source\design_top_wrapper.v")
PIN = os.path.join(ROOT, r"prj\board\lab_ex3_osd\user_source\constraints_source\pin.adc")
AL = os.path.join(ROOT, r"prj\board\lab_ex3_osd\td_project\camera_to_dsi_display.al")
EXT_SRC = os.path.join(ROOT, r"src\ext_ctrl.v")
EXT_DST = os.path.join(ROOT, r"prj\board\lab_ex3_osd\user_source\hdl_source\alg\ext_ctrl.v")

RES = []


def chk(name, n, bad, note=""):
    RES.append((name, n, bad, note))


def rd(p):
    return open(p, "r", encoding="utf-8", errors="replace").read()


def port_list(text, mod):
    """取 module <mod> (...) 的端口名列表（去方向/位宽/注释）"""
    m = re.search(r"\bmodule\s+%s\s*(#\s*\([^;]*?\)\s*)?\((.*?)\)\s*;" % mod, text, re.S)
    if not m:
        return None
    body = m.group(2)
    body = re.sub(r"//[^\n]*", "", body)
    names = []
    for seg in body.split(","):
        toks = seg.split()
        if not toks:
            continue
        # 去掉 input/output/inout/wire/reg 与位宽
        keep = [t for t in toks
                if t not in ("input", "output", "inout", "wire", "reg", "signed")
                and not t.startswith("[")]
        if keep:
            names.append(keep[-1])
    return names


def instance_conns(text, mod, inst):
    """取 <mod> [#( ... )] <inst> ( ... ); 的具名连接 -> {port: expr}"""
    m = re.search(r"\b%s\s*(?:#\s*\((?:[^()]|\([^()]*\))*\)\s*)?%s\s*\((.*?)\)\s*;"
                  % (mod, inst), text, re.S)
    if not m:
        return None
    body = re.sub(r"//[^\n]*", "", m.group(1))
    conns = {}
    for pm in re.finditer(r"\.\s*(\w+)\s*\(([^()]*)\)", body):
        conns[pm.group(1)] = pm.group(2).strip()
    return conns


def instance_params(text, mod, inst):
    """取 <mod> #( ... ) <inst> 的具名参数覆盖 -> {param: expr}；无 #() 返回 {}"""
    m = re.search(r"\b%s\s*#\s*\((.*?)\)\s*%s\s*\(" % (mod, inst), text, re.S)
    if not m:
        return {}
    body = re.sub(r"//[^\n]*", "", m.group(1))
    out = {}
    for pm in re.finditer(r"\.\s*(\w+)\s*\(([^()]*)\)", body):
        out[pm.group(1)] = pm.group(2).strip()
    return out


def param_list(text, mod):
    """取 module <mod> #( ... ) 的 parameter 名列表"""
    m = re.search(r"\bmodule\s+%s\s*#\s*\((.*?)\)\s*\(" % mod, text, re.S)
    if not m:
        return None
    body = re.sub(r"//[^\n]*", "", m.group(1))
    names = []
    for seg in body.split(","):
        t = [x for x in seg.split()
             if x not in ("parameter", "integer", "signed", "localparam")]
        t = [x for x in t if not x.startswith("[")]
        if t:
            names.append(t[0])
    return names


def main():
    isp_a, isp_b = rd(ISP_A), rd(ISP_B)
    wrap = rd(WRAP)
    pin = rd(PIN)
    al = rd(AL)

    # ---- 1. isp_top 端口 vs 例化 ----
    ports = port_list(isp_a, "isp_top")
    conns = instance_conns(wrap, "isp_top", "u_isp_top")
    if ports is None or conns is None:
        chk("isp_top 端口表/例化可解析", 0, 1, "正则没匹配到")
    else:
        unknown = [k for k in conns if k not in ports]
        chk("isp_top 例化无未知端口", len(conns), len(unknown), ",".join(unknown))
        unconn = [p for p in ports if p not in conns]
        chk("isp_top 端口全部被连接", len(ports), len(unconn), ",".join(unconn))
        new7 = ["O_bbox_x0", "O_bbox_x1", "O_bbox_y0", "O_bbox_y1",
                "O_bbox_valid", "O_pix_count", "O_mode"]
        miss = [p for p in new7 if p not in ports]
        chk("isp_top 已新增 7 个检测结果输出端口", len(new7), len(miss), ",".join(miss))
        miss = [p for p in new7 if p not in conns]
        chk("7 个新端口在 wrapper 里已连线", len(new7), len(miss), ",".join(miss))

    # ---- 2. ext_ctrl 端口 vs 例化 ----
    extp = port_list(rd(EXT_SRC), "ext_ctrl")
    extc = instance_conns(wrap, "ext_ctrl", "u_ext_ctrl")
    if extp is None or extc is None:
        chk("ext_ctrl 端口表/例化可解析", 0, 1, "正则没匹配到")
    else:
        unknown = [k for k in extc if k not in extp]
        chk("ext_ctrl 例化无未知端口", len(extc), len(unknown), ",".join(unknown))
        unconn = [p for p in extp if p not in extc]
        chk("ext_ctrl 端口全部被连接", len(extp), len(unconn), ",".join(unconn))
        empty = [p for p, v in extc.items() if v == ""]
        chk("ext_ctrl 无空连接", len(extc), len(empty), ",".join(empty))

    # ---- 2b. ext_ctrl 例化的参数覆盖必须都是真参数 ----
    extpl = param_list(rd(EXT_SRC), "ext_ctrl")
    over = instance_params(wrap, "ext_ctrl", "u_ext_ctrl")
    if extpl is None:
        chk("ext_ctrl 参数表可解析", 0, 1, "正则没匹配到")
    else:
        badp = [k for k in over if k not in extpl]
        chk("ext_ctrl 参数覆盖名都合法(%s)" % (",".join(sorted(over)) if over else "无覆盖"),
            max(len(over), 1), len(badp), ",".join(badp))

    # ---- 3. wrapper 顶层端口 ----
    wports = port_list(wrap, "design_top_wrapper")
    need = ["O_led", "O_buzzer"]
    miss = [p for p in need if wports is None or p not in wports]
    chk("wrapper 顶层已声明 O_led/O_buzzer", len(need), len(miss), ",".join(miss))
    if extc:
        drv = [p for p in need if extc.get(p, "") != "" and p in extc.get(p, "")]
        chk("O_led/O_buzzer 由 ext_ctrl 驱动", len(need), len(need) - len(drv),
            "未接:" + ",".join([p for p in need if p not in drv]))

    # ---- 4. pin.adc ----
    locs = {}
    for m in re.finditer(r"set_pin_assignment\s*\{\s*([^}]+?)\s*\}\s*\{\s*LOCATION\s*=\s*(\w+)", pin):
        locs.setdefault(m.group(1), []).append(m.group(2))
    want = {"O_led[0]": "E10", "O_led[1]": "C6", "O_led[2]": "D6",
            "O_led[3]": "A5", "O_buzzer": "C12"}
    bad = []
    for k, v in want.items():
        got = locs.get(k)
        if not got or got[0] != v or len(got) != 1:
            bad.append("%s(期望%s,实际%s)" % (k, v, got))
    chk("pin.adc 新增 5 条约束齐全且球号正确", len(want), len(bad), ",".join(bad))
    dup = [k for k, v in locs.items() if len(v) > 1]
    chk("pin.adc 无重复约束", len(locs), len(dup), ",".join(dup))
    allpin = [v[0] for v in locs.values()]
    chk("pin.adc 无重复球号", len(allpin), len(allpin) - len(set(allpin)),
        ",".join([p for p in set(allpin) if allpin.count(p) > 1]))

    # ---- 5. .al 源文件表 ----
    ok = "hdl_source/alg/ext_ctrl.v" in al
    chk(".al 已列入 alg/ext_ctrl.v", 1, 0 if ok else 1)

    # ---- 6. 副本一致 ----
    chk("两份 isp_top 逐字节一致", 1, 0 if isp_a == isp_b else 1)
    chk("ext_ctrl 正本/板级副本一致", 1,
        0 if open(EXT_SRC, "rb").read() == open(EXT_DST, "rb").read() else 1)

    print("=" * 76)
    print("%-46s %8s %8s" % ("静态检查项", "检查数", "不通过"))
    print("-" * 76)
    badn = 0
    for name, n, b, note in RES:
        f = ""
        if b:
            f = "  <== " + (note if note else "不通过")
            badn += 1
        if n == 0:
            f += "  <== 0 次检查"
            badn += 1
        print("%-46s %8d %8d%s" % (name, n, b, f))
    print("-" * 76)
    print("结论: %s" % ("FAIL" if badn else "PASS"))
    return 1 if badn else 0


if __name__ == "__main__":
    sys.exit(main())

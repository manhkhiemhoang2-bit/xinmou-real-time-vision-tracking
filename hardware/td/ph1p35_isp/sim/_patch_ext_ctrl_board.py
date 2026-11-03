# -*- coding: utf-8 -*-
"""_patch_ext_ctrl_board.py —— ext_ctrl 的板级接入补丁（一次性，可重复执行）

改 5 个文件 + 同步 1 个文件：
  1) prj\\_fullchip\\isp_top_alg.v                                     新增 7 个检测结果输出端口
  2) prj\\board\\lab_ex3_osd\\user_source\\hdl_source\\isp\\isp_top.v    与 (1) 保持逐字节一致
  3) prj\\board\\...\\hdl_source\\design_top_wrapper.v                  新增 O_led/O_buzzer 端口、
                                                                        wire、isp_top 连线、ext_ctrl 例化
  4) prj\\board\\...\\constraints_source\\pin.adc                       追加 5 条引脚约束
  5) prj\\board\\...\\td_project\\camera_to_dsi_display.al              追加 ext_ctrl.v 源文件条目
  6) src\\ext_ctrl.v -> user_source\\hdl_source\\alg\\ext_ctrl.v        同步副本

**只用精确串替换，保留原文件的 CRLF/LF 与空白**；每个锚点必须恰好命中一次。
"""
import hashlib
import os
import shutil
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

T = "\t"
NEW_PORTS = (
    "    output " + T + T + T + "I_tready" + T + T + ",\r\n"
    "    // ---- 检测结果引出（ext_ctrl：象限 LED + 蜂鸣器）2026-09-17 ----\r\n"
    "    output [10:0] " + T + "O_bbox_x0" + T + T + ",\r\n"
    "    output [10:0] " + T + "O_bbox_x1" + T + T + ",\r\n"
    "    output [10:0] " + T + "O_bbox_y0" + T + T + ",\r\n"
    "    output [10:0] " + T + "O_bbox_y1" + T + T + ",\r\n"
    "    output " + T + T + T + "O_bbox_valid" + T + ",\r\n"
    "    output [31:0] " + T + "O_pix_count" + T + T + ",\r\n"
    "    output [ 2:0] " + T + "O_mode\r\n"
    ");\r\n"
)

NEW_ASSIGNS = (
    "  assign O_tvalid = awb_O_tvalid_128   ;\r\n"
    "\r\n"
    "  // ---- 检测结果引到顶层（供 ext_ctrl 做象限 LED / 蜂鸣器）----\r\n"
    "  assign O_bbox_x0    = alg_x0    ;  //synthesis keep\r\n"
    "  assign O_bbox_x1    = alg_x1    ;  //synthesis keep\r\n"
    "  assign O_bbox_y0    = alg_y0    ;  //synthesis keep\r\n"
    "  assign O_bbox_y1    = alg_y1    ;  //synthesis keep\r\n"
    "  assign O_bbox_valid = alg_bbox_v;  //synthesis keep\r\n"
    "  assign O_pix_count  = alg_O_cnt ;  //synthesis keep\r\n"
    "  assign O_mode       = alg_O_mode;  //synthesis keep\r\n"
)

WRAP_PORTS_OLD = "    inout wire[1:0]   ddr_dqs_n   \r\n);\r\n"
WRAP_PORTS_NEW = (
    "    inout wire[1:0]   ddr_dqs_n,\r\n"
    "\r\n"
    "    output wire[3:0]  O_led,\r\n"
    "    output wire       O_buzzer\r\n"
    ");\r\n"
)

WRAP_WIRES_OLD = "\twire \t\t\tS_ISP_O_tvalid; \r\n"
WRAP_WIRES_NEW = (
    "\twire \t\t\tS_ISP_O_tvalid; \r\n"
    "\twire [10:0]\tS_ISP_O_bbox_x0;\r\n"
    "\twire [10:0]\tS_ISP_O_bbox_x1;\r\n"
    "\twire [10:0]\tS_ISP_O_bbox_y0;\r\n"
    "\twire [10:0]\tS_ISP_O_bbox_y1;\r\n"
    "\twire \t\t\tS_ISP_O_bbox_valid;\r\n"
    "\twire [31:0]\tS_ISP_O_pix_count;\r\n"
    "\twire [ 2:0]\tS_ISP_O_mode;\r\n"
)

WRAP_INST_OLD = (".O_tvalid        (S_ISP_O_tvalid),\r\n"
                 ".I_tready        ()\r\n"
                 "  );\r\n")
WRAP_INST_NEW = (
    ".O_tvalid        (S_ISP_O_tvalid),\r\n"
    ".I_tready        (),\r\n"
    ".O_bbox_x0       (S_ISP_O_bbox_x0),\r\n"
    ".O_bbox_x1       (S_ISP_O_bbox_x1),\r\n"
    ".O_bbox_y0       (S_ISP_O_bbox_y0),\r\n"
    ".O_bbox_y1       (S_ISP_O_bbox_y1),\r\n"
    ".O_bbox_valid    (S_ISP_O_bbox_valid),\r\n"
    ".O_pix_count     (S_ISP_O_pix_count),\r\n"
    ".O_mode          (S_ISP_O_mode)\r\n"
    "  );\r\n"
    "\r\n"
    "\r\n"
    "//检测结果外部控制：目标象限 LED + 蜂鸣器（扩展要求 2.4(3)）\r\n"
    "ext_ctrl u_ext_ctrl (\r\n"
    ".I_clk        (S_csi_rx_clk     ),\r\n"
    ".I_rst_n      (S_rst_n         ),\r\n"
    ".I_frame      (S_ISP_O_tuser   ),   // 每帧 1 拍；不可与 tvalid 相与（见 ext_ctrl 文件头）\r\n"
    ".I_bbox_x0    (S_ISP_O_bbox_x0 ),\r\n"
    ".I_bbox_x1    (S_ISP_O_bbox_x1 ),\r\n"
    ".I_bbox_y0    (S_ISP_O_bbox_y0 ),\r\n"
    ".I_bbox_y1    (S_ISP_O_bbox_y1 ),\r\n"
    ".I_bbox_valid (S_ISP_O_bbox_valid),\r\n"
    ".I_pix_count  (S_ISP_O_pix_count),\r\n"
    ".O_led        (O_led           ),\r\n"
    ".O_buzzer     (O_buzzer        )\r\n"
    "  );\r\n"
)

PIN_APPEND = """
#==============================================================================
# 追加（2026-09-17）：扩展要求 2.4(3)「根据视频识别结果实现外部控制」
#   LED0~LED3 = E10 / C6 / D6 / A5，BUZZER = C12（IO_T0_42，BANK42）
#   依据：C:\\Users\\29072\\Desktop\\安陆资料汇总\\10_设计文档\\S0\\资料补读\\03_原理图核对报告.md
#         §9 表：LED0~LED3 = E10, C6, D6, A5；BUZZER = C12（IO_T0_42）
#   ⚠ LED 极性与蜂鸣器驱动极性在原理图文字层读不出，按常规先设高有效；
#     若上板发现反相，只需改 design_top_wrapper 里 ext_ctrl 的 BUZZ_ACT_LOW
#     或在此处加反相器，不改 RTL 逻辑。
#==============================================================================
set_pin_assignment	{ O_led[0] }			{ LOCATION = E10; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = PULLUP; }
set_pin_assignment	{ O_led[1] }			{ LOCATION = C6;  IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = PULLUP; }
set_pin_assignment	{ O_led[2] }			{ LOCATION = D6;  IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = PULLUP; }
set_pin_assignment	{ O_led[3] }			{ LOCATION = A5;  IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = PULLUP; }
set_pin_assignment	{ O_buzzer }			{ LOCATION = C12; IOSTANDARD = LVCMOS33; DRIVESTRENGTH = 8; PULLTYPE = PULLUP; }
"""

AL_OLD = "        </Verilog>\r\n"
AL_NEW = (
    "            <File Path=\"../user_source/hdl_source/alg/ext_ctrl.v\">\r\n"
    "                <FileInfo>\r\n"
    "                    <Attr Name=\"UsedInSyn\" Val=\"true\"/>\r\n"
    "                    <Attr Name=\"UsedInP&R\" Val=\"true\"/>\r\n"
    "                    <Attr Name=\"BelongTo\" Val=\"design_1\"/>\r\n"
    "                    <Attr Name=\"CompileOrder\" Val=\"61\"/>\r\n"
    "                </FileInfo>\r\n"
    "            </File>\r\n"
    "        </Verilog>\r\n"
)


def rd(p):
    return open(p, "r", encoding="utf-8", newline="").read()


def wr(p, s):
    with open(p, "w", encoding="utf-8", newline="") as f:
        f.write(s)


def sub_once(text, old, new, what):
    n = text.count(old)
    if n != 1:
        raise RuntimeError("%s：锚点出现 %d 次（要求 1 次）" % (what, n))
    return text.replace(old, new, 1)


def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest().upper()


def main():
    # ---- (1)(2) 两份 isp_top 必须本来就完全一致 ----
    a, b = rd(ISP_A), rd(ISP_B)
    if a != b:
        raise RuntimeError("两份 isp_top 内容不一致，先人工对齐再打补丁")
    if "assign O_bbox_x0" in a:
        print("isp_top 已打过补丁，跳过")
    else:
        a = sub_once(a, "    output " + T + T + T + "I_tready\r\n);\r\n", NEW_PORTS,
                     "isp_top 端口表")
        a = sub_once(a, "  assign O_tvalid = awb_O_tvalid_128   ;\r\n", NEW_ASSIGNS,
                     "isp_top assign 区")
        wr(ISP_A, a)
        wr(ISP_B, a)
        print("OK  isp_top 两份均已更新，md5=%s" % md5(ISP_A))

    # ---- (3) design_top_wrapper ----
    w = rd(WRAP)
    if "u_ext_ctrl" in w:
        print("design_top_wrapper 已打过补丁，跳过")
    else:
        w = sub_once(w, WRAP_PORTS_OLD, WRAP_PORTS_NEW, "wrapper 端口表")
        w = sub_once(w, WRAP_WIRES_OLD, WRAP_WIRES_NEW, "wrapper wire 声明")
        w = sub_once(w, WRAP_INST_OLD, WRAP_INST_NEW, "wrapper isp_top 例化")
        wr(WRAP, w)
        print("OK  design_top_wrapper 已更新，md5=%s" % md5(WRAP))

    # ---- (4) pin.adc 追加 ----
    p = rd(PIN)
    if "O_led[0]" in p:
        print("pin.adc 已追加过，跳过")
    else:
        if not p.endswith("\n"):
            p += "\n"
        wr(PIN, p + PIN_APPEND)

    # ---- (5) .al 追加源文件 ----
    al = rd(AL)
    if "ext_ctrl.v" in al:
        print(".al 已追加过，跳过")
    else:
        al = sub_once(al, AL_OLD, AL_NEW, ".al 源文件表")
        wr(AL, al)
        print("OK  camera_to_dsi_display.al 追加 ext_ctrl.v (CompileOrder=61)")

    # ---- (6) 同步 RTL 副本 ----
    shutil.copyfile(EXT_SRC, EXT_DST)
    same = md5(EXT_SRC) == md5(EXT_DST)
    print("OK  ext_ctrl.v 已同步到 alg\\ ：%s (%s)" % (same, md5(EXT_DST)))
    return 0


if __name__ == "__main__":
    sys.exit(main())

create_clock -name {sys_clk_50m} -period 20.000 -waveform {0.000 10.000} [get_ports {I_sys_clk}]
# ★★ 2026-10-01 修正：MIPI 焊盘时钟从 240MHz(4.167ns) 改为 180MHz(5.556ns)。
#   原 4.167ns 是设计初的【假设值】，从未核对过。
#   实情：摄像头主时钟 = PLL 1500/84 = 17.857MHz，比原来的 23.81MHz 低 25%，
#         MIPI 链路与字节时钟同比例变慢 ⇒ 240->180MHz、字节 60->45MHz。
#   → 用 180MHz 约束是【保守】的：我们早先实测字节时钟约 51.2MHz（对应 MIPI 约 204.8MHz），
#     实际比 180MHz 还慢，真实余量比报告更大。
#   ⚠ 耦合：以后每次改 PLL 的 CLKC1_DIV，都必须同步改本行，否则报告又会说谎。
create_clock -name {mipi_rx_ck_pad} -period 5.556 -waveform {0.000 2.778} [get_nets {IO_rx_clk_pad_p}]

# MCU PLL（pll_mcua）输出时钟：300MHz core + 100MHz timer
# ⚠ 不要在 wrapper 端口 clk0_out/clk1_out 上 create_clock —— 那会被 derive_clocks
#   覆盖成 fanout=0 的孤儿时钟，set_clock_groups 匹配不到，导致 MCU core_clk 与
#   apb_clk(=sys_clk_50m) 的跨域路径被当同步时序分析（实测报 SWNS=-5.58ns）。
#   正确做法：derive_clocks 之后按 PLL 真实输出引脚 rename，见下方 rename_clock。

derive_clocks

rename_clock -name {pll_clk_100m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {pll_clk_24m} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[1]}]
rename_clock -name {HDMI_PIXEL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[4]}]
rename_clock -name {HDMI_SERIAL_CLK} [get_clocks {u_PLL/ph1p_phy_pll_wrapper_25a56e5ce2f9_Inst/u_PH1P_PHY_PLL.clkc[5]}]

rename_clock -name {MIPI_RX_BYTE_CLK} [get_clocks {u_mipi_dphy_rx_ph1p_mipiio_wrapper/u_ph1p_mipiio_rx_wrapper/u_PH1P_LOGIC_DPHY_MIPI_RX.o_fabric_div4_8_clk}]

# MCU PLL 的 300MHz core / 100MHz timer（clkc[0]=300MHz、clkc[1]=100MHz，与 pll_mcua 参数一致）
rename_clock -name {mcu_core_clk}  [get_clocks {u_pll_mcua/ph1p_phy_pll_wrapper_30427878e15a_Inst/u_PH1P_PHY_PLL.clkc[0]}]
rename_clock -name {mcu_timer_clk} [get_clocks {u_pll_mcua/ph1p_phy_pll_wrapper_30427878e15a_Inst/u_PH1P_PHY_PLL.clkc[1]}]


set_clock_groups -asynchronous \
    -group [get_clocks {mipi_rx_ck_pad MIPI_RX_BYTE_CLK}] \
    -group [get_clocks {sys_clk_50m pll_clk_100m pll_clk_24m HDMI_PIXEL_CLK HDMI_SERIAL_CLK}] \
    -group [get_clocks {mcu_core_clk mcu_timer_clk u_ps/u_MCU/MCU_ff19749f9ec3_Inst/PH1P_PHY_MCU_Inst.core_clk}] \
    -group [get_clocks {u_ph1p35_324_ddr_wrapper/u_ddr2/ddr_clk u_ph1p35_324_ddr_wrapper/u_ddr2/usr_clk}]

# MCU 硬核内部 core_clk 与 fabric apb_clk(=sys_clk_50m) 是硬核内部的 CDC，
# .lib 把 APB 输出(paddr/psel/...)建模成 core_clk 发射、prdata 由 apb_clk 采样，
# 产生假跨域路径（paddr→gim_reg_apb→prdata）。显式 false_path 双向切断兜底。
set_false_path -from [get_clocks {u_ps/u_MCU/MCU_ff19749f9ec3_Inst/PH1P_PHY_MCU_Inst.core_clk}] -to [get_clocks {sys_clk_50m}]
set_false_path -from [get_clocks {sys_clk_50m}] -to [get_clocks {u_ps/u_MCU/MCU_ff19749f9ec3_Inst/PH1P_PHY_MCU_Inst.core_clk}]

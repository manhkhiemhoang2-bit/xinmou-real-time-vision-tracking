//==============================================================================
// ps_wrapper.v —— PH1P35 RISC-V MCU 硬核的板级包装
//
// 干什么：
//   把 TD IP Catalog 生成的 MCU IP（模块名 RISCV_F6F1D1P0_0）包一层：
//     1. 把 MCU 的 gpio*_in/out/dir 三根信号合成顶层要的 IO_gpio* 三态 inout；
//     2. 把 i2c_sda/scl 的 in/out/sel 三根信号合成开漏 inout；
//     3. AHB/APB/uart0 直通；AHB 无从设备，给"立即完成无错误"的默认响应。
//
// ★2026-10-20 混合架构回撤：三路舵机恢复 MCU 直通（删 I_fpga_own/pwm_* 端口、
//   roll 看门狗、gpio0/1 mux）。I2C 总线新增 Fabric 从机 gim_i2c_slave @0x50：
//   新增 I_fpga_sda_pull（开漏拉低请求，与 MCU 的 sda_sel 线或）、
//   O_i2c_scl_in / O_i2c_sda_in（pad 电平观测引出给从机采样）。
//
// ⚠ 模块名 RISCV_F6F1D1P0_0 是 MCU IP 在 TD 里生成时的默认实例名。
//   若在 TD 里把该 IP 重命名（IP Catalog → 改名 → 重新 Generate），
//   这里实例化的名字必须跟着改，否则综合报黑盒。
//
// ⚠ 当前 MCU IP 参数（见 al_ip/RISCV_F6F1D1P0_0/.params_*.txt）：
//     I2C_Available=1（导出 i2c_sda/scl 三态）、MCU_JTAG_SEL=0（走板载 PAD JTAG，
//     不导出 jtag 到 Fabric，所以本文件没有 jtag 端口）、GPIO0~2、UART0、APB。
//   依据官方《PH1P35内MCU核使用指南.pdf》§5/§6：JTAG 不勾选 ⇒ 不导出
//   jtag_tck/tms/tdi/tdo，顶层无需连接 MCU JTAG 信号。
//==============================================================================
`timescale 1ns / 1ps


module ps_wrapper (
    input wire        I_core_clk,
    input wire        I_timer_clk,
    input wire        I_rst,

    input wire        I_apb_clk,
    input wire        I_apb_rst,
    output wire[19:0] O_apb_paddr,
    output wire       O_apb_psel,
    output wire       O_apb_penable,
    output wire       O_apb_pwrite,
    output wire[31:0] O_apb_pwdata,
    output wire[3:0]  O_apb_pstrobe,
    output wire[2:0]  O_apb_pprot,
    input wire[31:0]  I_apb_prdata,
    input wire        I_apb_pready,
    input wire        I_apb_pslverr,

    output wire       O_uart0_tx,
    input wire        I_uart0_rx,

    inout wire        IO_gpio0,
    inout wire        IO_gpio1,
    inout wire        IO_gpio2,

    // ★2026-10-20 混合架构回撤：三路舵机全部恢复 MCU 直通（无 Fabric mux）。
    //   I2C 总线上新增 Fabric 从机（gim_i2c_slave @0x50，与 MPU6050 @0x68 并存）：
    input  wire       I_fpga_sda_pull,   // Fabric 从机的开漏拉低请求：1=拉低 SDA
    output wire       O_i2c_scl_in,      // SCL pad 电平观测 → gim_i2c_slave
    output wire       O_i2c_sda_in,      // SDA pad 电平观测 → gim_i2c_slave

    inout wire        IO_i2c_scl,    // I2C SCL（开漏，需外部上拉）
    inout wire        IO_i2c_sda     // I2C SDA（开漏，需外部上拉）
);


    wire S_gpio0_in;
    wire S_gpio0_out;
    wire S_gpio0_dir;

    wire S_gpio1_in;
    wire S_gpio1_out;
    wire S_gpio1_dir;

    wire S_gpio2_in;
    wire S_gpio2_out;
    wire S_gpio2_dir;

    wire S_i2c_scl_in;
    wire S_i2c_scl_out;
    wire S_i2c_scl_sel;
    wire S_i2c_sda_in;
    wire S_i2c_sda_out;
    wire S_i2c_sda_sel;


    // ★★ 2026-10-09 修正（保留）：**忽略 gpio*_dir，直接驱动输出**。
    //   证据链：
    //     · UART 走的是纯输出路径（无三态），**上板正常**（串口能打印）；
    //     · GPIO（舵机）与 I2C（IMU）都经过三态逻辑，**两路全不通**；
    //     · 固件里的"引脚自检"（静态拉高后回读）恒为 **0x0** ⇒ 引脚从未被驱动。
    //   ⇒ 说明 gpio*_dir 的语义/极性与原注释的假设相反：
    //     SDK 把引脚设为输出时 dir=1，而三态逻辑见到 1 就释放成高阻 ⇒ 输出永远出不去。
    //   本工程这三路 GPIO 只作输出用（三路舵机 PWM），因此**直接驱动**即可绕开该歧义，
    //   功能正确且更稳。若将来某路要当输入用，需按实测极性改回三态。
    //   原写法（保留备查）：assign IO_gpio0 = S_gpio0_dir ? 1'bz : S_gpio0_out;
    //
    // ★2026-10-20 混合架构回撤：2026-10-13 的 yaw/pitch Fabric 接管 mux 与
    //   roll"MCU 在线看门狗"整体删除——MCU 的 CPU 访问不到 Fabric APB（实测证伪），
    //   坐标改经 I2C 从机（gim_i2c_slave @0x50）传给 MCU，追踪控制律全部回到 MCU。
    //   三路引脚恢复 MCU 直通（每脚唯一驱动源 = MCU GPIO）：
    //     IO_gpio0→J14(yaw)、IO_gpio1→L15(pitch)、IO_gpio2→L16(roll)。
    assign IO_gpio0 = S_gpio0_out;
    assign S_gpio0_in = IO_gpio0;

    assign IO_gpio1 = S_gpio1_out;
    assign S_gpio1_in = IO_gpio1;

    assign IO_gpio2 = S_gpio2_out;
    assign S_gpio2_in = IO_gpio2;

    // I2C 开漏三态：sel=1 驱动 out（拉低），sel=0 释放（上拉拉回高）。
    // ★★ 2026-10-10 改回原始写法：上一轮曾把它取反（照搬 GPIO"dir 极性反了"的经验），
    //   实测证明取反是错的——反版下 SCL/SDA 恒 0V（总线被死死拉低；I2C 空闲必须是高电平）。
    //   GPIO 的 dir 与 I2C 的 sel 是两个不同信号，语义相反，不能类推。
    //   判据：程序跑着、IMU 接好时，SCL 与 SDA 对地都应 ≈3.3V（空闲高）。
    //
    // ★2026-10-20 SDA 线或进 Fabric 从机（gim_i2c_slave，只拉低不驱高，开漏语义）。
    //   MCU 支路保持原样 sel?out:z；Fabric 支路只在 MCU 释放（sel=0）时起作用：
    //     I_fpga_sda_pull=1 → 驱动 1'b0（拉低）；=0 → 1'bz（释放，上拉拉回高）。
    //   ⚠ 有意未采用规格书 §2.2 的字面式 "(sel | pull) ? S_i2c_sda_out : 1'bz"：
    //     该式在 sel=0 且 Fabric 拉低期间会把 S_i2c_sda_out（此刻取值无保证）驱上 pad，
    //     若 MCU IP 空闲时 out=1，pad 会被主动驱高——与主机拉低对撞、且读数据位全错。
    //     现写法 Fabric 拉低时恒驱 1'b0，无论 out 为何值电气上都严格安全。
    assign IO_i2c_scl = S_i2c_scl_sel ? S_i2c_scl_out : 1'bz;
    assign S_i2c_scl_in = IO_i2c_scl;
    assign IO_i2c_sda = S_i2c_sda_sel ? S_i2c_sda_out : (I_fpga_sda_pull ? 1'b0 : 1'bz);
    assign S_i2c_sda_in = IO_i2c_sda;

    // pad 电平观测引出（→ gim_i2c_slave 的采样输入；SCL 只观测，从机绝不驱动）
    assign O_i2c_scl_in = S_i2c_scl_in;
    assign O_i2c_sda_in = S_i2c_sda_in;

    RISCV_F6F1D1P0_0 u_MCU(
        .core_sysrst (               ),   // MCU 内部系统复位输出；Fabric 用不到，悬空

        .gpio0_in    ( S_gpio0_in    ),
        .gpio0_out   ( S_gpio0_out   ),
        .gpio0_dir   ( S_gpio0_dir   ),
        .gpio1_in    ( S_gpio1_in    ),
        .gpio1_out   ( S_gpio1_out   ),
        .gpio1_dir   ( S_gpio1_dir   ),
        .gpio2_in    ( S_gpio2_in    ),
        .gpio2_out   ( S_gpio2_out   ),
        .gpio2_dir   ( S_gpio2_dir   ),

        .uart0_tx    ( O_uart0_tx    ),
        .uart0_rx    ( I_uart0_rx    ),

        .i2c_sda_in  ( S_i2c_sda_in  ),
        .i2c_sda_out ( S_i2c_sda_out ),
        .i2c_sda_sel ( S_i2c_sda_sel ),
        .i2c_scl_in  ( S_i2c_scl_in  ),
        .i2c_scl_out ( S_i2c_scl_out ),
        .i2c_scl_sel ( S_i2c_scl_sel ),

        // AHB 无从设备：hrdata=0 / hresp=OKAY / hready=1，输出全部悬空。
        .ahb_clk     (               ),
        .htrans      (               ),
        .hwrite      (               ),
        .haddr       (               ),
        .hsize       (               ),
        .hburst      (               ),
        .hprot       (               ),
        .hmastlock   (               ),
        .hwdata      (               ),
        .hrdata      ( 32'd0         ),
        .hresp       ( 2'b00         ),
        .hready      ( 1'b1          ),

        .apb_clk     ( I_apb_clk     ),
        .apb_rst     ( I_apb_rst     ),
        .paddr       ( O_apb_paddr   ),
        .psel        ( O_apb_psel    ),
        .penable     ( O_apb_penable ),
        .pwrite      ( O_apb_pwrite  ),
        .pwdata      ( O_apb_pwdata  ),
        .pstrobe     ( O_apb_pstrobe ),
        .pprot       ( O_apb_pprot   ),
        .prdata      ( I_apb_prdata  ),
        .pready      ( I_apb_pready  ),
        .pslverr     ( I_apb_pslverr ),

        .core_clk    ( I_core_clk    ),
        .timer_clk   ( I_timer_clk   ),
        .core_reset  ( I_rst         ),
        .por_reset   ( I_rst         ),
        .nmi         ( 1'b0          ),
        .clic_irq    ( 23'd0         )
    );


endmodule

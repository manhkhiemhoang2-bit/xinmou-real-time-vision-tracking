//==============================================================================
// bin2bcd.v —— 二进制转 BCD（组合，double-dabble / shift-add-3）
//
// 用途：把实测到的行像素数、帧行数、帧计数转成十进制各位，供 OSD 显示。
//   osd_mixer 里原有的十进制展开是"逐位常数比较链"，写十几次太冗长；
//   这里做成参数化模块，例化多次即可。
//
// 实现：纯组合 double-dabble，for 循环展开 ⇒ 无时钟、无除法器、可综合。
//   16 bit 输入 → 5 位 BCD（最大 65535）。DIGITS 参数可调（低位在前）。
//
// 例化示例（4 位十进制）：
//   bin2bcd #(.BIN_W(16), .DIGITS(4)) u_bcd (.I_bin(v), .O_bcd({d3,d2,d1,d0}));
//   注意：O_bcd 的第 [3:0] 是**个位**，依次向高位。
//==============================================================================
module bin2bcd #(
    parameter integer BIN_W  = 16,
    parameter integer DIGITS = 5
)(
    input  wire [BIN_W-1:0]           I_bin,
    output wire [DIGITS*4-1:0]        O_bcd
);

    integer i, j;
    reg [DIGITS*4-1:0] acc;
    reg [DIGITS*4-1:0] acc_n;

    always @ (*) begin
        acc = {DIGITS*4{1'b0}};
        for (i = BIN_W - 1; i >= 0; i = i - 1) begin
            // 先把每一位 BCD 中 >=5 的加 3
            acc_n = acc;
            for (j = 0; j < DIGITS; j = j + 1) begin
                if (acc_n[j*4 +: 4] >= 4'd5)
                    acc_n[j*4 +: 4] = acc_n[j*4 +: 4] + 4'd3;
            end
            // 再左移一位并补入当前二进制位
            acc = {acc_n[DIGITS*4-2:0], I_bin[i]};
        end
    end

    assign O_bcd = acc;

endmodule

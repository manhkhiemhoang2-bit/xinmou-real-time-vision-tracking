// ============================================================================
// my_charlib.v
//   —— 由 gen_osd_rom.py 自动生成（自研原创素材，**不复制**官方 ROM）
//   生成时间：2026-09-12 21:11:57
//   规格：字符 ROM 42 字 x 16x16 点阵
//   说明：每行 16 bit，bit[15] = 最左像素（MSB first）
//         '1' = 点亮（取前景色），'0' = 透明/背景
//   综合：Verilog-2001；用 case 组合逻辑，安路 TD 推断 ERAM/分布式 RAM 均可
// ============================================================================
`timescale 1ns / 1ps

module my_charlib #(
    parameter CHAR_W = 16,
    parameter CHAR_H = 16,
    parameter CHAR_N = 42
)(
    input      [ 7:0] I_index,   // 字符索引（见文件末尾 CHAR_* 表）
    input      [ 3:0] I_row,     // 行地址 0..15
    output reg [15:0] O_bits     // 该行点阵，bit[15] = 最左
);

// ---- 字符索引表（与生成本文件时的 CHARLIB_ORDER 完全一致）----
//   idx= 0  '0'  code=0x30
//   idx= 1  '1'  code=0x31
//   idx= 2  '2'  code=0x32
//   idx= 3  '3'  code=0x33
//   idx= 4  '4'  code=0x34
//   idx= 5  '5'  code=0x35
//   idx= 6  '6'  code=0x36
//   idx= 7  '7'  code=0x37
//   idx= 8  '8'  code=0x38
//   idx= 9  '9'  code=0x39
//   idx=10  'A'  code=0x41
//   idx=11  'B'  code=0x42
//   idx=12  'C'  code=0x43
//   idx=13  'D'  code=0x44
//   idx=14  'E'  code=0x45
//   idx=15  'F'  code=0x46
//   idx=16  'G'  code=0x47
//   idx=17  'H'  code=0x48
//   idx=18  'I'  code=0x49
//   idx=19  'J'  code=0x4A
//   idx=20  'K'  code=0x4B
//   idx=21  'L'  code=0x4C
//   idx=22  'M'  code=0x4D
//   idx=23  'N'  code=0x4E
//   idx=24  'O'  code=0x4F
//   idx=25  'P'  code=0x50
//   idx=26  'Q'  code=0x51
//   idx=27  'R'  code=0x52
//   idx=28  'S'  code=0x53
//   idx=29  'T'  code=0x54
//   idx=30  'U'  code=0x55
//   idx=31  'V'  code=0x56
//   idx=32  'W'  code=0x57
//   idx=33  'X'  code=0x58
//   idx=34  'Y'  code=0x59
//   idx=35  'Z'  code=0x5A
//   idx=36  ':'  code=0x3A
//   idx=37  '.'  code=0x2E
//   idx=38  '/'  code=0x2F
//   idx=39  'SPACE'  code=0x20
//   idx=40  '安'  code=0xA1A2
//   idx=41  '路'  code=0xA1A3

always @(*) begin
    case ({I_index, I_row})
        // ---- '0' (idx 0) ----
        12'd0: O_bits = 16'h3FF0;
        12'd1: O_bits = 16'h6018;
        12'd2: O_bits = 16'h6018;
        12'd3: O_bits = 16'h6018;
        12'd4: O_bits = 16'h6018;
        12'd5: O_bits = 16'h6018;
        12'd6: O_bits = 16'h6018;
        12'd7: O_bits = 16'h6018;
        12'd8: O_bits = 16'h6018;
        12'd9: O_bits = 16'h6018;
        12'd10: O_bits = 16'h6018;
        12'd11: O_bits = 16'h6018;
        12'd12: O_bits = 16'h6018;
        12'd13: O_bits = 16'h3FF0;
        12'd14: O_bits = 16'h0000;
        12'd15: O_bits = 16'h0000;
        // ---- '1' (idx 1) ----
        12'd16: O_bits = 16'h0300;
        12'd17: O_bits = 16'h0F00;
        12'd18: O_bits = 16'h3F00;
        12'd19: O_bits = 16'h0300;
        12'd20: O_bits = 16'h0300;
        12'd21: O_bits = 16'h0300;
        12'd22: O_bits = 16'h0300;
        12'd23: O_bits = 16'h0300;
        12'd24: O_bits = 16'h0300;
        12'd25: O_bits = 16'h0300;
        12'd26: O_bits = 16'h0300;
        12'd27: O_bits = 16'h0300;
        12'd28: O_bits = 16'h3FFC;
        12'd29: O_bits = 16'h3FFC;
        12'd30: O_bits = 16'h0000;
        12'd31: O_bits = 16'h0000;
        // ---- '2' (idx 2) ----
        12'd32: O_bits = 16'h3FF0;
        12'd33: O_bits = 16'h6018;
        12'd34: O_bits = 16'h000C;
        12'd35: O_bits = 16'h000C;
        12'd36: O_bits = 16'h0030;
        12'd37: O_bits = 16'h00C0;
        12'd38: O_bits = 16'h0300;
        12'd39: O_bits = 16'h0C00;
        12'd40: O_bits = 16'h3000;
        12'd41: O_bits = 16'h6000;
        12'd42: O_bits = 16'h6000;
        12'd43: O_bits = 16'h6000;
        12'd44: O_bits = 16'h7FFE;
        12'd45: O_bits = 16'h7FFE;
        12'd46: O_bits = 16'h0000;
        12'd47: O_bits = 16'h0000;
        // ---- '3' (idx 3) ----
        12'd48: O_bits = 16'h3FF0;
        12'd49: O_bits = 16'h6018;
        12'd50: O_bits = 16'h000C;
        12'd51: O_bits = 16'h000C;
        12'd52: O_bits = 16'h00F0;
        12'd53: O_bits = 16'h00F0;
        12'd54: O_bits = 16'h000C;
        12'd55: O_bits = 16'h000C;
        12'd56: O_bits = 16'h000C;
        12'd57: O_bits = 16'h000C;
        12'd58: O_bits = 16'h000C;
        12'd59: O_bits = 16'h6018;
        12'd60: O_bits = 16'h3FF0;
        12'd61: O_bits = 16'h0000;
        12'd62: O_bits = 16'h0000;
        12'd63: O_bits = 16'h0000;
        // ---- '4' (idx 4) ----
        12'd64: O_bits = 16'h00F0;
        12'd65: O_bits = 16'h03F0;
        12'd66: O_bits = 16'h0C30;
        12'd67: O_bits = 16'h3030;
        12'd68: O_bits = 16'h6030;
        12'd69: O_bits = 16'h6030;
        12'd70: O_bits = 16'h7FFE;
        12'd71: O_bits = 16'h7FFE;
        12'd72: O_bits = 16'h0030;
        12'd73: O_bits = 16'h0030;
        12'd74: O_bits = 16'h0030;
        12'd75: O_bits = 16'h0030;
        12'd76: O_bits = 16'h0030;
        12'd77: O_bits = 16'h0000;
        12'd78: O_bits = 16'h0000;
        12'd79: O_bits = 16'h0000;
        // ---- '5' (idx 5) ----
        12'd80: O_bits = 16'h7FFE;
        12'd81: O_bits = 16'h7FFE;
        12'd82: O_bits = 16'h6000;
        12'd83: O_bits = 16'h6000;
        12'd84: O_bits = 16'h6000;
        12'd85: O_bits = 16'h7FF0;
        12'd86: O_bits = 16'h7FF0;
        12'd87: O_bits = 16'h000C;
        12'd88: O_bits = 16'h000C;
        12'd89: O_bits = 16'h000C;
        12'd90: O_bits = 16'h000C;
        12'd91: O_bits = 16'h6018;
        12'd92: O_bits = 16'h3FF0;
        12'd93: O_bits = 16'h0000;
        12'd94: O_bits = 16'h0000;
        12'd95: O_bits = 16'h0000;
        // ---- '6' (idx 6) ----
        12'd96: O_bits = 16'h03F0;
        12'd97: O_bits = 16'h0C0C;
        12'd98: O_bits = 16'h3000;
        12'd99: O_bits = 16'h6000;
        12'd100: O_bits = 16'h6000;
        12'd101: O_bits = 16'h7FF0;
        12'd102: O_bits = 16'h6018;
        12'd103: O_bits = 16'h6018;
        12'd104: O_bits = 16'h6018;
        12'd105: O_bits = 16'h6018;
        12'd106: O_bits = 16'h6018;
        12'd107: O_bits = 16'h3030;
        12'd108: O_bits = 16'h0FC0;
        12'd109: O_bits = 16'h0000;
        12'd110: O_bits = 16'h0000;
        12'd111: O_bits = 16'h0000;
        // ---- '7' (idx 7) ----
        12'd112: O_bits = 16'h7FFE;
        12'd113: O_bits = 16'h7FFE;
        12'd114: O_bits = 16'h000C;
        12'd115: O_bits = 16'h0018;
        12'd116: O_bits = 16'h0030;
        12'd117: O_bits = 16'h0060;
        12'd118: O_bits = 16'h00C0;
        12'd119: O_bits = 16'h0180;
        12'd120: O_bits = 16'h0300;
        12'd121: O_bits = 16'h0300;
        12'd122: O_bits = 16'h0700;
        12'd123: O_bits = 16'h0700;
        12'd124: O_bits = 16'h0700;
        12'd125: O_bits = 16'h0000;
        12'd126: O_bits = 16'h0000;
        12'd127: O_bits = 16'h0000;
        // ---- '8' (idx 8) ----
        12'd128: O_bits = 16'h0FC0;
        12'd129: O_bits = 16'h3030;
        12'd130: O_bits = 16'h6018;
        12'd131: O_bits = 16'h6018;
        12'd132: O_bits = 16'h3030;
        12'd133: O_bits = 16'h0FC0;
        12'd134: O_bits = 16'h3030;
        12'd135: O_bits = 16'h6018;
        12'd136: O_bits = 16'h6018;
        12'd137: O_bits = 16'h6018;
        12'd138: O_bits = 16'h6018;
        12'd139: O_bits = 16'h3030;
        12'd140: O_bits = 16'h0FC0;
        12'd141: O_bits = 16'h0000;
        12'd142: O_bits = 16'h0000;
        12'd143: O_bits = 16'h0000;
        // ---- '9' (idx 9) ----
        12'd144: O_bits = 16'h0FC0;
        12'd145: O_bits = 16'h3030;
        12'd146: O_bits = 16'h6018;
        12'd147: O_bits = 16'h6018;
        12'd148: O_bits = 16'h6018;
        12'd149: O_bits = 16'h3038;
        12'd150: O_bits = 16'h0FFC;
        12'd151: O_bits = 16'h000C;
        12'd152: O_bits = 16'h000C;
        12'd153: O_bits = 16'h000C;
        12'd154: O_bits = 16'h0030;
        12'd155: O_bits = 16'h3060;
        12'd156: O_bits = 16'h3FC0;
        12'd157: O_bits = 16'h0000;
        12'd158: O_bits = 16'h0000;
        12'd159: O_bits = 16'h0000;
        // ---- 'A' (idx 10) ----
        12'd160: O_bits = 16'h03C0;
        12'd161: O_bits = 16'h07E0;
        12'd162: O_bits = 16'h0C30;
        12'd163: O_bits = 16'h1818;
        12'd164: O_bits = 16'h1818;
        12'd165: O_bits = 16'h300C;
        12'd166: O_bits = 16'h300C;
        12'd167: O_bits = 16'h3FFC;
        12'd168: O_bits = 16'h3FFC;
        12'd169: O_bits = 16'h6006;
        12'd170: O_bits = 16'h6006;
        12'd171: O_bits = 16'h6006;
        12'd172: O_bits = 16'hC003;
        12'd173: O_bits = 16'h0000;
        12'd174: O_bits = 16'h0000;
        12'd175: O_bits = 16'h0000;
        // ---- 'B' (idx 11) ----
        12'd176: O_bits = 16'h7FF0;
        12'd177: O_bits = 16'h6018;
        12'd178: O_bits = 16'h6018;
        12'd179: O_bits = 16'h6018;
        12'd180: O_bits = 16'h7FF0;
        12'd181: O_bits = 16'h7FF0;
        12'd182: O_bits = 16'h6018;
        12'd183: O_bits = 16'h6018;
        12'd184: O_bits = 16'h6018;
        12'd185: O_bits = 16'h6018;
        12'd186: O_bits = 16'h6018;
        12'd187: O_bits = 16'h7FF0;
        12'd188: O_bits = 16'h0000;
        12'd189: O_bits = 16'h0000;
        12'd190: O_bits = 16'h0000;
        12'd191: O_bits = 16'h0000;
        // ---- 'C' (idx 12) ----
        12'd192: O_bits = 16'h0FFC;
        12'd193: O_bits = 16'h3003;
        12'd194: O_bits = 16'h6000;
        12'd195: O_bits = 16'h6000;
        12'd196: O_bits = 16'hC000;
        12'd197: O_bits = 16'hC000;
        12'd198: O_bits = 16'hC000;
        12'd199: O_bits = 16'hC000;
        12'd200: O_bits = 16'hC000;
        12'd201: O_bits = 16'h6000;
        12'd202: O_bits = 16'h6000;
        12'd203: O_bits = 16'h3003;
        12'd204: O_bits = 16'h0FFC;
        12'd205: O_bits = 16'h0000;
        12'd206: O_bits = 16'h0000;
        12'd207: O_bits = 16'h0000;
        // ---- 'D' (idx 13) ----
        12'd208: O_bits = 16'h7FF0;
        12'd209: O_bits = 16'h6018;
        12'd210: O_bits = 16'h600C;
        12'd211: O_bits = 16'h6006;
        12'd212: O_bits = 16'h6006;
        12'd213: O_bits = 16'h6006;
        12'd214: O_bits = 16'h6006;
        12'd215: O_bits = 16'h6006;
        12'd216: O_bits = 16'h6006;
        12'd217: O_bits = 16'h600C;
        12'd218: O_bits = 16'h6018;
        12'd219: O_bits = 16'h7FF0;
        12'd220: O_bits = 16'h0000;
        12'd221: O_bits = 16'h0000;
        12'd222: O_bits = 16'h0000;
        12'd223: O_bits = 16'h0000;
        // ---- 'E' (idx 14) ----
        12'd224: O_bits = 16'h7FFE;
        12'd225: O_bits = 16'h7FFE;
        12'd226: O_bits = 16'h6000;
        12'd227: O_bits = 16'h6000;
        12'd228: O_bits = 16'h7FF0;
        12'd229: O_bits = 16'h7FF0;
        12'd230: O_bits = 16'h6000;
        12'd231: O_bits = 16'h6000;
        12'd232: O_bits = 16'h6000;
        12'd233: O_bits = 16'h6000;
        12'd234: O_bits = 16'h6000;
        12'd235: O_bits = 16'h7FFE;
        12'd236: O_bits = 16'h7FFE;
        12'd237: O_bits = 16'h0000;
        12'd238: O_bits = 16'h0000;
        12'd239: O_bits = 16'h0000;
        // ---- 'F' (idx 15) ----
        12'd240: O_bits = 16'h7FFE;
        12'd241: O_bits = 16'h7FFE;
        12'd242: O_bits = 16'h6000;
        12'd243: O_bits = 16'h6000;
        12'd244: O_bits = 16'h7FF0;
        12'd245: O_bits = 16'h7FF0;
        12'd246: O_bits = 16'h6000;
        12'd247: O_bits = 16'h6000;
        12'd248: O_bits = 16'h6000;
        12'd249: O_bits = 16'h6000;
        12'd250: O_bits = 16'h6000;
        12'd251: O_bits = 16'h6000;
        12'd252: O_bits = 16'h6000;
        12'd253: O_bits = 16'h0000;
        12'd254: O_bits = 16'h0000;
        12'd255: O_bits = 16'h0000;
        // ---- 'G' (idx 16) ----
        12'd256: O_bits = 16'h0FFC;
        12'd257: O_bits = 16'h3003;
        12'd258: O_bits = 16'h6000;
        12'd259: O_bits = 16'h6000;
        12'd260: O_bits = 16'hC000;
        12'd261: O_bits = 16'hC000;
        12'd262: O_bits = 16'hC0FF;
        12'd263: O_bits = 16'hC0FF;
        12'd264: O_bits = 16'hC00C;
        12'd265: O_bits = 16'h600C;
        12'd266: O_bits = 16'h600C;
        12'd267: O_bits = 16'h300C;
        12'd268: O_bits = 16'h0FFC;
        12'd269: O_bits = 16'h0000;
        12'd270: O_bits = 16'h0000;
        12'd271: O_bits = 16'h0000;
        // ---- 'H' (idx 17) ----
        12'd272: O_bits = 16'h6006;
        12'd273: O_bits = 16'h6006;
        12'd274: O_bits = 16'h6006;
        12'd275: O_bits = 16'h6006;
        12'd276: O_bits = 16'h7FFE;
        12'd277: O_bits = 16'h7FFE;
        12'd278: O_bits = 16'h6006;
        12'd279: O_bits = 16'h6006;
        12'd280: O_bits = 16'h6006;
        12'd281: O_bits = 16'h6006;
        12'd282: O_bits = 16'h6006;
        12'd283: O_bits = 16'h6006;
        12'd284: O_bits = 16'h6006;
        12'd285: O_bits = 16'h0000;
        12'd286: O_bits = 16'h0000;
        12'd287: O_bits = 16'h0000;
        // ---- 'I' (idx 18) ----
        12'd288: O_bits = 16'h3FFC;
        12'd289: O_bits = 16'h3FFC;
        12'd290: O_bits = 16'h0300;
        12'd291: O_bits = 16'h0300;
        12'd292: O_bits = 16'h0300;
        12'd293: O_bits = 16'h0300;
        12'd294: O_bits = 16'h0300;
        12'd295: O_bits = 16'h0300;
        12'd296: O_bits = 16'h0300;
        12'd297: O_bits = 16'h0300;
        12'd298: O_bits = 16'h0300;
        12'd299: O_bits = 16'h3FFC;
        12'd300: O_bits = 16'h3FFC;
        12'd301: O_bits = 16'h0000;
        12'd302: O_bits = 16'h0000;
        12'd303: O_bits = 16'h0000;
        // ---- 'J' (idx 19) ----
        12'd304: O_bits = 16'h000C;
        12'd305: O_bits = 16'h000C;
        12'd306: O_bits = 16'h000C;
        12'd307: O_bits = 16'h000C;
        12'd308: O_bits = 16'h000C;
        12'd309: O_bits = 16'h000C;
        12'd310: O_bits = 16'h000C;
        12'd311: O_bits = 16'h000C;
        12'd312: O_bits = 16'h000C;
        12'd313: O_bits = 16'h6018;
        12'd314: O_bits = 16'h6018;
        12'd315: O_bits = 16'h3030;
        12'd316: O_bits = 16'h0FC0;
        12'd317: O_bits = 16'h0000;
        12'd318: O_bits = 16'h0000;
        12'd319: O_bits = 16'h0000;
        // ---- 'K' (idx 20) ----
        12'd320: O_bits = 16'h6018;
        12'd321: O_bits = 16'h6060;
        12'd322: O_bits = 16'h6180;
        12'd323: O_bits = 16'h6600;
        12'd324: O_bits = 16'h7E00;
        12'd325: O_bits = 16'h7E00;
        12'd326: O_bits = 16'h6600;
        12'd327: O_bits = 16'h6180;
        12'd328: O_bits = 16'h6060;
        12'd329: O_bits = 16'h6018;
        12'd330: O_bits = 16'h6018;
        12'd331: O_bits = 16'h6006;
        12'd332: O_bits = 16'h6006;
        12'd333: O_bits = 16'h0000;
        12'd334: O_bits = 16'h0000;
        12'd335: O_bits = 16'h0000;
        // ---- 'L' (idx 21) ----
        12'd336: O_bits = 16'h6000;
        12'd337: O_bits = 16'h6000;
        12'd338: O_bits = 16'h6000;
        12'd339: O_bits = 16'h6000;
        12'd340: O_bits = 16'h6000;
        12'd341: O_bits = 16'h6000;
        12'd342: O_bits = 16'h6000;
        12'd343: O_bits = 16'h6000;
        12'd344: O_bits = 16'h6000;
        12'd345: O_bits = 16'h6000;
        12'd346: O_bits = 16'h6000;
        12'd347: O_bits = 16'h7FFE;
        12'd348: O_bits = 16'h7FFE;
        12'd349: O_bits = 16'h0000;
        12'd350: O_bits = 16'h0000;
        12'd351: O_bits = 16'h0000;
        // ---- 'M' (idx 22) ----
        12'd352: O_bits = 16'h6006;
        12'd353: O_bits = 16'h700E;
        12'd354: O_bits = 16'h7C3E;
        12'd355: O_bits = 16'h67E6;
        12'd356: O_bits = 16'h63C6;
        12'd357: O_bits = 16'h6186;
        12'd358: O_bits = 16'h6006;
        12'd359: O_bits = 16'h6006;
        12'd360: O_bits = 16'h6006;
        12'd361: O_bits = 16'h6006;
        12'd362: O_bits = 16'h6006;
        12'd363: O_bits = 16'h6006;
        12'd364: O_bits = 16'h6006;
        12'd365: O_bits = 16'h0000;
        12'd366: O_bits = 16'h0000;
        12'd367: O_bits = 16'h0000;
        // ---- 'N' (idx 23) ----
        12'd368: O_bits = 16'h6006;
        12'd369: O_bits = 16'h7006;
        12'd370: O_bits = 16'h7806;
        12'd371: O_bits = 16'h6C06;
        12'd372: O_bits = 16'h6606;
        12'd373: O_bits = 16'h6306;
        12'd374: O_bits = 16'h6186;
        12'd375: O_bits = 16'h60C6;
        12'd376: O_bits = 16'h6066;
        12'd377: O_bits = 16'h6036;
        12'd378: O_bits = 16'h601E;
        12'd379: O_bits = 16'h600E;
        12'd380: O_bits = 16'h6006;
        12'd381: O_bits = 16'h0000;
        12'd382: O_bits = 16'h0000;
        12'd383: O_bits = 16'h0000;
        // ---- 'O' (idx 24) ----
        12'd384: O_bits = 16'h0FFC;
        12'd385: O_bits = 16'h3003;
        12'd386: O_bits = 16'h6001;
        12'd387: O_bits = 16'h6001;
        12'd388: O_bits = 16'hC001;   // Δ2026-10-03 fix: O中段缺右列(原C000)→O看起来像C；补上 bit0
        12'd389: O_bits = 16'hC001;   // ★2026-10-05 十八修：原文件 388 直接跳到 393
        12'd390: O_bits = 16'hC001;   //   ⇒ 'O' 中段 4 行全空，COLOR/AUTO/MOVE/NONE
        12'd391: O_bits = 16'hC001;   //   等含 O 的 OSD 文字断成 'C'。取值与 388 同
        12'd392: O_bits = 16'hC001;   //   （左 15 位 + 右 0 位），上下严格对称。
        12'd393: O_bits = 16'h6001;
        12'd394: O_bits = 16'h6001;
        12'd395: O_bits = 16'h3003;
        12'd396: O_bits = 16'h0FFC;
        12'd397: O_bits = 16'h0000;
        12'd398: O_bits = 16'h0000;
        12'd399: O_bits = 16'h0000;
        // ---- 'P' (idx 25) ----
        12'd400: O_bits = 16'h7FF0;
        12'd401: O_bits = 16'h6018;
        12'd402: O_bits = 16'h6018;
        12'd403: O_bits = 16'h6018;
        12'd404: O_bits = 16'h6018;
        12'd405: O_bits = 16'h7FF0;
        12'd406: O_bits = 16'h7FF0;
        12'd407: O_bits = 16'h6000;
        12'd408: O_bits = 16'h6000;
        12'd409: O_bits = 16'h6000;
        12'd410: O_bits = 16'h6000;
        12'd411: O_bits = 16'h6000;
        12'd412: O_bits = 16'h6000;
        12'd413: O_bits = 16'h0000;
        12'd414: O_bits = 16'h0000;
        12'd415: O_bits = 16'h0000;
        // ---- 'Q' (idx 26) ----
        12'd416: O_bits = 16'h0FFC;
        12'd417: O_bits = 16'h3003;
        12'd418: O_bits = 16'h6001;
        12'd419: O_bits = 16'h6001;
        12'd420: O_bits = 16'hC000;
        12'd421: O_bits = 16'hC000;
        12'd422: O_bits = 16'hC000;
        12'd423: O_bits = 16'hC000;
        12'd424: O_bits = 16'hC030;
        12'd425: O_bits = 16'h601E;
        12'd426: O_bits = 16'h600C;
        12'd427: O_bits = 16'h300E;
        12'd428: O_bits = 16'h0FFD;
        12'd429: O_bits = 16'h0000;
        12'd430: O_bits = 16'h0000;
        12'd431: O_bits = 16'h0000;
        // ---- 'R' (idx 27) ----
        12'd432: O_bits = 16'h7FF0;
        12'd433: O_bits = 16'h6018;
        12'd434: O_bits = 16'h6018;
        12'd435: O_bits = 16'h6018;
        12'd436: O_bits = 16'h7FF0;
        12'd437: O_bits = 16'h7FF0;
        12'd438: O_bits = 16'h60C0;
        12'd439: O_bits = 16'h6060;
        12'd440: O_bits = 16'h6030;
        12'd441: O_bits = 16'h6018;
        12'd442: O_bits = 16'h6018;
        12'd443: O_bits = 16'h600C;
        12'd444: O_bits = 16'h6006;
        12'd445: O_bits = 16'h0000;
        12'd446: O_bits = 16'h0000;
        12'd447: O_bits = 16'h0000;
        // ---- 'S' (idx 28) ----
        12'd448: O_bits = 16'h0FFC;
        12'd449: O_bits = 16'h3003;
        12'd450: O_bits = 16'h6000;
        12'd451: O_bits = 16'h6000;
        12'd452: O_bits = 16'h3000;
        12'd453: O_bits = 16'h0E00;
        12'd454: O_bits = 16'h03C0;
        12'd455: O_bits = 16'h0070;
        12'd456: O_bits = 16'h000C;
        12'd457: O_bits = 16'h0006;
        12'd458: O_bits = 16'h6006;
        12'd459: O_bits = 16'h300C;
        12'd460: O_bits = 16'h0FF0;
        12'd461: O_bits = 16'h0000;
        12'd462: O_bits = 16'h0000;
        12'd463: O_bits = 16'h0000;
        // ---- 'T' (idx 29) ----
        12'd464: O_bits = 16'h7FFE;
        12'd465: O_bits = 16'h7FFE;
        12'd466: O_bits = 16'h0300;
        12'd467: O_bits = 16'h0300;
        12'd468: O_bits = 16'h0300;
        12'd469: O_bits = 16'h0300;
        12'd470: O_bits = 16'h0300;
        12'd471: O_bits = 16'h0300;
        12'd472: O_bits = 16'h0300;
        12'd473: O_bits = 16'h0300;
        12'd474: O_bits = 16'h0300;
        12'd475: O_bits = 16'h0300;
        12'd476: O_bits = 16'h0300;
        12'd477: O_bits = 16'h0000;
        12'd478: O_bits = 16'h0000;
        12'd479: O_bits = 16'h0000;
        // ---- 'U' (idx 30) ----
        12'd480: O_bits = 16'h6006;
        12'd481: O_bits = 16'h6006;
        12'd482: O_bits = 16'h6006;
        12'd483: O_bits = 16'h6006;
        12'd484: O_bits = 16'h6006;
        12'd485: O_bits = 16'h6006;
        12'd486: O_bits = 16'h6006;
        12'd487: O_bits = 16'h6006;
        12'd488: O_bits = 16'h6006;
        12'd489: O_bits = 16'h6006;
        12'd490: O_bits = 16'h300C;
        12'd491: O_bits = 16'h1818;
        12'd492: O_bits = 16'h07E0;
        12'd493: O_bits = 16'h0000;
        12'd494: O_bits = 16'h0000;
        12'd495: O_bits = 16'h0000;
        // ---- 'V' (idx 31) ----
        12'd496: O_bits = 16'hC003;
        12'd497: O_bits = 16'h6006;
        12'd498: O_bits = 16'h6006;
        12'd499: O_bits = 16'h300C;
        12'd500: O_bits = 16'h300C;
        12'd501: O_bits = 16'h1818;
        12'd502: O_bits = 16'h1818;
        12'd503: O_bits = 16'h0C30;
        12'd504: O_bits = 16'h0C30;
        12'd505: O_bits = 16'h0660;
        12'd506: O_bits = 16'h0660;
        12'd507: O_bits = 16'h03C0;
        12'd508: O_bits = 16'h03C0;
        12'd509: O_bits = 16'h0000;
        12'd510: O_bits = 16'h0000;
        12'd511: O_bits = 16'h0000;
        // ---- 'W' (idx 32) ----
        12'd512: O_bits = 16'hC003;
        12'd513: O_bits = 16'hC003;
        12'd514: O_bits = 16'h6006;
        12'd515: O_bits = 16'h6006;
        12'd516: O_bits = 16'h6186;
        12'd517: O_bits = 16'h63C6;
        12'd518: O_bits = 16'h67E6;
        12'd519: O_bits = 16'h7C3E;
        12'd520: O_bits = 16'h700E;
        12'd521: O_bits = 16'h6006;
        12'd522: O_bits = 16'h6006;
        12'd523: O_bits = 16'h6006;
        12'd524: O_bits = 16'h6006;
        12'd525: O_bits = 16'h0000;
        12'd526: O_bits = 16'h0000;
        12'd527: O_bits = 16'h0000;
        // ---- 'X' (idx 33) ----
        12'd528: O_bits = 16'hC003;
        12'd529: O_bits = 16'h6006;
        12'd530: O_bits = 16'h300C;
        12'd531: O_bits = 16'h1818;
        12'd532: O_bits = 16'h0C30;
        12'd533: O_bits = 16'h0660;
        12'd534: O_bits = 16'h03C0;
        12'd535: O_bits = 16'h03C0;
        12'd536: O_bits = 16'h0660;
        12'd537: O_bits = 16'h0C30;
        12'd538: O_bits = 16'h1818;
        12'd539: O_bits = 16'h300C;
        12'd540: O_bits = 16'h6006;
        12'd541: O_bits = 16'h0000;
        12'd542: O_bits = 16'h0000;
        12'd543: O_bits = 16'h0000;
        // ---- 'Y' (idx 34) ----
        12'd544: O_bits = 16'hC003;
        12'd545: O_bits = 16'h6006;
        12'd546: O_bits = 16'h300C;
        12'd547: O_bits = 16'h1818;
        12'd548: O_bits = 16'h0C30;
        12'd549: O_bits = 16'h0660;
        12'd550: O_bits = 16'h03C0;
        12'd551: O_bits = 16'h0300;
        12'd552: O_bits = 16'h0300;
        12'd553: O_bits = 16'h0300;
        12'd554: O_bits = 16'h0300;
        12'd555: O_bits = 16'h0300;
        12'd556: O_bits = 16'h0300;
        12'd557: O_bits = 16'h0000;
        12'd558: O_bits = 16'h0000;
        12'd559: O_bits = 16'h0000;
        // ---- 'Z' (idx 35) ----
        12'd560: O_bits = 16'h7FFE;
        12'd561: O_bits = 16'h7FFE;
        12'd562: O_bits = 16'h0018;
        12'd563: O_bits = 16'h0030;
        12'd564: O_bits = 16'h0060;
        12'd565: O_bits = 16'h00C0;
        12'd566: O_bits = 16'h0180;
        12'd567: O_bits = 16'h0300;
        12'd568: O_bits = 16'h0600;
        12'd569: O_bits = 16'h0C00;
        12'd570: O_bits = 16'h1800;
        12'd571: O_bits = 16'h3000;
        12'd572: O_bits = 16'h7FFE;
        12'd573: O_bits = 16'h7FFE;
        12'd574: O_bits = 16'h0000;
        12'd575: O_bits = 16'h0000;
        // ---- ':' (idx 36) ----
        12'd576: O_bits = 16'h0000;
        12'd577: O_bits = 16'h0000;
        12'd578: O_bits = 16'h03C0;
        12'd579: O_bits = 16'h03C0;
        12'd580: O_bits = 16'h03C0;
        12'd581: O_bits = 16'h03C0;
        12'd582: O_bits = 16'h0000;
        12'd583: O_bits = 16'h0000;
        12'd584: O_bits = 16'h0000;
        12'd585: O_bits = 16'h0000;
        12'd586: O_bits = 16'h03C0;
        12'd587: O_bits = 16'h03C0;
        12'd588: O_bits = 16'h03C0;
        12'd589: O_bits = 16'h03C0;
        12'd590: O_bits = 16'h0000;
        12'd591: O_bits = 16'h0000;
        // ---- '.' (idx 37) ----
        12'd592: O_bits = 16'h0000;
        12'd593: O_bits = 16'h0000;
        12'd594: O_bits = 16'h0000;
        12'd595: O_bits = 16'h0000;
        12'd596: O_bits = 16'h0000;
        12'd597: O_bits = 16'h0000;
        12'd598: O_bits = 16'h0000;
        12'd599: O_bits = 16'h0000;
        12'd600: O_bits = 16'h0000;
        12'd601: O_bits = 16'h0000;
        12'd602: O_bits = 16'h0000;
        12'd603: O_bits = 16'h03C0;
        12'd604: O_bits = 16'h03C0;
        12'd605: O_bits = 16'h03C0;
        12'd606: O_bits = 16'h03C0;
        12'd607: O_bits = 16'h0000;
        // ---- '/' (idx 38) ----
        12'd608: O_bits = 16'h0003;
        12'd609: O_bits = 16'h0006;
        12'd610: O_bits = 16'h000C;
        12'd611: O_bits = 16'h0018;
        12'd612: O_bits = 16'h0030;
        12'd613: O_bits = 16'h0060;
        12'd614: O_bits = 16'h00C0;
        12'd615: O_bits = 16'h0180;
        12'd616: O_bits = 16'h0300;
        12'd617: O_bits = 16'h0600;
        12'd618: O_bits = 16'h0C00;
        12'd619: O_bits = 16'h1800;
        12'd620: O_bits = 16'h3000;
        12'd621: O_bits = 16'h6000;
        12'd622: O_bits = 16'hC000;
        12'd623: O_bits = 16'h0000;
        // ---- '空格' (idx 39) ----
        12'd624: O_bits = 16'h0000;
        12'd625: O_bits = 16'h0000;
        12'd626: O_bits = 16'h0000;
        12'd627: O_bits = 16'h0000;
        12'd628: O_bits = 16'h0000;
        12'd629: O_bits = 16'h0000;
        12'd630: O_bits = 16'h0000;
        12'd631: O_bits = 16'h0000;
        12'd632: O_bits = 16'h0000;
        12'd633: O_bits = 16'h0000;
        12'd634: O_bits = 16'h0000;
        12'd635: O_bits = 16'h0000;
        12'd636: O_bits = 16'h0000;
        12'd637: O_bits = 16'h0000;
        12'd638: O_bits = 16'h0000;
        12'd639: O_bits = 16'h0000;
        // ---- '安' (idx 40) ----
        12'd640: O_bits = 16'h03C0;
        12'd641: O_bits = 16'h03C0;
        12'd642: O_bits = 16'h3FFC;
        12'd643: O_bits = 16'h3FFC;
        12'd644: O_bits = 16'h0660;
        12'd645: O_bits = 16'h0C30;
        12'd646: O_bits = 16'h1818;
        12'd647: O_bits = 16'h3FF0;
        12'd648: O_bits = 16'h3FF0;
        12'd649: O_bits = 16'h0C30;
        12'd650: O_bits = 16'h0C30;
        12'd651: O_bits = 16'h1818;
        12'd652: O_bits = 16'h300C;
        12'd653: O_bits = 16'h3FF0;
        12'd654: O_bits = 16'h0000;
        12'd655: O_bits = 16'h0000;
        // ---- '路' (idx 41) ----
        12'd656: O_bits = 16'h03C0;
        12'd657: O_bits = 16'h0F00;
        12'd658: O_bits = 16'h3C00;
        12'd659: O_bits = 16'h3F00;
        12'd660: O_bits = 16'h0C00;
        12'd661: O_bits = 16'h3F00;
        12'd662: O_bits = 16'h0C00;
        12'd663: O_bits = 16'h3FF0;
        12'd664: O_bits = 16'h3FF0;
        12'd665: O_bits = 16'h0C30;
        12'd666: O_bits = 16'h1C30;
        12'd667: O_bits = 16'h1818;
        12'd668: O_bits = 16'h300C;
        12'd669: O_bits = 16'h3FFC;
        12'd670: O_bits = 16'h0000;
        12'd671: O_bits = 16'h0000;
        default: O_bits = 16'h0000;
    endcase
end

endmodule

// ============================================================================
// 备选实现：initial + $readmemh（安路 TD 也支持，但需要外部 .hex 文件）
// 需要时把下面整块取消注释，并把上面的 always@(*) 块注释掉。
// ----------------------------------------------------------------------------
// reg [15:0] char_rom [0:671];   // 42 字 x 16 行
// integer i;
// initial begin
//     for (i = 0; i < 672; i = i + 1) char_rom[i] = 16'h0;
//     $readmemh("my_charlib.hex", char_rom);   // 每行 4 个十六进制字符
// end
// assign O_bits = char_rom[{I_index, I_row}];
// ============================================================================

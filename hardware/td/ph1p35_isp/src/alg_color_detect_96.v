//==============================================================================
// 文件名   : alg_color_detect_96.v
// 模块名   : alg_color_detect_96
// 日期     : 2026-09-14
// 版本     : v1.0
// 描述     : 96-bit AXI4-Stream 算法通道 · M5 目标颜色检测（扩展要求 FR-8）
//
//  接口：S1第二批_接口冻结.md §4（端口逐字照抄）。
//  行为：以 alg_ref.py 为准，不自行发明。逐条对应关系：
//        alg_ref.target_hit  → §2 逐像素判色
//        alg_ref.hit_vote    → §4 行内 3 邻域多数表决（跨拍左右邻居）
//        alg_ref.window_valid_mask → §5 有效像素掩蔽（y>=2 且 拍号!=0）
//        alg_ref.bbox_stats  → §6 帧内 min/max/count 累加
//        alg_ref.draw_bbox   → §5 画框（白色 1 像素矩形，来自上一帧 bbox）
//
//  ---------------------------------------------------------------------------
//  【一、判色口径（= alg_ref.target_hit，只是把上下界换成对称容差）】
//  ---------------------------------------------------------------------------
//      hit = |R-tR| <= tol && |G-tG| <= tol && |B-tB| <= tol
//  alg_ref 用 [lo, hi] 上下界表达；本模块的容差框与之等价：
//      rlo = max(0, tR-tol)  rhi = min(255, tR+tol)   （差值天然被 8bit 夹住）
//  差值用 8 bit 无符号绝对差：|a-b| 最大 255，装得进 8 bit，不需要 9 位。
//
//  ---------------------------------------------------------------------------
//  【二、行内表决 hit_vote（alg_ref.hit_vote，逐字）】
//  ---------------------------------------------------------------------------
//      hit_voted[y][x] = hit[y][x] & (hit[y][x-1] | hit[y][x+1])
//  图外（x<0 或 x>W-1）左侧/右侧按 0 补。
//  **先表决、后掩蔽**（alg_ref 里是 `hit_vote(hit) & valid`，顺序不能反）。
//
//  一拍 = 4 个相邻像素，所以"左右邻居"有三种情况：
//      pix0 的左邻居 = 上一拍的 pix3   → 逐拍历史寄存器（跨拍）
//      pix1/pix2      = 本拍内左右相邻 → 纯组合
//      pix3 的右邻居 = 下一拍的 pix0   → 【本拍还没有】，必须等下一拍上总线
//  即：表决必须**看一眼下一拍**。这是本模块输出延迟的结构性下限（推导见 §三）。
//  行边界（tlast=1 的那一拍）右侧补 0，行首（前一拍 tlast=1）左侧补 0。
//
//  ---------------------------------------------------------------------------
//  【三、延迟 = 2 拍（为什么不是施工图 §4 写的 1 拍 —— 这是推导，不是偷懒）】
//  ---------------------------------------------------------------------------
//  O_tdata / O_tvalid / O_tlast / O_tuser 四路全部 = 输入延迟 **2 拍**，彼此严格同拍。
//
//    1) 一拍 4 个像素装在同一个 96bit 寄存器里整拍出，**不能只让 pix3 晚出**；
//       所以"某一拍的画框结果"必须整拍一起算出来。
//    2) pix3 的右邻居（下一拍的 pix0）只在**下一拍**才出现在 I_tdata 上
//       ⇒ 第 n 拍的画框结果最早只能在第 n+1 拍组合出来。
//    3) O_tdata 是寄存器：要在第 c 拍期间稳定，就得在第 c-1 拍末装载，装载的源数据
//       （那 4 个像素的原图）也必须在第 c-1 拍期间稳定 ⇒ 原图自己还得打一拍。
//    2)+3) 合起来 = 2 拍。想压到 1 拍，唯一的办法是把 pix3 的右邻居丢掉（表决退化，
//    每拍第 4 个像素列 4k+3 失去右邻居），那就不再是 alg_ref.hit_vote 的口径。
//
//  ⇒ 本模块的选择：**行为逐位对齐 alg_ref，延迟 2 拍**。
//    实测（sim/check_color_detect.py，32x8 x 5 帧 x 346 拍比对）：
//        延迟按 2 拍比 → 不符 0 条（图像/控制/统计全过）
//        延迟按 1 拍比 → 不符 386 条
//        延迟按 3 拍比 → 不符 385 条
//    即"2 拍"是实测钉死的，不是估计值。
//  ⇒ 若集成方坚持要 1 拍：把 §3 的 `w_vote[3]` 里的 `w_right_nb && w_hit[0]` 项去掉，
//    输出级直接吃当拍 I_tdata（判色与掩蔽坐标改用 w_hit / r_x_grp / r_y_pos），
//    代价实测：5 帧测试图上 F3 的命中数 34 → 33（bbox 不变），即与 alg_ref 不再逐位一致。
//  ⇒ 全通道对齐（S0-02 §8.1⑥）：M2/M3/M4 是"窗口后再 +1 拍"= 绝对 3 拍，M5 是 2 拍，
//    alg_top 需要给 M5 补 1 拍；本模块不自作主张加这一拍（加了就无法从这里看出真实延迟）。
//
//  ---------------------------------------------------------------------------
//  【四、帧边界与统计更新时刻（与 2 拍延迟的自洽性，已实测核对）】
//  ---------------------------------------------------------------------------
//  tlast 是**行末**（一帧 720 次），不是帧末，所以"帧尾"靠下一帧的 tuser 界定：
//  **下一帧的 tuser 拍一上总线**（此刻输出级还在吐上一帧的最后一个 beat），
//  就把上一帧累加好的统计锁进 O_bbox_*；由于输出本身滞后 2 拍，这份新统计
//  **正好从新帧的第 0 个输出 beat 起可见** —— 与 alg_ref 的 bbox_prev 语义
//  （"整帧都画上一帧的框"）逐拍重合，**不存在"帧首那一拍还用着旧统计"的窗口**。
//  （若延迟改成 1 拍就会错开一拍；校验器 sim/check_color_detect.py 按全局 beat 号
//    逐拍核对这一条，5 帧 320 拍全部相符。）
//
//  ---------------------------------------------------------------------------
//  【五、编码规范】Verilog-2001，单文件单模块；无 function/task/fork/wait/force/
//  #delay；无 latch（组合逻辑 100% 是 assign/wire）；一个 always 只干一件事；
//  低有效异步复位（与同批 win3x3_96 一致）。本模块**没有存储器**，不涉及 ERAM 规则。
//==============================================================================

module alg_color_detect_96 #(
    parameter IMG_WIDTH  = 1280,
    parameter IMG_HEIGHT = 720,
    // ★★ 2026-10-01 新增（全部保持"默认值 = 原行为"，故本模块已通过的仿真判据一字不变）：
    //   ① DOM_MODE —— 判色方式开关
    //        0 = 原【绝对容差】判据：|R-tR|<=tol && |G-tG|<=tol && |B-tB|<=tol（默认，不变）
    //        1 = 【红主导】判据：R 足够亮 且 R 明显大于 G 和 B
    //      为什么加它：上板实测「检测很少触发、只有橙色轨迹点没有白框」——
    //      绝对容差要求像素本身接近饱和红（R≈255,G≈0,B≈0），而现实里红笔/红纸/红杯子
    //      在室内光下 R 只有 150~200、G/B 有 50~90，全部落在门外。
    //      红主导判据只看"红色占优"，与物体绝对明暗无关，鲁棒得多。
    parameter        DOM_MODE   = 1'b0,
    parameter [7:0]  DOM_MIN    = 8'd80,      // 红主导：R 至少这么亮
    parameter [7:0]  DOM_MARGIN = 8'd30,      // 红主导：R 至少比 G / B 大这么多
    //   ② BBOX_COLOR —— 目标框的颜色
    //        默认 24'hFFFFFF（白，原行为）；板级覆盖成 24'hFF0000（红）以符合选题规格
    //        「原图 + 红框圈住红色物体」。
    parameter [23:0] BBOX_COLOR = 24'hFFFFFF,
    // ★★ 2026-10-01 【判据参数化 + 新增 AUTO 档】
    //   背景：原判据把"红主导"写死 ⇒ 屏幕上报的 RED 是同义反复（能过关的像素当然全红），
    //         没有信息量。要让标签有意义，判据本身必须能换。
    //   COLOR_MODE：
    //     0 = 固定红  R 够亮，且 R 比 G、B 各至少大 DOM_MARGIN  ← 官方规格那档，必须保留
    //     1 = 固定绿
    //     2 = 固定蓝
    //     3 = AUTO    只看"这个像素有没有颜色"，不预设是哪个通道：
    //                   饱和度 = max(R,G,B) − min(R,G,B) > SAT_TH，且 max > DOM_MIN
    //                 ⇒ 拿红东西对它报红、拿蓝的报蓝 —— 颜色是【统计出来的】(见 §2b)
    //   【依据】SC500CS 输出 RGB888，三通道独立可得，所以"通道差"是可直接算的量，
    //          不需要任何额外硬件、不需要新存储器。
    //   ⚠ AUTO 的固有局限（如实写进报告，不藏）：饱和的彩色背景（黄标签、木桌、肤色）
    //     同样"有颜色" ⇒ 背景一杂它会被带跑。所以固定档必须保留、可对比演示。
    // ★★ 2026-10-02：COLOR_MODE 由 parameter 改为输入端口 I_color_mode（见端口区）。
    //   原因：板上要现场在【固定红(官方规格)】与【AUTO(鲜艳色)】之间切换，参数做不到运行时改。
    parameter [7:0]  SAT_TH     = 8'd40,       // AUTO 档饱和度门限（max−min）
    // ★★ 2026-10-03 固定色档判据加强（板上反馈：暖光下万物被框成红）：
    //   旧判据只要“X 比另两通道各高 DOM_MARGIN”——木纹(150,110,90)、皮肤(190,140,110)在暖光下也满足。
    //   SAT_MIN：饱和度下限，灰白黑高光一律出局（默认 0=不设限，行为同旧；板级取 60）。
    //   RED_GAP 等：色调形状门——“红”的陡降在 G 侧(R−G 大、G−B 小)，“橙/黄/棕”是 G 也高(G−B 大)；
    //     要求 (最高−次高差距) > (次高−最低) + GAP 才算该色系（默认 255=永不生效=旧行为；板级 25）。
    parameter [7:0]  SAT_MIN    = 8'd0,
    parameter [8:0]  COLOR_GAP  = 9'd255,   // ★2026-10-03 尾逗号（后面新增 Y_MARGIN）
    //   自审修正：原定 60 会漏检深色物体
    //     —— 如暗红 (120,60,60) 饱和度恰好等于 60，不满足"严格大于"
    //     改 40 后：灰红(25)/浅灰蓝(30) 仍不命中，有安全余量
    // ★★ 2026-10-03 AUTO 档四族并行（多框多色）：黄族判据的 B 通道余量。
    //   黄 = (R>=DOM_MIN) && (G>=DOM_MIN) && (R>=B+Y_MARGIN) && (G>=B+Y_MARGIN)
    //   只在 AUTO 档（DOM_MODE=1 且 I_color_mode==3）参与像素归类与四族统计；
    //   固定档与 DOM_MODE=0 路径完全不引入该判据 ⇒ 输出逐位不变。
    parameter [7:0]  Y_MARGIN   = 8'd40,
    // ★★ 2026-10-03 五修：AUTO 黄族开关。板级 0 = 只留红/绿/蓝三族（黄/橙像素落回红族），
    //   默认 1 = 保持四族旧口径（金标准 TB 不受影响）。
    parameter        AUTO_Y     = 1'b1,
    // ★★ 2026-10-05 六修：蓝族专属放宽门（AUTO 档）。深蓝物体通道绝对差小，
    //   统一 SAT_TH 必漏检；红族不能放（木纹/肤色冒充红），所以只给蓝族单开。
    //   默认 = 通用值 ⇒ 所有既有 TB/金标准行为零变化。
    parameter [7:0]  SAT_TH_B   = SAT_TH,
    parameter [7:0]  DOM_MIN_B  = DOM_MIN,
    // ★★ 2026-10-05 十二修：绿族专属饱和门槛（真绿物体通道差常在 60~80，统一 80 太狠
    //   ⇒ 用户实测"绿不敏感"）。默认 = SAT_TH ⇒ 行为不变。
    parameter [7:0]  SAT_TH_G   = SAT_TH,
    // ★★ 2026-10-05 十六修：红/绿族专属门槛（用户：红色误检多、绿色识别弱）。
    //   红族抬高（板级 饱和110 / 亮度96）：肤色、暗暖色出局；真红物体差值 150+ 轻松过。
    //   绿族降低（板级 饱和45 / 亮度48）：真绿物体通道差常 60~80、亮度常 80~150。
    //   默认 = 通用值 ⇒ 既有行为逐位不变。
    parameter [7:0]  SAT_TH_R   = SAT_TH,
    parameter [7:0]  DOM_MIN_R  = DOM_MIN,
    parameter [7:0]  DOM_MIN_G  = DOM_MIN,
    // ★★ 2026-10-05 八修：绿族领先余量。旧判据 G>R 且 G>=B 零余量 ⇒ 橄榄/黄绿/卡其
    //   （G 只多 10~20）全灌进绿族（用户板上实测）。绿主导像素必须比 R、B 都高出
    //   GREEN_M 才算绿；不够格的不进任何族。默认 0 ⇒ 行为逐位不变。
    parameter [7:0]  GREEN_M    = 8'd0,
    // ★★ 2026-10-05 九修：族框最小命中像素数。旧判据"计数!=0 就给框"⇒ 物体边缘的
    //   混色像素（红球压蓝布，边界偏蓝）给别的族白送一个框，同一个区域套多个框。
    //   默认 1（与 !=0 逐位等价 ⇒ 既有 TB/金标准零影响）；板级 600（≈24x24 实心块）。
    parameter [31:0] FAM_MIN    = 32'd1
)(
    input  wire         I_clk,
    input  wire         I_rst_n,
    input  wire [95:0]  I_tdata,      // 原图（RGB888）
    input  wire         I_tvalid,
    input  wire         I_tlast,      // 行末：本行表决结束
    input  wire         I_tuser,      // 帧首：清表决计数、载入上一帧 bbox
    input  wire         I_tready,
    input  wire [23:0]  I_tgt_color,  // 目标颜色（RGB888）
    input  wire [7:0]   I_tgt_tol,    // 容差
    // ★★ 2026-10-02 新增：判色档位运行时选择（原 COLOR_MODE 参数端口化，取值语义不变）
    //   0=固定红 1=固定绿 2=固定蓝 3=AUTO（只看饱和度，报出色系由逐帧表决得到）
    input  wire [1:0]   I_color_mode,
    output reg  [95:0]  O_tdata,
    output reg          O_tvalid,
    output reg          O_tlast,
    output reg          O_tuser,
    output wire         O_tready,
    output reg  [10:0]  O_bbox_x0,
    output reg  [10:0]  O_bbox_x1,
    output reg  [10:0]  O_bbox_y0,
    output reg  [10:0]  O_bbox_y1,
    output reg  [31:0]  O_pix_count,
    output reg          O_bbox_valid,
    // ---- 2026-09-20：颜色类别（扩展要求 2.4(2)「识别」）--------------------
    //   0 = 红主导 / 1 = 绿主导 / 2 = 蓝主导 / 3 = 黄主导（2026-10-03 新增，仅 AUTO 档可能取 3）。
    //   有效性与 O_bbox_valid 同相
    //   （本帧一个命中像素都没有时，四计数器全 0，类别退化为 0，消费方靠
    //    O_bbox_valid 判断"有没有"）。
    output reg  [1:0]   O_color_class,
    // ---- 2026-09-20：动态跟踪（进阶要求 2.5(2)）------------------------------
    //   O_track_id：**跟踪编号**。目标连续丢失 >= LOST_N 帧后重新捕获 ⇒ 编号 +1；
    //     一直看得见就一直不变。屏上第 42~43 格显示成 "RED 01" 里的那两位。
    //     为什么不是"每帧+1"：那样只是帧计数器，证明不了"跟踪"。
    //     编号只在**重新捕获**时变，才真的说明跟踪有始有终。
    output reg  [7:0]   O_track_id,
    // ---- 2026-10-03：AUTO 档四族并行（多框多色）。族号=分类编码 0=R 1=G 2=B 3=Y。
    //   O_fam_valid[f] = 本帧族 f 是否有原始命中像素（r_hit_d1，与 O_color_class 同一口径）。
    //   O_fam_x*/y* = 44 位平面向量，族 f 占 [11*f +: 11]（Verilog-2001 无 2D 端口）；
    //     各族 bbox 按"表决+掩蔽后的本族命中像素"累加（与 §9 并集组同口径）。
    //     族计数为 0 时 x0/y0 保持 BBOX_SENT 哨兵、x1/y1 保持 0（画框判据自然压掉）。
    //   全部为寄存输出，与 O_bbox_valid **同一沿**（w_frame_start）更新。
    //   固定档 / DOM_MODE=0：Y 族恒不归类 ⇒ O_fam_valid[3]=0，O_fam_*[0..2] 退化为按旧三类分组。
    output reg  [3:0]        O_fam_valid,
    output reg  [4*11-1:0]   O_fam_x0,
    output reg  [4*11-1:0]   O_fam_x1,
    output reg  [4*11-1:0]   O_fam_y0,
    output reg  [4*11-1:0]   O_fam_y1
);

//------------------------------------------------------------------------------
// 1. 常量、tready 直通、寄存器声明
//------------------------------------------------------------------------------
localparam BEATS_PER_LINE = IMG_WIDTH >> 2;                 // 1280 >> 2 = 320
localparam XW = $clog2(BEATS_PER_LINE);                     // 320 → 9
localparam [XW-1:0] LAST_BEAT = BEATS_PER_LINE - 1;         // 319（行末拍）
localparam [10:0]   LAST_ROW  = IMG_HEIGHT - 1;             // 719

// 空 bbox 哨兵：min > max。与 alg_ref 的 bbox=None 在 draw_bbox 的
// `if (max_x < min_x) return` 判据下等价 —— 即使消费方漏看 O_bbox_valid，
// 也不会在 (0,0) 画出一个假框。
localparam [10:0] BBOX_SENT = 11'h7FF;

assign O_tready = I_tready;                                 // C-3：全链路不反压

// ---- 1.1 坐标计数器 ----
reg [XW-1:0] r_x_grp;                 // 拍计数器 0..319（不是像素计数器）
reg [10:0]   r_y_pos;                 // 行计数器 0..719

// ---- 1.2 第 1 级流水（输出级的前一级；两级合起来 = 输入延迟 2 拍）----
reg [95:0]   r_data_d1;               // 被输出拍的原图
reg [XW-1:0] r_x_d1;                  // 被输出拍的拍号
reg [10:0]   r_y_d1;                  // 被输出拍的行号
reg [3:0]    r_hit_d1;                // 被输出拍 4 个像素的原始判色位
// 2026-10-03：bbox 族归属用的 cls **不打拍**——w_cls0..3 已是 r_data_d1（与 r_hit_d1
//   同一拍捕获的同一份数据）的组合，天然与 voted 对齐；再打拍会错一拍（见 §9a 注释）。
reg          r_tu_d1;                 // 被输出拍的 tuser
reg          r_tl_d1;                 // 被输出拍的 tlast
reg          r_vld1;                  // I_tvalid 延迟 1 拍（C-4，**不被 tvalid 门控**；两级后 = 2 拍）

// ---- 1.3 邻居历史（再早一拍）----
reg          r_hit3_p2;               // 再前一拍 pix3 的判色位 = 当前输出拍 pix0 的左邻居
reg          r_tl_p2;                 // 再前一拍的 tlast = 1 说明当前输出拍是行首

// ---- 1.4 帧内累加（min/max/count）----
reg [10:0]   r_min_x;
reg [10:0]   r_max_x;
reg [10:0]   r_min_y;
reg [10:0]   r_max_y;
reg [31:0]   r_cnt;
// 2026-09-20：三类各自的命中像素数（红/绿/蓝主导）。与 r_cnt 同一套口径：
//   w_frame_start 重置、每个有效拍累加。位宽照抄 r_cnt 的 32 位，保持风格一致。
reg [31:0]   r_cnt_cls_r, r_cnt_cls_g, r_cnt_cls_b;
// 2026-10-03：第 4 个类别计数器（黄族）。口径与 r 组**逐字相同**（统计 r_hit_d1 原始命中，
//   与 r_data_d1 同拍）；黄归类只在 AUTO 档生效 ⇒ 固定档 / DOM_MODE=0 时恒 0。
reg [31:0]   r_cnt_cls_y;
// 2026-10-03：四族 bbox 累加器（族 0..3 = R/G/B/Y）。口径与上面并集组逐条相同，
//   唯一区别：每个 voted 像素按自己的族（w_cls0..3，与 r_hit_d1 同拍）只更新自己那一组。
reg [10:0]   r_fminx [0:3];
reg [10:0]   r_fmaxx [0:3];
reg [10:0]   r_fminy [0:3];
reg [10:0]   r_fmaxy [0:3];
// 2026-09-20：动态跟踪（进阶 2.5(2)）——
//   · r_tx/r_ty：最近 TRAIL_N 帧的目标**框中心**，r_tx[0] 最新。只在"那一帧有目标"
//     时才压入（没目标就保持原样，轨迹停在最后一次看见的地方）。
//   · r_track_id / r_lost_f：跟踪编号 / 连续丢失帧数。复位时 r_lost_f 置成"很久没看见"，
//     这样**第一次捕获**就能把编号从 0 推到 1（见 §10c）。
//   ⚠⚠ 复位值必须是 **BBOX_SENT（11'h7FF = 2047）而不是 0**：
//     轨迹是 8 级移位寄存器，上电时只有几个槽位是真点，其余是空的。
//     若空槽位复位成 0，它们会落在画面左上角的第 0 个 8x8 格里，
//     屏上就凭空多出一个"目标来过这里"的橙块 —— **谎报历史**。
//     2047 这个哨兵永远匹配不上：格号 = 2047>>3 = 255，而 x_base>>3 最大 159、
//     y>>3 最大 89（1280x720），连小图都不会撞上。**零成本**，不用加有效位。
localparam TRAIL_N = 8;                 // 轨迹点个数 = 保留最近 8 帧
localparam [2:0] LOST_MAX = 3'd7;       // 丢失计数饱和值（3 bit）
localparam [2:0] LOST_N   = 3'd4;       // >= 4 帧没看见才算"跟丢了"（@60fps ≈ 67ms）

reg [10:0]   r_tx [0:TRAIL_N-1];
reg [10:0]   r_ty [0:TRAIL_N-1];
reg [7:0]    r_track_id;
reg [2:0]    r_lost_f;

//------------------------------------------------------------------------------
// 2. 逐像素判色（= alg_ref.target_hit 的容差写法）
//------------------------------------------------------------------------------
wire [7:0] w_t_r = I_tgt_color[23:16];
wire [7:0] w_t_g = I_tgt_color[15:8];
wire [7:0] w_t_b = I_tgt_color[7:0];

// w_hit[k] = 本拍第 k 个像素（列 4*x_grp+k）的判色结果，k=0 是最左（tdata[95:72]）
wire [3:0] w_hit;

genvar gi;
genvar gk;                      // §5b 轨迹点比对用
genvar gf;                      // §9a 四族 bbox 累加用
integer ii;                     // §12 上电初值的 for 循环用（genvar 不能用在过程块里）
generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_hit
        wire [7:0] w_r = I_tdata[24*(3-gi) + 23 -: 8];
        wire [7:0] w_g = I_tdata[24*(3-gi) + 15 -: 8];
        wire [7:0] w_b = I_tdata[24*(3-gi) +  7 -: 8];
        wire [7:0] w_dr = (w_r >= w_t_r) ? (w_r - w_t_r) : (w_t_r - w_r);
        wire [7:0] w_dg = (w_g >= w_t_g) ? (w_g - w_t_g) : (w_t_g - w_g);
        wire [7:0] w_db = (w_b >= w_t_b) ? (w_b - w_t_b) : (w_t_b - w_b);
        // ★★ 2026-10-01 判据参数化：固定红/绿/蓝 + AUTO 共 4 档，由 I_color_mode 选(2026-10-02 端口化)。
        //   （先扩到 9 位再相加，避免 X+margin 溢出 8 位）
        wire [8:0] w_r9 = {1'b0, w_r};
        wire [8:0] w_g9 = {1'b0, w_g};
        wire [8:0] w_b9 = {1'b0, w_b};
        wire [8:0] w_rm = w_r9 + {1'b0, DOM_MARGIN};
        wire [8:0] w_gm = w_g9 + {1'b0, DOM_MARGIN};
        wire [8:0] w_bm = w_b9 + {1'b0, DOM_MARGIN};

        // 饱和度：最大通道 − 最小通道（灰/白/黑都近似为 0）
        wire [7:0] w_mx  = (w_r >= w_g) ? ((w_r >= w_b) ? w_r : w_b)
                                        : ((w_g >= w_b) ? w_g : w_b);
        wire [7:0] w_mn  = (w_r <= w_g) ? ((w_r <= w_b) ? w_r : w_b)
                                        : ((w_g <= w_b) ? w_g : w_b);
        wire [7:0] w_sat = w_mx - w_mn;

        // ★2026-10-03：固定色档三重门——够亮 && 双主导 && 饱和度 && 色调形状
        //   形状门以“主导通道 → 次通道 → 末通道”的落差比例区分 红 vs 橙黄棕（红：R-G 远大于 G-B）。
        wire [8:0] w_rg = (w_r9 > w_g9) ? (w_r9 - w_g9) : 9'd0;
        wire [8:0] w_gb = (w_g9 > w_b9) ? (w_g9 - w_b9) : 9'd0;
        wire [8:0] w_gr = (w_g9 > w_r9) ? (w_g9 - w_r9) : 9'd0;
        wire [8:0] w_rb2= (w_r9 > w_b9) ? (w_r9 - w_b9) : 9'd0;
        wire [8:0] w_bg = (w_b9 > w_g9) ? (w_b9 - w_g9) : 9'd0;
        wire [8:0] w_gr2= (w_g9 > w_r9) ? (w_g9 - w_r9) : 9'd0;
        wire w_hit_fixr = (w_r >= DOM_MIN) && (w_r9 >= w_gm) && (w_r9 >= w_bm)
                          && (w_sat > SAT_MIN) && (w_rg > w_gb + COLOR_GAP);
        wire w_hit_fixg = (w_g >= DOM_MIN) && (w_g9 >= w_rm) && (w_g9 >= w_bm)
                          && (w_sat > SAT_MIN) && (w_gb > w_rg + COLOR_GAP);
        wire w_hit_fixb = (w_b >= DOM_MIN) && (w_b9 >= w_rm) && (w_b9 >= w_gm)
                          && (w_sat > SAT_MIN) && (w_bg > w_gr2 + COLOR_GAP);
        // ★六修：蓝主导像素走专属阈值（暗蓝绝对色差小，统一门必漏）；其余族原样。
        wire       w_blu_px = (w_b > w_r) && (w_b > w_g);
        // ★八修：绿主导像素要"明显赢"（G 比 R、B 都 >= +GREEN_M）才进候选；
        //   弱绿（橄榄/黄绿）直接不进任何族，也不灌给红。
        wire       w_grn_px = (w_g > w_r) && (w_g >= w_b);
        wire       w_grn_ok = (w_g9 >= w_r9 + {1'b0, GREEN_M})
                           && (w_g9 >= w_b9 + {1'b0, GREEN_M});
        // ★十六修：三族各自的门槛（蓝=专属、绿=专属+领先余量、红=最高门槛压误检）
        wire w_hit_auto = w_blu_px ? ((w_sat > SAT_TH_B) && (w_mx > DOM_MIN_B))
                     : w_grn_px    ? ((w_sat > SAT_TH_G) && (w_mx > DOM_MIN_G) && w_grn_ok)
                                   : ((w_sat > SAT_TH_R) && (w_mx > DOM_MIN_R));

        wire w_hit_dom = (I_color_mode == 2'd0) ? w_hit_fixr :
                         (I_color_mode == 2'd1) ? w_hit_fixg :
                         (I_color_mode == 2'd2) ? w_hit_fixb : w_hit_auto;

        assign w_hit[gi] = DOM_MODE
                         ? w_hit_dom
                         : ((w_dr <= I_tgt_tol) && (w_dg <= I_tgt_tol) && (w_db <= I_tgt_tol));
    end
endgenerate

//------------------------------------------------------------------------------
// 2b. 颜色类别统计（2026-09-20，扩展要求 2.4(2)「识别」）
//
//   目标：让屏上不只知道"有没有检测到"，还知道**是什么类别**（红/绿/蓝）。
//
//   第一性原理：类别 = **命中像素的主导通道**。一个红的物体，它的命中像素里
//   R 通道最大；绿的是 G 最大。所以只要对每个命中像素判一次"哪个通道最大"，
//   三类各计一个计数器，一帧结束时谁最大就是谁。**没有一个字是写死的。**
//
//   ⚠ 为什么统计**原始命中 r_hit_d1**、而不是 §3 表决后的 w_voted：
//     表决的作用是**去噪**，不改变"这一片东西是什么颜色"；而 r_hit_d1 与
//     r_data_d1 是同一拍同一份数据，一分钱对齐风险都不用担。
//     帧级统计上两者的差别只是"少数边缘噪点算不算"，对主导通道没有影响。
//
//   ⚠⚠ 2026-09-20 实测踩到的坑（第一版写错，已改）：原先这里取的是 **I_tdata / w_hit**
//     （本拍输入总线），而计数器的门控是 **r_vld1 / w_frame_start**（它们对应的是
//     **上一拍**输入，见 §1.2）。两者差 1 拍 ⇒ 统计窗口整体平移 4 个像素：
//     每帧丢掉开头 4 个像素、多吃下一帧开头 4 个像素。
//     1280x720 全尺寸回归里命中像素是上千个、且分布均匀，**看不出**这 4 个像素的差别；
//     小图专项 TB（tb_cd_cls.v）把"关键像素放在帧首"才把它钉出来。
//     正确口径只有一个：**取 r_data_d1 / r_hit_d1**，与 r_cnt（取 w_voted）严格同拍。
//
//   平局优先级：R > G > B（`>=` 链，确定、可复现）。
//
//   ★★ 2026-10-03 AUTO 档四族并行：新增**黄族优先归类**。
//     黄 = (R>=DOM_MIN) && (G>=DOM_MIN) && (R >= B+Y_MARGIN) && (G >= B+Y_MARGIN)
//     —— R、G 同高且都明显高于 B（9bit 先扩位防溢出，与 §2 固定档同手法）。
//     归类优先级：**黄 > 红 > 绿 > 蓝**。
//     生效范围：**仅 AUTO 档**（DOM_MODE=1 且 I_color_mode==3，见 w_cls_y_en）。
//     固定档像素的主导通道已被判据锁死（fixr⇒R、fixg⇒G、fixb⇒B），旧分类器对它的
//     输出本来就与档位一致；DOM_MODE=0 走容差判据，更不该被新归类扰动 ——
//     两种情形下黄判定整体旁路，w_cls0..3 退化为**逐位相同**的旧三分 ⇒
//     三个老计数器、O_color_class、O_bbox_* 的固定档输出与 30 项既有断言语义不变。
//------------------------------------------------------------------------------
wire [7:0] w_p0_r = r_data_d1[95:88], w_p0_g = r_data_d1[87:80], w_p0_b = r_data_d1[79:72];
wire [7:0] w_p1_r = r_data_d1[71:64], w_p1_g = r_data_d1[63:56], w_p1_b = r_data_d1[55:48];
wire [7:0] w_p2_r = r_data_d1[47:40], w_p2_g = r_data_d1[39:32], w_p2_b = r_data_d1[31:24];
wire [7:0] w_p3_r = r_data_d1[23:16], w_p3_g = r_data_d1[15:8],  w_p3_b = r_data_d1[7:0];

// 黄族归类使能：只有 AUTO 档的统计走新优先级（默认值/固定档旁路，见上方注释）
wire       w_cls_y_en = DOM_MODE && (I_color_mode == 2'd3) && AUTO_Y;   // ★五修：AUTO_Y=0 关黄族
wire [8:0] w_p0_r9 = {1'b0, w_p0_r}, w_p0_g9 = {1'b0, w_p0_g}, w_p0_b9 = {1'b0, w_p0_b};
wire [8:0] w_p1_r9 = {1'b0, w_p1_r}, w_p1_g9 = {1'b0, w_p1_g}, w_p1_b9 = {1'b0, w_p1_b};
wire [8:0] w_p2_r9 = {1'b0, w_p2_r}, w_p2_g9 = {1'b0, w_p2_g}, w_p2_b9 = {1'b0, w_p2_b};
wire [8:0] w_p3_r9 = {1'b0, w_p3_r}, w_p3_g9 = {1'b0, w_p3_g}, w_p3_b9 = {1'b0, w_p3_b};
wire [8:0] w_ym9    = {1'b0, Y_MARGIN};
wire       w_is_y0  = w_cls_y_en && (w_p0_r >= DOM_MIN) && (w_p0_g >= DOM_MIN)
                              && (w_p0_r9 >= w_p0_b9 + w_ym9) && (w_p0_g9 >= w_p0_b9 + w_ym9);
wire       w_is_y1  = w_cls_y_en && (w_p1_r >= DOM_MIN) && (w_p1_g >= DOM_MIN)
                              && (w_p1_r9 >= w_p1_b9 + w_ym9) && (w_p1_g9 >= w_p1_b9 + w_ym9);
wire       w_is_y2  = w_cls_y_en && (w_p2_r >= DOM_MIN) && (w_p2_g >= DOM_MIN)
                              && (w_p2_r9 >= w_p2_b9 + w_ym9) && (w_p2_g9 >= w_p2_b9 + w_ym9);
wire       w_is_y3  = w_cls_y_en && (w_p3_r >= DOM_MIN) && (w_p3_g >= DOM_MIN)
                              && (w_p3_r9 >= w_p3_b9 + w_ym9) && (w_p3_g9 >= w_p3_b9 + w_ym9);

wire [1:0] w_cls0 = w_is_y0 ? 2'd3 :
                    ((w_p0_r >= w_p0_g) && (w_p0_r >= w_p0_b)) ? 2'd0 :
                    ((w_p0_g >= w_p0_b))                       ? 2'd1 : 2'd2;
wire [1:0] w_cls1 = w_is_y1 ? 2'd3 :
                    ((w_p1_r >= w_p1_g) && (w_p1_r >= w_p1_b)) ? 2'd0 :
                    ((w_p1_g >= w_p1_b))                       ? 2'd1 : 2'd2;
wire [1:0] w_cls2 = w_is_y2 ? 2'd3 :
                    ((w_p2_r >= w_p2_g) && (w_p2_r >= w_p2_b)) ? 2'd0 :
                    ((w_p2_g >= w_p2_b))                       ? 2'd1 : 2'd2;
wire [1:0] w_cls3 = w_is_y3 ? 2'd3 :
                    ((w_p3_r >= w_p3_g) && (w_p3_r >= w_p3_b)) ? 2'd0 :
                    ((w_p3_g >= w_p3_b))                       ? 2'd1 : 2'd2;

// 本拍 4 个像素里，属于各类别的命中像素数（0..4）
wire [2:0] w_hit_r = {2'b00, r_hit_d1[0] && (w_cls0 == 2'd0)}
                   + {2'b00, r_hit_d1[1] && (w_cls1 == 2'd0)}
                   + {2'b00, r_hit_d1[2] && (w_cls2 == 2'd0)}
                   + {2'b00, r_hit_d1[3] && (w_cls3 == 2'd0)};
wire [2:0] w_hit_g = {2'b00, r_hit_d1[0] && (w_cls0 == 2'd1)}
                   + {2'b00, r_hit_d1[1] && (w_cls1 == 2'd1)}
                   + {2'b00, r_hit_d1[2] && (w_cls2 == 2'd1)}
                   + {2'b00, r_hit_d1[3] && (w_cls3 == 2'd1)};
wire [2:0] w_hit_b = {2'b00, r_hit_d1[0] && (w_cls0 == 2'd2)}
                   + {2'b00, r_hit_d1[1] && (w_cls1 == 2'd2)}
                   + {2'b00, r_hit_d1[2] && (w_cls2 == 2'd2)}
                   + {2'b00, r_hit_d1[3] && (w_cls3 == 2'd2)};
wire [2:0] w_hit_y = {2'b00, r_hit_d1[0] && (w_cls0 == 2'd3)}
                   + {2'b00, r_hit_d1[1] && (w_cls1 == 2'd3)}
                   + {2'b00, r_hit_d1[2] && (w_cls2 == 2'd3)}
                   + {2'b00, r_hit_d1[3] && (w_cls3 == 2'd3)};

//------------------------------------------------------------------------------
// 3. 行内表决 hit_vote
//    被表决的是【输出那一拍】（= 上一拍总线上的拍，寄存器 r_hit_d1），
//    它的左邻居来自更早一拍的历史寄存器，右邻居来自【本拍总线上】的下一拍 pix0。
//------------------------------------------------------------------------------
// 输出拍的 pix0 左邻居：再前一拍的 pix3。前一拍是行末（tlast）时说明当前拍是行首，
// 左邻居在图外，按 0 补。
wire w_left_nb  = (!r_tl_p2) && r_hit3_p2;

// 输出拍的 pix3 右邻居：本拍总线拍的 pix0 判色结果。以下任一情况说明"没有下一拍
// 或下一拍是另一行"，右邻居按 0 补：
//   · 输出拍本身是行末（tlast）            → r_tl_d1
//   · 本拍总线上没有有效数据                → !I_tvalid
//   · 上一拍没有有效数据（不连续，非法激励）→ !r_vld1
wire w_right_nb = (!r_tl_d1) && I_tvalid && r_vld1;

wire [3:0] w_vote;
assign w_vote[0] = r_hit_d1[0] && ( w_left_nb || r_hit_d1[1] );
assign w_vote[1] = r_hit_d1[1] && ( r_hit_d1[0] || r_hit_d1[2] );
assign w_vote[2] = r_hit_d1[2] && ( r_hit_d1[1] || r_hit_d1[3] );
assign w_vote[3] = r_hit_d1[3] && ( r_hit_d1[2] || (w_right_nb && w_hit[0]) );

//------------------------------------------------------------------------------
// 4. 有效掩蔽 + 本拍命中候选
//------------------------------------------------------------------------------
wire [10:0] w_x_base = {r_x_d1, 2'b00};                     // 4 * r_x_d1 = 本拍第 0 像素的列
wire w_row_ok = (r_y_d1 >= 11'd2) && (r_x_d1 != {XW{1'b0}});

// 同一拍 4 个像素的掩蔽相同（x>>2 == x_grp）⇒ 一次判断管 4 个
wire [3:0] w_voted = w_vote & {4{w_row_ok}};

// 本拍命中的最小/最大列（仅 w_any=1 时有意义）；命中像素数 0..4
wire w_any = |w_voted;
wire [10:0] w_x_lo = w_voted[0] ? (w_x_base + 11'd0) :
                     w_voted[1] ? (w_x_base + 11'd1) :
                     w_voted[2] ? (w_x_base + 11'd2) : (w_x_base + 11'd3);
wire [10:0] w_x_hi = w_voted[3] ? (w_x_base + 11'd3) :
                     w_voted[2] ? (w_x_base + 11'd2) :
                     w_voted[1] ? (w_x_base + 11'd1) : (w_x_base + 11'd0);
wire [2:0] w_vcnt = {2'b00, w_voted[0]} + {2'b00, w_voted[1]}
                  + {2'b00, w_voted[2]} + {2'b00, w_voted[3]};

//------------------------------------------------------------------------------
// 5. 画框判定与输出数据（= alg_ref.draw_bbox）
//    bbox 四边任一命中即涂白；bbox 无效（min>max）时 w_bbox_ok 直接压掉。
//------------------------------------------------------------------------------
wire w_bbox_ok = (O_bbox_x0 <= O_bbox_x1) && (O_bbox_y0 <= O_bbox_y1);
wire [3:0] w_mark;

generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_mark
        wire [10:0] w_xk  = w_x_base + gi;                  // 本像素绝对列
        wire w_on_row = ((r_y_d1 == O_bbox_y0) || (r_y_d1 == O_bbox_y1))
                     && (w_xk >= O_bbox_x0) && (w_xk <= O_bbox_x1);
        wire w_on_col = ((w_xk == O_bbox_x0) || (w_xk == O_bbox_x1))
                     && (r_y_d1 >= O_bbox_y0) && (r_y_d1 <= O_bbox_y1);
        assign w_mark[gi] = w_bbox_ok && (w_on_row || w_on_col);
    end
endgenerate

//------------------------------------------------------------------------------
// 5b. 轨迹点判定（2026-09-20，进阶要求 2.5(2)「动态目标跟踪」）
//
//   把 §10c 记下的最近 TRAIL_N 个目标中心画成小方块，越旧越靠后 —— 一片点连起来
//   就是目标走过的**轨迹**。当前那一帧的框仍然是白色（见 §5c 的优先级）。
//
//   第一性原理（为什么这么便宜）：
//     · 点只需要"画在哪一格"，不需要精确到像素 ⇒ 用**对齐比较**代替范围比较：
//         行：r_y_d1[10:3] == r_ty[k][10:3]     （按 8 行对齐）
//         列：w_x_base[10:3] == r_tx[k][10:3]  （按 8 列对齐）
//       两个 9 位**相等**比较即可，一个点约 6 个 LUT，8 个点约 50 个 LUT。
//       对比 §5 画框那种 11 位范围比较，一个点比一条边还便宜。
//     · **列比较按"拍基址"做、不逐像素做**：w_x_base 是 4 对齐的拍基址，一个 8 列格
//       正好跨 2 拍，两拍的 w_x_base[10:3] 相同 ⇒ 4 个像素一起点亮，天然是 8 像素宽。
//       这样每拍只做 TRAIL_N 次比较，而不是 TRAIL_N x4 次。代价是点被量化到 8 列网格上
//       （位置误差 <= 7 像素）—— 对"轨迹点"完全够用，且**确定、可复现**，金标准照抄同一条。
//     · 不额外占存储：TRAIL_N x 22 bit = 176 个触发器，没有 ERAM。
//------------------------------------------------------------------------------
wire [TRAIL_N-1:0] w_trail_hit;

generate
    for (gk = 0; gk < TRAIL_N; gk = gk + 1) begin : g_trail
        assign w_trail_hit[gk] = (r_y_d1[10:3]  == r_ty[gk][10:3]) &&
                                 (w_x_base[10:3] == r_tx[gk][10:3]);
    end
endgenerate

wire w_trail = |w_trail_hit;

//------------------------------------------------------------------------------
// 5c. 输出像素：当前框(白) > 轨迹点(橙) > 原像素
//     优先级理由：当前目标框是"这一刻目标在哪"，最重要；轨迹是历史，不能盖住它。
//------------------------------------------------------------------------------
wire [95:0] w_marked;

generate
    for (gi = 0; gi < 4; gi = gi + 1) begin : g_out
        assign w_marked[24*(3-gi) +: 24] =
               w_mark[gi] ? BBOX_COLOR :                       // 当前框：默认白，板级可覆盖为红
               (w_trail   ? 24'hFF8000 :                       // 轨迹点：橙
                            r_data_d1[24*(3-gi) +: 24]);       // 其余：原像素
    end
endgenerate

// 帧边界：下一帧的 tuser 拍正上总线（此时输出级还在吐上一帧最后一个 beat）——
// 此刻累加器里装的正是上一帧的完整统计，把它锁出去就是"帧尾更新"（见文件头 §四）
wire w_frame_start = r_vld1 && r_tu_d1;

//------------------------------------------------------------------------------
// 6. 坐标推进（与 win3x3_96 / 官方 edge_detect_96.v 同一推进规则）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_grp <= {XW{1'b0}};
        r_y_pos <= 11'd0;
    end else if (I_tvalid) begin
        if (I_tuser) begin                       // 帧首：本拍坐标就是 (0,0)
            r_x_grp <= {{(XW-1){1'b0}}, 1'b1};
            r_y_pos <= 11'd0;
        end else if (r_x_grp == LAST_BEAT) begin
            r_x_grp <= {XW{1'b0}};               // 行末回绕
            r_y_pos <= (r_y_pos == LAST_ROW) ? 11'd0 : (r_y_pos + 11'd1);
        end else begin
            r_x_grp <= r_x_grp + 1'b1;
        end
    end
end

//------------------------------------------------------------------------------
// 7. 第 1 级流水寄存器（一个 always 只搬一件东西）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_data_d1 <= 96'd0;
    else if (I_tvalid)
        r_data_d1 <= I_tdata;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_x_d1 <= {XW{1'b0}};
        r_y_d1 <= 11'd0;
    end else if (I_tvalid) begin
        r_x_d1 <= r_x_grp;
        r_y_d1 <= r_y_pos;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_hit_d1 <= 4'd0;
    else if (I_tvalid)
        r_hit_d1 <= w_hit;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        r_tu_d1 <= 1'b0;
        r_tl_d1 <= 1'b0;
    end else if (I_tvalid) begin
        r_tu_d1 <= I_tuser;
        r_tl_d1 <= I_tlast;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_vld1 <= 1'b0;
    else
        r_vld1 <= I_tvalid;                      // 不加 I_tvalid 门控（C-4 握手延迟）
end

//------------------------------------------------------------------------------
// 8. 邻居历史寄存器
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_hit3_p2 <= 1'b0;
    else if (I_tvalid)
        r_hit3_p2 <= r_hit_d1[3];
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_tl_p2 <= 1'b0;
    else if (I_tvalid)
        r_tl_p2 <= r_tl_d1;
end

//------------------------------------------------------------------------------
// 9. 帧内累加（= alg_ref.bbox_stats 的流式实现）
//    帧首（tuser 拍被输出）时清成哨兵/0，本拍 tuser 拍本身必然被掩蔽（y=0），
//    所以 w_any 恒为 0，等价于"清零后从下一拍开始重新累加"。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_min_x <= BBOX_SENT;
    else if (w_frame_start)
        r_min_x <= w_any ? w_x_lo : BBOX_SENT;
    else if (r_vld1 && w_any && (w_x_lo < r_min_x))
        r_min_x <= w_x_lo;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_max_x <= 11'd0;
    else if (w_frame_start)
        r_max_x <= w_any ? w_x_hi : 11'd0;
    else if (r_vld1 && w_any && (w_x_hi > r_max_x))
        r_max_x <= w_x_hi;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_min_y <= BBOX_SENT;
    else if (w_frame_start)
        r_min_y <= w_any ? r_y_d1 : BBOX_SENT;
    else if (r_vld1 && w_any && (r_y_d1 < r_min_y))
        r_min_y <= r_y_d1;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_max_y <= 11'd0;
    else if (w_frame_start)
        r_max_y <= w_any ? r_y_d1 : 11'd0;
    else if (r_vld1 && w_any && (r_y_d1 > r_max_y))
        r_max_y <= r_y_d1;
end

//------------------------------------------------------------------------------
// 9a. 四族 bbox 累加（2026-10-03，AUTO 档多框多色）
//     与 §9 并集组**同口径同节奏**（w_frame_start 重置 / r_vld1+w_anyf 累加），
//     唯一区别：每个 voted 像素按其族（w_cls0..3，r_data_d1 的组合 = 与 r_hit_d1
//     同一路径的族编码，见 §9a 注释）只更新
//     自己那一组。族 g 的 w_anyg / w_xlog / w_xhig 与 §4 的 w_any/w_x_lo/w_x_hi
//     逐字同构，只是候选集从 w_voted 换成"w_voted 里族为 g 的那几个像素"。
//     固定档 / DOM_MODE=0：族归类退化为旧三分 ⇒ Y 组永远空（保持哨兵/0），
//     R/G/B 组照常累加；**并集组不受任何影响**，O_bbox_* 在非 AUTO 档仍取并集组。
//------------------------------------------------------------------------------
// 本拍 voted 像素的族归属（2026-10-03）：直接用 §2b 的组合 w_cls0..3。
//   w_cls* 由 r_data_d1 组合得到，而 r_data_d1 / r_hit_d1 / w_voted **本就同一拍**
//   （r_hit_d1 是 w_hit(I_tdata) 打一拍 ⇒ 与 r_data_d1 同路；w_cls* 是 r_data_d1 的
//   纯组合 ⇒ 天然同拍）。若把 w_cls* 再打一拍（r_cls_d1），族会相对 voted 错开
//   一整拍（实测：AUTO 下红带族会把蓝带前 3 列划进自己，maxx 4->14）。
//   §9a 的 {w_cls3..w_cls0} 掩码即任务书所说"cls 与 r_hit_d1 同路打拍"的落点。
generate
    for (gf = 0; gf < 4; gf = gf + 1) begin : g_fambb
        localparam [1:0] GFID = gf;             // 本 generate 分支的族号（2bit 形）
        wire [3:0] w_vfg   = w_voted &
                             { (w_cls3 == GFID),
                               (w_cls2 == GFID),
                               (w_cls1 == GFID),
                               (w_cls0 == GFID) };
        wire       w_anyg  = |w_vfg;
        wire [10:0] w_xlog = w_vfg[0] ? (w_x_base + 11'd0) :
                             w_vfg[1] ? (w_x_base + 11'd1) :
                             w_vfg[2] ? (w_x_base + 11'd2) : (w_x_base + 11'd3);
        wire [10:0] w_xhig = w_vfg[3] ? (w_x_base + 11'd3) :
                             w_vfg[2] ? (w_x_base + 11'd2) :
                             w_vfg[1] ? (w_x_base + 11'd1) : (w_x_base + 11'd0);

        always @ (posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n)
                r_fminx[gf] <= BBOX_SENT;
            else if (w_frame_start)
                r_fminx[gf] <= w_anyg ? w_xlog : BBOX_SENT;
            else if (r_vld1 && w_anyg && (w_xlog < r_fminx[gf]))
                r_fminx[gf] <= w_xlog;
        end

        always @ (posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n)
                r_fmaxx[gf] <= 11'd0;
            else if (w_frame_start)
                r_fmaxx[gf] <= w_anyg ? w_xhig : 11'd0;
            else if (r_vld1 && w_anyg && (w_xhig > r_fmaxx[gf]))
                r_fmaxx[gf] <= w_xhig;
        end

        always @ (posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n)
                r_fminy[gf] <= BBOX_SENT;
            else if (w_frame_start)
                r_fminy[gf] <= w_anyg ? r_y_d1 : BBOX_SENT;
            else if (r_vld1 && w_anyg && (r_y_d1 < r_fminy[gf]))
                r_fminy[gf] <= r_y_d1;
        end

        always @ (posedge I_clk or negedge I_rst_n) begin
            if (!I_rst_n)
                r_fmaxy[gf] <= 11'd0;
            else if (w_frame_start)
                r_fmaxy[gf] <= w_anyg ? r_y_d1 : 11'd0;
            else if (r_vld1 && w_anyg && (r_y_d1 > r_fmaxy[gf]))
                r_fmaxy[gf] <= r_y_d1;
        end
    end
endgenerate

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt <= 32'd0;
    else if (w_frame_start)
        r_cnt <= {29'd0, w_vcnt};
    else if (r_vld1)
        r_cnt <= r_cnt + {29'd0, w_vcnt};
end

//------------------------------------------------------------------------------
// 9b. 颜色类别的三个计数器（2026-09-20）—— 口径与 r_cnt **逐条相同**
//     门控用 w_frame_start 重置、有效拍累加（r_vld1）。统计的是原始命中 r_hit_d1
//     （**未表决**，理由见 §2b），且与 r_data_d1 同拍 ⇒ 与 r_cnt 同一统计窗口。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt_cls_r <= 32'd0;
    else if (w_frame_start)
        r_cnt_cls_r <= {29'd0, w_hit_r};
    else if (r_vld1)
        r_cnt_cls_r <= r_cnt_cls_r + {29'd0, w_hit_r};
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt_cls_g <= 32'd0;
    else if (w_frame_start)
        r_cnt_cls_g <= {29'd0, w_hit_g};
    else if (r_vld1)
        r_cnt_cls_g <= r_cnt_cls_g + {29'd0, w_hit_g};
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt_cls_b <= 32'd0;
    else if (w_frame_start)
        r_cnt_cls_b <= {29'd0, w_hit_b};
    else if (r_vld1)
        r_cnt_cls_b <= r_cnt_cls_b + {29'd0, w_hit_b};
end

// 2026-10-03：黄族计数器（第 4 类）。口径与上面三个**逐字相同**（原始命中 r_hit_d1、
//   与 r_data_d1 同拍、帧首重置/有效拍累加）；黄归类仅 AUTO 档生效 ⇒ 固定档恒 0。
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        r_cnt_cls_y <= 32'd0;
    else if (w_frame_start)
        r_cnt_cls_y <= {29'd0, w_hit_y};
    else if (r_vld1)
        r_cnt_cls_y <= r_cnt_cls_y + {29'd0, w_hit_y};
end

//------------------------------------------------------------------------------
// 10. 帧尾锁存（下一帧第 0 拍 = 上一帧的帧尾）：把上一帧统计交给 O_bbox_*
//     O_bbox_valid 在**清零之前**用 r_cnt 求值（非阻塞，读到的是上一帧的值）。
//
//     2026-10-03 AUTO 档多框多色：
//       · w_cls_win = 四族计数器的胜族（平局优先 R>G>B>Y，`>=` 链写死可复现）。
//         固定档 / DOM_MODE=0 时 r_cnt_cls_y 恒 0 ⇒ 该链逐位退化为旧的 R>G>B 三分。
//       · O_bbox_* = **获胜族**的 bbox（mux），仅 w_cls_y_en（AUTO 档）生效；
//         其余档位 O_bbox_* 仍取 §9 并集组 ⇒ 固定档输出逐位不变。
//------------------------------------------------------------------------------

// 四路比较（平局优先 R > G > B > Y，链式 >=）
wire [1:0] w_cls_win =
        ((r_cnt_cls_r >= r_cnt_cls_g) && (r_cnt_cls_r >= r_cnt_cls_b) && (r_cnt_cls_r >= r_cnt_cls_y)) ? 2'd0 :
        ((r_cnt_cls_g >= r_cnt_cls_b) && (r_cnt_cls_g >= r_cnt_cls_y))                                 ? 2'd1 :
        ((r_cnt_cls_b >= r_cnt_cls_y))                                                                  ? 2'd2 : 2'd3;

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_x0 <= BBOX_SENT;
    else if (w_frame_start)
        O_bbox_x0 <= w_cls_y_en ? r_fminx[w_cls_win] : r_min_x;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_x1 <= 11'd0;
    else if (w_frame_start)
        O_bbox_x1 <= w_cls_y_en ? r_fmaxx[w_cls_win] : r_max_x;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_y0 <= BBOX_SENT;
    else if (w_frame_start)
        O_bbox_y0 <= w_cls_y_en ? r_fminy[w_cls_win] : r_min_y;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_y1 <= 11'd0;
    else if (w_frame_start)
        O_bbox_y1 <= w_cls_y_en ? r_fmaxy[w_cls_win] : r_max_y;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_pix_count <= 32'd0;
    else if (w_frame_start)
        O_pix_count <= r_cnt;
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_bbox_valid <= 1'b0;
    else if (w_frame_start)
        O_bbox_valid <= (r_cnt != 32'd0);
end

//------------------------------------------------------------------------------
// 10b. 颜色类别锁存（2026-09-20；2026-10-03 扩为四族）：帧尾比较四个类别计数器，
//      取最大的那一类（平局 R>G>B>Y，见 §10 的 w_cls_win 链）。
//      与 O_pix_count / O_bbox_valid **同一拍、同一条件**（w_frame_start）锁存
//      ⇒ 消费方读到的"有没有"和"是什么"永远同相，不会一个新一个旧。
//      四计数器全 0（本帧无命中）时落回 0（R），但此时 O_bbox_valid=0，消费方不看它。
//      固定档 / DOM_MODE=0：y 恒 0 ⇒ 与旧的三分链逐位等价。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_color_class <= 2'd0;
    else if (w_frame_start)
        O_color_class <= w_cls_win;
end

//------------------------------------------------------------------------------
// 10d. 四族帧级输出锁存（2026-10-03）：与 O_bbox_valid 同沿（w_frame_start）。
//      O_fam_valid[f] = 族 f 本帧有无原始命中（与类别表决同口径，非 voted 计数）；
//      O_fam_* = 各族 bbox（voted+掩蔽口径，帧尾锁存后直通到下一帧尾）。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_fam_valid <= 4'd0;
        O_fam_x0    <= {4{BBOX_SENT}};
        O_fam_x1    <= 44'd0;
        O_fam_y0    <= {4{BBOX_SENT}};
        O_fam_y1    <= 44'd0;
    end else if (w_frame_start) begin
        // ★九修：族命中 >= FAM_MIN 才有框（旧口径"有 1 个像素就发框"⇒ 边缘混色白送套框）。
        O_fam_valid <= { (r_cnt_cls_y >= FAM_MIN), (r_cnt_cls_b >= FAM_MIN),
                         (r_cnt_cls_g >= FAM_MIN), (r_cnt_cls_r >= FAM_MIN) };
        O_fam_x0    <= { r_fminx[3], r_fminx[2], r_fminx[1], r_fminx[0] };
        O_fam_x1    <= { r_fmaxx[3], r_fmaxx[2], r_fmaxx[1], r_fmaxx[0] };
        O_fam_y0    <= { r_fminy[3], r_fminy[2], r_fminy[1], r_fminy[0] };
        O_fam_y1    <= { r_fmaxy[3], r_fmaxy[2], r_fmaxy[1], r_fmaxy[0] };
    end
end

//------------------------------------------------------------------------------
// 10c. 动态跟踪（2026-09-20，进阶要求 2.5(2)）
//
//   帧边界（w_frame_start，与 O_bbox_* / O_color_class **同一拍同一条件**）做两件事：
//
//     ① **推轨迹**：本帧有目标（r_cnt != 0）时，把 O_bbox_x0/y0 与 O_bbox_x1/y1
//        此刻的值（= **上一帧**统计出的框，见 §四）算中心，压进移位寄存器，
//        最旧的从 r_tx[7]/r_ty[7] 挤出去。
//        ⚠ 用的是锁存完的旧值：本模块所有帧级量都在同一拍更新，这里读到的
//          就是"上一帧的框"，与画在屏上那个白框是**同一个框** —— 轨迹点连起来
//          正好是那个白框走过的路径，不会出现"轨迹和白框对不上"。
//        ⚠ 没目标就**不压**：轨迹停在最后一次看见目标的地方。这不是缺陷，
//          是刻意的——空帧压进去会把轨迹抹掉。
//
//     ② **跟踪编号**：连续丢失 >= LOST_N 帧之后再看见目标，编号 +1，否则不变。
//        复位时 r_lost_f 直接置成 LOST_MAX（"很久没看见"），这样**第一次捕获**
//        就能把编号从 0 推到 1，上电后屏上第一眼就是 "RED 01" 而不是 "RED 00"。
//        编号饱和在 99 后回到 1（不显示 00，00 会和"没编号"混淆）。
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        for (ii = 0; ii < TRAIL_N; ii = ii + 1) begin
            r_tx[ii] <= BBOX_SENT;      // 空槽位 = 哨兵，永远匹配不上（见 §1.4 的说明）
            r_ty[ii] <= BBOX_SENT;
        end
    end else if (w_frame_start && (r_cnt != 32'd0)) begin
        for (ii = TRAIL_N - 1; ii > 0; ii = ii - 1) begin
            r_tx[ii] <= r_tx[ii-1];
            r_ty[ii] <= r_ty[ii-1];
        end
        // 新点 = 上一帧框的中心 = ((x0+x1)>>1, (y0+y1)>>1)，零除法。
        //
        // ⚠⚠ 必须读**累加器 r_min_x/r_max_x/r_min_y/r_max_y**，不能读 O_bbox_x0/x1！
        //   两个原因，缺一个都会错：
        //   ① O_bbox_* 是在**同一个时钟沿**（w_frame_start）被赋成"上一帧的框"的。
        //      非阻塞赋值下，本块在同一沿读到的还是**再前一帧**的框 ⇒ 轨迹整体晚一帧。
        //      （2026-09-20 全尺寸回归实测：M5 帧正好差 16 拍 = 一个 8x8 轨迹格，
        //        就是这条造成的。小图专项只查类别/编号/bbox，照不出来。）
        //   ② 累加器在这一沿装的正是**上一帧结束时**的完整统计，与随后写进
        //      O_bbox_* 的值逐位相同 ⇒ 轨迹点与屏上那个白框永远是同一个框。
        //
        // ⚠ 还要**先加宽到 12 位再相加**：r_min_x、r_max_x 各 11 位，真实画面里都能到 1279，
        //   和最大 2558 > 2047 ⇒ 直接写 `r_min_x + r_max_x` 会在 11 位处**截断**
        //   （x=1279 时和变成 510，中心算成 255，轨迹点跑到画面左侧去）。
        r_tx[0] <= ({1'b0, r_min_x} + {1'b0, r_max_x}) >> 1;
        r_ty[0] <= ({1'b0, r_min_y} + {1'b0, r_max_y}) >> 1;
    end
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_track_id <= 8'd0;
        r_lost_f   <= LOST_MAX;             // "很久没看见" ⇒ 第一次捕获就编号 1
    end else if (w_frame_start) begin
        if (r_cnt != 32'd0) begin
            r_lost_f <= 3'd0;
            if (r_lost_f >= LOST_N)         // 跟丢过 ⇒ 新的一次跟踪
                O_track_id <= (O_track_id >= 8'd99) ? 8'd1 : (O_track_id + 8'd1);
        end else if (r_lost_f != LOST_MAX) begin
            r_lost_f <= r_lost_f + 3'd1;
        end
    end
end

//------------------------------------------------------------------------------
// 11. 输出级（第 2 级；与输入相差 2 拍，四路严格同拍 —— 推导见文件头 §三）
//------------------------------------------------------------------------------
always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tdata <= 96'd0;
    else if (r_vld1)
        O_tdata <= w_marked;
    else
        O_tdata <= 96'd0;                        // C-4：无效拍输出清零
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n)
        O_tvalid <= 1'b0;
    else
        O_tvalid <= r_vld1;                      // = I_tvalid 延迟 1 拍（此级之前还有一级）
end

always @ (posedge I_clk or negedge I_rst_n) begin
    if (!I_rst_n) begin
        O_tlast <= 1'b0;
        O_tuser <= 1'b0;
    end else begin
        O_tlast <= r_vld1 && r_tl_d1;
        O_tuser <= r_vld1 && r_tu_d1;
    end
end

//------------------------------------------------------------------------------
// 12. 上电初值（仿真友好；每个寄存器的值与复位分支逐一相同）
//------------------------------------------------------------------------------
initial begin
    r_data_d1  = 96'd0;
    r_x_d1     = {XW{1'b0}};
    r_y_d1     = 11'd0;
    r_hit_d1   = 4'd0;
    r_tu_d1    = 1'b0;
    r_tl_d1    = 1'b0;
    r_vld1     = 1'b0;
    r_hit3_p2  = 1'b0;
    r_tl_p2    = 1'b0;
    r_x_grp    = {XW{1'b0}};
    r_y_pos    = 11'd0;
    r_min_x    = BBOX_SENT;
    r_max_x    = 11'd0;
    r_min_y    = BBOX_SENT;
    r_max_y    = 11'd0;
    r_cnt      = 32'd0;
    O_tdata    = 96'd0;
    O_tvalid   = 1'b0;
    O_tlast    = 1'b0;
    O_tuser    = 1'b0;
    O_bbox_x0  = BBOX_SENT;
    O_bbox_x1  = 11'd0;
    O_bbox_y0  = BBOX_SENT;
    O_bbox_y1  = 11'd0;
    O_pix_count   = 32'd0;
    O_bbox_valid  = 1'b0;
    r_cnt_cls_r   = 32'd0;
    r_cnt_cls_g   = 32'd0;
    r_cnt_cls_b   = 32'd0;
    O_color_class = 2'd0;
    // 2026-10-03：AUTO 四族（每个初值与对应复位分支逐一相同）
    r_cnt_cls_y = 32'd0;
    for (ii = 0; ii < 4; ii = ii + 1) begin
        r_fminx[ii] = BBOX_SENT;
        r_fmaxx[ii] = 11'd0;
        r_fminy[ii] = BBOX_SENT;
        r_fmaxy[ii] = 11'd0;
    end
    O_fam_valid = 4'd0;
    O_fam_x0    = {4{BBOX_SENT}};
    O_fam_x1    = 44'd0;
    O_fam_y0    = {4{BBOX_SENT}};
    O_fam_y1    = 44'd0;
    // 2026-09-20：动态跟踪（每个初值都与 §10c 的复位分支逐一相同）
    for (ii = 0; ii < TRAIL_N; ii = ii + 1) begin
        r_tx[ii] = BBOX_SENT;       // 空槽位 = 哨兵（写 0 会在左上角冒出假轨迹点）
        r_ty[ii] = BBOX_SENT;
    end
    O_track_id = 8'd0;
    r_lost_f   = LOST_MAX;
end

endmodule

# 板级工程说明（ph1p35_isp 板级版）

**这个工程是从官方例程 lab_ex3_osd 复制出来改的，用来出真实时序和可下载的码流。**

---

## 一、怎么打开

```
1. 启动  D:\TD\bin\td.exe
2. 菜单 File -> Open Project
3. 选这个文件：
   D:\TD\bin\work_for_all\ph1p35_isp\prj\board\lab_ex3_osd\td_project\camera_to_dsi_display.al
4. 左侧应看到顶层 design_top_wrapper，以及 isp 目录下的 isp_top（换成了我们的）
```

**注意**：工程名沿用了官方的 `camera_to_dsi_display`（没改名），因为 run 目录名和它绑定，改名容易出问题。**靠所在目录来区分**——这个在 `ph1p35_isp\prj\board\` 下，是**我们的**；官方原件还在
`C:\Users\29072\Desktop\安陆资料汇总\02_官方例程\...` 下，**没动过**。

---

## 二、目录结构

```
D:\TD\bin\work_for_all\ph1p35_isp\prj\board\lab_ex3_osd\
├── td_project\
│   ├── camera_to_dsi_display.al      ★ 工程入口（已加入我们的 11 个模块）
│   ├── camera_to_dsi_display.sdc       时钟约束（50MHz 系统时钟 + 240MHz MIPI 时钟）
│   ├── al_ip\                          IP 目录（PLL / DDR 等）
│   └── verify_syn.tcl                  综合验证脚本（命令行用，GUI 不用管）
└── user_source\
    ├── hdl_source\
    │   ├── design_top_wrapper.v        ★ 板级顶层（PLL+MIPI+ISP+HDMI+DDR）
    │   ├── hdmi_mixer.v                 ★ 已改成纯直通（去掉官方 Logo，见改动 4）
    │   ├── hdmi_mixer.v.official-backup   官方原版（909 行，含 Logo 叠加）
    │   ├── _removed_official_osd\         官方 Logo ROM / 字符库（已弃用，勿恢复）
    │   ├── isp\isp_top.v               ★ 已替换成我们的版本
    │   ├── isp\isp_top.v.official-backup  官方原版（备份）
    │   └── alg\                        ★ 新目录：我们的 11 个算法模块
    └── constraints_source\
        ├── pin.adc                     ★ 已修正 4 个错引脚
        └── pin.adc.official-backup     官方原版（备份，含 4 个错引脚）
```

---

## 三、改了哪些文件（一共 4 处）

### 改动 1：`user_source\hdl_source\isp\isp_top.v` —— 换成我们的

| | |
|---|---|
| 官方原件 | 已备份为 `isp_top.v.official-backup` |
| 新内容 | 我们 `prj\_fullchip\isp_top_alg.v` 的完整内容 |
| 为什么能直接换 | **端口完全一致**（`I_tdata[39:0]` 进、`O_tdata[127:0]` 出，13 个端口逐个相同），模块名都叫 `isp_top`，**不用改任何例化代码** |
| 差别 | 官方里面是 `edge_detect_96`（官方边缘检测）；我们的里面是 `alg_top`（6 档算法）+ `osd_mixer`（自研 OSD） |

### 改动 2：新增 `user_source\hdl_source\alg\` 目录，放进 11 个模块

```
alg_binarize_96.v   alg_color_detect_96.v   alg_smooth_96.v
alg_sobel_96.v      alg_top.v               gray_bt601_96.v
my_charlib.v        my_logo_rom.v           osd_mixer.v
rgb_row_delay_96.v  win3x3_96.v
```
来源：`D:\TD\bin\work_for_all\ph1p35_isp\src\`（完全一致的副本）

同时 `camera_to_dsi_display.al` 的文件清单里**追加了这 11 条**（CompileOrder 52~62），
否则综合时 `alg_top` / `osd_mixer` 会是黑盒。

### 改动 3：`user_source\constraints_source\pin.adc` —— 修正 4 个错引脚

官方那份有 4 个引脚是错的（经原理图逐脚核对，依据见
`C:\Users\29072\Desktop\安陆资料汇总\10_设计文档\S0\S0-04_板级引脚与约束基线.md`）：

| 信号 | 官方（错） | 实际是什么 | 改成 | 板上的什么 |
|---|---|---|---|---|
| `I_rst_n` | R10 | 以太网 PHY 的 TX_EN（不可断开） | **D5** | 板载 KEY1 |
| `I_button[0]` | N2 | 扩展口"组二"第 22 脚 | **A9** | 板载 KEY2 |
| `I_button[1]` | J14 | 扩展口"组一"第 15 脚 | **B9** | 板载 KEY3 |
| `O_screen_pwm` | R11 | 以太网 PHY 的 TXD0（不可断开） | **T5** | 扩展口"组一"第 33 脚（空脚） |

**⛔ 官方那 4 条的实际后果**（不改就中招）：
- `I_rst_n = R10` → 复位网络没有驱动源，**复位恒为 1，电路永不复位**
- `I_button = N2/J14` → 按键接到扩展口排针，**永远读到 1，按键无效**
- `O_screen_pwm = R11` → **把 PWM 灌进以太网发送数据线**（而且板上没屏幕）

**⚠ 需要复核的一处**：`O_screen_pwm` 的落脚点 `T5` 是**本队自行选定的**（官方没给可用替代脚），
选的是扩展口空脚。若原理图上 T5 另有用途，请换一个扩展口空脚。

### 改动 4：`user_source\hdl_source\hdmi_mixer.v` —— 去掉官方 Logo 叠加，改成纯直通

| | |
|---|---|
| 官方原件 | 已备份为 `hdmi_mixer.v.official-backup`（909 行） |
| 新内容 | 99 行纯直通（只保留 DDR 读使能 + 3 级时序对齐） |
| 为什么改 | 见下面两条 |

**原因一：原创性。** 官方 `hdmi_mixer.v` 里例化了安路的 Logo ROM（`anlogic_logo_rom`，160×160）
和字符库（`osd_char_lib`），在 **HDMI 输出的最后一级**把安路 Logo 盖在整幅画面上。
这属于官方素材出现在我们的显示通路里。我们自己的 OSD 是在上游 `isp_top` 里的
`osd_mixer` 做的，随像素写进 DDR 再读出来，**不需要在这一级重复叠加**。

**原因二：时序。** 那个 Logo 的地址计算 `S_logo_y * 160 + S_logo_x` 带来一个 DSP 乘法器
和一片 95 扇出的 ROM 地址译码网，正是官方基线里**最差的那条路径**（HDMI_PIXEL_CLK 75 MHz，
setup WNS 只剩 0.103 ns）。

**隔离 A/B 实测**（同器件速度等级 -3、同 13.333 ns 时钟约束，只换这一个文件）：

| 指标 @75.002 MHz | 官方 OLD | 旁路 NEW | 差值 |
|---|---|---|---|
| **SWNS（建立余量）** | **+0.104 ns** | **+11.147 ns** | **+11.043 ns** |
| 逻辑级数 | 17 | 0 | −17 |
| LUT6 | 2,708 | 0 | **−2,708** |
| slice | 2,752 | 44 | −2,708 |
| reg | 181 | 81 | −100 |
| DSP | 1 | 0 | **−1** |
| ERAM | 0 | 0 | 0 |

我这边独立跑出的 **0.104 ns**，和厂商自己那份 `phy_1` 报告里的 **0.103 ns** 是同一根路径，
差 1 ps —— 说明这个隔离测试台是可信的。

> **⚠ 不要把 "+11.147 ns" 当成整板的新 WNS。** 这是**单独综合这一个模块**的结果。
> 整板在 HDMI_PIXEL_CLK 域还有别的路径，去掉这条之后新 WNS 等于"原来的次差路径"，
> **必须由一次完整的整板 `phy_1` 重新测**。能确凿说的是：官方报告点名的那条最差路径被消掉了。

**顺带的好处**：75 MHz 这个最紧的时钟域几乎被清空（时钟扇出 124 → 44），
以后要在这个域加东西（比如帧差 / 直方图显示）不再一动就违例。

**同时归档**：`anlogic_logo_rom.v` 和 `osd_char_lib.v` 已从 `hdl_source` 移到
`hdl_source\_removed_official_osd\`，并从 `camera_to_dsi_display.al` 的清单里删掉
（文件条目 64 → 62 条）。那两个文件现在**没有任何文件引用**，不要恢复。

**端口表没动**，`design_top_wrapper.v` 一行都不用改。

---

## 四、这个工程能干嘛

| 能做 | 说明 |
|---|---|
| **拿真实时序（WNS）** | 有完整时钟约束，布局布线跑出来的是**能写进报告的时序数字** |
| **出可下载的码流** | `.bit` / `.bid`，前提是引脚约束没问题 |
| **完整板级综合** | 含 PLL / MIPI / ISP / HDMI / DDR 的全设计面积 |
| **上板调试** | ChipWatcher / 在线逻辑分析 |

**不能做**：功能正确性验证——那要靠 `sim\` 里的测试台和检查程序（仿真与综合是两条独立的验证路线）。

---

## 五、下一步怎么做

```
1. TD 打开 camera_to_dsi_display.al
   ⚠ 打开时会自动生成 IP（PLL / FIFO / BRAM / DDR2），要等一会儿，别急着操作
2. 确认左侧树里 isp_top 下面能看到我们的模块（alg_top / osd_mixer 等）
3. 跑 syn_1（综合）→ 看有没有 ERROR
4. 跑 phy_1（布局布线）→ 拿 WNS
5. 过了就生成码流
```

**跑完布局布线要看的数字**：`SWNS`（建立时间余量）和 `HWNS`（保持时间余量），都为正才算过。
红线是 **setup WNS ≥ +150 ps**。

### ⚠ 一个必须知道的技术点：这个工程不能用命令行验证

我试过用命令行批处理（`verify_syn.tcl`）跑综合，**失败了**，报一堆黑盒：

```
HDL-8007 ERROR: PLL is a black box
HDL-8007 ERROR: ddr2 is a black box
HDL-8007 ERROR: w128_d512_fifo is a black box
HDL-8007 ERROR: blk_mem_gen_zhenghe is a black box   ... 等 8 个
```

**原因不是工程错了**，而是：这些 IP 在文件清单里是 `.xml`（IP 定义文件），
比如 `user_source/ip_source/PLL/PLL.xml`、`.../ddr2/ddr2.xml`。
**真正的 RTL 需要 TD 的 IP 工具根据这些 `.xml` 生成出来。**

- **GUI 打开工程时会自动生成**（官方工程目录里那个 `ipgen.log` 就是证据）
- **命令行 `read_hdl` 不会生成**，所以那些模块全是黑盒

**结论：这个工程的验证只能在图形界面里做。** 命令行那条路对"含 IP 的板级工程"不适用
（我们之前跑通的全芯片 A/B 是纯 HDL、没有 IP，所以命令行能跑）。

因此下面第 2~4 步**必须你来点**，我没法替你验证到底。打开后请重点看：
1. 有没有 IP 生成失败的报错
2. `isp_top` 下面能不能看到 `alg_top` / `osd_mixer`
3. 综合有没有 ERROR（尤其中文注释导致的语法错）


---

## 六、和另一个工程的区别（别搞混）

| | `prj\gui\isp_alg.al` | **本工程** `prj\board\...\camera_to_dsi_display.al` |
|---|---|---|
| 顶层 | `isp_alg_shell`（我写的测试壳，LFSR 造假数据） | `design_top_wrapper`（真实板级顶层） |
| 内容 | 只有我们的 11 个模块 | 我们的模块 + PLL/MIPI/HDMI/DDR |
| 约束 | 无 | 引脚 + 时钟都有 |
| 用途 | **开发用**：看代码、改代码、快速综合 | **出产品用**：真实时序、出码流 |
| 能上板吗 | ❌ 不能 | ✅ 可以 |

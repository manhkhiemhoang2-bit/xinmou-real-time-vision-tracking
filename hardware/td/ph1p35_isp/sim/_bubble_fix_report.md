# alg_top 行消隐气泡：根因定位与修复报告（2026-09-14）

复现/验证入口：`sim\run_bubble.ps1`（5 步）。修复后 **ALL STEPS PASS**。

---

## 1. 根因（两条，互相独立）

### 根因 A —— `rgb_row_delay_96.v` 的**读口没有按 I_tvalid 门控**（数据错位）

上一轮只门控了写口与地址计数器，读寄存器是：

```verilog
always @ (posedge I_clk) begin
    if (I_tvalid)
        r_mem[r_x_grp] <= w_wr_word;
    r_q <= r_mem[w_rd_addr];      // <-- 自由跑
end
```

停顿期间 `r_x_grp` 冻住 ⇒ `w_rd_addr = x_grp+2` 冻住 ⇒ `r_q` **每个时钟都被重新
装载成同一个"未来字"** ⇒ 停顿结束后 O_tdata 比正确值超前、且同一个字被连吐数拍。
M3 的 src 正是取 O_tdata，于是 M3 帧（第 3/6 帧）每行第一个非掩蔽拍（列 4..7）错位。

**实测证据**（`_dbg_bubdiff.py`，ref=无气泡 / bub=有气泡，同一份激励）：

```
修复前：逐位不符 39 拍，其中 tdata 12 拍、bbox 组 27 拍
  拍 209 (=第3帧第2行第1拍, 列4..7):
    ref 90 9e9e | 10 1e1e | 10 1e1e | 90 9e9e
    bub 90 ffbc | 10 c83c | 10 c83c | 90 ffbc      <- 用的是下一拍的 src
  逐像素（_dbg_bubwin.py 全帧像素级比对，第 3 帧）:
    r2 c4  ref=909e9e bub=90ffbc     而 ref 的 c8 = 90ffbc
    r2 c5  ref=101e1e bub=10c83c     而 ref 的 c9 = 10c83c
    r2 c6  ref=101e1e bub=10c83c     而 ref 的 c10= 10c83c
```
只改读口门控后：**39 → 27**，12 个 tdata 不符全部消失。

### 根因 B —— M5 帧级统计（bbox/pix_count）在**时钟沿**上换值，不在**有效拍**上

`alg_color_detect_96.v` 的锁存沿是 `r_vld1 && r_tu_d1`（帧首拍之后那一拍），是纯时钟
事件；而 bbox 组被 check_bubble.py 当作逐拍输出列比较。无气泡时它落在输出流倒数第 4
拍；有行消隐气泡时输出流在帧首拍前有一段空档，那一瞬整段落进空档 ⇒ 同样的激励，
bbox 在不同的输出拍上翻新。

**实测证据**（修复 A 之后剩下的全部 27 拍都是这一组列）：

```
拍 61 : ref bbv=1 x0=4  x1=11 y0=3 y1=6 pix=32
        bub bbv=0 x0=2047 x1=0 y0=2047 y1=0 pix=0
拍 125: ref x0=6  x1=13   /  bub x0=4  x1=11
拍 189: ref x0=?  x1=?    /  bub = ref 上一帧的值       (9 组 × 3 拍 = 27)
列直方图：{'x0': 27, 'x1': 27, 'bbv': 3, 'y0': 3, 'y1': 3, 'pix': 3, 'tdata': 0}
```

---

## 2. 改动（只改 RTL，判据口径一字未动）

| 文件 | 位置 | 改动 |
|---|---|---|
| `src\rgb_row_delay_96.v` | §5（143-148 行） | `r_q <= r_mem[w_rd_addr];` 移进 `if (I_tvalid)` 内；§四/§5 注释同步 |
| `src\alg_top.v` | §5（251-268 行） | u_det 的 `O_bbox_* / O_pix_count / O_bbox_valid` 改接内部线网 `w_det_*` |
| `src\alg_top.v` | 新增 §7.6（376-420 行） | 在输出寄存器前一级（对齐 4 拍）遇**帧首有效拍** `w_sof_a0` 采样一次，`assign` 到顶层端口；换值时刻由有效拍决定 |
| `src\alg_top.v` | 文件头 §六（58-67 行） | 记录"帧级状态必须在有效拍上换值"这条纪律 |
| `prj\_fullchip\alg\*.v` | — | 直接复制，11 个文件 MD5 全部 SAME |

采样点恒晚于 u_det 锁存沿（T+1）、远早于下一帧锁存沿（T 为帧首拍的输入拍号，帧首拍必为
有效拍 ⇒ `r_vld1(T+1)=1 && r_tu_d1(T+1)=1` 与别处有无气泡无关），所以采到的必然是
"上一帧完整统计"，与金标准 `bbox_prev`（整帧都报/画上一帧的框）语义逐拍一致。

---

## 3. 四项判据实测

| 判据 | 命令 | 结果 |
|---|---|---|
| 回归 | `run_bubble.ps1` 第 1 步 / `check_alg_top.py` | **10153 条断言，不符 0，PASS** |
| 真 RTL 变异 | `python rtl_mutation_top.py` | **8/8 PASS**（基线 667 拍无误报） |
| 气泡判据 | `check_bubble.py dump_top_ref.txt dump_top_bub.txt` | **逐位不符 0**（640/640 拍，tlast 80/80，tuser 10/10，X/Z 0） |
| 判据自证 | `check_bubble.py --selftest` | **5/5 被抓住；基线 通过** |
| 附加 | `check_alg_top.py --selftest` | 17/17 PASS |

---

## 4. 两个必须如实说明的附带发现

### 4.1 `check_bubble.py --selftest` 原来的 5/5 是**假绿**

E3/E5 两个变异是**空操作**，与 RTL 无关（实测：变异后的 dump 与基线 dump **逐字节相同**）：

* E3 原来写 `rows[idx[len(idx)//2]][C_OV] = "1"`，而 `idx` 里全是 `O_tvalid=="1"` 的
  行 ⇒ 置 "1" 等于没改（实测 `E3 output identical to baseline input? True`）；
* E5 原来交换 `idx[10]`/`idx[11]` 的档位，而本激励每 64 拍才换档，第 10/11 拍档位都是
  `0` ⇒ 交换等于没改（`E5 output identical to baseline input? True`）。

基线本来是 FAIL 的 ⇒ "任何变异都必然被抓住" ⇒ 5/5 完全由失败基线撑着。基线修好之后
真相暴露成 3/5。**已只修这两个变异实现**（挑一行当前无效的拍标成有效；挑相邻且档位
确实不同的一对交换），`compare()` 与判据口径一字未改（`check_bubble.py.bak-20260914-210648`
是修改前原件，可直接 diff；改动集中在 `selftest()` 内，共 ±22 行）。这是**加强**自证，
不是放宽。

### 4.2 `run_all_second_batch.ps1` 的 B 项（rgb_row_delay 320 拍延迟）现在 FAIL 401 条，
但**不是本次改动造成的**，且全部落在**排空尾巴**上

三份 RTL 对照实测（同一份激励、同一个判据，dump 在 `sim\_rd_probe\`）：

| 版本 | 说明 | 判据结果 | 首个不符拍 |
|---|---|---|---|
| V0 | 原版：计数器/写口/读口**全不门控**（时钟域） | **PASS** | — |
| V1 | 交接给我的状态：计数器+写口门控、**读口不门控** | **FAIL 400 条** | 拍 1927 |
| V2 | 本次：全部按 I_tvalid 门控 | FAIL 401 条 | 拍 1926 |

* 输入流最后一个有效拍在 cycle 1923，判据窗口到 2243 —— **1926 之前的 1602 拍比较全部相符**，
  401 条全部是"输入停了、延迟线不再吐剩下的 320 个字"。
* 这是"按有效拍延迟"（V1 起就选定的语义，也是配对 win3x3 所必需）与判据里"O=I 延迟
  320 **时钟**"（含排空尾巴，V0 语义）的**合同冲突**，因果上无法同时满足：停顿与流结束
  在实时不可区分。
* 本次没有改 `check_row_delay.py`（判据）。建议二选一：① 接受"有效拍延迟"语义，把
  判据 B 的比对区收在输入流有效区（改动在判据侧）；② 若坚持要排空尾巴，就得给延迟线
  增加"帧末排空"判据（需要 IMG_HEIGHT/帧末信息，是接口改动）。

---

## 5. 复现命令

```powershell
cd D:\TD\bin\work_for_all\ph1p35_isp\sim
.\run_bubble.ps1                       # 5 步全绿
python rtl_mutation_top.py             # 8/8
python check_alg_top.py --selftest     # 17/17
python _dbg_bubdiff.py                 # 逐列对照 ref/bub（需先跑过 run_bubble.ps1）
python _rd_probe\probe.py              # 重建 V0/V1/V2 三份 dump_rd.txt
```

本任务**未改** `win3x3_96.v`（MD5 `0D70E84C896262BCE1D3EFC747B26C99`，与 prj 副本一致），
其 `tb_win3x3.v` + `check_win3x3.py` 无需复跑。

/*
 * gimbal_coord.h —— FPGA 坐标从机（I2C 0x50）读取接口
 *
 * 规格：SPEC_i2c_coord_20261020 §1.1/§1.2/§3.2
 *   FPGA 只做检测：alg_top 的 bbox 在 gim_i2c_slave 里锁存 → 影子寄存器，
 *   MCU 经与 MPU6050 同一条 I2C0 总线读取（协议同 MPU6050 风格：
 *   先写 1 字节寄存器指针，重复起始后连续读、地址自增）。
 *
 * 取代旧 APB 通路（gimbal_reg.h + gimbal_visual.*，均已删除）：
 *   实测证明 CPU 访问不到 Fabric APB，坐标改走 I2C 从机 0x50。
 *
 * 依赖：gimbal_imu_bus_read()（复用 gimbal_imu 的 s_i2c 句柄），
 *       使用前必须先 gimbal_imu_init() 成功。
 */

#ifndef GIMBAL_COORD_H
#define GIMBAL_COORD_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- 总线参数（规格 §1.1）---- */
#define GIMBAL_COORD_I2C_ADDR    0x50u   /* 7-bit 从机地址（写 0xA0 / 读 0xA1） */

/* ---- 寄存器映射（规格 §1.2，只读、地址自增）---- */
#define GIMBAL_COORD_REG_CX_L    0x00    /* 目标中心 x 低 8 位 */
#define GIMBAL_COORD_REG_CX_H    0x01    /* x[10:8]（低 3 位有效） */
#define GIMBAL_COORD_REG_CY_L    0x02    /* 目标中心 y 低 8 位 */
#define GIMBAL_COORD_REG_CY_H    0x03    /* y[10:8] */
#define GIMBAL_COORD_REG_VALID   0x04    /* bit0 = 本帧是否检出目标 */
#define GIMBAL_COORD_REG_FRAME_L 0x05    /* 帧计数低 8 位 */
#define GIMBAL_COORD_REG_FRAME_H 0x06    /* 帧计数高 8 位 */
#define GIMBAL_COORD_REG_MODE    0x07    /* 当前 ISP 档位 [2:0]（M0~M7） */
#define GIMBAL_COORD_REG_VERSION 0x0F    /* 固定 0x5A（握手/自检用） */

#define GIMBAL_COORD_VERSION_VAL 0x5Au   /* VERSION 期望值 */

/* ---- 返回码（0=成功，负=失败）---- */
#define GIMBAL_COORD_OK           0
#define GIMBAL_COORD_ERR_BUS     (-1)    /* I2C 事务失败（从机不应答/总线故障/句柄未初始化） */
#define GIMBAL_COORD_ERR_VERSION (-2)    /* VERSION != 0x5A（从机未就绪或 FPGA 位流不配套） */
#define GIMBAL_COORD_ERR_FRAME   (-3)    /* 双读 FRAME 3 次尝试后仍不一致（跨帧撕裂） */
#define GIMBAL_COORD_ERR_RANGE   (-4)    /* valid 但坐标超出画面（数据损坏），3 次尝试后仍如此 */

/* 一次坐标快照（已通过 FRAME 双读一致性校验） */
typedef struct {
    int32_t  cx;       /* 目标中心 x（像素 0..2047；坐标域 1280×720） */
    int32_t  cy;       /* 目标中心 y（像素 0..2047） */
    uint32_t frame;    /* 帧计数（FPGA 每帧 +1，喂 gimbal_tracker_update 做去重） */
    uint8_t  valid;    /* 1 = 本帧检出目标 */
    uint8_t  mode;     /* 当前 ISP 档位 [2:0]（追踪档 = M5） */
    /* ★2026-10-22 质量信息（从机 0x08~0x0D），给 MCU 做尺寸门 / 置信度门 */
    int32_t  w;        /* 目标宽（像素） */
    int32_t  h;        /* 目标高（像素） */
    int32_t  pix_cnt;  /* 命中像素数（饱和 255） */
    uint8_t  cls;      /* 颜色类别 0=R 1=G 2=B 3=其它 */
    uint8_t  auto_mode;/* ★1=AUTO 子档（三色识别，不牵引） */
    uint8_t  track_en; /* ★SW2：1=允许牵引 0=只识别不牵引 */
    uint8_t  status;   /* ★0x0E 原始字节（bit0=ROI bit1=AUTO bit2=SW2） */
} gimbal_coord_t;

/*
 * 握手自检：读 0x0F（VERSION），必须 == 0x5A。
 * 返回 GIMBAL_COORD_OK / ERR_BUS / ERR_VERSION。
 * 用法：上电调一次打印 "coord ok"；失败后由调用者降频重试（见 main.c）。
 */
int32_t gimbal_coord_init(void);

/*
 * 读一次坐标快照（规格 §3.2，含防撕裂）：
 *   ⓪ 先读 0x0F 校验 VERSION == 0x5A，失败直接返回错误码；
 *   ① 读 FRAME（0x05..0x06）得 frame1；
 *   ② 读 0x00~0x07 共 8 字节 payload（取 cx/cy/valid/mode）；
 *   ③ 再读 FRAME 得 frame2；
 *   frame1 != frame2 ⇒ 读取期间 FPGA 影子寄存器被帧脉冲更新过 ⇒ 重试，
 *   最多 3 次尝试（与旧 gimbal_visual 快照同款预算）；仍不一致返回 ERR_FRAME。
 * 成功返回 GIMBAL_COORD_OK 并填写 *out；失败不修改 *out。
 */
int32_t gimbal_coord_read(gimbal_coord_t *out);
/*
 * 写 ROI 窗口（从机 0x10~0x17，X0/X1/Y0/Y1 各两字节，写后自动递增并使能）。
 * 用途：锁定目标后只在窗口内检测，压掉窗口外的杂色干扰。
 * 传 roi_en=0 时写"全画面"（0..2047），等于关闭 ROI。
 */
int32_t gimbal_coord_write_roi(int32_t x0, int32_t x1, int32_t y0, int32_t y1);

/*
 * ★2026-10-21 调试探针：从 0x00 起连续读 n 字节（n<=16）原样返回，不做任何校验。
 *   用途：握手失败时把 0x00~0x0F 原始字节打出来，区分三种情况：
 *     全 0xFF → 线上没人驱动（从机不在/地址不对/位流不是新的）
 *     全 0x00 → 从机应答了但数据通路有问题（读时序/指针/影子寄存器）
 *     其他    → 有数据但映射错位
 *   仅调试用，正常路径不调用。
 */
int32_t gimbal_coord_probe(uint8_t *buf, uint32_t n);

/*
 * ★2026-10-21 单地址探测：对 addr7 做一次"写指针+读1字节"，返回 HAL 原始返回码。
 *   用来判断 HAL 是否会把 NACK 报成错误（对不存在的地址试一次即知）。
 */
int32_t gimbal_coord_probe_addr(uint8_t addr7, uint8_t reg);

#ifdef __cplusplus
}
#endif

#endif /* GIMBAL_COORD_H */

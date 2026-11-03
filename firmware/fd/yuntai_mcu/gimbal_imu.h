/*
 * gimbal_imu.h —— MPU6050 六轴 IMU 读取 + roll 横滚姿态解算接口
 *
 * 职责：
 *   1. 经 MCU 的 I2C 外设读 MPU6050（陀螺 + 加速度计）
 *   2. 上电零偏标定 + 互补滤波，解算出 roll 横滚角（Q16 度）
 *   3. 供 main 把 roll 角映射成第三路舵机脉宽，实现横滚自稳
 *
 * 角度约定：roll_deg 是"机械横滚角"，单位度，0=水平，右倾为正（受 OUT_SIGN 控制）。
 *   融合角度软件限幅在 gimbal_config.h 的 GIMBAL_IMU_ROLL_LIMIT_DEG（40°）；
 *   舵机命令/积分限幅是 GIMBAL_IMU_ROLL_CMD_LIMIT_DEG（20°），两者不同。
 */

#ifndef GIMBAL_IMU_H
#define GIMBAL_IMU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t roll_q16;       /* 横滚角 Q16（1°=65536），限幅 ±25° */
    int32_t roll_deg;       /* 横滚角（度，整数） */
    int32_t rate_dps;
    int32_t acc_mdeg;       /* ★2026-10-21 纯加速度算出的横滚角（毫度，诊断用） */       /* ★2026-10-21 roll 轴角速度（度/秒）—— 给 D 项做阻尼 */
    int32_t bias;           /* 陀螺零偏（标定得到） */
    int32_t bias_sum;       /* 标定累加 */
    int32_t acc_zero;       /* ★加速度计零点（标定得到）：水平时应读到的值 */
    int32_t acc_sum;        /* ★加速度零点标定累加 */
    int32_t ay0, az0;       /* ★2026-10-21 双轴零点：横滚绕 X 轴，重力在 Y-Z 平面转 */
    int32_t ay_sum, az_sum; /* ★双轴零点标定累加 */
    int32_t roll_int;       /* ★roll 积分器状态：舵机要转的角度（Q8 定点，256=1°） */
    uint32_t calib_cnt;     /* 标定计数 */
    uint32_t fail_cnt;      /* ★连续读失败计数（用于掉线自恢复） */
    uint8_t  calib_done;    /* 标定完成标志 */
    uint8_t  ok;            /* 1=WHO_AM_I 对上、I2C 正常 */
} gimbal_imu_t;

/* 初始化 I2C + MPU6050 配置 + WHO_AM_I 检查。返回 AL_OK(0) 或错误码 */
int32_t gimbal_imu_init(gimbal_imu_t *imu);

/* ★2026-10-21 roll 目标角偏移（毫度，1000=1°），运行时可改（ROLLTEST 扫描用） */
extern int32_t g_roll_target_mdeg;

/*
 * 每个采样周期调用一次（由 main 以 GIMBAL_IMU_SAMPLE_HZ 节拍调用）：
 *   读一组传感器 → （标定未完成时只累加零偏）→ 互补滤波更新 roll。
 * 标定期间必须保持云台静止。
 */
void gimbal_imu_update(gimbal_imu_t *imu);

/* ★2026-10-11 诊断：读一次六轴原始值（不参与滤波），用于实测确定
 *   GIMBAL_IMU_GYRO_AXIS / ACC_AXIS / *_SIGN 该填什么。
 *   用法：绕横滚轴慢慢转云台，看 gx/gy/gz 哪个变化最大 ⇒ 那个就是 GYRO_AXIS。
 *   返回 0 成功、-1 失败。 */
int32_t gimbal_imu_read_raw(int16_t *ax, int16_t *ay, int16_t *az,
                            int16_t *gx, int16_t *gy, int16_t *gz);

/* ★2026-10-20 通用总线读（规格 SPEC_i2c_coord_20261020 §3.1）：
 *   复用本模块内部的 s_i2c 句柄，对同一 I2C 总线上任意 7-bit 从机地址
 *   （如 FPGA 坐标从机 0x50）做与 MPU6050 同款的两段式读：
 *     写 1 字节寄存器指针（NOSTOP）→ 重复起始 → 读 n 字节（地址自增）→ STOP。
 *   前提：gimbal_imu_init() 已成功（句柄存在），否则返回 -1。
 *   超时沿用 I2C_TIMEOUT，单位是毫秒（50ms）。
 *   返回 AL_OK(0)=成功，否则为驱动错误码（从机不应答/超时为 -1 等）。 */
int32_t gimbal_imu_bus_read(uint8_t addr7, uint8_t reg, uint8_t *dst, uint32_t n);
int32_t gimbal_imu_bus_write(uint8_t addr7, uint8_t reg, const uint8_t *src, uint32_t n);

/* ★2026-10-11 掉线自恢复：I2C 偶发失败（线松动/干扰）后不必重启板子。
 *   重新初始化 I2C 并读一次 WHO_AM_I：通了就把 ok 置回 1。
 *   **保留原有的 bias / acc_zero**（不能在未知姿态下重新标定零点），
 *   但把 roll 角清零，让舵机先回中位，避免带着旧角度猛冲。
 *   返回 0 = 恢复成功，-1 = 仍不通。 */
int32_t gimbal_imu_recover(gimbal_imu_t *imu);

#ifdef __cplusplus
}
#endif

#endif /* GIMBAL_IMU_H */

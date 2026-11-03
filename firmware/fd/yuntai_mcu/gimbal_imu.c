/*
 * gimbal_imu.c —— MPU6050 读取 + roll 互补滤波解算
 *
 * 数学（与 FPGA 侧 gim_imu_roll.v 完全一致，逐条带单位）：
 *   陀螺 ±250°/s，灵敏度 131.072 LSB/(°/s) ⇒ 1 LSB = 1/131.072 °/s
 *   角度用 Q16（1°=65536）。一拍 dt=1/SAMPLE_HZ：
 *     增量 = (gyro-bias)/131.072 × dt × 65536 = (gyro-bias) × 500 / SAMPLE_HZ
 *   250Hz 时 500/250=2.0 ⇒ 增量 = (gyro-bias) × 2（正好整数，无截断）
 *
 *   加速度 ±2g，16384 LSB/g。小角度横滚 φ ≈ −ay/g（弧度），转 Q16 度：
 *     φ_q16 = −ay × (180/π) × 65536 / 16384 ≈ −ay × 229.18 ≈ −ay × 229
 *     注意 229 **已经含 /16384**，不要再移位（多移会让加速度半边形同虚设）。
 *     只在小角度可信（±30° 内误差 <2%），云台 roll 工作区 ±25° 正好够。
 *
 *   互补滤波：roll += 陀螺积分 − K·(roll − 加速度倾角)，K=2^−COMP_SH。
 *     陀螺高频准、低频漂；加速度低频准、高频被运动加速度带偏，两者互补。
 *
 * 使用约束：上电后云台必须静止约 1 秒（零偏标定），用 calib_done 表示完成。
 */

#include <stdio.h>
#include "gimbal_imu.h"
#include "gimbal_config.h"

#include "al_i2c_hal.h"   /* i2c_n 驱动（PH1P35 的 I2C0） */
#include "al_misc_ll.h"   /* AlMisc_ll_SetClkEn / SetReset */
#include "al_systimer.h"  /* AlSys_MDelay */

/* ---- MPU6050 寄存器 ---- */
#define MPU6050_REG_PWR_MGMT_1    0x6B
#define MPU6050_REG_SMPLRT_DIV    0x19
#define MPU6050_REG_CONFIG        0x1A
#define MPU6050_REG_GYRO_CONFIG   0x1B
#define MPU6050_REG_ACCEL_CONFIG  0x1C
#define MPU6050_REG_ACCEL_XOUT_H  0x3B
#define MPU6050_REG_WHO_AM_I      0x75

static AL_I2C_HalStruct *s_i2c;

/* ★2026-10-09：器件地址改为运行期变量，支持自动探测。
 *   MPU6050 的 I2C 地址由模块上的 AD0 引脚决定：AD0 接地=0x68，接高=0x69。
 *   很多模块 AD0 悬空或默认上拉，只按 0x68 找就会"整个 I2C 一个事务都不应答"，
 *   表现正是驱动超时返回 0xffffffff。先探测再写，最稳。 */
/* ★2026-10-21 roll 目标角偏移改为【运行时可改】（原本是编译期宏）。
 *   目的：让 ROLLTEST 模式能自动扫一遍偏移量，人工只需看"哪个数最平"，
 *   不必靠一次次编译+烧写去猜。默认值仍取配置文件里的宏。 */
int32_t g_roll_target_mdeg = GIMBAL_IMU_ROLL_TARGET_MDEG;

static uint8_t s_addr = GIMBAL_IMU_ADDR;

/* ★2026-10-05 修正：原来的 0xFFFFFFFF 让"IMU 掉线"变成了"永不死心"。
 *   查 BSP 驱动 al_i2c_dev.c：该参数单位是【毫秒】，
 *       Endtick = Start + Freq * DelayMs / 1000
 *   所以 0xFFFFFFFF = 4,294,967,295 ms ≈ 49.7 天。
 *   后果：MPU6050 不应答时（没接/接错/没供电），程序卡在 gimbal_imu_init()
 *   的第一个 I2C 调用上，后面所有 printf 都出不来，main.c 里
 *   "IMU 初始化失败不致命" 的降级设计完全失效。
 *   改成 50 ms：单次 I2C 传输只需 ~90us，50ms 足够宽松；
 *   IMU 不在也能在几百毫秒内返回失败，程序继续走下去（roll 保持中位）。
 *
 * ★2026-10-21 自平衡优化：把 MPU6050 读超时从 50ms 降到 5ms。
 *   正常 14 字节 @100kHz 约 1.5ms，5ms 仍有 3 倍余量；但一次线接触不良
 *   原来会让 250Hz 自稳环停 50ms，现在最多 5ms，且配合下面的连续失败计数，
 *   不会因为一次瞬断就猛回中位。 */
#define I2C_TIMEOUT  5u

/* ---- 基础 I2C 收发 ---- */

/* 写一个寄存器：START → [addr, reg, val] → STOP */
static int32_t mpu_write_reg(uint8_t reg, uint8_t val)
{
    uint8_t buf[2] = { reg, val };
    return AlI2c_Hal_MasterSendDataPolling(s_i2c, s_addr, buf, 2,
                                           AL_I2C_START, AL_I2C_STOP, I2C_TIMEOUT);
}

/* 读 n 个连续寄存器：START → [reg] (无STOP) → RESTART → 读 n 字节 → STOP */
static int32_t mpu_read_regs(uint8_t reg, uint8_t *dst, uint32_t n)
{
    int32_t ret;
    ret = AlI2c_Hal_MasterSendDataPolling(s_i2c, s_addr, &reg, 1,
                                          AL_I2C_START, AL_I2C_NOSTOP, I2C_TIMEOUT);
    if (ret != AL_OK) {
        return ret;
    }
    return AlI2c_Hal_MasterRecvDataPolling(s_i2c, s_addr, dst, n,
                                           AL_I2C_RESTART, AL_I2C_STOP, I2C_TIMEOUT);
}

/* ----------------------------------------------------------------------------
 * ★2026-10-20 通用总线读（规格 SPEC_i2c_coord_20261020 §3.1）
 *   同一条 I2C0 总线上还挂着 FPGA 坐标从机（7-bit 地址 0x50）。本函数把内部
 *   s_i2c 句柄借给其它模块用，避免第二次 AlI2c_Hal_Init 抢外设。
 *   时序与 mpu_read_regs 完全同款两段式：
 *     START → [addr7 写 1 字节寄存器指针] (NOSTOP) → RESTART → 读 n 字节 → STOP
 *   超时沿用本文件顶部的 I2C_TIMEOUT——单位是【毫秒】（2026-10-21 起为 5ms），不是 tick。
 *   注意：不碰 s_addr（那是 MPU6050 探测出来的地址），地址完全由参数给定。
 *   返回 AL_OK(0)=成功；否则透传驱动错误码；句柄未初始化/参数无效返回 -1。
 * --------------------------------------------------------------------------*/
/* ★2026-10-21 坐标读总线用【短超时】。
 *   为什么：本函数只给 FPGA 坐标从机（0x50）用，而调用它的 20Hz 逻辑跑在
 *   250Hz 自稳环的同一个大循环里。原来沿用 I2C_TIMEOUT=50ms，一次"读一帧"
 *   （读 FRAME + 读 8 字节 + 再读 FRAME 校验）最坏就是 3×50=150ms，
 *   再乘 COORD_ATTEMPT_MAX(3) ≈ 450ms ⇒ 自稳环停摆近半秒：
 *   陀螺积分漏采样、稳定环无输出 ⇒ 平台沉到某个姿态后就"锁死"在那儿，
 *   而且每次锁死的角度都不一样。5ms 对 8 字节传输绰绰有余（400kHz 下 <1ms）。
 *   超时只影响"读不到时等多久"，不影响正常读取。 */
#define BUS_TIMEOUT_COORD_MS   5u

int32_t gimbal_imu_bus_read(uint8_t addr7, uint8_t reg, uint8_t *dst, uint32_t n)
{
    int32_t ret;

    if (s_i2c == 0 || dst == 0 || n == 0u) {
        return -1;
    }
    ret = AlI2c_Hal_MasterSendDataPolling(s_i2c, addr7, &reg, 1,
                                          AL_I2C_START, AL_I2C_NOSTOP, BUS_TIMEOUT_COORD_MS);
    if (ret != AL_OK) {
        return ret;
    }
    return AlI2c_Hal_MasterRecvDataPolling(s_i2c, addr7, dst, n,
                                           AL_I2C_RESTART, AL_I2C_STOP, BUS_TIMEOUT_COORD_MS);
}

/* ----------------------------------------------------------------------------
 * 初始化：I2C 时钟/复位 → I2C 初始化 → MPU6050 配置 → WHO_AM_I 检查
 * --------------------------------------------------------------------------*/
int32_t gimbal_imu_init(gimbal_imu_t *imu)
{
    AL_I2C_InitStruct cfg = {
        .WorkMode = AL_I2C_CPU_MODE,
        .RoleMode = AL_I2C_MASTER_MODE,
        .ClkSpeed = AL_I2C_STANDARD_MODE,   /* 100kHz，稳；可改 FAST 400kHz */
        .SclDuty  = AL_I2C_SCL_DUTY_50,
        .SclPull  = AL_TRUE,
        .SdaPull  = AL_TRUE,
    };
    int32_t ret;
    uint8_t who = 0;

    imu->roll_q16   = 0;
    imu->roll_deg   = 0;
    imu->bias       = 0;
    imu->bias_sum   = 0;
    imu->acc_zero   = 0;
    imu->acc_sum    = 0;
    imu->ay0 = 0;  imu->az0 = 0;
    imu->ay_sum = 0;  imu->az_sum = 0;
    imu->calib_cnt  = 0;
    imu->fail_cnt   = 0;
    imu->roll_int   = 0;    /* ★roll 积分器清零 */
    imu->calib_done = 0;
    imu->ok         = 0;

    /* 使能 I2C 时钟并复位一次（参考 i2c_n 例程） */
    AlMisc_ll_SetClkEn(AL_MISC_I2C, 1);
    AlMisc_ll_SetReset(AL_MISC_I2C, 0);
    AlMisc_ll_SetReset(AL_MISC_I2C, 1);

    ret = AlI2c_Hal_Init(&s_i2c, 0, &cfg, AL_NULL);
    if (ret != AL_OK) {
        return ret;
    }
    AlSys_MDelay(10);   /* 上电后给模块一点时间稳定 */

    /* ---- ① 探测器件地址：0x68（AD0=0）→ 0x69（AD0=1）----------------------
     *   必须在任何"写"之前做！原来代码先写 PWR_MGMT_1，地址不对就死在第一次写、
     *   直接返回超时 -1（0xffffffff），完全看不出是"地址错"还是"线没接"。
     *   现在先读 WHO_AM_I 探测：两个地址都不应答 ⇒ 才是真的 I2C 没通。 */
    s_addr = GIMBAL_IMU_ADDR;
    ret = mpu_read_regs(MPU6050_REG_WHO_AM_I, &who, 1);
    if (ret != AL_OK) {
        s_addr = (uint8_t)(GIMBAL_IMU_ADDR + 1u);   /* 试 AD0=1 的地址 */
        AlSys_MDelay(5);
        ret = mpu_read_regs(MPU6050_REG_WHO_AM_I, &who, 1);
        if (ret != AL_OK) {
            return ret;     /* 两个地址都没应答 ⇒ I2C 硬件没通 */
        }
    }

    /* 唤醒（PWR_MGMT_1=0，退出休眠、用内部 8MHz 时钟） */
    ret = mpu_write_reg(MPU6050_REG_PWR_MGMT_1, 0x00);
    if (ret != AL_OK) {
        return ret;
    }
    AlSys_MDelay(100);

    /* 采样率 1kHz、DLPF 开（~44Hz 带宽，滤掉高频运动噪声） */
    (void)mpu_write_reg(MPU6050_REG_SMPLRT_DIV, 0x00);
    (void)mpu_write_reg(MPU6050_REG_CONFIG,     0x03);
    /* 陀螺 ±250°/s（GYRO_CONFIG=0x00） */
    (void)mpu_write_reg(MPU6050_REG_GYRO_CONFIG,  0x00);

    /* 加速度 ★±4g★（2026-10-11 从 ±2g 改过来）
     *   为什么改：本模块加速度计 Y 轴零点偏到 -22410，在 ±2g 量程里已占 68%，
     *   往负方向再歪约 21° 读数就被削顶到 -32768（硬饱和），
     *   环路看不到真实倾斜 ⇒ 那个方向补不动（实测"两边最大补偿角度不一样"）。
     *   改 ±4g 后读数减半 ⇒ 零点只占 34%，余量从 0.36g 涨到 2.6g，不再饱和。
     *   代价：灵敏度减半（角度噪声变大一点），但不再饱和更重要。
     *   ⚠ 换正品模块后建议改回 ±2g（0x00）并把 GIMBAL_IMU_ACC_K 改回 229。 */
    (void)mpu_write_reg(MPU6050_REG_ACCEL_CONFIG, 0x08);   /* AFS_SEL=2 → ±4g */
    /* ★2026-10-21 量程回读校验：这颗模块的 ACCEL_CONFIG 写入偶发不生效。
     *   若实际停在 ±2g（16384 LSB/g）而算法按 ±4g（8192）换算，
     *   倾角会差 2 倍 ⇒ 补偿过头、来回摆。回读确认并重试，把实际值打出来。 */
    {
        uint8_t afs = 0xFFu;
        int32_t k;
        for (k = 0; k < 3; k++) {
            (void)mpu_read_regs(MPU6050_REG_ACCEL_CONFIG, &afs, 1u);
            if ((afs & 0x18u) == 0x08u) {
                break;
            }
            (void)mpu_write_reg(MPU6050_REG_ACCEL_CONFIG, 0x08);
        }
        printf("acc range: ACCEL_CONFIG=0x%02X (%s)\r\n",
               (unsigned)afs,
               ((afs & 0x18u) == 0x08u) ? "4g ok" : "NOT 4g -> scale will be wrong");
    }
    /* ---- ③ ID 校验：接受兼容家族（who 已在①里读到，不必重读）----
     *   0x68 = MPU6050 / 0x70 = MPU6500 / 0x71 = MPU9250 / 0x73 = MPU9255
     *   这一家族的加速度/陀螺寄存器映射与本驱动完全兼容，可以放行。 */
    imu->ok = (who == 0x68 || who == 0x70 || who == 0x71 || who == 0x73) ? 1 : 0;

    /* ★2026-10-09 诊断增强：失败时把**真实的 WHO_AM_I 值**当错误码返回，
     *   这样 main.c 那句 "gimbal_imu_init failed (roll disabled): 0x%x" 会直接打印芯片身份：
     *     0x68            = MPU6050（正品，正常）
     *     0x70/0x71/0x73  = MPU6500 / MPU9250 / MPU9255（寄存器与本驱动兼容，可放行）
     *     0x98 / 0x72 …   = 克隆片（多数也兼容）
     *     0xffffffff      = 驱动超时返回的 -1 ⇒ **I2C 根本没通**（线/上拉/地址错）
     *     0xfffffffe      = 读回 0x00 ⇒ 总线被拉死 / SDA 短路到地
     *   拿到这个值就能一眼定位，不用瞎猜。 */
    if (imu->ok) {
        return AL_OK;
    }
    return (who != 0x00) ? (int32_t)who : -2;
}

/* ----------------------------------------------------------------------------
 * 采样 + 互补滤波
 * --------------------------------------------------------------------------*/
void gimbal_imu_update(gimbal_imu_t *imu)
{
    uint8_t  buf[14];
    int16_t  ax, ay, az, gx, gy, gz;
    int16_t  acc, gyr;
    int32_t  gyro_step, acc_ang, err, roll;
    int32_t  lim = GIMBAL_IMU_ROLL_LIMIT_DEG * 65536;   /* 融合角度软件限幅（非舵机命令限幅） */

    if (!imu->ok) {
        /* ★2026-10-11 掉线自恢复：线松动/干扰造成的偶发 I2C 失败，
         *   不必重启板子。每 125 拍（250Hz → 0.5 秒）试着重连一次。 */
        if (++imu->fail_cnt >= 125u) {
            imu->fail_cnt = 0;
            (void)gimbal_imu_recover(imu);
        }
        return;
    }

    /* 一次读 14 字节：AX AY AZ T GX GY GZ（0x3B 起） */
    if (mpu_read_regs(MPU6050_REG_ACCEL_XOUT_H, buf, 14) != AL_OK) {
        /* ★2026-10-21 自平衡优化：单次失败不立刻判掉线。
         *   连续 GIMBAL_IMU_FAIL_MAX 次失败才把 ok 清 0；main 里 roll_apply
         *   看到 ok=0 后会按 GIMBAL_IMU_FAIL_RAMP_US 缓慢回中位，而不是瞬跳。
         *   一次成功读恢复 fail_cnt，不影响正常标定/自稳。 */
        if (imu->fail_cnt < 255u) {
            imu->fail_cnt++;
        }
        if (imu->fail_cnt >= GIMBAL_IMU_FAIL_MAX) {
            imu->ok      = 0;
            imu->fail_cnt = 0;
        }
        return;
    }
    imu->fail_cnt = 0;    /* 读成功：清掉失败计数 */

    ax = (int16_t)((buf[0]  << 8) | buf[1]);
    ay = (int16_t)((buf[2]  << 8) | buf[3]);
    az = (int16_t)((buf[4]  << 8) | buf[5]);
    gx = (int16_t)((buf[8]  << 8) | buf[9]);
    gy = (int16_t)((buf[10] << 8) | buf[11]);
    gz = (int16_t)((buf[12] << 8) | buf[13]);

    /* 按参数选轴（哪根轴对应横滚，取决于 IMU 怎么贴） */
    acc = (GIMBAL_IMU_ACC_AXIS  == 0) ? ax : (GIMBAL_IMU_ACC_AXIS  == 1) ? ay : az;
    gyr = (GIMBAL_IMU_GYRO_AXIS == 0) ? gx : (GIMBAL_IMU_GYRO_AXIS == 1) ? gy : gz;
    if (GIMBAL_IMU_ACC_SIGN  < 0) acc = (int16_t)-acc;
    if (GIMBAL_IMU_GYRO_SIGN < 0) gyr = (int16_t)-gyr;

    /* 零偏标定：上电静止，累加陀螺求均；★顺便标定加速度计零点（2026-10-11） */
    if (!imu->calib_done) {
        /* ★2026-10-21 只在"静止"时积累标定样本。
         *   判据：本拍陀螺读数与已累计均值的偏差超过阈值（约 5°/s），
         *   说明平台还在动 ⇒ 清空重来，避免把运动中的姿态当零点。
         *   ±250°/s 量程下 131 LSB = 1°/s，故 650 ≈ 5°/s。 */
        {
            int32_t mean = (imu->calib_cnt != 0u)
                         ? (imu->bias_sum / (int32_t)imu->calib_cnt) : 0;
            int32_t dev  = gyr - mean;
            if (dev < 0) dev = -dev;
            if (imu->calib_cnt >= 8u && dev > 650) {
                imu->calib_cnt = 0u;
                imu->bias_sum  = 0;
                imu->acc_sum   = 0;
                imu->ay_sum    = 0;
                imu->az_sum    = 0;
            }
        }
        imu->bias_sum += gyr;
        imu->acc_sum  += acc;            /* 加速度零点：水平时应读到的值 */
        imu->ay_sum   += ay;             /* ★双轴零点（横滚 = 绕 X 轴，重力在 Y-Z 平面） */
        imu->az_sum   += az;
        imu->calib_cnt++;
        if (imu->calib_cnt >= GIMBAL_IMU_CAL_N) {
            imu->bias     = imu->bias_sum >> GIMBAL_IMU_CAL_SH;
            imu->acc_zero = imu->acc_sum  >> GIMBAL_IMU_CAL_SH;
            imu->ay0      = imu->ay_sum   >> GIMBAL_IMU_CAL_SH;
            imu->az0      = imu->az_sum   >> GIMBAL_IMU_CAL_SH;
            imu->calib_done = 1;
        }
        return;   /* 标定期不输出，roll 保持 0（中位） */
    }

    /* 陀螺积分（Q16 度） */
    gyro_step = (gyr - imu->bias) * GIMBAL_IMU_GYRO_K;

    /* ★2026-10-21 角速度（度/秒），给 roll 的 D 项做阻尼。
     *   gyro_step 是"每拍增量"（Q16 度/拍）⇒ 换算：step/65536 * SAMPLE_HZ。
     *   ±250°/s 量程下 131 LSB = 1°/s，故 (bias 校正后的 LSB)*131 对应 1°/s。 */
    imu->rate_dps = (gyro_step * (int32_t)GIMBAL_IMU_SAMPLE_HZ) >> 16;

    /* 加速度倾角（Q16 度，小角度近似；负号见文件头推导）
     * ★2026-10-11 减去上电标定得到的零点：本模块加速度计有约 0.3g 固定偏移，
     *   不减掉的话"水平时 ay 也不是 0"，自稳会永远往一边偏。
     *   减零点等价于"把上电时的姿态定义为水平"。 */
    /* ★2026-10-21 退回【单轴】写法（这是 10-11 上板验收过的版本）。
     *   为什么退：双轴 atan2 版本在实机上把 roll 直接顶到 −40° 饱和，
     *   而单轴版本此前能达到"静止静默、误差<1°"。改进应在链路稳定后再做。 */
    /* ===== 2026-10-21 回退：恢复 10-14 那套验证过的单轴倾角 =====
     *   这几天在 roll 上试过 P/I 系数、D 项、双轴 atan2、向量夹角、目标偏移，
     *   都未能稳定，故整体回退到交接工程里上板验收过的版本。
     *   保留的只有与自稳算法无关的工程性修复：
     *     · 上电等 1.5s 再标定 + 静止判据（避免抓到运动中的姿态）
     *     · 坐标 I2C 读超时 50ms→5ms、重试 3→2（避免卡住 250Hz 环） */
    acc_ang = -((acc - imu->acc_zero) * GIMBAL_IMU_ACC_K);

    /* 互补修正：roll += gyro − (roll − acc) >> COMP_SH */
    err  = imu->roll_q16 - acc_ang;
    roll = imu->roll_q16 + gyro_step - (err >> GIMBAL_IMU_COMP_SH);

    /* 限幅到配置的融合角度软件限幅（不是舵机命令限幅） */
    if (roll < -lim) roll = -lim;
    if (roll >  lim) roll =  lim;

    imu->roll_q16 = roll;
    imu->roll_deg = ((GIMBAL_IMU_OUT_SIGN >= 0) ? roll : -roll) >> 16;
}

/* ----------------------------------------------------------------------------
 * ★2026-10-11 诊断：读一次六轴原始值（不参与滤波），供"定轴 / 定符号"实测用。
 *   为什么要它：GIMBAL_IMU_GYRO_AXIS / ACC_AXIS / *_SIGN 到底该填什么，
 *   取决于 MPU 模块在云台上怎么贴——**只能靠实测**。做法：
 *     1) 把云台绕"横滚轴"（摄像头光轴）慢慢转，看 gx/gy/gz 里哪个变化最大
 *        ⇒ 那个就是 GIMBAL_IMU_GYRO_AXIS（0=gx 1=gy 2=gz）；
 *     2) 静止时看 ax/ay/az 哪个受重力影响最明显（绕横滚轴倾斜时变化最大）
 *        ⇒ 那个就是 GIMBAL_IMU_ACC_AXIS；
 *     3) 转的方向决定 *_SIGN 填 +1 还是 -1。
 *   返回 0 成功、-1 失败（I2C 没通或未初始化）。
 * --------------------------------------------------------------------------*/
int32_t gimbal_imu_read_raw(int16_t *ax, int16_t *ay, int16_t *az,
                            int16_t *gx, int16_t *gy, int16_t *gz)
{
    uint8_t buf[14];

    if (s_i2c == 0) {
        return -1;
    }
    if (mpu_read_regs(MPU6050_REG_ACCEL_XOUT_H, buf, 14) != AL_OK) {
        return -1;
    }

    *ax = (int16_t)((buf[0]  << 8) | buf[1]);
    *ay = (int16_t)((buf[2]  << 8) | buf[3]);
    *az = (int16_t)((buf[4]  << 8) | buf[5]);
    *gx = (int16_t)((buf[8]  << 8) | buf[9]);
    *gy = (int16_t)((buf[10] << 8) | buf[11]);
    *gz = (int16_t)((buf[12] << 8) | buf[13]);
    return 0;
}

/* ----------------------------------------------------------------------------
 * ★2026-10-11 掉线自恢复
 *   背景：跨关节的 I2C 线在云台运动时容易接触不良。原代码一旦读失败就把 ok 清 0
 *   且永不恢复 ⇒ 必须重启板子。本函数让固件每 0.5s 自己试着重连一次。
 *   策略：只重连 I2C + 确认 WHO_AM_I，**不重做 bias/acc_zero 标定**
 *   （掉线时的姿态未知，重标会污染零点）；同时把角度清零让舵机先回中位。
 * --------------------------------------------------------------------------*/
int32_t gimbal_imu_recover(gimbal_imu_t *imu)
{
    AL_I2C_InitStruct cfg = {
        .WorkMode = AL_I2C_CPU_MODE,
        .RoleMode = AL_I2C_MASTER_MODE,
        .ClkSpeed = AL_I2C_STANDARD_MODE,
        .SclDuty  = AL_I2C_SCL_DUTY_50,
        .SclPull  = AL_TRUE,
        .SdaPull  = AL_TRUE,
    };
    uint8_t who = 0;

    AlMisc_ll_SetClkEn(AL_MISC_I2C, 1);
    AlMisc_ll_SetReset(AL_MISC_I2C, 0);
    AlMisc_ll_SetReset(AL_MISC_I2C, 1);

    if (AlI2c_Hal_Init(&s_i2c, 0, &cfg, AL_NULL) != AL_OK) {
        return -1;
    }

    /* 重新探测器件地址（0x68 / 0x69） */
    s_addr = GIMBAL_IMU_ADDR;
    if (mpu_read_regs(MPU6050_REG_WHO_AM_I, &who, 1) != AL_OK) {
        s_addr = (uint8_t)(GIMBAL_IMU_ADDR + 1u);
        if (mpu_read_regs(MPU6050_REG_WHO_AM_I, &who, 1) != AL_OK) {
            return -1;              /* 还是不通，等下一次再试 */
        }
    }

    /* 通了：保留原 bias / acc_zero，只把角度与积分清零让舵机先回中位 */
    imu->roll_q16 = 0;
    imu->roll_deg = 0;
    imu->roll_int = 0;
    imu->fail_cnt = 0;
    imu->ok       = 1;
    (void)who;
    return 0;
}

/*------------------------------------------------------------------------------
 * ★2026-10-22 总线写（写从机 ROI 寄存器用）：先发寄存器地址，再发数据，中间 RESTART。
 *----------------------------------------------------------------------------*/
int32_t gimbal_imu_bus_write(uint8_t addr7, uint8_t reg, const uint8_t *src, uint32_t n)
{
    int32_t ret;

    if (s_i2c == 0 || src == 0 || n == 0u) {
        return -1;
    }
    ret = AlI2c_Hal_MasterSendDataPolling(s_i2c, addr7, &reg, 1,
                                          AL_I2C_START, AL_I2C_NOSTOP, BUS_TIMEOUT_COORD_MS);
    if (ret != AL_OK) {
        return ret;
    }
    return AlI2c_Hal_MasterSendDataPolling(s_i2c, addr7, (uint8_t *)src, n,
                                           AL_I2C_RESTART, AL_I2C_STOP, BUS_TIMEOUT_COORD_MS);
}

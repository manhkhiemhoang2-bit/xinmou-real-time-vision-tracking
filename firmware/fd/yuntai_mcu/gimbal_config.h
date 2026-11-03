/*
 * gimbal_config.h —— 云台舵机控制 · 全部可调参数集中地
 */

#ifndef GIMBAL_CONFIG_H
#define GIMBAL_CONFIG_H

#include <stdint.h>

#define GIMBAL_TIMER_CLK_HZ    100000000u

#define GIMBAL_PWM_FREQ_HZ     50u
#define GIMBAL_PWM_PERIOD_US   20000u
#define GIMBAL_PWM_TICK_US     4u

#define GIMBAL_PWM_TICK_COUNTS   (GIMBAL_TIMER_CLK_HZ / 1000000u * GIMBAL_PWM_TICK_US)
#define GIMBAL_PWM_PERIOD_TICKS  (GIMBAL_PWM_PERIOD_US / GIMBAL_PWM_TICK_US)

#define GIMBAL_SERVO_MIN_US    1000u
#define GIMBAL_SERVO_MID_US    1500u
#define GIMBAL_SERVO_MAX_US    2000u
#define GIMBAL_SERVO_SPAN_DEG  180

#define GIMBAL_SERVO_DEADBAND_US     12u
#define GIMBAL_TRK_SERVO_DEADBAND_US 0u

#define GIMBAL_TRIM_US_YAW      0
#define GIMBAL_TRIM_US_PITCH    0
#define GIMBAL_TRIM_US_ROLL     0

#define GIMBAL_HOME_DEG_YAW     0
#define GIMBAL_HOME_DEG_PITCH   0
#define GIMBAL_HOME_DEG_ROLL    0
#define GIMBAL_HOME_STEP_US     12u

#define GIMBAL_NUM_CH    3
#define GIMBAL_CH_YAW    0
#define GIMBAL_CH_PITCH  1
#define GIMBAL_CH_ROLL   2

#define GIMBAL_GPIO_YAW    0
#define GIMBAL_GPIO_PITCH  1
#define GIMBAL_GPIO_ROLL   2

/* ============================================================================
 * 4. 追踪控制律（yaw/pitch 视觉伺服 · 防过冲 Smith 预测 + 软死区 + 接近制动版）
 * ----------------------------------------------------------------------------
 *   解决"舵机牵引摄像头摆过头（过冲/来回摆）"的四大核心措施：
 *     1) Q8 亚度级定点角度控制（1° = 256，分辨率 0.004°），直接换算微秒脉宽，
 *        消除整数度截断造成的阶梯跳变；
 *     2) 二拍在途运动补偿（Smith Predictor，GIMBAL_PX_PER_DEG = 22）：
 *        摄像头曝光 + FPGA 帧尾锁存存在约 2 帧视觉滞后，控制器自动从当前像素误差中
 *        扣除前 2 拍已发出但尚未反映到画面的舵机位移，彻底杜绝滞后期间重复累加导致摆过头；
 *     3) 连续软死区（GIMBAL_DEADZONE_PX = 42）：误差在 ±42px 内锁死不动，超出死区时
 *        按 (|ex| - DEADZONE) 连续起步，消除死区边界阶跃冲击；
 *     4) 单向接近制动阻尼（GIMBAL_TRK_D_TICKS = 2）：当目标向画面中心靠近时施加
 *        2 倍微分制动，提前减速停稳，实现零过冲锁定。
 * ==========================================================================*/
#define GIMBAL_IMG_W              1280
#define GIMBAL_IMG_H              720
#define GIMBAL_DEADZONE_ENTER_PX  42      /* 进入锁定区：到这里立即停住 */
#define GIMBAL_DEADZONE_EXIT_PX   58      /* 退出锁定区：必须明显偏离后才重新启动 */
#define GIMBAL_DEADZONE_PX        GIMBAL_DEADZONE_ENTER_PX
#define GIMBAL_TARGET_LOST_FRAMES 15u     /* 20Hz 下连续约 0.75s 丢目标后回中 */
#define GIMBAL_KP_DEG_PER_1000PX  20      /* 比例增益：20° / 1000px */
#define GIMBAL_SLEW_MAX_DEG       1       /* 兼容旧宏：整数度单步上限 */
#define GIMBAL_SLEW_MAX_Q8        320     /* Q8 定点单步上限：320/256 = 1.25°/帧 */
#define GIMBAL_PX_PER_DEG         22      /* 摄像头每转 1° 对应的画面像素位移（用于二拍在途补偿） */

#define GIMBAL_TRK_D_TICKS        2       /* 接近中心时的制动超前拍数 */
#define GIMBAL_TRK_D_EMA_SH       1       /* 误差微分低通移位 */

#define GIMBAL_TRK_JUMP_PX        240     /* 单帧异常跳变门限 */
#define GIMBAL_TRK_JUMP_N         3       /* 连续跳变确认帧数 */
#define GIMBAL_TRK_SMOOTH_SH      0       /* ★设为 0：取消额外 IIR 滞后，避免相位滞后引发舵机过冲 */

#define GIMBAL_SIGN_YAW     1
#define GIMBAL_SIGN_PITCH   1

#define GIMBAL_YAW_MIN_DEG    (-85)
#define GIMBAL_YAW_MAX_DEG    ( 85)
#define GIMBAL_PITCH_MIN_DEG  (-85)
#define GIMBAL_PITCH_MAX_DEG  ( 85)
#define GIMBAL_ROLL_DEG       0

/* ============================================================================
 * 6. MPU6050 六轴 IMU（roll 横滚自稳）
 * ==========================================================================*/
#define GIMBAL_IMU_ADDR               0x68u
#define GIMBAL_IMU_SAMPLE_HZ          250u
#define GIMBAL_IMU_GYRO_K             2
#define GIMBAL_IMU_ACC_K              262
#define GIMBAL_IMU_COMP_SH            6

#define GIMBAL_IMU_P_GAIN             0
#define GIMBAL_IMU_INT_KI             2
#define GIMBAL_IMU_D_GAIN_Q8          0
#define GIMBAL_IMU_ROLL_TARGET_MDEG   0
#define GIMBAL_IMU_QUIET_DEG          1
#define GIMBAL_IMU_INT_LEAK_SH        30
#define GIMBAL_IMU_ROLL_CMD_LIMIT_DEG 23

#define GIMBAL_IMU_FAIL_MAX           5u
#define GIMBAL_IMU_FAIL_RAMP_US       8

#define GIMBAL_SWEEP_DEG              12
#define GIMBAL_IMU_CAL_N              256
#define GIMBAL_IMU_CAL_SH             8
#define GIMBAL_IMU_ROLL_LIMIT_DEG     40
#define GIMBAL_IMU_PULSE_PER_DEG      22

#define GIMBAL_IMU_GYRO_AXIS          0
#define GIMBAL_IMU_ACC_AXIS           1
#define GIMBAL_IMU_GYRO_SIGN          1
#define GIMBAL_IMU_ACC_SIGN           1
#define GIMBAL_IMU_OUT_SIGN           1

/* ============================================================================
 * 7. 运行模式
 * ==========================================================================*/
#define GIMBAL_MODE_TRACKING  0
#define GIMBAL_MODE_SWEEP     1
#define GIMBAL_MODE_MID       2
#define GIMBAL_MODE_HOME      3
#define GIMBAL_MODE_CALIB     4
#define GIMBAL_MODE_IMUDBG    5
#define GIMBAL_MODE_ROLLTEST  6
#define GIMBAL_MODE_SYMTEST   7

#define GIMBAL_MODE           GIMBAL_MODE_TRACKING

#endif /* GIMBAL_CONFIG_H */

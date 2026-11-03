/*
 * main.c —— PH1P35 MCU 三轴云台舵机控制 · 入口
 *
 * 本次改进要点：
 *   1. 修复 M5 红色档下 B4 引脚（SW2 拨码开关，coord.track_en）追踪使能开关不生效的问题：
 *      原代码因 GIMBAL_USE_ROI=0 导致 status_supported 恒为 0，`if (status_supported && !coord.track_en)`
 *      沦为死代码；现直接检测 `if (!coord.track_en) trk_ok = 0;`，拨动 B4 开关即可实时开启/关闭追踪。
 *   2. 配合 gimbal_tracking.c 的二拍在途 Smith 预测器 + Q8 亚度级控制，使用
 *      gimbal_servo_set_q8_deg() 直接输出高精度脉宽，并去除多余的坐标 IIR 滞后，彻底解决舵机摆过头。
 */

#include <stdio.h>
#include <stdint.h>

#include "gimbal_config.h"
#include "gimbal_servo.h"
#include "gimbal_tracking.h"
#include "gimbal_control.h"
#include "gimbal_imu.h"
#include "gimbal_coord.h"
#include "al_systimer.h"

#define GIMBAL_MIN_W        20      /* 目标最小宽（像素） */
#define GIMBAL_MIN_H        16      /* 目标最小高 */
#define GIMBAL_MIN_PIX      24      /* 命中像素数下限 */
#define GIMBAL_MAX_W        960     /* 目标最大宽 */
#define GIMBAL_MAX_H        680
#define GIMBAL_USE_ROI      0
#define GIMBAL_ROI_DX       240
#define GIMBAL_ROI_DY       180
#define GIMBAL_ROI_EVERY    10u
#define GIMBAL_ROI_LOST_MAX 20u

static void roll_apply(gimbal_imu_t *imu, int vision_axes_moving)
{
    static int32_t s_last_pulse = (int32_t)GIMBAL_SERVO_MID_US;

    const int32_t mid = (int32_t)GIMBAL_SERVO_MID_US;
    const int32_t cmd_lim_q8 = (int32_t)GIMBAL_IMU_ROLL_CMD_LIMIT_DEG << 8;
    int32_t pulse;
    int32_t p_term_q8 = 0;
    int32_t delta_q8  = 0;

    if (imu->ok && imu->calib_done) {
        /* yaw/pitch 正在转动时冻结 roll 积分，避免运动加速度被误当成横滚。 */
        if (!vision_axes_moving &&
            (imu->roll_deg > GIMBAL_IMU_QUIET_DEG ||
             imu->roll_deg < -GIMBAL_IMU_QUIET_DEG)) {
            int32_t inc;

            p_term_q8 = (-(imu->roll_deg) * GIMBAL_IMU_P_GAIN) * 256;
            inc = -(imu->roll_deg) * GIMBAL_IMU_INT_KI;

            if (!((imu->roll_int >=  cmd_lim_q8 && inc > 0) ||
                  (imu->roll_int <= -cmd_lim_q8 && inc < 0))) {
                imu->roll_int += inc;
            }
        } else {
            p_term_q8 = 0;
        }

        if (imu->roll_int >  cmd_lim_q8) imu->roll_int =  cmd_lim_q8;
        if (imu->roll_int < -cmd_lim_q8) imu->roll_int = -cmd_lim_q8;

        delta_q8 = p_term_q8 + imu->roll_int;
        if (delta_q8 >  cmd_lim_q8) delta_q8 =  cmd_lim_q8;
        if (delta_q8 < -cmd_lim_q8) delta_q8 = -cmd_lim_q8;

        pulse = mid + (delta_q8 * (int32_t)GIMBAL_IMU_PULSE_PER_DEG) / 256;

        if (pulse > (int32_t)GIMBAL_SERVO_MAX_US) {
            pulse = (int32_t)GIMBAL_SERVO_MAX_US;
            imu->roll_int = (pulse - mid) * 256 / (int32_t)GIMBAL_IMU_PULSE_PER_DEG
                          - p_term_q8;
        } else if (pulse < (int32_t)GIMBAL_SERVO_MIN_US) {
            pulse = (int32_t)GIMBAL_SERVO_MIN_US;
            imu->roll_int = (pulse - mid) * 256 / (int32_t)GIMBAL_IMU_PULSE_PER_DEG
                          - p_term_q8;
        }
        if (imu->roll_int >  cmd_lim_q8) imu->roll_int =  cmd_lim_q8;
        if (imu->roll_int < -cmd_lim_q8) imu->roll_int = -cmd_lim_q8;
    } else {
        imu->roll_int = 0;
        if (s_last_pulse > mid + (int32_t)GIMBAL_IMU_FAIL_RAMP_US) {
            pulse = s_last_pulse - (int32_t)GIMBAL_IMU_FAIL_RAMP_US;
        } else if (s_last_pulse < mid - (int32_t)GIMBAL_IMU_FAIL_RAMP_US) {
            pulse = s_last_pulse + (int32_t)GIMBAL_IMU_FAIL_RAMP_US;
        } else {
            pulse = mid;
        }
    }

    if (pulse > (int32_t)GIMBAL_SERVO_MAX_US) pulse = (int32_t)GIMBAL_SERVO_MAX_US;
    if (pulse < (int32_t)GIMBAL_SERVO_MIN_US) pulse = (int32_t)GIMBAL_SERVO_MIN_US;

    s_last_pulse = pulse;
    gimbal_servo_set_us(GIMBAL_CH_ROLL, (uint32_t)pulse);
}

static int32_t sweep_angle(uint32_t *phase)
{
    static const int16_t sine[32] = {
        0,    18,   35,   52,   68,   82,   93,   101,
        106,  108,  107,  103,  96,   87,   75,   61,
        45,   28,   11,   -7,   -24,  -41,  -57,  -71,
        -83,  -92,  -98,  -102, -104, -103, -99,  -92,
    };
    int32_t idx = (*phase >> 3) & 31;
    *phase += 1;
    return (int32_t)sine[idx];
}

int main(void)
{
    int32_t ret;
    uint32_t tick = 0;
    uint32_t dbg  = 0;

    printf("PH1P35 gimbal servo control start (mode=%d)\r\n", GIMBAL_MODE);

    ret = gimbal_servo_init();
    if (ret != 0) {
        printf("gimbal_servo_init failed: 0x%x\r\n", (unsigned)ret);
        while (1) { }
    }

    printf("servo passive pin probe = 0x%x  (no forced pulse)\r\n",
           (unsigned)gimbal_servo_pin_probe());
    printf("servo pulse_ticks = %u/%u/%u (expect 375 each)\r\n",
           (unsigned)gimbal_servo_get_pulse_ticks(0),
           (unsigned)gimbal_servo_get_pulse_ticks(1),
           (unsigned)gimbal_servo_get_pulse_ticks(2));
    printf("servo pwm samples = %u / 18000 (expect ~1350)\r\n",
           (unsigned)gimbal_servo_pwm_probe());

    gimbal_servo_home();
    printf("gimbal -> home attitude (HOME_DEG = %d/%d/%d deg)\r\n",
           (int)GIMBAL_HOME_DEG_YAW, (int)GIMBAL_HOME_DEG_PITCH, (int)GIMBAL_HOME_DEG_ROLL);
    gimbal_servo_print_state();

    printf("settling... (wait for platform to stop before gyro calibration)\r\n");
    AlSys_MDelay(1500u);

    gimbal_tracker_t trk;
    gimbal_tracker_init(&trk);

    gimbal_imu_t imu;
    ret = gimbal_imu_init(&imu);
    if (ret != 0) {
        printf("gimbal_imu_init failed (roll disabled): 0x%x\r\n", (unsigned)ret);
    } else {
        printf("MPU6050 ok, calibrating gyro bias... keep gimbal STILL!\r\n");
    }

#if GIMBAL_MODE == GIMBAL_MODE_TRACKING
    gimbal_coord_t coord;
    uint32_t coord_ok      = 0;
    uint32_t coord_hb      = 0;
    uint32_t coord_err_cnt = 0;
    uint32_t track_mode_requested = 0;
    int32_t  last_cx = 0, last_cy = 0;
    int32_t  last_valid = 0, last_mode = -1;

    int32_t  flt_cx = 640, flt_cy = 360;
    uint32_t flt_init = 0;
    uint32_t dbg_tick = 0u;
    uint32_t flt_rej  = 0;
    uint32_t last_target_frame = 0xFFFFFFFFu;
    gimbal_control_t control;

    coord.cx = 0; coord.cy = 0; coord.frame = 0; coord.valid = 0; coord.mode = 0;
    coord.track_en = 1; coord.auto_mode = 0;
    gimbal_control_init(&control);

    printf("tracking mode: FPGA detect -> I2C slave 0x50 -> MCU Smith-PD control\r\n");
    printf("tracking: yaw/pitch 20Hz vision loop (M5 + B4 switch enabled), roll 250Hz IMU level\r\n");

    ret = gimbal_coord_init();
    if (ret == GIMBAL_COORD_OK) {
        coord_ok = 1;
        printf("coord ok (version 0x5A handshake)\r\n");
    } else {
        printf("coord init failed: %d (expect 0x5A from slave 0x50), retry 1Hz\r\n",
               (int)ret);
        {
            uint8_t  dump[16];
            uint32_t i;
            if (gimbal_coord_probe(dump, 16u) == GIMBAL_COORD_OK) {
                printf("coord probe 0x00..0x0F:");
                for (i = 0u; i < 16u; i++) {
                    printf(" %02X", (unsigned)dump[i]);
                }
                printf("\r\n");
            } else {
                printf("coord probe: bus error (no ACK from 0x50)\r\n");
            }
        }
        printf("coord addr scan: 0x50=%d 0x51=%d 0x68=%d (0 = HAL says OK)\r\n",
               (int)gimbal_coord_probe_addr(0x50u, 0x0Fu),
               (int)gimbal_coord_probe_addr(0x51u, 0x0Fu),
               (int)gimbal_coord_probe_addr(0x68u, 0x75u));
    }

    while (1) {
        /* ① 250Hz：先更新 IMU；标定、追踪和回中由同一个状态机分配三轴控制权。 */
        gimbal_imu_update(&imu);
        gimbal_control_update(&control,
                              imu.calib_done,
                              (int)track_mode_requested,
                              (int)gimbal_servo_at_home());

        if (gimbal_control_take_reset_history(&control)) {
            gimbal_tracker_init(&trk);
            flt_init = 0;
            flt_rej = 0;
            imu.roll_int = 0;
        }

        if (gimbal_control_force_home(&control)) {
            imu.roll_int = 0;
            gimbal_servo_step_home(GIMBAL_HOME_STEP_US);
        } else if (last_valid) {
            roll_apply(&imu, gimbal_tracker_is_moving(&trk));
        }

        /* ② 20Hz：读坐标 → 喂 tracker → yaw/pitch 舵机 */
        if (++tick >= 5) {
            tick = 0;

            if (!coord_ok) {
                track_mode_requested = 0;
                gimbal_tracker_drop(&trk);
                flt_init = 0;
                flt_rej  = 0;
                if (++coord_hb >= 50) {
                    coord_hb = 0;
                    if (gimbal_coord_init() == GIMBAL_COORD_OK) {
                        coord_ok = 1;
                        coord_err_cnt = 0;
                        printf("coord ok (version 0x5A handshake)\r\n");
                    }
                }
            } else {
                ret = gimbal_coord_read(&coord);
                if (ret == GIMBAL_COORD_OK) {
                    coord_err_cnt = 0;
                    last_cx    = coord.cx;
                    last_cy    = coord.cy;
                    last_valid = (int32_t)coord.valid;
                    last_mode  = (int32_t)coord.mode;

                    int32_t has_quality = (coord.w != 0) || (coord.h != 0) || (coord.pix_cnt != 0);
                    int32_t quality_ok  = (!has_quality)
                                  || ((coord.w >= GIMBAL_MIN_W) && (coord.h >= GIMBAL_MIN_H)
                                   && (coord.pix_cnt >= GIMBAL_MIN_PIX)
                                   && (coord.w <= GIMBAL_MAX_W) && (coord.h <= GIMBAL_MAX_H));
                    int32_t trk_ok;

                    /*
                     * 退出追踪只改变云台状态，不写 FPGA 画面档位：
                     * B4 关闭、AUTO 开启、离开 M5（包括 M6）都会进入统一三轴缓回中。
                     */
                    track_mode_requested = (uint32_t)gimbal_control_tracking_requested(
                        coord.mode, coord.auto_mode, coord.track_en);
                    gimbal_control_update(&control,
                                          imu.calib_done,
                                          (int)track_mode_requested,
                                          (int)gimbal_servo_at_home());
                    if (gimbal_control_take_reset_history(&control)) {
                        gimbal_tracker_init(&trk);
                        flt_init = 0;
                        flt_rej = 0;
                        imu.roll_int = 0;
                    }
                    if (gimbal_control_force_home(&control)) {
                        gimbal_servo_step_home(GIMBAL_HOME_STEP_US);
                    }

                    if (coord.frame != last_target_frame) {
                        last_target_frame = coord.frame;
                        gimbal_control_note_target(&control,
                                                   coord.valid && quality_ok,
                                                   GIMBAL_TARGET_LOST_FRAMES);
                    }

                    trk_ok = gimbal_control_allow_tracking(&control)
                          && coord.valid && quality_ok;

                    if (trk_ok) {
                        int32_t dx, dy, adx, ady;

                        dx = coord.cx - flt_cx;
                        dy = coord.cy - flt_cy;
                        adx = (dx < 0) ? -dx : dx;
                        ady = (dy < 0) ? -dy : dy;

                        if (!flt_init) {
                            flt_cx = coord.cx; flt_cy = coord.cy;
                            flt_init = 1;      flt_rej = 0;
                        } else if (adx > GIMBAL_TRK_JUMP_PX || ady > GIMBAL_TRK_JUMP_PX) {
                            if (++flt_rej >= GIMBAL_TRK_JUMP_N) {
                                flt_cx = coord.cx; flt_cy = coord.cy;
                                flt_rej = 0;
                            }
                        } else {
                            flt_rej = 0;
#if GIMBAL_TRK_SMOOTH_SH > 0
                            flt_cx += (coord.cx - flt_cx) >> GIMBAL_TRK_SMOOTH_SH;
                            flt_cy += (coord.cy - flt_cy) >> GIMBAL_TRK_SMOOTH_SH;
#else
                            flt_cx = coord.cx;
                            flt_cy = coord.cy;
#endif
                        }
                        gimbal_tracker_update(&trk, flt_cx, flt_cy, 1, coord.frame);
                    } else {
                        gimbal_tracker_drop(&trk);
                        flt_init = 0;
                        flt_rej  = 0;
                    }

                    if (gimbal_control_allow_tracking(&control)) {
                        gimbal_servo_set_q8_deg(GIMBAL_CH_YAW,   trk.yaw_q8);
                        gimbal_servo_set_q8_deg(GIMBAL_CH_PITCH, trk.pitch_q8);
                    }

                    if (++dbg_tick >= 20u) {
                        static uint32_t last_frm = 0;
                        static AL_U64   last_tk  = 0;
                        static uint8_t  frm_started = 0;
                        uint32_t dfrm = 0u, fps = 0u, tms = 0u;
                        AL_U64   now_tk, freq, dt;

                        now_tk = AlSys_GetTimerTickCount();
                        freq   = AlSys_GetTimerFreq();
                        dbg_tick = 0u;
                        if (frm_started && (freq != 0u)) {
                            dfrm = (coord.frame - last_frm) & 0xFFFFu;
                            dt = now_tk - last_tk;
                            if (dt != 0u) {
                                tms = (uint32_t)((dt * 1000u) / freq);
                                fps = (uint32_t)(((AL_U64)dfrm * freq) / dt);
                            }
                        }
                        last_frm    = coord.frame;
                        last_tk     = now_tk;
                        frm_started = 1u;
                        printf("m%u v%u b4=%u cx%ld cy%ld w%ld h%ld c%ld ok%d f%lu d%lu t%lu\r\n",
                               (unsigned)coord.mode, (unsigned)coord.valid,
                               (unsigned)coord.track_en,
                               (long)coord.cx, (long)coord.cy,
                               (long)coord.w, (long)coord.h, (long)coord.pix_cnt,
                               (int)trk_ok,
                               (unsigned long)(coord.frame & 0xFFFFu),
                               (unsigned long)fps,
                               (unsigned long)tms);
                    }
                } else {
                    gimbal_tracker_drop(&trk);
                    if (++coord_err_cnt >= 10) {
                        coord_err_cnt = 0;
                        coord_ok = 0;
                        track_mode_requested = 0;
                        printf("coord read failed: %d, re-handshake slave 0x50\r\n",
                               (int)ret);
                    }
                }
            }
        }

        /* ③ 5Hz 诊断打印 */
        if (++dbg >= 50) {
            dbg = 0;
            printf("dbg: ok=%d cal=%d roll=%4d deg pulse=%4u int=%d acc_z=%d cx=%4d cy=%4d valid=%d mode=%d\r\n",
                   (int)imu.ok, (int)imu.calib_done,
                   (int)imu.roll_deg,
                   (unsigned)gimbal_servo_get_us(GIMBAL_CH_ROLL),
                   (int)imu.roll_int, (int)imu.acc_zero,
                   (int)last_cx, (int)last_cy, (int)last_valid, (int)last_mode);
        }

        AlSys_MDelay(4);
    }

#elif GIMBAL_MODE == GIMBAL_MODE_SWEEP
    uint32_t phase = 0;
    printf("sweep mode: yaw/pitch scan + roll self-level\r\n");
    while (1) {
        int32_t a;
        gimbal_imu_update(&imu);
        roll_apply(&imu, 0);

        if (++tick >= 10) {
            a = sweep_angle(&phase) * GIMBAL_SWEEP_DEG / 108;
            if (a >  GIMBAL_SWEEP_DEG) a =  GIMBAL_SWEEP_DEG;
            if (a < -GIMBAL_SWEEP_DEG) a = -GIMBAL_SWEEP_DEG;
            gimbal_servo_set_deg(GIMBAL_CH_YAW,   a);
            gimbal_servo_set_deg(GIMBAL_CH_PITCH, -a);
            tick = 0;
        }
        AlSys_MDelay(4);
    }

#elif GIMBAL_MODE == GIMBAL_MODE_HOME
    printf("home mode: hold initial attitude, print state every 1s\r\n");
    while (1) {
        gimbal_servo_home();
        gimbal_servo_print_state();
        AlSys_MDelay(1000);
    }

#else
    printf("mid mode\r\n");
    gimbal_servo_center();
    while (1) { }
#endif
}

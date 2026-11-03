/*
 * gimbal_tracking.c —— yaw/pitch 视觉追踪闭环（二拍在途 Smith 预测 + 连续软死区 + 接近制动）
 *
 * 彻底解决"舵机牵引摄像头摆过头"（过冲与来回震荡）：
 *   1. 二拍在途运动补偿（Smith Predictor）：
 *      30fps 摄像头曝光 + FPGA 帧尾锁存造成当前读到的 (cx, cy) 反映的是约 1~2 帧前
 *      摄像头的朝向。若不扣除前两帧已发出的舵机步进（du_1, du_2），在摄像头已转到位后的
 *      滞后窗口内，控制器会继续往同一方向累加 2~3 步，导致必然摆过头。
 *      本模块用 ex_pred = ex - ((du_1 + du_2) * PX_PER_DEG / 256) 预测真实剩余误差，
 *      当在途步进已足够抵达目标中心时立即停止累加，且绝不反向倒车。
 *   2. 连续软死区：超出 DEADZONE_PX 后按 (|ex_pred| - DEADZONE_PX) 线性起步，
 *      消除死区边缘的阶跃跳变。
 *   3. 单向接近制动：仅在目标向画面中心靠近（ex 与 d_ex 异号）时施加微分阻尼，
 *      且限制阻尼绝不反向推舵机。
 *   4. Q8 亚度级输出（1° = 256）：配合 gimbal_servo_set_q8_deg 直接驱动微秒脉宽，平滑无阶梯。
 */

#include "gimbal_tracking.h"
#include "gimbal_config.h"

static int32_t clamp_i32(int32_t v, int32_t lo, int32_t hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

void gimbal_tracker_init(gimbal_tracker_t *t)
{
    t->yaw_deg       = GIMBAL_HOME_DEG_YAW;
    t->pitch_deg     = GIMBAL_HOME_DEG_PITCH;
    t->roll_deg      = GIMBAL_HOME_DEG_ROLL;
    t->yaw_q8        = GIMBAL_HOME_DEG_YAW * 256;
    t->pitch_q8      = GIMBAL_HOME_DEG_PITCH * 256;
    t->last_frame_id = 0;

    gimbal_tracker_drop(t);
}

void gimbal_tracker_drop(gimbal_tracker_t *t)
{
    t->last_ex    = 0;
    t->last_ey    = 0;
    t->d_ex_f     = 0;
    t->d_ey_f     = 0;
    t->du_yaw_1   = 0;
    t->du_yaw_2   = 0;
    t->du_pitch_1 = 0;
    t->du_pitch_2 = 0;
    t->have_last  = 0;
    t->yaw_locked = 0;
    t->pitch_locked = 0;
}

static int32_t compute_axis_step_q8(int32_t ex, int32_t d_ex,
                                    int32_t du_1, int32_t du_2,
                                    uint8_t *locked)
{
    int32_t inflight_px;
    int32_t ex_pred;
    int32_t ex_net;
    int32_t d_term;
    int32_t ex_eff;
    int32_t du_q8;

    /* 0. 中心锁定带滞回：进入阈值小、退出阈值大，避免边缘噪声反复启停。 */
    if (*locked != 0u) {
        if (ex >= -(int32_t)GIMBAL_DEADZONE_EXIT_PX
            && ex <= (int32_t)GIMBAL_DEADZONE_EXIT_PX) {
            return 0;
        }
        *locked = 0u;
    }
    if (ex >= -(int32_t)GIMBAL_DEADZONE_ENTER_PX
        && ex <= (int32_t)GIMBAL_DEADZONE_ENTER_PX) {
        *locked = 1u;
        return 0;
    }

    /* 1. 扣除前 2 帧已发出、尚在相机曝光/传输流水线中的舵机角位移对应的像素量 */
    inflight_px = ((du_1 + du_2) * (int32_t)GIMBAL_PX_PER_DEG) / 256;
    ex_pred     = ex - inflight_px;

    /* 在途补偿只做单向衰减，绝不让预测误差跨越 0 点导致反向倒车 */
    if ((ex > 0 && ex_pred <= 0) || (ex < 0 && ex_pred >= 0)) {
        return 0;
    }

    /* 2. 连续软死区：预测误差落在死区内（含边界）时停步；超出死区时减去死区阈值平滑起步 */
    if (ex_pred >= -(int32_t)GIMBAL_DEADZONE_PX && ex_pred <= (int32_t)GIMBAL_DEADZONE_PX) {
        return 0;
    } else if (ex_pred > (int32_t)GIMBAL_DEADZONE_PX) {
        ex_net = ex_pred - (int32_t)GIMBAL_DEADZONE_PX;
    } else {
        ex_net = ex_pred + (int32_t)GIMBAL_DEADZONE_PX;
    }

    /* 3. 单向接近制动：当目标正在向中心靠近（ex 与 d_ex 异号）时施加微分刹车 */
    if ((ex > 0 && d_ex < 0) || (ex < 0 && d_ex > 0)) {
        d_term = (int32_t)GIMBAL_TRK_D_TICKS * d_ex;
    } else {
        d_term = 0;
    }

    ex_eff = ex_net + d_term;

    /* 严格保证输出步进方向与原始误差 ex 同向，绝不因微分刹车反向倒车 */
    if ((ex > 0 && ex_eff <= 0) || (ex < 0 && ex_eff >= 0)) {
        return 0;
    }

    /* 4. 换算为 Q8 角度步进并做单步速率限幅 */
    du_q8 = (ex_eff * (int32_t)GIMBAL_KP_DEG_PER_1000PX * 256) / 1000;
    du_q8 = clamp_i32(du_q8, -(int32_t)GIMBAL_SLEW_MAX_Q8, (int32_t)GIMBAL_SLEW_MAX_Q8);
    return du_q8;
}

void gimbal_tracker_update(gimbal_tracker_t *t,
                           int32_t cx, int32_t cy, int valid, uint32_t frame_id)
{
    int32_t ex, ey;
    int32_t d_ex, d_ey;
    int32_t dyaw_q8, dpitch_q8;

    if (!valid) {
        gimbal_tracker_drop(t);
        return;
    }

    /* 帧号去重：同一帧只处理一次 */
    if (frame_id == t->last_frame_id) {
        return;
    }
    t->last_frame_id = frame_id;

    ex = cx - (int32_t)(GIMBAL_IMG_W / 2);
    ey = cy - (int32_t)(GIMBAL_IMG_H / 2);

    if (!t->have_last) {
        d_ex         = 0;
        d_ey         = 0;
        t->last_ex   = ex;
        t->last_ey   = ey;
        t->d_ex_f    = 0;
        t->d_ey_f    = 0;
        t->have_last = 1;
    } else {
        d_ex       = ex - t->last_ex;
        d_ey       = ey - t->last_ey;
        t->last_ex = ex;
        t->last_ey = ey;
        t->d_ex_f  = d_ex;
        t->d_ey_f  = d_ey;
    }

    dyaw_q8   = compute_axis_step_q8(ex, d_ex, t->du_yaw_1,   t->du_yaw_2,
                                     &t->yaw_locked);
    dpitch_q8 = compute_axis_step_q8(ey, d_ey, t->du_pitch_1, t->du_pitch_2,
                                     &t->pitch_locked);

    /* 方向叠加与行程限幅（Q8 定点） */
    {
        int32_t old_yaw_q8 = t->yaw_q8;
        int32_t old_pitch_q8 = t->pitch_q8;

        t->yaw_q8 = clamp_i32(old_yaw_q8 - (int32_t)GIMBAL_SIGN_YAW * dyaw_q8,
                              (int32_t)GIMBAL_YAW_MIN_DEG * 256,
                              (int32_t)GIMBAL_YAW_MAX_DEG * 256);
        t->pitch_q8 = clamp_i32(old_pitch_q8 - (int32_t)GIMBAL_SIGN_PITCH * dpitch_q8,
                                (int32_t)GIMBAL_PITCH_MIN_DEG * 256,
                                (int32_t)GIMBAL_PITCH_MAX_DEG * 256);

        /* Smith 队列只记录舵机实际走出的量，限位处不再虚构“在途运动”。 */
        dyaw_q8 = (old_yaw_q8 - t->yaw_q8) * (int32_t)GIMBAL_SIGN_YAW;
        dpitch_q8 = (old_pitch_q8 - t->pitch_q8) * (int32_t)GIMBAL_SIGN_PITCH;
    }

    /* 推进二拍在途队列 */
    t->du_yaw_2   = t->du_yaw_1;
    t->du_yaw_1   = dyaw_q8;
    t->du_pitch_2 = t->du_pitch_1;
    t->du_pitch_1 = dpitch_q8;

    t->yaw_deg   = t->yaw_q8 / 256;
    t->pitch_deg = t->pitch_q8 / 256;
    t->roll_deg  = GIMBAL_ROLL_DEG;
}

int gimbal_tracker_is_moving(const gimbal_tracker_t *t)
{
    return t->du_yaw_1 != 0 || t->du_pitch_1 != 0;
}

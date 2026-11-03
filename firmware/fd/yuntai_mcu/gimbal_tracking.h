/*
 * gimbal_tracking.h —— yaw/pitch 视觉追踪闭环接口（Q8 亚度级 + 二拍在途 Smith 预测防过冲）
 */

#ifndef GIMBAL_TRACKING_H
#define GIMBAL_TRACKING_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t  yaw_deg;        /* 当前 yaw 机械角度（整度，供状态打印） */
    int32_t  pitch_deg;      /* 当前 pitch 机械角度（整度，供状态打印） */
    int32_t  roll_deg;       /* roll 中位 */
    int32_t  yaw_q8;         /* ★当前 yaw 角度（Q8 定点：256 = 1°） */
    int32_t  pitch_q8;       /* ★当前 pitch 角度（Q8 定点：256 = 1°） */
    uint32_t last_frame_id;  /* 上次已处理的帧号，用于去重 */

    /* ★二拍在途位移补偿（Smith Predictor）+ 接近制动状态 */
    int32_t  last_ex;        /* 上一帧原始像素误差 x */
    int32_t  last_ey;        /* 上一帧原始像素误差 y */
    int32_t  d_ex_f;         /* 误差变化量 x */
    int32_t  d_ey_f;         /* 误差变化量 y */
    int32_t  du_yaw_1;       /* 前第 1 帧发出的 yaw 步进（Q8 度，尚在相机曝光滞后中） */
    int32_t  du_yaw_2;       /* 前第 2 帧发出的 yaw 步进（Q8 度） */
    int32_t  du_pitch_1;     /* 前第 1 帧发出的 pitch 步进（Q8 度） */
    int32_t  du_pitch_2;     /* 前第 2 帧发出的 pitch 步进（Q8 度） */
    uint8_t  have_last;      /* 是否已有一帧有效历史 */
    uint8_t  yaw_locked;     /* 带滞回的中心锁定，抑制死区边缘来回启停 */
    uint8_t  pitch_locked;
} gimbal_tracker_t;

void gimbal_tracker_init(gimbal_tracker_t *t);
void gimbal_tracker_drop(gimbal_tracker_t *t);
void gimbal_tracker_update(gimbal_tracker_t *t,
                           int32_t cx, int32_t cy, int valid, uint32_t frame_id);
int gimbal_tracker_is_moving(const gimbal_tracker_t *t);

#ifdef __cplusplus
}
#endif

#endif /* GIMBAL_TRACKING_H */

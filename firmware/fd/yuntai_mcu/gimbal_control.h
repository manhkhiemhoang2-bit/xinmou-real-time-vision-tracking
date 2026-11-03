#ifndef GIMBAL_CONTROL_H
#define GIMBAL_CONTROL_H

#include <stdint.h>

typedef enum {
    GIMBAL_CTL_CALIBRATING = 0,
    GIMBAL_CTL_HOME_IDLE,
    GIMBAL_CTL_TRACKING,
    GIMBAL_CTL_RETURN_HOME,
    GIMBAL_CTL_WAIT_TARGET
} gimbal_control_state_t;

typedef struct {
    gimbal_control_state_t state;
    uint8_t reset_history_pending;
    uint16_t target_lost_frames;
    uint8_t target_good_frames;
} gimbal_control_t;

void gimbal_control_init(gimbal_control_t *ctl);
void gimbal_control_update(gimbal_control_t *ctl,
                           int calibration_done,
                           int tracking_mode_requested,
                           int home_reached);
gimbal_control_state_t gimbal_control_state(const gimbal_control_t *ctl);
int gimbal_control_force_home(const gimbal_control_t *ctl);
int gimbal_control_allow_tracking(const gimbal_control_t *ctl);
int gimbal_control_take_reset_history(gimbal_control_t *ctl);
void gimbal_control_note_target(gimbal_control_t *ctl,
                                int target_valid,
                                uint16_t lost_limit_frames);
int gimbal_control_tracking_requested(uint8_t mode,
                                      uint8_t auto_mode,
                                      uint8_t track_enabled);

#endif

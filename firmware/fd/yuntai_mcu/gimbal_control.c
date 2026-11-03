#include "gimbal_control.h"

void gimbal_control_init(gimbal_control_t *ctl)
{
    ctl->state = GIMBAL_CTL_CALIBRATING;
    ctl->reset_history_pending = 1u;
    ctl->target_lost_frames = 0u;
    ctl->target_good_frames = 0u;
}

void gimbal_control_update(gimbal_control_t *ctl,
                           int calibration_done,
                           int tracking_mode_requested,
                           int home_reached)
{
    if (!calibration_done) {
        ctl->target_good_frames = 0u;
        if (ctl->state != GIMBAL_CTL_CALIBRATING) {
            ctl->reset_history_pending = 1u;
        }
        ctl->state = GIMBAL_CTL_CALIBRATING;
        ctl->target_lost_frames = 0u;
        return;
    }

    switch (ctl->state) {
    case GIMBAL_CTL_CALIBRATING:
        ctl->state = GIMBAL_CTL_HOME_IDLE;
        break;
    case GIMBAL_CTL_HOME_IDLE:
        if (tracking_mode_requested) {
            ctl->state = GIMBAL_CTL_WAIT_TARGET;
            ctl->target_good_frames = 0u;
            ctl->target_lost_frames = 0u;
        }
        break;
    case GIMBAL_CTL_TRACKING:
    case GIMBAL_CTL_WAIT_TARGET:
        if (!tracking_mode_requested) {
            ctl->state = GIMBAL_CTL_RETURN_HOME;
            ctl->reset_history_pending = 1u;
            ctl->target_lost_frames = 0u;
        }
        break;
    case GIMBAL_CTL_RETURN_HOME:
        if (home_reached) {
            ctl->state = GIMBAL_CTL_HOME_IDLE;
        }
        break;
    default:
        ctl->state = GIMBAL_CTL_CALIBRATING;
        ctl->reset_history_pending = 1u;
        break;
    }
}

void gimbal_control_note_target(gimbal_control_t *ctl,
                                int target_valid,
                                uint16_t lost_limit_frames)
{
    if (ctl->state == GIMBAL_CTL_WAIT_TARGET) {
        if (!target_valid) ctl->target_good_frames = 0u;
        else if (++ctl->target_good_frames >= 3u) {
            ctl->state = GIMBAL_CTL_TRACKING;
            ctl->target_lost_frames = 0u;
        }
        return;
    }
    if (ctl->state != GIMBAL_CTL_TRACKING) {
        ctl->target_lost_frames = 0u;
        return;
    }
    if (target_valid) {
        ctl->target_lost_frames = 0u;
        return;
    }
    if (lost_limit_frames == 0u) {
        return;
    }
    if (ctl->target_lost_frames < lost_limit_frames) {
        ctl->target_lost_frames++;
    }
    if (ctl->target_lost_frames >= lost_limit_frames) {
        ctl->state = GIMBAL_CTL_RETURN_HOME;
        ctl->reset_history_pending = 1u;
        ctl->target_lost_frames = 0u;
    }
}

gimbal_control_state_t gimbal_control_state(const gimbal_control_t *ctl)
{
    return ctl->state;
}

int gimbal_control_force_home(const gimbal_control_t *ctl)
{
    return ctl->state == GIMBAL_CTL_CALIBRATING
        || ctl->state == GIMBAL_CTL_HOME_IDLE
        || ctl->state == GIMBAL_CTL_WAIT_TARGET
        || ctl->state == GIMBAL_CTL_RETURN_HOME;
}

int gimbal_control_allow_tracking(const gimbal_control_t *ctl)
{
    return ctl->state == GIMBAL_CTL_TRACKING;
}

int gimbal_control_take_reset_history(gimbal_control_t *ctl)
{
    int pending = ctl->reset_history_pending != 0u;
    ctl->reset_history_pending = 0u;
    return pending;
}

int gimbal_control_tracking_requested(uint8_t mode,
                                      uint8_t auto_mode,
                                      uint8_t track_enabled)
{
    return mode == 5u && auto_mode == 0u && track_enabled != 0u;
}

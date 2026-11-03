/*
 * gimbal_servo.h —— 三路舵机 PWM 驱动接口（支持 Q8 亚度级定点角度控制）
 */

#ifndef GIMBAL_SERVO_H
#define GIMBAL_SERVO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t  gimbal_servo_init(void);
void     gimbal_servo_set_us(int ch, uint32_t pulse_us);
void     gimbal_servo_set_deg(int ch, int32_t deg);
void     gimbal_servo_set_q8_deg(int ch, int32_t deg_q8);
void     gimbal_servo_center(void);
void     gimbal_servo_home(void);
void     gimbal_servo_step_home(uint32_t max_step_us);
uint32_t gimbal_servo_at_home(void);
uint32_t gimbal_servo_get_us(int ch);
int32_t  gimbal_servo_get_deg(int ch);
void     gimbal_servo_print_state(void);
uint32_t gimbal_servo_pin_probe(void);
uint32_t gimbal_servo_pwm_probe(void);
uint32_t gimbal_servo_get_pulse_ticks(int ch);

#ifdef __cplusplus
}
#endif

#endif /* GIMBAL_SERVO_H */

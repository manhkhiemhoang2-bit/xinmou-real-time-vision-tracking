/*
 * gimbal_servo.c —— 三路舵机软件 PWM 实现（含 Q8 亚度级高精度脉宽换算）
 */

#include "gimbal_servo.h"
#include "gimbal_config.h"

#include <stdio.h>

#include "al_gpio_hal.h"
#include "al_systimer.h"
#include "al_intr.h"
#include "al_misc_ll.h"

static AL_GPIO_HalStruct *s_gpio = 0;
static volatile uint32_t s_pulse_ticks_active[GIMBAL_NUM_CH];
static volatile uint32_t s_pulse_ticks_pending[GIMBAL_NUM_CH];
static volatile uint32_t s_pwm_cnt = 0;

static const uint32_t s_pin[GIMBAL_NUM_CH] = {
    GIMBAL_GPIO_YAW,
    GIMBAL_GPIO_PITCH,
    GIMBAL_GPIO_ROLL,
};

static const int32_t s_trim_us[GIMBAL_NUM_CH] = {
    GIMBAL_TRIM_US_YAW,
    GIMBAL_TRIM_US_PITCH,
    GIMBAL_TRIM_US_ROLL,
};

static uint32_t clamp_u32(uint32_t v, uint32_t lo, uint32_t hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static uint32_t us_to_ticks(uint32_t us)
{
    return (us + (GIMBAL_PWM_TICK_US / 2u)) / GIMBAL_PWM_TICK_US;
}

static uint32_t pulse_us_to_ticks(int ch, uint32_t pulse_us)
{
    int32_t trimmed = (int32_t)pulse_us + s_trim_us[ch];

    if (trimmed < 0) {
        trimmed = 0;
    }
    pulse_us = clamp_u32((uint32_t)trimmed,
                         GIMBAL_SERVO_MIN_US,
                         GIMBAL_SERVO_MAX_US);
    return us_to_ticks(pulse_us);
}

static void servo_set_us_exact(int ch, uint32_t pulse_us)
{
    if (ch < 0 || ch >= GIMBAL_NUM_CH) {
        return;
    }
    s_pulse_ticks_pending[ch] = pulse_us_to_ticks(ch, pulse_us);
}

static int32_t home_deg_for_ch(int ch)
{
    if (ch == GIMBAL_CH_YAW) {
        return GIMBAL_HOME_DEG_YAW;
    }
    if (ch == GIMBAL_CH_PITCH) {
        return GIMBAL_HOME_DEG_PITCH;
    }
    return GIMBAL_HOME_DEG_ROLL;
}

static uint32_t home_ticks_for_ch(int ch)
{
    int32_t half_span_q8 = (GIMBAL_SERVO_SPAN_DEG / 2) * 256;
    int32_t half_us = (int32_t)(GIMBAL_SERVO_MAX_US - GIMBAL_SERVO_MID_US);
    int32_t deg_q8 = home_deg_for_ch(ch) * 256;
    int32_t pulse_us = (int32_t)GIMBAL_SERVO_MID_US
                     + (deg_q8 * half_us) / half_span_q8;

    return pulse_us_to_ticks(ch, (uint32_t)pulse_us);
}

static uint32_t deadband_ticks_for_ch(int ch)
{
    uint32_t us = (ch == GIMBAL_CH_ROLL)
                ? GIMBAL_SERVO_DEADBAND_US
                : GIMBAL_TRK_SERVO_DEADBAND_US;
    return us / GIMBAL_PWM_TICK_US;
}

static void gimbal_servo_isr(AL_VOID *param)
{
    (void)param;

    uint32_t c = s_pwm_cnt;
    int i;

    if (c == 0u) {
        for (i = 0; i < GIMBAL_NUM_CH; i++) {
            s_pulse_ticks_active[i] = s_pulse_ticks_pending[i];
        }
    }

    AlGpio_Hal_WritePin(s_gpio, s_pin[GIMBAL_CH_YAW],   (AL_BOOL)(c < s_pulse_ticks_active[GIMBAL_CH_YAW]));
    AlGpio_Hal_WritePin(s_gpio, s_pin[GIMBAL_CH_PITCH], (AL_BOOL)(c < s_pulse_ticks_active[GIMBAL_CH_PITCH]));
    AlGpio_Hal_WritePin(s_gpio, s_pin[GIMBAL_CH_ROLL],  (AL_BOOL)(c < s_pulse_ticks_active[GIMBAL_CH_ROLL]));

    if (++c >= GIMBAL_PWM_PERIOD_TICKS) {
        c = 0;
    }
    s_pwm_cnt = c;
}

int32_t gimbal_servo_init(void)
{
    int32_t ret;
    int i;

    AlMisc_ll_SetClkEn(AL_MISC_LGPIO, 1);
    AlMisc_ll_SetReset(AL_MISC_LGPIO, 0);
    AlMisc_ll_SetReset(AL_MISC_LGPIO, 1);

    ret = AlGpio_Hal_Init(&s_gpio, 0, AL_NULL);
    if (ret != AL_OK) {
        return ret;
    }
    for (i = 0; i < GIMBAL_NUM_CH; i++) {
        AlGpio_Hal_SetDirection(s_gpio, AL_GPIO_OUTPUT, s_pin[i]);
        AlGpio_Hal_SetTransType(s_gpio, s_pin[i], AL_GPIO_PUSH_PULL);
        AlGpio_Hal_WritePin(s_gpio, s_pin[i], AL_FALSE);
        s_pulse_ticks_active[i] = home_ticks_for_ch(i);
        s_pulse_ticks_pending[i] = s_pulse_ticks_active[i];
    }

    AL_SysTick tick;
    tick.Ticks    = GIMBAL_PWM_TICK_COUNTS;
    tick.CallBack = gimbal_servo_isr;
    tick.Priv     = AL_NULL;
    AlSys_StartTick(&tick);

    AlSys_StartTimer();
    AlIntr_SetLocalInterrupt(AL_FUNC_ENABLE);

    return AL_OK;
}

uint32_t gimbal_servo_pin_probe(void)
{
    uint32_t i, n, seen = 0;

    if (s_gpio == 0) {
        return 0;
    }

    for (n = 0; n < 2500u; n++) {
        for (i = 0; i < GIMBAL_NUM_CH; i++) {
            if (AlGpio_Hal_ReadPin(s_gpio, s_pin[i])) {
                seen |= (1u << i);
            }
        }
        if (seen == 0x7u) {
            break;
        }
        AlSys_UDelay(10u);
    }
    return seen;
}

uint32_t gimbal_servo_pwm_probe(void)
{
    uint32_t i, n, hi = 0;

    if (s_gpio == 0) {
        return 0;
    }

    for (n = 0; n < 6000; n++) {
        for (i = 0; i < GIMBAL_NUM_CH; i++) {
            if (AlGpio_Hal_ReadPin(s_gpio, s_pin[i])) {
                hi++;
            }
        }
        AlSys_UDelay(10);
    }
    return hi;
}

uint32_t gimbal_servo_get_pulse_ticks(int ch)
{
    if (ch < 0 || ch >= GIMBAL_NUM_CH) {
        return 0;
    }
    return s_pulse_ticks_active[ch];
}

void gimbal_servo_set_us(int ch, uint32_t pulse_us)
{
    uint32_t ticks, cur, db_ticks;

    if (ch < 0 || ch >= GIMBAL_NUM_CH) {
        return;
    }
    ticks = pulse_us_to_ticks(ch, pulse_us);

    db_ticks = deadband_ticks_for_ch(ch);
    cur = s_pulse_ticks_pending[ch];
    if (ticks >= cur) {
        if (ticks - cur <= db_ticks) {
            return;
        }
    } else {
        if (cur - ticks <= db_ticks) {
            return;
        }
    }
    s_pulse_ticks_pending[ch] = ticks;
}

void gimbal_servo_set_q8_deg(int ch, int32_t deg_q8)
{
    int32_t half_span_q8 = (GIMBAL_SERVO_SPAN_DEG / 2) * 256;
    int32_t half_us      = (int32_t)(GIMBAL_SERVO_MAX_US - GIMBAL_SERVO_MID_US);
    int32_t pulse;

    if (deg_q8 < -half_span_q8) deg_q8 = -half_span_q8;
    if (deg_q8 >  half_span_q8) deg_q8 =  half_span_q8;

    pulse = (int32_t)GIMBAL_SERVO_MID_US
          + (deg_q8 * half_us) / half_span_q8;
    gimbal_servo_set_us(ch, (uint32_t)pulse);
}

void gimbal_servo_set_deg(int ch, int32_t deg)
{
    gimbal_servo_set_q8_deg(ch, deg * 256);
}

void gimbal_servo_center(void)
{
    servo_set_us_exact(GIMBAL_CH_YAW,   GIMBAL_SERVO_MID_US);
    servo_set_us_exact(GIMBAL_CH_PITCH, GIMBAL_SERVO_MID_US);
    servo_set_us_exact(GIMBAL_CH_ROLL,  GIMBAL_SERVO_MID_US);
}

void gimbal_servo_home(void)
{
    int ch;

    for (ch = 0; ch < GIMBAL_NUM_CH; ch++) {
        s_pulse_ticks_pending[ch] = home_ticks_for_ch(ch);
    }
}

void gimbal_servo_step_home(uint32_t max_step_us)
{
    uint32_t max_step_ticks = us_to_ticks(max_step_us);
    int ch;

    if (max_step_ticks == 0u) {
        max_step_ticks = 1u;
    }
    for (ch = 0; ch < GIMBAL_NUM_CH; ch++) {
        uint32_t cur = s_pulse_ticks_active[ch];
        uint32_t home = home_ticks_for_ch(ch);

        if (cur + max_step_ticks < home) {
            s_pulse_ticks_pending[ch] = cur + max_step_ticks;
        } else if (cur > home + max_step_ticks) {
            s_pulse_ticks_pending[ch] = cur - max_step_ticks;
        } else {
            s_pulse_ticks_pending[ch] = home;
        }
    }
}

uint32_t gimbal_servo_at_home(void)
{
    int ch;

    for (ch = 0; ch < GIMBAL_NUM_CH; ch++) {
        if (s_pulse_ticks_active[ch] != home_ticks_for_ch(ch)) {
            return 0u;
        }
    }
    return 1u;
}

uint32_t gimbal_servo_get_us(int ch)
{
    if (ch < 0 || ch >= GIMBAL_NUM_CH) {
        return 0;
    }
    return s_pulse_ticks_active[ch] * GIMBAL_PWM_TICK_US;
}

int32_t gimbal_servo_get_deg(int ch)
{
    int32_t half_span;
    int32_t us;

    if (ch < 0 || ch >= GIMBAL_NUM_CH) {
        return 0;
    }
    half_span = GIMBAL_SERVO_SPAN_DEG / 2;
    us = (int32_t)gimbal_servo_get_us(ch) - (int32_t)GIMBAL_SERVO_MID_US;
    return us * half_span / (int32_t)(GIMBAL_SERVO_MAX_US - GIMBAL_SERVO_MID_US);
}

void gimbal_servo_print_state(void)
{
    printf("servo state: yaw=%4uus(%3ddeg)  pitch=%4uus(%3ddeg)  roll=%4uus(%3ddeg)\r\n",
           (unsigned)gimbal_servo_get_us(GIMBAL_CH_YAW),   (int)gimbal_servo_get_deg(GIMBAL_CH_YAW),
           (unsigned)gimbal_servo_get_us(GIMBAL_CH_PITCH), (int)gimbal_servo_get_deg(GIMBAL_CH_PITCH),
           (unsigned)gimbal_servo_get_us(GIMBAL_CH_ROLL),  (int)gimbal_servo_get_deg(GIMBAL_CH_ROLL));
}

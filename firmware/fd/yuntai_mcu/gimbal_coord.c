/*
 * gimbal_coord.c —— FPGA 坐标从机（I2C 0x50）读取实现
 */

#include "gimbal_coord.h"
#include "gimbal_imu.h"
#include "gimbal_config.h"

#define COORD_ATTEMPT_MAX  2u

static int32_t coord_read_frame(uint32_t *frame)
{
    uint8_t fb[2];
    int32_t ret = gimbal_imu_bus_read(GIMBAL_COORD_I2C_ADDR,
                                      GIMBAL_COORD_REG_FRAME_L, fb, 2u);
    if (ret != 0) {
        return GIMBAL_COORD_ERR_BUS;
    }
    *frame = (uint32_t)fb[0] | ((uint32_t)fb[1] << 8);
    return GIMBAL_COORD_OK;
}

int32_t gimbal_coord_init(void)
{
    uint8_t ver = 0;
    int32_t ret = gimbal_imu_bus_read(GIMBAL_COORD_I2C_ADDR,
                                      GIMBAL_COORD_REG_VERSION, &ver, 1u);
    if (ret != 0) {
        return GIMBAL_COORD_ERR_BUS;
    }
    return (ver == GIMBAL_COORD_VERSION_VAL) ? GIMBAL_COORD_OK
                                             : GIMBAL_COORD_ERR_VERSION;
}

int32_t gimbal_coord_read(gimbal_coord_t *out)
{
    uint32_t attempt;
    int32_t  last_err = GIMBAL_COORD_ERR_FRAME;
    int32_t  ret;

    if (out == 0) {
        return GIMBAL_COORD_ERR_BUS;
    }

    ret = gimbal_coord_init();
    if (ret != GIMBAL_COORD_OK) {
        return ret;
    }

    for (attempt = 0u; attempt < COORD_ATTEMPT_MAX; attempt++) {
        uint8_t  buf[15];
        uint32_t f1 = 0u, f2 = 0u;
        int32_t  cx, cy;

        ret = coord_read_frame(&f1);
        if (ret != GIMBAL_COORD_OK) {
            return ret;
        }

        ret = gimbal_imu_bus_read(GIMBAL_COORD_I2C_ADDR,
                                  GIMBAL_COORD_REG_CX_L, buf, 15u);
        if (ret != 0) {
            return GIMBAL_COORD_ERR_BUS;
        }

        ret = coord_read_frame(&f2);
        if (ret != GIMBAL_COORD_OK) {
            return ret;
        }

        if (f1 != f2) {
            last_err = GIMBAL_COORD_ERR_FRAME;
            continue;
        }

        cx = (int32_t)((uint32_t)buf[0] | (((uint32_t)buf[1] & 0x07u) << 8));
        cy = (int32_t)((uint32_t)buf[2] | (((uint32_t)buf[3] & 0x07u) << 8));

        if ((buf[4] & 0x01u) != 0u &&
            (cx >= (int32_t)GIMBAL_IMG_W || cy >= (int32_t)GIMBAL_IMG_H)) {
            last_err = GIMBAL_COORD_ERR_RANGE;
            continue;
        }

        out->cx        = cx;
        out->cy        = cy;
        out->frame     = f1;
        out->valid     = (uint8_t)(buf[4] & 0x01u);
        out->mode      = (uint8_t)(buf[7] & 0x0Fu);   /* 支持 M0~M8 全部 9 档 */
        out->w         = (int32_t)((uint32_t)buf[8]  | (((uint32_t)buf[9]  & 0x07u) << 8));
        out->h         = (int32_t)((uint32_t)buf[10] | (((uint32_t)buf[11] & 0x07u) << 8));
        out->pix_cnt   = (int32_t)buf[12];
        out->cls       = (uint8_t)(buf[13] & 0x03u);
        out->auto_mode = (uint8_t)((buf[14] >> 1) & 0x01u);
        out->track_en  = (uint8_t)((buf[14] >> 2) & 0x01u);   /* ★B4(SW2) 追踪使能开关 */
        out->status    = buf[14];
        return GIMBAL_COORD_OK;
    }

    return last_err;
}

int32_t gimbal_coord_probe_addr(uint8_t addr7, uint8_t reg)
{
    uint8_t  b = 0u;
    return gimbal_imu_bus_read(addr7, reg, &b, 1u);
}

int32_t gimbal_coord_probe(uint8_t *buf, uint32_t n)
{
    uint32_t i;

    if (buf == 0 || n == 0u || n > 16u) {
        return GIMBAL_COORD_ERR_BUS;
    }
    for (i = 0u; i < n; i++) {
        buf[i] = 0u;
    }
    if (gimbal_imu_bus_read(GIMBAL_COORD_I2C_ADDR,
                            GIMBAL_COORD_REG_CX_L, buf, n) != 0) {
        return GIMBAL_COORD_ERR_BUS;
    }
    return GIMBAL_COORD_OK;
}

int32_t gimbal_coord_write_roi(int32_t x0, int32_t x1, int32_t y0, int32_t y1)
{
    uint8_t buf[8];

    buf[0] = (uint8_t)(x0 & 0xFF);  buf[1] = (uint8_t)((x0 >> 8) & 0x07);
    buf[2] = (uint8_t)(x1 & 0xFF);  buf[3] = (uint8_t)((x1 >> 8) & 0x07);
    buf[4] = (uint8_t)(y0 & 0xFF);  buf[5] = (uint8_t)((y0 >> 8) & 0x07);
    buf[6] = (uint8_t)(y1 & 0xFF);  buf[7] = (uint8_t)((y1 >> 8) & 0x07);

    return gimbal_imu_bus_write(GIMBAL_COORD_I2C_ADDR, 0x10u, buf, 8u);
}

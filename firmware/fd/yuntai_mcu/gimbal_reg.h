/*
 * gimbal_reg.h —— FPGA↔MCU 的 APB 寄存器映射（详细设计 §6.5）
 *
 * FPGA 侧的 gim_reg_apb.v 挂一个 APB 从设备，把"目标检测结果"暴露给 MCU：
 *   MCU 通过 volatile 指针直接读写这些寄存器。
 *
 * 地址约定：
 *   GIMBAL_REG_BASE 的【低 20 位】= FPGA gim_reg_apb.v 的 BASE_ADDR 参数，
 *   并且要落在 HPF 里 APB Fabric 端口的地址窗口内，三处必须一致。
 */

#ifndef GIMBAL_REG_H
#define GIMBAL_REG_H

#include <stdint.h>
#include "gimbal_config.h"

/* 偏移地址（相对 GIMBAL_REG_BASE） */
#define GIMBAL_REG_TARGET_X   0x00   /* [15:0] 目标中心 X（FPGA→MCU，只读） */
#define GIMBAL_REG_TARGET_Y   0x04   /* [15:0] 目标中心 Y（FPGA→MCU，只读） */
#define GIMBAL_REG_DET        0x08   /* [0] 目标有效标志（FPGA→MCU，只读） */
#define GIMBAL_REG_FRAME_ID   0x0C   /* [15:0] 帧号，用于去重（FPGA→MCU，只读） */
#define GIMBAL_REG_CTRL       0x10   /* [7:0] 控制命令（MCU→FPGA，写） */
#define GIMBAL_REG_STATUS     0x14   /* [7:0] 状态回读（FPGA→MCU，只读） */

/* ★2026-10-11 运行时基址：Fabric APB 窗口的基址靠"容错地址探测"在上电时找出来
 *   （编译期常量 GIMBAL_REG_BASE 只是默认值/历史值，实测不可访问）。
 *   main.c 里定义；为 0 表示"还没找到" ⇒ 此时**绝不允许**读寄存器（会抛 Load access fault）。
 *   放在 gimbal_reg.h 里定义、main.c 里给初值，所有用到 gimbal_reg_read() 的
 *   翻译单元都能看到同一声明。 */
extern volatile uint32_t g_gimbal_reg_base;

/* 寄存器访问：基址优先用运行时找到的 g_gimbal_reg_base，为 0 时退回编译期常量 */
static inline uint32_t gimbal_reg_base_now(void)
{
    return (g_gimbal_reg_base != 0u) ? g_gimbal_reg_base : (uint32_t)GIMBAL_REG_BASE;
}

static inline uint32_t gimbal_reg_read(uint32_t offset)
{
    return *(volatile uint32_t *)(gimbal_reg_base_now() + offset);
}

static inline void gimbal_reg_write(uint32_t offset, uint32_t value)
{
    *(volatile uint32_t *)(gimbal_reg_base_now() + offset) = value;
}

#endif /* GIMBAL_REG_H */

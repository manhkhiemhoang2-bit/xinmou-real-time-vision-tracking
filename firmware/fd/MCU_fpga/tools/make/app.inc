
# Default toolchain prefixes can be overridden externally.

# ARM toolchains for dr1m90
ifeq ($(CHIP),dr1m90)
    ifeq ($(ARMv8_STATE), 32)
        COMPILE_PREFIX ?= /opt/toolchain/13.2/arm-gnu-toolchain-13.2.Rel1-x86_64-arm-none-eabi/bin/arm-none-eabi-
    else
        COMPILE_PREFIX ?= /opt/toolchain/arm-gnu-toolchain-12.3.rel1-x86_64-aarch64-none-elf/bin/aarch64-none-elf-
    endif

# RISC-V 64 toolchain for dr1v90
else ifeq ($(CHIP),dr1v90)
    COMPILE_PREFIX ?= /opt/toolchain/riscv-gcc/bin/riscv-nuclei-elf-

# RISC-V 64 toolchain for ph1p35
else ifeq ($(CHIP),ph1p35)
    COMPILE_PREFIX ?= /opt/toolchain/NucleiStudio/toolchain/gcc/bin/riscv64-unknown-elf-

else ifeq ($(CHIP),ph1p50)
    COMPILE_PREFIX ?= /opt/toolchain/NucleiStudio/toolchain/gcc/bin/riscv64-unknown-elf-

else ifeq ($(CHIP),softcore)
    COMPILE_PREFIX ?= /opt/toolchain/riscv-gcc/bin/riscv-nuclei-elf-

# Fallback RISC-V toolchain for other chips
else
    COMPILE_PREFIX ?= /opt/toolchain/riscv-gcc/bin/riscv-nuclei-elf-
endif

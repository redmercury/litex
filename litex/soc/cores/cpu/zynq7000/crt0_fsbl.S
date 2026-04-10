/*
 * This file is part of LiteX.
 *
 * Cortex-A9 bootstrap for Zynq-7000 FSBL mode.
 *
 * When used as the FSBL, this code is loaded to OCM (0x00000000) by
 * the Zynq BootROM and is the first code that executes on the ARM PS.
 * It initialises the processor, calls ps7_init() to bring up DDR/clocks/MIO,
 * enables caches, clears BSS and jumps to main().
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

#define MODE_USR 0x10
#define MODE_FIQ 0x11
#define MODE_IRQ 0x12
#define MODE_SVC 0x13
#define MODE_ABT 0x17
#define MODE_UND 0x1B
#define MODE_SYS 0x1F
#define I_BIT    0x80
#define F_BIT    0x40

.section .vectors, "ax"
.global _vector_table
_vector_table:
    b   _boot                   /* 0x00 - Reset */
    b   _vector_undef           /* 0x04 - Undefined Instruction */
    b   _vector_swi             /* 0x08 - Software Interrupt */
    b   _vector_prefetch_abort  /* 0x0C - Prefetch Abort */
    b   _vector_data_abort      /* 0x10 - Data Abort */
    nop                         /* 0x14 - Reserved */
    b   _vector_irq             /* 0x18 - IRQ */
    b   _vector_fiq             /* 0x1C - FIQ */

/*
 * Default exception handlers — hang with a distinctive register value
 * so JTAG debugging can identify the fault type.
 */
_vector_undef:
    mov r0, #1
    b   _exception_hang
_vector_swi:
    mov r0, #2
    b   _exception_hang
_vector_prefetch_abort:
    mov r0, #3
    b   _exception_hang
_vector_data_abort:
    mov r0, #4
    b   _exception_hang
_vector_fiq:
    mov r0, #7
    b   _exception_hang
_exception_hang:
    b   _exception_hang

/* IRQ handler — calls C handler via irq_handler() if implemented. */
_vector_irq:
    sub     lr, lr, #4          /* Adjust return address */
    stmfd   sp!, {r0-r12, lr}   /* Save context */
    bl      isr                 /* Call C-level ISR dispatcher */
    ldmfd   sp!, {r0-r12, pc}^  /* Restore context and return */

/* --------------------------------------------------------------------- */
.section .boot, "ax"
.global _boot
.global _start
_start:
_boot:
    /*
     * Ensure we are in SVC mode with IRQ/FIQ disabled.
     * The BootROM enters us in SVC mode, but be explicit.
     */
    mrs     r0, cpsr
    bic     r0, r0, #0x1F
    orr     r0, r0, #(MODE_SVC | I_BIT | F_BIT)
    msr     cpsr_c, r0

    /*
     * Set VBAR so exceptions use OUR vector table, not the default at
     * 0x00000000 (which is OCM and may not contain our handlers).
     */
    ldr     r0, =_vector_table
    mcr     p15, 0, r0, c12, c0, 0  /* Write VBAR */
    isb

    /*
     * Invalidate caches and disable MMU.
     * After BootROM or rst -system, D-cache should be clean.
     * We only invalidate (not clean) which is safe at reset.
     */
    mrc     p15, 0, r0, c1, c0, 0   /* Read SCTLR */
    bic     r0, r0, #(1 << 0)       /* M - MMU disable */
    bic     r0, r0, #(1 << 2)       /* C - D-cache disable */
    bic     r0, r0, #(1 << 12)      /* I - I-cache disable */
    bic     r0, r0, #(1 << 11)      /* Z - branch prediction disable */
    mcr     p15, 0, r0, c1, c0, 0
    dsb
    isb

    /* Invalidate I-cache, branch predictor, TLB. */
    mov     r0, #0
    mcr     p15, 0, r0, c7, c5, 0   /* Invalidate entire I-cache */
    mcr     p15, 0, r0, c7, c5, 6   /* Invalidate branch predictor */
    mcr     p15, 0, r0, c8, c7, 0   /* Invalidate entire TLB */
    dsb
    isb

    /*
     * Set up stacks for each ARM processor mode.
     * Stack symbols are provided by the linker script (linker-zynq.ld).
     */

    /* IRQ mode stack */
    mrs     r0, cpsr
    bic     r0, r0, #0x1F
    orr     r0, r0, #(MODE_IRQ | I_BIT | F_BIT)
    msr     cpsr_c, r0
    ldr     sp, =__irq_stack

    /* FIQ mode stack */
    mrs     r0, cpsr
    bic     r0, r0, #0x1F
    orr     r0, r0, #(MODE_FIQ | I_BIT | F_BIT)
    msr     cpsr_c, r0
    ldr     sp, =__fiq_stack

    /* Abort mode stack */
    mrs     r0, cpsr
    bic     r0, r0, #0x1F
    orr     r0, r0, #(MODE_ABT | I_BIT | F_BIT)
    msr     cpsr_c, r0
    ldr     sp, =__abort_stack

    /* Undefined mode stack */
    mrs     r0, cpsr
    bic     r0, r0, #0x1F
    orr     r0, r0, #(MODE_UND | I_BIT | F_BIT)
    msr     cpsr_c, r0
    ldr     sp, =__undef_stack

    /* Supervisor mode stack */
    mrs     r0, cpsr
    bic     r0, r0, #0x1F
    orr     r0, r0, #(MODE_SVC | I_BIT | F_BIT)
    msr     cpsr_c, r0
    ldr     sp, =__supervisor_stack

    /* System mode stack (used by main code) */
    mrs     r0, cpsr
    bic     r0, r0, #0x1F
    orr     r0, r0, #(MODE_SYS | I_BIT | F_BIT)
    msr     cpsr_c, r0
    ldr     sp, =__stack

    /*
     * Switch back to SVC mode for the rest of boot.
     */
    mrs     r0, cpsr
    bic     r0, r0, #0x1F
    orr     r0, r0, #(MODE_SVC | I_BIT | F_BIT)
    msr     cpsr_c, r0

    /*
     * Call ps7_init() — configures PLLs, clocks, DDR, MIO.
     * Only called if DDR is not already initialised (the DDRC mode
     * register at 0xF8006000 is zero after a cold reset but non-zero
     * if xsdb/debugger already ran ps7_init before downloading us).
     */
    ldr     r0, =0xF8006000     /* DDRC mode status register */
    ldr     r0, [r0]
    cmp     r0, #0
    bne     _skip_ps7_init
    bl      ps7_init
_skip_ps7_init:

    /*
     * Enable VFP/NEON (Coprocessor Access Control).
     */
    mrc     p15, 0, r0, c1, c0, 2   /* Read CPACR */
    orr     r0, r0, #(0xF << 20)    /* Full access to CP10 and CP11 */
    mcr     p15, 0, r0, c1, c0, 2
    isb
    vmrs    r0, fpexc
    orr     r0, r0, #(1 << 30)      /* Set FPEXC.EN */
    vmsr    fpexc, r0

    /*
     * Set up a flat 1:1 MMU translation table (1MB sections).
     * - 0x00000000–0x3FFFFFFF : DDR, cacheable/bufferable (normal WB-WA)
     * - 0x40000000–0xFFFFFFFF : device/strongly-ordered (peripherals, PL)
     *
     * Uses the .mmu_tbl section (16KB aligned) from the linker script.
     */
    ldr     r0, =__mmu_tbl_start

    /* Fill entire table with device memory (non-cacheable, non-bufferable). */
    /* Section descriptor: AP=11 (full access), domain 0, device memory */
    ldr     r1, =0x00000C02         /* Device: S=0, TEX=0, AP=11, domain=0 */
    mov     r2, #0                  /* Virtual address counter */
    mov     r3, #4096               /* 4096 entries for 4GB address space */
1:
    orr     r4, r1, r2, lsl #20    /* Section base | attributes */
    str     r4, [r0], #4
    add     r2, r2, #1
    subs    r3, r3, #1
    bne     1b

    /* Overwrite DDR entries (0x00000000–0x3FFFFFFF) with cacheable. */
    /* Section descriptor: normal memory, write-back write-allocate */
    ldr     r0, =__mmu_tbl_start
    ldr     r1, =0x00015C06         /* Normal: TEX=1,C=1,B=1, S=1, AP=11 */
    mov     r2, #0
    mov     r3, #1024               /* 1024 entries = 1GB */
2:
    orr     r4, r1, r2, lsl #20
    str     r4, [r0], #4
    add     r2, r2, #1
    subs    r3, r3, #1
    bne     2b

    /*
     * OCM at 0x00000000–0x000FFFFF: override first entry to non-cacheable
     * so we don't get coherency issues with code running from OCM.
     */
    ldr     r0, =__mmu_tbl_start
    ldr     r1, =0x00000C02         /* Device memory for OCM */
    str     r1, [r0]

    /* Set TTBR0 to point to our translation table. */
    ldr     r0, =__mmu_tbl_start
    mcr     p15, 0, r0, c2, c0, 0   /* Write TTBR0 */

    /* Set domain 0 to "client" (access checked against permission bits). */
    mov     r0, #0x01
    mcr     p15, 0, r0, c3, c0, 0   /* Write DACR */

    /* Invalidate TLB before enabling MMU. */
    mov     r0, #0
    mcr     p15, 0, r0, c8, c7, 0
    dsb
    isb

    /* Enable MMU, I-cache, D-cache, branch prediction. */
    mrc     p15, 0, r0, c1, c0, 0   /* Read SCTLR */
    orr     r0, r0, #(1 << 0)       /* M - MMU enable */
    orr     r0, r0, #(1 << 2)       /* C - D-cache enable */
    orr     r0, r0, #(1 << 12)      /* I - I-cache enable */
    orr     r0, r0, #(1 << 11)      /* Z - branch prediction enable */
    mcr     p15, 0, r0, c1, c0, 0
    dsb
    isb

    /*
     * Clear BSS.
     */
    ldr     r0, =__bss_start
    ldr     r1, =__bss_end
    mov     r2, #0
3:
    cmp     r0, r1
    strlt   r2, [r0], #4
    blt     3b

    /*
     * Initialise PS UART1 — ps7_init sets up clocking and MIO mux
     * but leaves the controller in reset.  Enable TX/RX here so
     * early prints from main() work immediately.
     */
    ldr     r0, =0xE0001000
    ldr     r1, =0x00000114     /* CR: TX_EN | RX_EN, clear resets */
    str     r1, [r0, #0x00]
    ldr     r1, =0x00000020     /* MR: 8-N-1 */
    str     r1, [r0, #0x04]

    /*
     * Jump to C main().
     */
    bl      main

    /* Should never return, but if it does, hang. */
4:
    wfi
    b       4b

.end

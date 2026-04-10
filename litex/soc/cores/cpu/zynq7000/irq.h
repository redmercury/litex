#ifndef __IRQ_H
#define __IRQ_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Zynq-7000 GIC-based interrupt support for LiteX.
 *
 * The Zynq PS uses an ARM GIC (PL390) with:
 *   GICD (Distributor)   at 0xF8F01000
 *   GICC (CPU Interface) at 0xF8F00100
 *
 * PL-to-PS (F2P) interrupt mapping:
 *   LiteX IRQ [7:0]  → GIC IDs 61–68  (SPI 29–36)
 *   LiteX IRQ [15:8] → GIC IDs 84–91  (SPI 52–59)
 */

#include <stdint.h>

/* GIC register base addresses (Zynq-7000). */
#define GICC_BASE   0xF8F00100
#define GICD_BASE   0xF8F01000

/* GICC (CPU Interface) registers. */
#define GICC_CTLR   (*(volatile uint32_t *)(GICC_BASE + 0x00))
#define GICC_PMR    (*(volatile uint32_t *)(GICC_BASE + 0x04))
#define GICC_IAR    (*(volatile uint32_t *)(GICC_BASE + 0x0C))
#define GICC_EOIR   (*(volatile uint32_t *)(GICC_BASE + 0x10))

/* GICD (Distributor) registers — indexed by 32-bit word. */
#define GICD_CTLR       (*(volatile uint32_t *)(GICD_BASE + 0x000))
#define GICD_ISENABLER(n) (*(volatile uint32_t *)(GICD_BASE + 0x100 + 4*(n)))
#define GICD_ICENABLER(n) (*(volatile uint32_t *)(GICD_BASE + 0x180 + 4*(n)))
#define GICD_ISPENDR(n)   (*(volatile uint32_t *)(GICD_BASE + 0x200 + 4*(n)))
#define GICD_ICPENDR(n)   (*(volatile uint32_t *)(GICD_BASE + 0x280 + 4*(n)))
#define GICD_IPRIORITYR(n)(*(volatile uint32_t *)(GICD_BASE + 0x400 + 4*(n)))

/*
 * LiteX IRQ bit  →  GIC IRQ ID mapping.
 *
 * IRQ_F2P[7:0]  → GIC IDs 61–68
 * IRQ_F2P[15:8] → GIC IDs 84–91
 */
static inline unsigned int _litex_irq_to_gic_id(unsigned int irq)
{
	if (irq < 8)
		return 61 + irq;
	else
		return 84 + (irq - 8);
}

/*
 * Initialise the GIC for LiteX F2P interrupts.
 * Called automatically on first irq_setie(1).
 */
static unsigned int _gic_initialized = 0;

static inline void irq_init(void)
{
	unsigned int i, gic_id;

	if (_gic_initialized)
		return;
	_gic_initialized = 1;

	/* Enable the GIC distributor and CPU interface. */
	GICD_CTLR = 1;
	GICC_CTLR = 1;

	/* Accept all priority levels. */
	GICC_PMR = 0xFF;

	/* Set all F2P interrupts to mid priority and disable them. */
	for (i = 0; i < 16; i++) {
		gic_id = _litex_irq_to_gic_id(i);
		/* Each priority register holds 4 x 8-bit priorities. */
		volatile uint32_t *pr = &GICD_IPRIORITYR(gic_id / 4);
		unsigned int shift = (gic_id % 4) * 8;
		*pr = (*pr & ~(0xFFu << shift)) | (0xA0u << shift);
		/* Disable the interrupt. */
		GICD_ICENABLER(gic_id / 32) = (1u << (gic_id % 32));
	}
}

/*
 * irq_getie() — check if IRQs are globally enabled (CPSR I bit).
 */
static inline unsigned int irq_getie(void)
{
	unsigned int cpsr;
	__asm__ volatile("mrs %0, cpsr" : "=r"(cpsr));
	/* I bit clear means IRQs enabled. */
	return (cpsr & (1 << 7)) ? 0 : 1;
}

/*
 * irq_setie() — globally enable or disable IRQs.
 * Initialises the GIC on first enable.
 */
static inline void irq_setie(unsigned int ie)
{
	if (ie) {
		irq_init();
		__asm__ volatile("cpsie i" ::: "memory");
	} else {
		__asm__ volatile("cpsid i" ::: "memory");
	}
}

/*
 * irq_getmask() — return a 16-bit mask of enabled F2P interrupts.
 */
static inline unsigned int irq_getmask(void)
{
	unsigned int mask = 0;
	unsigned int i, gic_id;
	for (i = 0; i < 16; i++) {
		gic_id = _litex_irq_to_gic_id(i);
		if (GICD_ISENABLER(gic_id / 32) & (1u << (gic_id % 32)))
			mask |= (1u << i);
	}
	return mask;
}

/*
 * irq_setmask() — enable/disable F2P interrupts according to a 16-bit mask.
 */
static inline void irq_setmask(unsigned int mask)
{
	unsigned int i, gic_id;
	for (i = 0; i < 16; i++) {
		gic_id = _litex_irq_to_gic_id(i);
		if (mask & (1u << i))
			GICD_ISENABLER(gic_id / 32) = (1u << (gic_id % 32));
		else
			GICD_ICENABLER(gic_id / 32) = (1u << (gic_id % 32));
	}
}

/*
 * irq_pending() — return a 16-bit mask of pending F2P interrupts.
 */
static inline unsigned int irq_pending(void)
{
	unsigned int mask = 0;
	unsigned int i, gic_id;
	for (i = 0; i < 16; i++) {
		gic_id = _litex_irq_to_gic_id(i);
		if (GICD_ISPENDR(gic_id / 32) & (1u << (gic_id % 32)))
			mask |= (1u << i);
	}
	return mask;
}

/*
 * irq_acknowledge() — acknowledge the current IRQ and return its LiteX IRQ number.
 * Returns -1 if spurious.
 */
static inline int irq_acknowledge(void)
{
	uint32_t iar = GICC_IAR;
	unsigned int gic_id = iar & 0x3FF;
	unsigned int i;

	/* Spurious? */
	if (gic_id == 1023)
		return -1;

	/* Map GIC ID back to LiteX IRQ number. */
	for (i = 0; i < 16; i++) {
		if (_litex_irq_to_gic_id(i) == gic_id) {
			/* Signal end-of-interrupt. */
			GICC_EOIR = iar;
			return (int)i;
		}
	}

	/* Not one of ours — still complete it. */
	GICC_EOIR = iar;
	return -1;
}

#ifdef __cplusplus
}
#endif

#endif /* __IRQ_H */

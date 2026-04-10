/*
 * This file is part of LiteX.
 *
 * Weak stub for ps7_init().  When building in FSBL mode the Vivado-generated
 * ps7_init.c is compiled and linked, overriding this stub.  In legacy mode
 * (external FSBL already initialised the PS) this no-op is used.
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

__attribute__((weak)) int ps7_init(void)
{
    /* No-op: PS already initialised by an external FSBL. */
    return 0;
}

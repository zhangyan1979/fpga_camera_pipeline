// ============================================================================
//  gt911.h - portable GT911 capacitive-touch driver (no OS, no vendor SDK)
//
//  The board wiring is supplied by the caller through gt911_glue_t, so the same
//  driver works on the ACZ702 (PS I2C0 + PL TP_RST + PS MIO0 TP_INT) and on any
//  other MCU/SoC.
//
//  Typical use
//  -----------
//      static const gt911_glue_t glue = { my_rst, my_int, my_i2c_w, my_i2c_r, my_delay };
//      int ver = 0, dl = 0;
//      int addr = gt911_init(&glue, &ver, &dl);     // -1 on failure
//      if (addr < 0) { ... }
//      for (;;) {
//          gt911_point_t p[5];
//          int n = gt911_poll(&glue, addr, p, 5);   // -1 on bus error
//          if (n > 0) { /* p[0].x, p[0].y ... */ }
//          my_delay_ms(10);
//      }
//
//  See references/touch-gt911.md for the wiring, timing rationale, the config
//  version rule and the failure modes this driver is written to avoid.
// ============================================================================
#ifndef GT911_H
#define GT911_H

#include <stdint.h>

/* Register map (only the ones a driver needs) */
#define GT911_REG_COMMAND   0x8040u   /* 0x02 = soft reset, 0x00 = end reset  */
#define GT911_REG_CONFIG    0x8047u   /* 184-byte table; [0] = version         */
#define GT911_REG_CHKSUM    0x80FFu   /* two's complement of 0x8047..0x80FE    */
#define GT911_REG_FRESH     0x8100u   /* write 1 to apply the table            */
#define GT911_REG_PRODUCT   0x8140u   /* 4 bytes, "911\0" on a GT911           */
#define GT911_REG_STATUS    0x814Eu   /* bit7 ready, bits[3:0] point count     */
#define GT911_REG_POINT1    0x8150u   /* 8 bytes per point                     */

/* 7-bit addresses: the INT level at the RST rising edge selects one */
#define GT911_ADDR_INT_HIGH 0x14u
#define GT911_ADDR_INT_LOW  0x5Du

#define GT911_MAX_POINTS    5

typedef struct {
    /* TP_RST pin: level 0 = reset asserted, 1 = released */
    void (*rst)(int level);
    /* TP_INT pin: output = 0 -> input (high-Z, no pull), 1 -> driven at 'level' */
    void (*int_pin)(int output, int level);
    /* 7-bit address, 16-bit register, block write (max 16 bytes per call) */
    int  (*write)(uint8_t addr7, uint16_t reg, const uint8_t *buf, int len);
    /* 7-bit address, 16-bit register, block read (1..4 bytes) */
    int  (*read)(uint8_t addr7, uint16_t reg, uint8_t *buf, int len);
    void (*delay_ms)(uint32_t ms);
} gt911_glue_t;

typedef struct {
    uint16_t x;      /* 0..799 on the ACZ702 800x480 panel */
    uint16_t y;      /* 0..479                            */
    uint8_t  size;   /* contact size, panel dependent     */
    uint8_t  id;     /* track id                          */
} gt911_point_t;

/* Reset, select the address, soft reset, apply the version rule.
 * Returns the 7-bit I2C address (0x14 or 0x5D) on success, -1 otherwise.
 * version_out     : configuration version read from 0x8047 (may be NULL)
 * downloaded_out  : 1 if the table was written, 0 if the panel's own table was
 *                   kept (may be NULL) */
int gt911_init(const gt911_glue_t *g, int *version_out, int *downloaded_out);

/* Read the current points. Returns 0..5 (number of points), -1 on bus error.
 * The buffer must hold at least 'max' entries. */
int gt911_poll(const gt911_glue_t *g, uint8_t addr7,
               gt911_point_t *pts, int max);

#endif /* GT911_H */

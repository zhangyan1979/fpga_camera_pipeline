// ============================================================================
//  gt911.c - portable GT911 capacitive-touch driver
//
//  The touch logic below is extracted verbatim from the application that was
//  built, downloaded and verified on an ACZ702 (592 coordinate samples in one
//  capture, 1..4 simultaneous points). Only the board glue was replaced by the
//  gt911_glue_t callbacks, so this file is the same procedure without the
//  Xilinx-specific register poking.
//
//  Deliberate details, each one paid for during debugging:
//    * INT is driven HIGH before reset is released -> address 0x14.
//    * 0x8040 = 0x02 (soft reset) before reading the configuration version,
//      0x8040 = 0x00 (end reset) after it. Dropping either one leaves the
//      controller alive on I2C but not scanning.
//    * the configuration table is only written when the version read back from
//      0x8047 is LOWER than GT911_CFG_VERSION. Unconditionally writing a table
//      from another panel destroys the factory configuration.
//    * the table is written in 16-byte chunks; some host I2C controllers
//      truncate long transfers silently.
// ============================================================================
#include "gt911.h"
#include "gt911_cfg_acz702.h"

#define GT911_CFG_LEN   184
#define GT911_CFG_CHUNK 16

/* -------------------------------------------------------------------------- */
static int wr_block(const gt911_glue_t *g, uint8_t addr, uint16_t reg,
                    const uint8_t *buf, int len)
{
    return g->write(addr, reg, buf, len);
}

/* Write the configuration table plus checksum and Fresh flag. */
static int send_cfg(const gt911_glue_t *g, uint8_t addr, uint8_t mode)
{
    uint8_t  tbl[GT911_CFG_LEN];
    uint8_t  tail[2];
    uint16_t sum = 0;
    int      i;

    for (i = 0; i < GT911_CFG_LEN; i++)
        tbl[i] = GT911_CFG_TBL[i];
    tbl[0] = GT911_CFG_VERSION;          /* make the version explicit */

    for (i = 0; i < GT911_CFG_LEN; i++)
        sum += tbl[i];

    tail[0] = (uint8_t)(~sum + 1);       /* -> 0x80FF */
    tail[1] = mode;                      /* -> 0x8100, 1 = keep it */

    for (i = 0; i < GT911_CFG_LEN; i += GT911_CFG_CHUNK) {
        int n = (GT911_CFG_LEN - i > GT911_CFG_CHUNK)
                    ? GT911_CFG_CHUNK : (GT911_CFG_LEN - i);
        if (wr_block(g, addr, (uint16_t)(GT911_REG_CONFIG + i), &tbl[i], n) != 0)
            return -1;
        g->delay_ms(2);
    }
    g->delay_ms(2);
    if (wr_block(g, addr, GT911_REG_CHKSUM, tail, 2) != 0)
        return -1;
    g->delay_ms(5);
    return 0;
}

/* -------------------------------------------------------------------------- */
static uint8_t probe(const gt911_glue_t *g)
{
    static const uint8_t candidates[2] = { GT911_ADDR_INT_HIGH, GT911_ADDR_INT_LOW };
    uint8_t id[4];
    int     i;

    for (i = 0; i < 2; i++) {
        if (g->read(candidates[i], GT911_REG_PRODUCT, id, 4) == 0 && id[0] == '9')
            return candidates[i];
    }
    return 0;
}

/* -------------------------------------------------------------------------- */
int gt911_init(const gt911_glue_t *g, int *version_out, int *downloaded_out)
{
    uint8_t addr, cmd, ver = 0;

    if (version_out)    *version_out = 0;
    if (downloaded_out) *downloaded_out = 0;

    /* INT high -> address 0x14; reset pulse 10 ms / 10 ms, then INT low */
    g->int_pin(1, 1);
    g->rst(0);
    g->delay_ms(10);
    g->rst(1);
    g->delay_ms(10);
    g->int_pin(1, 0);
    g->delay_ms(100);

    addr = probe(g);
    if (addr == 0)
        return -1;

    /* soft reset before touching the configuration */
    cmd = 0x02;
    if (wr_block(g, addr, GT911_REG_COMMAND, &cmd, 1) != 0)
        return -1;
    g->delay_ms(20);

    /* the version rule */
    if (g->read(addr, GT911_REG_CONFIG, &ver, 1) != 0)
        return -1;
    if (ver < GT911_CFG_VERSION) {
        if (send_cfg(g, addr, 1) != 0)
            return -1;
        g->delay_ms(50);
        if (g->read(addr, GT911_REG_CONFIG, &ver, 1) != 0)
            return -1;
        if (downloaded_out)
            *downloaded_out = 1;
    }
    if (version_out)
        *version_out = ver;

    /* end reset -> the controller starts scanning */
    cmd = 0x00;
    if (wr_block(g, addr, GT911_REG_COMMAND, &cmd, 1) != 0)
        return -1;
    g->delay_ms(50);

    return (int)addr;
}

/* -------------------------------------------------------------------------- */
int gt911_poll(const gt911_glue_t *g, uint8_t addr7,
               gt911_point_t *pts, int max)
{
    uint8_t sts = 0, zero = 0, raw[4];
    int     n, i;

    if (g->read(addr7, GT911_REG_STATUS, &sts, 1) != 0)
        return -1;
    if (!(sts & 0x80))
        return 0;                        /* nothing new */

    /* release the buffer before anything else, or the next event never comes */
    if (wr_block(g, addr7, GT911_REG_STATUS, &zero, 1) != 0)
        return -1;

    n = sts & 0x0F;
    if (n > max)
        n = max;

    for (i = 0; i < n; i++) {
        if (g->read(addr7, (uint16_t)(GT911_REG_POINT1 + 8 * i), raw, 4) != 0)
            return -1;
        pts[i].x = (uint16_t)(((uint16_t)raw[1] << 8) | raw[0]);
        pts[i].y = (uint16_t)(((uint16_t)raw[3] << 8) | raw[2]);
        pts[i].size = 0;
        pts[i].id   = 0;
    }
    return n;
}

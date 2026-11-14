// =============================================================================
//  main.c — ACZ702 camera pipeline (OV5640 -> DDR3 -> TFT), PS side
//
//  The PL does all of the video work: OV5640 DVP capture -> tagged 64-bit pixel
//  words -> processing stage -> DDR3 double buffer through S_AXI_HP0 -> 33.3 MHz
//  RGB565 panel timing.  The Cortex-A9 only
//
//      * initialises DDR3 and the clocks (ps7_init, done by the debugger),
//      * writes the 32-bit control word (test pattern, freeze, stage, backlight),
//      * reads back the status words and reports them on UART1,
//      * accepts single-key commands on the console.
//
//  Control word (PL side: ov5640_top.v)
//      ctrl[0]     test pattern instead of the camera image
//      ctrl[1]     freeze frame
//      ctrl[4:2]   processing stage: 0 = bypass, 1..7 = populated slots
//      ctrl[7:5]   stage mode (interpreted by the selected stage)
//      ctrl[15:8]  backlight duty, 0..255 (0 = off)
//      ctrl[31:16] stage parameter (interpreted by the selected stage)
//
//  status_cam
//      [0]     camera register initialisation done
//      [1]     camera streaming (a frame arrived in the last second)
//      [15:8]  camera frames per second (measured in the PL)
//      [31:16] camera frames since boot
//
//  status_disp
//      [15:0]  panel frames since boot
//      [23:16] frames with a missing pixel
//      [31:24] AXI error responses
//
//  status_ext
//      [31:0]  statistic of the selected processing stage (stage-defined; see
//              docs/stage_contract.md and the stage's own header)
// =============================================================================
#include <stdio.h>

#include "xparameters.h"
#include "xil_types.h"
#include "xil_printf.h"
#include "xgpio.h"
#include "xuartps_hw.h"
#include "sleep.h"

// ---- register map -----------------------------------------------------------
#define CTRL_PATTERN    (1u << 0)
#define CTRL_FREEZE     (1u << 1)
#define CTRL_STAGE_SHIFT 2
#define CTRL_STAGE_MASK (0x7u << CTRL_STAGE_SHIFT)
#define CTRL_KNOB_SHIFT 5
#define CTRL_KNOB_MASK  (0x7u << CTRL_KNOB_SHIFT)
#define CTRL_BL_SHIFT   8
#define CTRL_BL_MASK    (0xFFu << CTRL_BL_SHIFT)
#define CTRL_PARAM_SHIFT 16

#define ST_CAM_INIT     (1u << 0)
#define ST_CAM_LIVE     (1u << 1)

#define CAM_FPS(w)      (((w) >> 8)  & 0xFFu)
#define CAM_FRAMES(w)   (((w) >> 16) & 0xFFFFu)
#define DISP_FRAMES(w)  ((w) & 0xFFFFu)
#define DISP_UNDERRUN(w)(((w) >> 16) & 0xFFu)
#define DISP_ERRS(w)    (((w) >> 24) & 0xFFu)

// ---- frame buffers in DDR (must match fb_ddr.v) -----------------------------
#define FB_BASE         0x01800000u
#define FB_BYTES        768000u
#define H_ACTIVE        800
#define V_ACTIVE        480

// ---- processing stages ------------------------------------------------------
// The PL decides what a slot does; this table only names it on the console.
// Keep it in step with stage_mux's NUM_STAGES in ov5640_top.v.
#define NUM_STAGES      8

static const char *const stage_name[NUM_STAGES] = {
    "bypass",
    "lut point op",
    "win3x3",
    "histogram",
    "segment",
    "stage 5",
    "stage 6",
    "stage 7"
};

static XGpio g_ctrl;
static XGpio g_status;
static XGpio g_ext;

static u32 ctrl_word;
static int pattern_on;
static int frozen;
static int bl_duty = 255;
static u32 stage;
static u32 knob;
static u32 param;

static const u8 bl_steps[] = { 255, 153, 77, 26 };
static int bl_idx;

// -----------------------------------------------------------------------------
static int gpio_init(void)
{
    if (XGpio_Initialize(&g_ctrl, XPAR_AXI_GPIO_CTRL_DEVICE_ID) != XST_SUCCESS)
        return XST_FAILURE;
    XGpio_SetDataDirection(&g_ctrl, 1, 0x00000000u);   // all outputs

    if (XGpio_Initialize(&g_status, XPAR_AXI_GPIO_STATUS_DEVICE_ID) != XST_SUCCESS)
        return XST_FAILURE;
    XGpio_SetDataDirection(&g_status, 1, 0xFFFFFFFFu); // channel 1: camera
    XGpio_SetDataDirection(&g_status, 2, 0xFFFFFFFFu); // channel 2: panel

    if (XGpio_Initialize(&g_ext, XPAR_AXI_GPIO_EXT_DEVICE_ID) != XST_SUCCESS)
        return XST_FAILURE;
    XGpio_SetDataDirection(&g_ext, 1, 0xFFFFFFFFu);    // stage statistic

    return XST_SUCCESS;
}

static void ctrl_flush(void)
{
    ctrl_word = (pattern_on ? CTRL_PATTERN : 0u) |
                (frozen     ? CTRL_FREEZE  : 0u) |
                ((stage & 0x7u) << CTRL_STAGE_SHIFT) |
                ((knob  & 0x7u) << CTRL_KNOB_SHIFT) |
                ((u32)bl_duty << CTRL_BL_SHIFT) |
                ((param & 0xFFFFu) << CTRL_PARAM_SHIFT);
    XGpio_DiscreteWrite(&g_ctrl, 1, ctrl_word);
}

static u32 status_cam(void)  { return XGpio_DiscreteRead(&g_status, 1); }
static u32 status_disp(void) { return XGpio_DiscreteRead(&g_status, 2); }
static u32 status_ext(void)  { return XGpio_DiscreteRead(&g_ext, 1); }

// -----------------------------------------------------------------------------
static void print_help(void)
{
    xil_printf("\r\nconsole commands:\r\n");
    xil_printf("  p   test pattern / camera image\r\n");
    xil_printf("  f   freeze / resume the frame buffer\r\n");
    xil_printf("  s   next processing stage (0 = bypass)\r\n");
    xil_printf("  k   next stage mode\r\n");
    xil_printf("  + - stage parameter up / down\r\n");
    xil_printf("  b   cycle the backlight (100/60/30/10 %%)\r\n");
    xil_printf("  i   print the control and status words\r\n");
    xil_printf("  h   this help\r\n\r\n");
}

static void print_status(void)
{
    u32 sc = status_cam();
    u32 sd = status_disp();

    xil_printf("cam init=%u live=%u fps=%u frames=%u | panel frames=%u underruns=%u errs=%u"
               " | bl=%u%% %s%s | %s k=%u p=0x%04X stat=0x%08X\r\n",
               (sc & ST_CAM_INIT) ? 1 : 0,
               (sc & ST_CAM_LIVE) ? 1 : 0,
               (unsigned)CAM_FPS(sc),
               (unsigned)CAM_FRAMES(sc),
               (unsigned)DISP_FRAMES(sd),
               (unsigned)DISP_UNDERRUN(sd),
               (unsigned)DISP_ERRS(sd),
               (unsigned)((bl_duty * 100u + 127u) / 255u),
               pattern_on ? "pattern " : "camera ",
               frozen ? "FROZEN" : "live",
               stage_name[stage & 7u],
               (unsigned)knob,
               (unsigned)param,
               (unsigned)status_ext());
}

static void print_info(void)
{
    u32 sc = status_cam();
    u32 sd = status_disp();

    xil_printf("\r\nresolution      %d x %d RGB565\r\n", H_ACTIVE, V_ACTIVE);
    xil_printf("frame buffer   0x%08X / 0x%08X (%u bytes each)\r\n",
               FB_BASE, FB_BASE + FB_BYTES, FB_BYTES);
    xil_printf("ctrl           0x%08X (pattern=%d freeze=%d stage=%u knob=%u param=0x%04X bl=%u)\r\n",
               ctrl_word, pattern_on, frozen, (unsigned)stage, (unsigned)knob,
               (unsigned)param, (unsigned)bl_duty);
    xil_printf("status_cam     0x%08X (init=%d live=%d fps=%u frames=%u)\r\n",
               sc, (sc & ST_CAM_INIT) ? 1 : 0, (sc & ST_CAM_LIVE) ? 1 : 0,
               (unsigned)CAM_FPS(sc), (unsigned)CAM_FRAMES(sc));
    xil_printf("status_disp    0x%08X (frames=%u underruns=%u axi errs=%u)\r\n",
               sd, (unsigned)DISP_FRAMES(sd), (unsigned)DISP_UNDERRUN(sd),
               (unsigned)DISP_ERRS(sd));
    xil_printf("status_ext     0x%08X (%s, knob=%u, param=0x%04X)\r\n\r\n",
               (unsigned)status_ext(), stage_name[stage & 7u],
               (unsigned)knob, (unsigned)param);
}

// -----------------------------------------------------------------------------
static int console_poll(void)
{
    int acted = 0;

    while (XUartPs_IsReceiveData(XPAR_XUARTPS_0_BASEADDR)) {
        u8 c = (u8)(XUartPs_ReadReg(XPAR_XUARTPS_0_BASEADDR, XUARTPS_FIFO_OFFSET) & 0xFF);

        switch (c) {
        case 'p':
            pattern_on = !pattern_on;
            xil_printf("mode: %s\r\n", pattern_on ? "test pattern" : "camera image");
            ctrl_flush();
            acted = 1;
            break;
        case 'f':
            frozen = !frozen;
            xil_printf("frame %s\r\n", frozen ? "FROZEN" : "running");
            ctrl_flush();
            acted = 1;
            break;
        case 's':
            stage = (stage + 1u) & 0x7u;
            xil_printf("stage %u: %s\r\n", (unsigned)stage, stage_name[stage]);
            ctrl_flush();
            acted = 1;
            break;
        case 'k':
            knob = (knob + 1u) & 0x7u;
            xil_printf("stage %s mode %u\r\n", stage_name[stage], (unsigned)knob);
            ctrl_flush();
            acted = 1;
            break;
        case '+':
        case '=':
            param = (param + 1u) & 0xFFFFu;
            ctrl_flush();
            acted = 1;
            break;
        case '-':
        case '_':
            param = (param - 1u) & 0xFFFFu;
            ctrl_flush();
            acted = 1;
            break;
        case 'b':
            bl_idx = (bl_idx + 1) & 3;
            bl_duty = bl_steps[bl_idx];
            xil_printf("backlight %u%%\r\n", (unsigned)((bl_duty * 100u + 127u) / 255u));
            ctrl_flush();
            acted = 1;
            break;
        case 'i':
            print_info();
            acted = 1;
            break;
        case 'h':
            print_help();
            acted = 1;
            break;
        default:
            break;
        }
    }
    return acted;
}

// -----------------------------------------------------------------------------
int main(void)
{
    unsigned tick = 0;

    xil_printf("\r\n");
    xil_printf("=============================================\r\n");
    xil_printf(" ACZ702 camera pipeline - OV5640 -> DDR3 -> TFT\r\n");
    xil_printf(" %d x %d RGB565, two frame buffers in DDR\r\n", H_ACTIVE, V_ACTIVE);
    xil_printf("=============================================\r\n");

    if (gpio_init() != XST_SUCCESS) {
        xil_printf("ERROR: AXI GPIO init failed\r\n");
        for (;;) { }
    }

    // backlight on, camera image, no freeze, no processing stage
    bl_duty = 255;
    pattern_on = 0;
    frozen = 0;
    stage = 0;
    knob = 0;
    param = 0;
    ctrl_flush();

    print_help();

    // wait for the camera registers to be programmed (the PL does the I2C)
    {
        unsigned wait_ms = 0;
        while (!(status_cam() & ST_CAM_INIT) && wait_ms < 3000) {
            usleep(10000);
            wait_ms += 10;
        }
        if (status_cam() & ST_CAM_INIT)
            xil_printf("OV5640 configured, waiting for the first frames...\r\n");
        else
            xil_printf("WARNING: camera initialisation did not report done\r\n");
    }

    for (;;) {
        usleep(10000);                  // 100 Hz service loop
        tick++;

        console_poll();

        if ((tick % 100) == 0)          // once per second
            print_status();
    }

    return 0;
}

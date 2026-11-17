// Geometry shared by the PS hit test and rtl/menu_overlay.v.
// Both sides must use these numbers; sim/tb_menu_overlay.v checks the PL.
#ifndef MENU_GEOM_H
#define MENU_GEOM_H

#define MENU_PANEL_X0   520
#define MENU_TAB_X0     776
#define MENU_TAB_Y0     200
#define MENU_TAB_W      24
#define MENU_TAB_H      80

#define MENU_TITLE_Y0   8
#define MENU_TITLE_H    32

#define MENU_STAGE_X0   528
#define MENU_STAGE_Y0   48
#define MENU_STAGE_W    264
#define MENU_STAGE_H    36
#define MENU_STAGE_PITCH 40
#define MENU_STAGE_N    5

#define MENU_MODE_X0    528
#define MENU_MODE_Y0    248
#define MENU_MODE_W     63
#define MENU_MODE_H     28
#define MENU_MODE_PITCH 67
#define MENU_MODE_ROW   32

#define MENU_MINUS_X0   528
#define MENU_MINUS_Y0   344
#define MENU_MINUS_W    72
#define MENU_MINUS_H    48

#define MENU_PLUS_X0    712
#define MENU_PLUS_Y0    344
#define MENU_PLUS_W     80
#define MENU_PLUS_H     48

#define MENU_HOLD_TICKS 40   /* 400 ms at the 10 ms poll */
#define MENU_REPEAT_TICKS 12 /* 120 ms */
#define MENU_IDLE_TICKS 400  /* 4 s */

#endif

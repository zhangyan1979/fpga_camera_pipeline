#include "menu.h"
#include "menu_geom.h"

static int in_box(int x, int y, int x0, int y0, int w, int h)
{
    return x >= x0 && x < x0 + w && y >= y0 && y < y0 + h;
}

int menu_knob_valid(int stage, int knob)
{
    if (knob < 0 || knob > 7)
        return 0;
    switch (stage) {
    case 1: /* lut: 6 and 7 are identity again */
    case 2: /* win3x3: 6 and 7 are the box mean again */
        return knob <= 5;
    case 3: /* histogram: 3..7 are pass-through again */
        return knob <= 2;
    case 4: /* segment: knob[2] paints, knob[1:0] rotates the four colours */
        return 1;
    default:
        return 0;
    }
}

menu_hit_t menu_classify(int menu_open, int stage, int x, int y)
{
    menu_hit_t h;
    int i;

    h.kind = MENU_HIT_NONE;
    h.index = 0;

    if (x < 0 || y < 0 || x >= 800 || y >= 480)
        return h;

    if (!menu_open) {
        if (in_box(x, y, MENU_TAB_X0, MENU_TAB_Y0, MENU_TAB_W, MENU_TAB_H))
            h.kind = MENU_HIT_TAB;
        return h;
    }

    if (x < MENU_PANEL_X0) {
        h.kind = MENU_HIT_OUTSIDE;
        return h;
    }

    if (in_box(x, y, MENU_PANEL_X0, MENU_TITLE_Y0, 800 - MENU_PANEL_X0, MENU_TITLE_H)) {
        h.kind = MENU_HIT_TITLE;
        return h;
    }

    for (i = 0; i < MENU_STAGE_N; i++) {
        if (in_box(x, y, MENU_STAGE_X0, MENU_STAGE_Y0 + i * MENU_STAGE_PITCH,
                   MENU_STAGE_W, MENU_STAGE_H)) {
            h.kind = MENU_HIT_STAGE;
            h.index = i;
            return h;
        }
    }

    for (i = 0; i < 8; i++) {
        int col = i % 4;
        int row = i / 4;
        if (menu_knob_valid(stage, i) &&
            in_box(x, y,
                   MENU_MODE_X0 + col * MENU_MODE_PITCH,
                   MENU_MODE_Y0 + row * MENU_MODE_ROW,
                   MENU_MODE_W, MENU_MODE_H)) {
            h.kind = MENU_HIT_MODE;
            h.index = i;
            return h;
        }
    }

    if (in_box(x, y, MENU_MINUS_X0, MENU_MINUS_Y0, MENU_MINUS_W, MENU_MINUS_H)) {
        h.kind = MENU_HIT_MINUS;
        return h;
    }
    if (in_box(x, y, MENU_PLUS_X0, MENU_PLUS_Y0, MENU_PLUS_W, MENU_PLUS_H)) {
        h.kind = MENU_HIT_PLUS;
        return h;
    }
    return h;
}

#include "touch_menu.h"
#include "menu.h"
#include "menu_geom.h"

static int was_down;
static int repeat;
static int idle;
static int held_kind;

static void step_param(uint32_t *param, int kind)
{
    if (kind == MENU_HIT_PLUS)
        *param = (*param + 1u) & 0xFFFFu;
    else
        *param = (*param - 1u) & 0xFFFFu;
}

static int apply_edge(menu_hit_t h, uint32_t *stage, uint32_t *knob,
                      uint32_t *param, int *menu_open)
{
    if (!*menu_open) {
        if (h.kind == MENU_HIT_TAB) {
            *menu_open = 1;
            return 1;
        }
        return 0;
    }

    switch (h.kind) {
    case MENU_HIT_OUTSIDE:
    case MENU_HIT_TITLE:
        *menu_open = 0;
        return 1;
    case MENU_HIT_STAGE:
        *stage = (uint32_t)h.index & 7u;
        return 1;
    case MENU_HIT_MODE:
        *knob = (uint32_t)h.index & 7u;
        return 1;
    case MENU_HIT_MINUS:
    case MENU_HIT_PLUS:
        step_param(param, h.kind);
        return 1;
    default:
        return 0;
    }
}

void touch_menu_reset(void)
{
    was_down = 0;
    repeat = 0;
    idle = 0;
    held_kind = MENU_HIT_NONE;
}

int touch_menu_step(int down, int x, int y,
                    uint32_t *stage, uint32_t *knob, uint32_t *param,
                    int *menu_open)
{
    menu_hit_t h;
    int acted = 0;

    if (down && (x < 0 || y < 0 || x >= 800 || y >= 480))
        return 0;

    if (down) {
        idle = 0;
        h = menu_classify(*menu_open, (int)(*stage & 7u), x, y);
        if (!was_down) {
            repeat = 0;
            held_kind = h.kind;
            acted = apply_edge(h, stage, knob, param, menu_open);
        } else if ((h.kind == MENU_HIT_MINUS || h.kind == MENU_HIT_PLUS) &&
                   h.kind == held_kind) {
            repeat++;
            if (repeat == MENU_HOLD_TICKS ||
                (repeat > MENU_HOLD_TICKS &&
                 ((repeat - MENU_HOLD_TICKS) % MENU_REPEAT_TICKS) == 0)) {
                step_param(param, h.kind);
                acted = 1;
            }
        } else {
            repeat = 0;
        }
        was_down = 1;
    } else {
        was_down = 0;
        repeat = 0;
        held_kind = MENU_HIT_NONE;
        if (*menu_open) {
            idle++;
            if (idle >= MENU_IDLE_TICKS) {
                *menu_open = 0;
                idle = 0;
                acted = 1;
            }
        } else {
            idle = 0;
        }
    }
    return acted;
}

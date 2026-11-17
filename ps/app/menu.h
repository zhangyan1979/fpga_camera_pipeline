#ifndef MENU_H
#define MENU_H

enum {
    MENU_HIT_NONE = 0,
    MENU_HIT_TAB,
    MENU_HIT_TITLE,
    MENU_HIT_STAGE,
    MENU_HIT_MODE,
    MENU_HIT_MINUS,
    MENU_HIT_PLUS,
    MENU_HIT_OUTSIDE
};

typedef struct {
    int kind;
    int index;
} menu_hit_t;

/* 1 when this stage actually implements that knob. Reserved aliases
 * (lut/win 6..7, hist 3..7, every knob of bypass) are not buttons. */
int menu_knob_valid(int stage, int knob);

/* menu_open = 0: only the right-edge tab is a hit.
 * menu_open = 1: x left of the panel is OUTSIDE; buttons return STAGE/MODE/
 * MINUS/PLUS. MODE is only reported for knobs menu_knob_valid accepts. */
menu_hit_t menu_classify(int menu_open, int stage, int x, int y);

#endif

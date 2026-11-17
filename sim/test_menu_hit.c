/* Host check for the PS hit test and the press / repeat / idle rules.
 * Build: gcc -Wall -Wextra -Werror -o test_menu_hit.exe test_menu_hit.c
 *        ../ps/app/menu.c ../ps/app/touch_menu.c
 */
#include <stdio.h>

#include "../ps/app/menu.h"
#include "../ps/app/menu_geom.h"
#include "../ps/app/touch_menu.h"

static int failures;

static void expect_hit(const char *what, int open, int stage, int x, int y,
                       int kind, int index)
{
    menu_hit_t h = menu_classify(open, stage, x, y);
    if (h.kind != kind ||
        ((kind == MENU_HIT_STAGE || kind == MENU_HIT_MODE) && h.index != index)) {
        printf("FAIL %s: (%d,%d) open=%d -> kind %d index %d, expected %d/%d\n",
               what, x, y, open, h.kind, h.index, kind, index);
        failures++;
    }
}

int main(void)
{
    uint32_t stage = 0, knob = 0, param = 0;
    int open = 0;
    int i;

    failures = 0;

    expect_hit("centre closed", 0, 1, 400, 240, MENU_HIT_NONE, 0);
    expect_hit("tab", 0, 1, 780, 220, MENU_HIT_TAB, 0);
    expect_hit("left of tab", 0, 1, 775, 220, MENU_HIT_NONE, 0);
    expect_hit("outside", 1, 1, 400, 240, MENU_HIT_OUTSIDE, 0);
    expect_hit("title", 1, 1, 600, 20, MENU_HIT_TITLE, 0);
    expect_hit("stage 1", 1, 1, 530, 100, MENU_HIT_STAGE, 1);
    expect_hit("hist", 1, 1, 530, 180, MENU_HIT_STAGE, 3);
    expect_hit("segment", 1, 1, 530, 220, MENU_HIT_STAGE, 4);
    expect_hit("lut mode 5", 1, 1, 597, 282, MENU_HIT_MODE, 5);
    expect_hit("lut mode 6", 1, 1, 662, 282, MENU_HIT_NONE, 0);
    expect_hit("hist mode 5", 1, 3, 597, 282, MENU_HIT_NONE, 0);
    expect_hit("hist mode 2", 1, 3, 662, 250, MENU_HIT_MODE, 2);
    expect_hit("bypass mode", 1, 0, 530, 250, MENU_HIT_NONE, 0);
    expect_hit("seg mode 7", 1, 4, 730, 282, MENU_HIT_MODE, 7);
    expect_hit("minus", 1, 1, 540, 360, MENU_HIT_MINUS, 0);
    expect_hit("plus", 1, 1, 720, 360, MENU_HIT_PLUS, 0);
    expect_hit("bad x", 1, 1, 900, 10, MENU_HIT_NONE, 0);

    touch_menu_reset();
    if (!touch_menu_step(1, 780, 220, &stage, &knob, &param, &open) || !open) {
        printf("FAIL open from tab\n");
        failures++;
    }
    touch_menu_step(0, 0, 0, &stage, &knob, &param, &open);
    if (!touch_menu_step(1, 530, 100, &stage, &knob, &param, &open) || stage != 1) {
        printf("FAIL stage select, stage=%u\n", stage);
        failures++;
    }
    touch_menu_step(0, 0, 0, &stage, &knob, &param, &open);
    if (!touch_menu_step(1, 597, 282, &stage, &knob, &param, &open) || knob != 5) {
        printf("FAIL mode select, knob=%u\n", knob);
        failures++;
    }
    touch_menu_step(0, 0, 0, &stage, &knob, &param, &open);

    param = 0;
    if (!touch_menu_step(1, 720, 360, &stage, &knob, &param, &open) || param != 1) {
        printf("FAIL plus edge, param=%u\n", param);
        failures++;
    }
    for (i = 0; i < MENU_HOLD_TICKS - 1; i++)
        touch_menu_step(1, 720, 360, &stage, &knob, &param, &open);
    if (param != 1) {
        printf("FAIL plus repeated early, param=%u\n", param);
        failures++;
    }
    touch_menu_step(1, 720, 360, &stage, &knob, &param, &open);
    if (param != 2) {
        printf("FAIL plus after hold, param=%u\n", param);
        failures++;
    }
    for (i = 0; i < MENU_REPEAT_TICKS - 1; i++)
        touch_menu_step(1, 720, 360, &stage, &knob, &param, &open);
    if (param != 2) {
        printf("FAIL plus between repeats, param=%u\n", param);
        failures++;
    }
    touch_menu_step(1, 720, 360, &stage, &knob, &param, &open);
    if (param != 3) {
        printf("FAIL plus repeat, param=%u\n", param);
        failures++;
    }

    /* sliding off the button stops the repeat */
    touch_menu_step(1, 400, 240, &stage, &knob, &param, &open);
    for (i = 0; i < MENU_HOLD_TICKS + MENU_REPEAT_TICKS; i++)
        touch_menu_step(1, 400, 240, &stage, &knob, &param, &open);
    if (param != 3 || !open) {
        printf("FAIL slide-off changed param=%u open=%d\n", param, open);
        failures++;
    }

    touch_menu_reset();
    open = 1;
    for (i = 0; i < MENU_IDLE_TICKS - 1; i++)
        touch_menu_step(0, 0, 0, &stage, &knob, &param, &open);
    if (!open) {
        printf("FAIL idle closed early\n");
        failures++;
    }
    if (!touch_menu_step(0, 0, 0, &stage, &knob, &param, &open) || open) {
        printf("FAIL idle did not close, open=%d\n", open);
        failures++;
    }

    if (failures == 0) {
        printf("TEST PASS\n");
        return 0;
    }
    printf("TEST FAIL: %d\n", failures);
    return 1;
}

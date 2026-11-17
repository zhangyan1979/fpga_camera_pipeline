#ifndef TOUCH_MENU_H
#define TOUCH_MENU_H

#include <stdint.h>

/* One 10 ms sample. down = 0 is a finger-up.
 * Returns 1 when stage, knob, param or menu_open changed. */
int touch_menu_step(int down, int x, int y,
                    uint32_t *stage, uint32_t *knob, uint32_t *param,
                    int *menu_open);

void touch_menu_reset(void);

#endif

#pragma once
extern int g_devmode;
void devmode_init(void);
const char *devmode_tag(void);
void devmode_on_device(void *device, void *hwnd);
void devmode_patch_pause(void);
void devmode_main(void);            /* main thread */
void devmode_render(void *device);  /* render thread (Present) */

#pragma once
/* emote orbit camera (see ncam.c) */
int ncam_install(void);
int ncam_available(void);
void ncam_set(const float *pivot, float arm, int ignore, float minz);
void ncam_stop(const char *why);

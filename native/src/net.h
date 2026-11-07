#pragma once
#include "rt.h"

#define NET_MAX_PLAYERS 4
#define NET_EVT_MAX 200

typedef struct {
	float x, y, z, pitch, yaw;
	s32 flags;   /* GSC-defined bits: stance, firing, ads, downed, hidden... */
	s32 health;  /* 0..255 */
	s32 weapon;  /* GSC-defined weapon table index */
} Pose;

void net_init(void);
void net_tick(void);              /* call every frame and from builtins; rate-limited internally */
void net_frame_main(void);        /* main-thread-only actions (map loads), called from Present */
void net_leave(void);

int net_active(void);             /* session configured and joined */
int net_is_host(void);
int net_local_slot(void);
int net_num_players(void);
int net_slot_connected(int slot);
const char *net_slot_name(int slot);
int net_slot_ping(int slot);
double net_slot_age(int slot);    /* ms since last pose from that slot */
double net_host_time(void);       /* estimate of the host's clock (ms) */

void net_set_pose(const Pose *p);
int net_get_pose(int slot, Pose *out); /* interpolated; returns 0 if no data */

int net_send_event(const char *txt);   /* reliable, ordered, broadcast to all other players */
int net_pop_event(char *out, int cap); /* "<origin>|<payload>"; system events use origin "s" */

void net_set_map(const char *map, const char *start, int skill);     /* the local level that just loaded */
const char *net_host_map(void);
int net_barrier(void);             /* 1 while waiting for everyone to load the level */

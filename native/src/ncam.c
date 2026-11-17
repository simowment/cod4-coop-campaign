/* Emote orbit camera, computed every rendered frame.
 *
 * CG_CalcViewValues (0x42eaa0) rebuilds the refdef each frame from the predicted playerstate: vieworg = eye,
 * refdefViewAngles/viewaxis = the live (this frame's mouse) view angles. Its one per-frame caller, in
 * CG_DrawActiveFrame, is redirected to a thunk that runs it and then moves vieworg back along the view axis
 * from a pivot (the emote avatar's chest): the view turns exactly with the mouse and the camera swings around
 * the avatar in the same frame, so nothing lags or glides. Everything after the call (fx camera, sound
 * listener, world-to-screen, scene) reads the refdef we wrote. Restoring the normal view = no longer writing:
 * the next frame is first person again.
 *
 * GSC drives it through openfile("coop","emotecam", pivot, arm, ignoreEntnum [, minz]) every 0.05 s and
 * openfile("coop","emotecam") to stop. It switches itself off when the refreshes stop for 500 ms of game time
 * (script ended, level change), when game time goes back (checkpoint load) and when there is no snapshot.
 */
#include "rt.h"
#include "game.h"
#include "ncam.h"

#define CALCVIEW_CALL 0x42f92e /* E8 -> CG_CalcViewValues(eax = localClientNum) in CG_DrawActiveFrame */
#define FN_CalcViewValues 0x42eaa0
#define FN_CG_Trace 0x436600 /* esi = trace_t*, edi = end; cdecl (start, mins, maxs, passEnt, mask) */
#define RD_VIEWORG ((float *)0x720090)
#define RD_AXIS ((float *)0x72009c) /* axis[0] = forward */
#define RD_ANGLES ((float *)0x724110)
#define CL_VIEWANGLES ((float *)0x868728) /* cl.viewangles pitch, yaw (mouse adds here, CL_MouseMove 0x43fd89/0x43fcdd) */
#define FN_AnglesToAxis 0x57f670
#define CG_SNAP (*(void *volatile *)0x6fa5b8)
#define CG_TIME (*(volatile s32 *)0x714b9c)
#define DV_DRAWGUN (*(u8 **)0x6fa10c) /* cg_drawGun dvar_t*, bool current at +0xc */
/* solid + glass + playerclip + monsterclip + 0x800000: every wall the player or an AI cannot walk through,
   thin tarp/plywood included (bullet traces have no clip bits and pass some of them; the killhouse tarp is
   0x8031640: clip + canshootclip 0x40 + ai_nosight 0x1000). A brush that is only player/monster/vehicle/item
   clip (+ detail 0x8000000), e.g. the invisible walls along bog_a's road (0x8010000, 0x8030200), does not
   stop the camera: the trace goes on past it */
#define CAM_MASK 0x830011
#define PURE_CLIP(c) (((c) & ~0x08030600) == 0)
#define CLIP_PASSES 4
#define CLIP_THIN 24.0f /* a clip brush still around this far past where the arm entered it is a volume */
#define LENS_GAP 8.0f   /* keep the lens this far off what stopped the arm */
#define GROW_MIN 60.0f  /* u/s: the arm grows back at least this fast ... */
#define GROW_EASE 6.0f  /* ... and eases in (per second fraction of the remaining length) */
#define MIN_ARM 40.0f   /* turning further toward a wall than this is held (the camera would be inside the avatar) */

typedef struct { float fraction, normal[3]; s32 sflags, contents; void *mat; s32 hitType; u16 hitId, modelIndex; u16 part, group; u8 allsolid, startsolid, walkable, pad; } Trace;

/* the engine calls below are wrapped in out-of-line functions: the asm does not declare the x87 stack clobbered,
   and inlined into ncam_frame gcc (-mfpmath=387) kept live floats in st(n) across the call -> NaN camera */
__attribute__((noinline)) static void cg_trace(Trace *t, const float *start, const float *mins, const float *maxs, const float *end, int pass, int mask)
{
	u32 args[5] = { (u32)start, (u32)mins, (u32)maxs, (u32)pass, (u32)mask };
	u32 *a = args, fn = FN_CG_Trace;
	__asm__ volatile(
		"pushl 16(%%ecx)\n\tpushl 12(%%ecx)\n\tpushl 8(%%ecx)\n\tpushl 4(%%ecx)\n\tpushl (%%ecx)\n\t"
		"call *%%eax\n\taddl $20, %%esp"
		: "+a"(fn), "+c"(a), "+S"(t), "+D"(end) : : "edx", "memory", "cc");
}

/* AnglesToAxis: usercall esi = angles, edx = axis[3][3] out */
__attribute__((noinline)) static void angles_to_axis(const float *angles, float *axis)
{
	u32 fn = FN_AnglesToAxis;
	__asm__ volatile("call *%%eax" : "+a"(fn), "+S"(angles), "+d"(axis) : : "ecx", "memory", "cc");
}

static int g_installed;
static struct {
	int on;
	float pivot[3], arm, minz;
	int ignore;
	s32 refreshTime; /* CG_TIME at the last refresh */
	s32 onTime;      /* CG_TIME when it was switched on */
	float cur;       /* current arm length, < 0 = not placed yet */
	double last;     /* real time of the last frame (arm easing) */
	int gunHidden, crossHidden;   /* we set cg_drawGun 0 */
	int haveGood;    /* last view direction that had room for the camera */
	float goodCl[2], goodRd[3], goodTarget;
	int haveOff;     /* refdef angles - cl.viewangles last frame (the server's delta_angles: setplayerangles) */
	float off[2];
	float pivotWant[3]; /* the pivot eases to the script's latest one (pose height changes, no stepping) */
	int clipSkips;   /* pure-clip brushes passed by the last arm_room */
	int clipThick;   /* ... and thick ones that stopped it */
	int wasHeld;
	float maxOffJump; /* largest frame-to-frame change of the offset below the re-base limit (log) */
	double lastLog, lastHoldLog;
} g;

static float wrap180(float a)
{
	while (a > 180.0f) a -= 360.0f;
	while (a < -180.0f) a += 360.0f;
	return a;
}

static float absf(float a) { return a < 0 ? -a : a; }

/* how far back from the pivot along -fwd the camera can sit */
static float arm_room(const float *fwd, Trace *tr)
{
	float start[3], want[3], mins[3] = { -5, -5, -5 }, maxs[3] = { 5, 5, 5 };
	for (int i = 0; i < 3; i++) want[i] = g.pivot[i] - fwd[i] * g.arm;
	float done = 0; /* arm length already cleared (in front of the current trace start) */
	g.clipSkips = 0;
	g.clipThick = 0;
	for (int pass = 0;; pass++) {
		for (int i = 0; i < 3; i++) start[i] = g.pivot[i] - fwd[i] * done;
		float rest = g.arm - done;
		memset(tr, 0, sizeof *tr);
		if (rest <= 0) { tr->fraction = 1.0f; return g.arm; }
		cg_trace(tr, start, mins, maxs, want, g.ignore, CAM_MASK);
		if (pass > 0 && (tr->allsolid || (tr->startsolid && tr->fraction <= 0.0f)) && !PURE_CLIP(tr->contents)) {
			/* the clip brush we stepped into touches a real wall (bog_a: road clip against a fence 0x8031640):
			   stop where the clip began */
			float target = done - 1.0f - LENS_GAP;
			return target < 0 ? 0 : target;
		}
		if (tr->allsolid) {
			/* never left a brush: inside an invisible clip all the way is still open space */
			if (PURE_CLIP(tr->contents)) { tr->fraction = 1.0f; return g.arm; }
			return 0;
		}
		/* the first pass starts at the avatar's chest (open space: the player stood there); later passes start
		   inside the clip brush they step through, so startsolid is expected there */
		if (pass == 0 && tr->startsolid && !PURE_CLIP(tr->contents)) return 0;
		if (tr->fraction >= 1.0f) return g.arm;
		float hit = done + rest * tr->fraction;
		if (PURE_CLIP(tr->contents) && pass < CLIP_PASSES) {
			/* a thin clip sheet (an invisible wall) is skipped; a thick clip volume is a prop's collision (bog_a's
			   cars are wrapped in player clip, the models themselves do not stop traces): behind it the prop would
			   hide the avatar, so it stops the camera like a wall */
			float probe = hit + CLIP_THIN, zero[3] = { 0, 0, 0 }, pt[3];
			if (probe > g.arm) probe = g.arm;
			for (int i = 0; i < 3; i++) pt[i] = g.pivot[i] - fwd[i] * probe;
			Trace in;
			memset(&in, 0, sizeof in);
			cg_trace(&in, pt, zero, zero, pt, g.ignore, CAM_MASK);
			if (in.startsolid || in.allsolid) {
				g.clipThick++;
				float target = hit - LENS_GAP;
				return target < 0 ? 0 : target;
			}
			g.clipSkips++;
			done = hit + 1.0f; /* step into the clip brush and trace on from there */
			continue;
		}
		float target = hit - LENS_GAP;
		return target < 0 ? 0 : target;
	}
}

static u8 *drawgun_dvar(void)
{
	u8 *d = DV_DRAWGUN;
	if (!d || !*(const char **)d || strcmp(*(const char **)d, "cg_drawGun")) return NULL;
	return d;
}

/* cg_drawCrosshair (bool, current at +0xc): an internal dvar scripts may not change, so the camera hides it */
static u8 *crosshair_dvar(void)
{
	static u8 *d;
	if (!d) {
		u32 fn = FN_Dvar_FindVar;
		const char *name = "cg_drawCrosshair";
		__asm__ volatile("pushl %%ebx; call *%%ecx; addl $4, %%esp"
			: "=a"(d), "+c"(fn) : "b"(name) : "edx", "memory", "cc");
	}
	if (!d || !*(const char **)d || strcmp(*(const char **)d, "cg_drawCrosshair")) return NULL;
	return d;
}

static void gun_hide(void)
{
	u8 *x = crosshair_dvar();
	if (!g.crossHidden && x && x[0xc]) { x[0xc] = 0; g.crossHidden = 1; }
	u8 *d = drawgun_dvar();
	if (g.gunHidden || !d || !d[0xc]) return; /* already hidden by someone else: leave it to them */
	d[0xc] = 0;
	g.gunHidden = 1;
}

static void gun_show(void)
{
	u8 *x = crosshair_dvar();
	if (g.crossHidden) { g.crossHidden = 0; if (x && !x[0xc]) x[0xc] = 1; }
	u8 *d = drawgun_dvar();
	if (!g.gunHidden) return;
	g.gunHidden = 0;
	if (d && !d[0xc]) d[0xc] = 1;
}

static void cam_off(const char *why)
{
	if (!g.on) return;
	g.on = 0;
	gun_show();
	logf("ncam: off (%s)", why);
}

int ncam_available(void) { return g_installed; }

void ncam_set(const float *pivot, float arm, int ignore, float minz)
{
	if (!g_installed) return;
	int was = g.on;
	for (int i = 0; i < 3; i++) {
		g.pivotWant[i] = pivot[i];
		if (!was) g.pivot[i] = pivot[i];
	}
	g.arm = arm < 0 ? 0 : arm;
	g.ignore = ignore;
	g.minz = minz;
	g.refreshTime = CG_TIME;
	if (!was) {
		g.on = 1;
		g.cur = -1;
		g.haveGood = 0;
		g.haveOff = 0;
		g.onTime = CG_TIME;
		g.last = now_ms();
		gun_hide();
		logf("ncam: on pivot %f %f %f arm %f ignore %d minz %f t %d", pivot[0], pivot[1], pivot[2], arm, ignore, minz, CG_TIME);
	}
}

void ncam_stop(const char *why) { cam_off(why); }

void ncam_frame(void) __asm__("coop_ncam_frame");
void ncam_frame(void)
{
	if (!g.on) return;
	if (!CG_SNAP) { cam_off("no snapshot"); return; }
	s32 now = CG_TIME;
	if (now < g.refreshTime) { cam_off("game time went back (checkpoint or level load)"); return; }
	if (now - g.refreshTime > 500) { cam_off("no refresh from script"); return; }
	double t = now_ms();
	float dt = (float)((t - g.last) / 1000.0);
	g.last = t;
	if (dt < 0) dt = 0;
	if (dt > 0.1f) dt = 0.1f;

	/* the pivot follows the avatar's pose height (kneel, lie down) slowly: no stepping at the 20 Hz refreshes */
	float pk = 3.0f * dt;
	if (pk > 1.0f) pk = 1.0f;
	for (int i = 0; i < 3; i++) g.pivot[i] += (g.pivotWant[i] - g.pivot[i]) * pk;

	/* refdef angles = cl.viewangles (mouse) + the playerstate's delta_angles. A setplayerangles (script) moves
	   only the delta: when it jumps, the view was re-based and a held "good" snapshot is stale */
	float offP = wrap180(RD_ANGLES[0] - CL_VIEWANGLES[0]), offY = wrap180(RD_ANGLES[1] - CL_VIEWANGLES[1]);
	int rebased = g.haveOff && (absf(wrap180(offP - g.off[0])) > 2.0f || absf(wrap180(offY - g.off[1])) > 2.0f);
	if (g.haveOff) {
		float j = absf(wrap180(offP - g.off[0])) + absf(wrap180(offY - g.off[1]));
		if (j > g.maxOffJump && !rebased) g.maxOffJump = j;
	}
	if (rebased) logf("ncam: view re-based by the server (%f %f -> %f %f): hold reset", g.off[0], g.off[1], offP, offY);
	g.off[0] = offP;
	g.off[1] = offY;
	g.haveOff = 1;

	const float *fwd = RD_AXIS;
	Trace tr;
	float target = arm_room(fwd, &tr);
	int held = 0;
	/* the script turns the view to face the avatar as it starts us; that reaches the client a frame or two later:
	   until then place the camera at once and do not take those angles as a "good" direction */
	int settling = now - g.onTime < 200;
	if (settling) { g.cur = -1; g.haveGood = 0; }
	else if (rebased) g.haveGood = 0; /* take the script's new direction as it is (below) */
	if (!settling && g.haveGood && target < MIN_ARM && target < g.goodTarget) {
		/* no room this way (avatar against a wall): the view stops where it still had room, as if the mouse
		   hit an edge; turning back the other way keeps orbiting. Undo this frame's turn at the source too.
		   No tolerance here: a slow turn must not walk the stored direction toward the wall a bit per frame */
		CL_VIEWANGLES[0] = g.goodCl[0];
		CL_VIEWANGLES[1] = g.goodCl[1];
		RD_ANGLES[0] = g.goodRd[0];
		RD_ANGLES[1] = g.goodRd[1];
		RD_ANGLES[2] = g.goodRd[2];
		angles_to_axis(RD_ANGLES, RD_AXIS);
		target = arm_room(fwd, &tr);
		/* the room at the held direction itself shrank (a door, the pivot easing down): that is the new limit,
		   or every direction would stay held */
		if (target < g.goodTarget - 2.0f) g.goodTarget = target;
		held = 1;
	} else if (!settling) {
		g.haveGood = 1;
		g.goodCl[0] = CL_VIEWANGLES[0];
		g.goodCl[1] = CL_VIEWANGLES[1];
		g.goodRd[0] = RD_ANGLES[0];
		g.goodRd[1] = RD_ANGLES[1];
		g.goodRd[2] = RD_ANGLES[2];
		g.goodTarget = target;
	}
	/* in at once (never look through a wall), back out smoothly (no popping); rotation itself never waits */
	if (g.cur < 0 || target <= g.cur) g.cur = target;
	else {
		float step = (target - g.cur) * GROW_EASE * dt;
		if (step < GROW_MIN * dt) step = GROW_MIN * dt;
		g.cur += step;
		if (g.cur > target) g.cur = target;
	}
	float cam[3];
	for (int i = 0; i < 3; i++) cam[i] = g.pivot[i] - fwd[i] * g.cur;
	if (cam[2] < g.minz) cam[2] = g.minz; /* never under the floor */
	RD_VIEWORG[0] = cam[0];
	RD_VIEWORG[1] = cam[1];
	RD_VIEWORG[2] = cam[2];

	if (held != g.wasHeld && t - g.lastHoldLog > 250.0) {
		g.lastHoldLog = t;
		logf("ncam: %s at %f %f (good room %f, here %f)", held ? "hold" : "release", RD_ANGLES[0], RD_ANGLES[1], g.goodTarget, target);
	}
	g.wasHeld = held;
	if (t - g.lastLog > 1000.0) {
		g.lastLog = t;
		logf("ncam: ang %f %f frac %f hit %d/%d ss %d contents %x clipskip %d thick %d arm %f/%f good %f held %d offjump %f pivotz %f cam %f %f %f",
		     RD_ANGLES[0], RD_ANGLES[1], tr.fraction, tr.hitType, tr.hitId, tr.startsolid, tr.contents, g.clipSkips, g.clipThick, g.cur, target,
		     g.goodTarget, held, g.maxOffJump, g.pivot[2], cam[0], cam[1], cam[2]);
		g.maxOffJump = 0;
	}
}

void ncam_thunk(void) __asm__("coop_ncam_thunk");
__asm__(
	".text\n"
	"coop_ncam_thunk:\n"
	"	movl $0x42eaa0, %ecx\n"
	"	call *%ecx\n" /* eax (localClientNum) passed through untouched */
	"	call coop_ncam_frame\n"
	"	ret\n");

int ncam_install(void)
{
	u8 *p = (u8 *)CALCVIEW_CALL;
	if (p[0] != 0xE8 || (u32)(CALCVIEW_CALL + 5 + *(s32 *)(p + 1)) != FN_CalcViewValues) return 0;
	u32 old;
	if (!VirtualProtect(p, 5, 0x40, &old)) return 0;
	*(s32 *)(p + 1) = (s32)((u32)ncam_thunk - (CALCVIEW_CALL + 5));
	VirtualProtect(p, 5, old, &old);
	g_installed = 1;
	return 1;
}

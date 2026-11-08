/* GSC <-> native bridge: replaces six compiled-out builtins (ret stubs in retail iw3sp 1.0).
 *
 *   openfile("coop" [, cmd [, arg]])  -> control/query, see below. Any other first arg -> -1 (stock "file failed")
 *   fprintln(str)                     -> send reliable event to all other players; returns 1/0
 *   freadln()                         -> next inbound event "<origin>|<payload>" or ""
 *   fprintfields(x,y,z,pitch,yaw,flags,health,weapon) -> local pose for the 20 Hz snapshot
 *   fgetarg(slot, field)              -> float from interpolated remote pose (fields below)
 *   closefile("coop")                 -> leave the session
 *
 * Every param is copied out before a return value is pushed (pushing frees the args).
 */
#include "bridge.h"
#include "game.h"
#include "net.h"

int g_forceUnpause = 1;
static int g_as = -1; /* openfile("coop","as",slot): the next fprintln/fprintfields speaks for that bot slot */

static int is_coop_arg0(void)
{
	return scr_nparams() >= 1 && scr_type(0) == VT_STRING && !strcmp(scr_str(0), "coop");
}

static void bi_openfile(void)
{
	char cmd[32], arg[256];
	int iarg = 0, argType;
	if (!is_coop_arg0()) { scr_add_int(-1); return; }
	strlcpy_(cmd, scr_nparams() >= 2 ? scr_str(1) : "", sizeof cmd);
	argType = scr_type(2);
	strlcpy_(arg, argType == VT_STRING ? scr_str(2) : "", sizeof arg);
	iarg = scr_int(2);

	if (!cmd[0]) { scr_add_int(net_local_slot()); return; }
	if (!strcmp(cmd, "level")) {
		char start[64];
		strlcpy_(start, scr_type(3) == VT_STRING ? scr_str(3) : "", sizeof start);
		net_set_map(arg, start, scr_nparams() >= 5 ? scr_int(4) : -1); scr_add_int(net_local_slot()); return;
	}
	if (!strcmp(cmd, "host")) { scr_add_int(net_active() ? net_is_host() : 1); return; }
	if (!strcmp(cmd, "active")) { scr_add_int(net_active()); return; }
	if (!strcmp(cmd, "count")) { scr_add_int(net_num_players()); return; }
	if (!strcmp(cmd, "max")) { scr_add_int(NET_MAX_PLAYERS); return; }
	if (!strcmp(cmd, "connected")) { scr_add_int(net_slot_connected(iarg)); return; }
	if (!strcmp(cmd, "name")) { scr_add_string(net_slot_name(iarg)); return; }
	if (!strcmp(cmd, "ping")) { scr_add_int(net_slot_ping(iarg)); return; }
	if (!strcmp(cmd, "hostmap")) { scr_add_string(net_host_map()); return; }
	if (!strcmp(cmd, "htime")) { scr_add_int((int)net_host_time()); return; }
	if (!strcmp(cmd, "log")) { logf("gsc: %s", arg); scr_add_int(1); return; }
	if (!strcmp(cmd, "cmd")) {
		char c[300]; fmt(c, sizeof c, "%s\n", arg);
		logf("gsc cmd: %s", arg);
		cbuf_add_text(c); scr_add_int(1); return;
	}
	if (!strcmp(cmd, "unpause")) { g_forceUnpause = iarg; scr_add_int(1); return; }
	if (!strcmp(cmd, "barrier")) { scr_add_int(net_barrier()); return; }
	/* level time heartbeat; returns the previous value. A smaller value than last time means a save was loaded */
	if (!strcmp(cmd, "tick")) { static int last; int prev = last; last = iarg; scr_add_int(prev); return; }
	if (!strcmp(cmd, "bots")) { scr_add_int(net_bot_mask()); return; }
	if (!strcmp(cmd, "isbot")) { scr_add_int(net_is_bot(iarg)); return; }
	if (!strcmp(cmd, "as")) { g_as = net_is_bot(iarg) ? iarg : -1; scr_add_int(g_as >= 0); return; }
	if (!strcmp(cmd, "version")) { scr_add_string(COOP_NATIVE_VERSION); return; }
	scr_add_int(-2);
}

static void bi_closefile(void)
{
	if (!is_coop_arg0()) return; /* stock closefile(int) */
	net_leave();
}

static void bi_fprintln(void)
{
	char txt[NET_EVT_MAX + 1];
	if (scr_nparams() != 1 || scr_type(0) != VT_STRING) { scr_add_int(0); return; }
	strlcpy_(txt, scr_str(0), sizeof txt);
	net_tick();
	if (g_as >= 0) { int s = g_as; g_as = -1; scr_add_int(net_bot_event(s, txt)); return; }
	scr_add_int(net_send_event(txt));
}

static void bi_freadln(void)
{
	char txt[NET_EVT_MAX + 8];
	net_tick();
	net_pop_event(txt, sizeof txt);
	scr_add_string(txt);
}

static void bi_fprintfields(void)
{
	Pose p;
	if (scr_nparams() < 8) return;
	p.x = scr_float(0); p.y = scr_float(1); p.z = scr_float(2);
	p.pitch = scr_float(3); p.yaw = scr_float(4);
	p.flags = scr_int(5); p.health = scr_int(6); p.weapon = scr_int(7);
	if (g_as >= 0) { net_bot_pose(g_as, &p); g_as = -1; return; }
	net_set_pose(&p);
}

/* fields: 0 x, 1 y, 2 z, 3 pitch, 4 yaw, 5 flags, 6 health, 7 weapon, 8 connected, 9 ping, 10 pose age ms */
static void bi_fgetarg(void)
{
	int slot = scr_int(0), field = scr_int(1);
	Pose p;
	float v = 0.0f;
	int have = net_get_pose(slot, &p);
	switch (field) {
	case 0: v = have ? p.x : 0; break;
	case 1: v = have ? p.y : 0; break;
	case 2: v = have ? p.z : 0; break;
	case 3: v = have ? p.pitch : 0; break;
	case 4: v = have ? p.yaw : 0; break;
	case 5: v = have ? (float)p.flags : 0; break;
	case 6: v = have ? (float)p.health : 0; break;
	case 7: v = have ? (float)p.weapon : 0; break;
	case 8: v = (float)net_slot_connected(slot); break;
	case 9: v = (float)net_slot_ping(slot); break;
	case 10: { double a = net_slot_age(slot); v = a > 1e8 ? 1e8f : (float)a; break; }
	}
	scr_add_float(v);
}

typedef struct { const char *name; void (*fn)(void); int dev; } BuiltinEntry;

static int patch_one(u32 va, const char *name, void (*fn)(void))
{
	BuiltinEntry *e = (BuiltinEntry *)va;
	if (!e->name || strcmp(e->name, name) != 0) { logf("bridge: table entry %x is not '%s'", va, name); return 0; }
	if ((u32)e->fn != STUB_RET) { logf("bridge: '%s' fn %p is not the stub", name, e->fn); return 0; }
	e->fn = fn;
	e->dev = 0;
	return 1;
}

int bridge_verify_exe(void)
{
	u8 *base = (u8 *)GetModuleHandleA(NULL);
	if ((u32)base != 0x400000) return 0;
	/* PE header: only iw3sp 1.0 (TimeDateStamp 2007-10-04, SizeOfImage) gets patched; everything else is passthrough */
	u32 pe = *(u32 *)(base + 0x3c);
	if (pe > 0x1000 || *(u32 *)(base + pe) != 0x4550) return 0;
	if (*(u32 *)(base + pe + 8) != IW3SP_TIMESTAMP) return 0;
	if (*(u8 *)STUB_RET != 0xC3) return 0;
	static const struct { u32 va; const char *n; } t[] = {
		{ BT_OPENFILE, "openfile" }, { BT_CLOSEFILE, "closefile" }, { BT_FPRINTLN, "fprintln" },
		{ BT_FPRINTFIELDS, "fprintfields" }, { BT_FREADLN, "freadln" }, { BT_FGETARG, "fgetarg" },
	};
	for (int i = 0; i < 6; i++) {
		BuiltinEntry *e = (BuiltinEntry *)t[i].va;
		if (!e->name || strcmp(e->name, t[i].n) != 0) return 0;
	}
	return 1;
}

/* Developer-only builtins that are fully implemented in retail; we just clear the dev flag.
   getentnum (method) / getentbynum (function) give coop a variable-free entity id for map entities. */
static int enable_dev_builtin(u32 va, const char *name)
{
	BuiltinEntry *e = (BuiltinEntry *)va;
	if (!e->name || strcmp(e->name, name) != 0 || e->dev != 1) { logf("bridge: %x is not dev builtin '%s'", va, name); return 0; }
	/* the method table lives in .rdata: unprotect around the write */
	u32 old;
	if (!VirtualProtect(&e->dev, 4, 0x04 /* PAGE_READWRITE */, &old)) { logf("bridge: VirtualProtect failed for '%s'", name); return 0; }
	e->dev = 0;
	VirtualProtect(&e->dev, 4, old, &old);
	return 1;
}

int bridge_install(void)
{
	int ok = 1;
	ok &= enable_dev_builtin(0x680b94, "getentnum");
	ok &= enable_dev_builtin(0x6ddee4, "getentbynum");
	ok &= patch_one(BT_OPENFILE, "openfile", bi_openfile);
	ok &= patch_one(BT_CLOSEFILE, "closefile", bi_closefile);
	ok &= patch_one(BT_FPRINTLN, "fprintln", bi_fprintln);
	ok &= patch_one(BT_FPRINTFIELDS, "fprintfields", bi_fprintfields);
	ok &= patch_one(BT_FREADLN, "freadln", bi_freadln);
	ok &= patch_one(BT_FGETARG, "fgetarg", bi_fgetarg);
	return ok;
}

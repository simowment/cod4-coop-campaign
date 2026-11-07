/* d3d9.dll proxy for iw3sp.exe: forwards Direct3DCreate9 to the system d3d9, installs the GSC bridge,
 * and hooks IDirect3DDevice9::Present to run networking every rendered frame (also while paused/loading menus). */
#include "rt.h"
#include "game.h"
#include "net.h"
#include "bridge.h"
#include "devmode.h"

typedef void *(WINAPI *Direct3DCreate9_t)(u32);
typedef s32 (WINAPI *CreateDevice_t)(void *self, u32 adapter, u32 type, void *hwnd, u32 flags, void *pp, void **out);
typedef s32 (WINAPI *Present_t)(void *self, const void *src, const void *dst, void *hwnd, const void *dirty);

static Direct3DCreate9_t real_create;
static CreateDevice_t real_CreateDevice;
static Present_t real_Present;
typedef s32 (WINAPI *SCPresent_t)(void *self, const void *src, const void *dst, void *hwnd, const void *dirty, u32 flags);
static SCPresent_t real_SCPresent;
static int g_enabled, g_started;
static void *g_device;

static int patch_vtable(void **vt, int idx, void *fn, void **orig)
{
	u32 old;
	if (vt[idx] == fn) return 1;
	if (!VirtualProtect(&vt[idx], sizeof(void *), 0x40 /* PAGE_EXECUTE_READWRITE */, &old)) return 0;
	*orig = vt[idx];
	vt[idx] = fn;
	VirtualProtect(&vt[idx], sizeof(void *), old, &old);
	return 1;
}

/* Game main thread, once per frame (after Com_Frame). Everything that touches game state - network,
   Cbuf, dvars - runs here. NOT in Present: iw3sp presents from its render backend thread, and the main
   thread may be spin-waiting on that thread (a SendMessage-style call from there deadlocks). */
static void main_tick(void)
{
	if (!g_enabled) return;
	static int once;
	if (!once) { once = 1; cbuf_add_text("set loc_warnings 0\n"); } /* else plain-text HUD names show "UNLOCALIZED:" (script may not set it) */
	/* +set coop_startmap X: start at the menu and load X from there. Loading a map straight from the
	   command line can stall before the first server frame when the window is not focused. */
	static int startDone; static double t0;
	if (!startDone) {
		if (t0 == 0.0) t0 = now_ms();
		if (now_ms() - t0 > 4000.0) {
			char m[64], cmd[96];
			startDone = 1;
			if (cmdline_get("coop_startmap", m, sizeof m) && m[0]) {
				int ok = 1;
				for (char *q = m; *q; q++) if (!((*q >= 'a' && *q <= 'z') || (*q >= '0' && *q <= '9') || *q == '_')) ok = 0;
				if (ok) { fmt(cmd, sizeof cmd, "map %s\n", m); logf("proxy: start map %s", m); cbuf_add_text(cmd); }
			}
		}
	}
	net_frame_main();
	devmode_main();
	if (net_barrier()) dvar_set_int("cl_paused", 1);
	else if (g_devmode || (g_forceUnpause && net_active() && net_num_players() > 1)) dvar_set_int("cl_paused", 0);
}

#define MAINLOOP_CALL 0x5956e4  /* E8 rel32 -> 0x5356a0 (per-frame body) inside the main loop */
#define COM_FRAME     0x5356a0
static void hk_ComFrame(void)
{
	((void (*)(void))COM_FRAME)();
	main_tick();
}

static int install_mainloop_hook(void)
{
	u8 *p = (u8 *)MAINLOOP_CALL;
	if (p[0] != 0xE8 || (u32)(MAINLOOP_CALL + 5 + *(s32 *)(p + 1)) != COM_FRAME) return 0;
	u32 old;
	if (!VirtualProtect(p, 5, 0x40, &old)) return 0;
	*(s32 *)(p + 1) = (s32)((u32)hk_ComFrame - (MAINLOOP_CALL + 5));
	VirtualProtect(p, 5, old, &old);
	return 1;
}

static s32 WINAPI hk_Present(void *self, const void *src, const void *dst, void *hwnd, const void *dirty)
{
	devmode_render(self);
	return real_Present(self, src, dst, hwnd, dirty);
}

/* iw3sp presents through the implicit swap chain, on its render backend thread */
static s32 WINAPI hk_SCPresent(void *self, const void *src, const void *dst, void *hwnd, const void *dirty, u32 flags)
{
	devmode_render(g_device);
	return real_SCPresent(self, src, dst, hwnd, dirty, flags);
}

static s32 WINAPI hk_CreateDevice(void *self, u32 adapter, u32 type, void *hwnd, u32 flags, void *pp, void **out)
{
	s32 hr = real_CreateDevice(self, adapter, type, hwnd, flags, pp, out);
	if (hr >= 0 && out && *out) {
		void **vt = *(void ***)*out;
		g_device = *out;
		devmode_on_device(*out, hwnd);
		if (patch_vtable(vt, 17, (void *)hk_Present, (void **)&real_Present)) logf("proxy: device Present hooked");
		/* IDirect3DDevice9::GetSwapChain is vtable 14; IDirect3DSwapChain9::Present is 3, Release is 2 */
		typedef s32 (WINAPI *GetSwapChain_t)(void *, u32, void **);
		void *sc = NULL;
		if (((GetSwapChain_t)vt[14])(*out, 0, &sc) >= 0 && sc) {
			void **svt = *(void ***)sc;
			if (patch_vtable(svt, 3, (void *)hk_SCPresent, (void **)&real_SCPresent)) logf("proxy: swapchain Present hooked");
			((u32 (WINAPI *)(void *))svt[2])(sc);
		}
	}
	return hr;
}

static void start_once(void)
{
	char path[300];
	if (g_started) return;
	g_started = 1;
	u32 n = GetModuleFileNameA(NULL, path, sizeof path - 32);
	while (n && path[n - 1] != '\\' && path[n - 1] != '/') n--;
	devmode_init();
	if (g_devmode) fmt(path + n, (int)(sizeof path - n), "coop_native_%s.log", devmode_tag());
	else memcpy(path + n, "coop_native.log", 16);
	log_open(path);
	logf("cod4 coop native %s", COOP_NATIVE_VERSION);
	if (!bridge_verify_exe()) { logf("proxy: unsupported iw3sp.exe build, coop disabled (pure d3d9 passthrough)"); return; }
	if (!bridge_install()) { logf("proxy: bridge install failed, coop disabled"); return; }
	logf("proxy: GSC bridge installed");
	if (!install_mainloop_hook()) { logf("proxy: main loop hook failed, coop disabled"); return; }
	devmode_patch_pause();
	logf("proxy: main loop hooked");
	net_init();
	g_enabled = 1;
}

__attribute__((dllexport)) void *WINAPI Direct3DCreate9(u32 sdk)
{
	start_once();
	if (!real_create) {
		char sys[300];
		u32 n = GetSystemDirectoryA(sys, sizeof sys - 16); /* SysWOW64 for a 32-bit process */
		memcpy(sys + n, "\\d3d9.dll", 10);
		HMODULE h = LoadLibraryA(sys);
		if (h) real_create = (Direct3DCreate9_t)GetProcAddress(h, "Direct3DCreate9");
		if (!real_create) { logf("proxy: cannot load %s", sys); return NULL; }
	}
	void *d3d = real_create(sdk);
	if (d3d && g_enabled) {
		void **vt = *(void ***)d3d;
		if (patch_vtable(vt, 16, (void *)hk_CreateDevice, (void **)&real_CreateDevice)) logf("proxy: CreateDevice hooked");
	}
	return d3d;
}

/* test mode: log the game-code return addresses on the exit path (why did the process quit?) */
static void log_exit_stack(void)
{
	u32 *sp; __asm__ volatile("movl %%esp, %0" : "=r"(sp));
	char buf[600]; int n = 0;
	for (int i = 0; i < 3000 && n < 560; i++) {
		u32 v = sp[i];
		if (v >= 0x401000 && v < 0x65d000) n += fmt(buf + n, 600 - n, "%x ", v);
	}
	buf[n] = 0;
	logf("exit path (iw3sp return addresses): %s", buf);
}

BOOL WINAPI DllMain(HMODULE h, u32 reason, void *res)
{
	(void)h;
	if (reason == 1 /* DLL_PROCESS_ATTACH */) {
		char v[64];
		if (cmdline_get("coop_background", v, sizeof v) && v[0] == '1') {
			char path[300], tag[32];
			u32 n = GetModuleFileNameA(NULL, path, sizeof path - 40);
			while (n && path[n - 1] != 92 /* backslash */) n--;
			fmt(path + n, (int)(sizeof path - n), "coop_early_%s.log", cmdline_get("coop_tag", tag, sizeof tag) ? tag : "0");
			log_open(path);
			logf("process attach");
		}
	}
	if (reason == 0 /* DLL_PROCESS_DETACH */) {
		log_exit_stack();
		if (g_enabled && res == NULL) net_leave();
	}
	return 1;
}

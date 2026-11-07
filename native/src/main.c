/* d3d9.dll proxy for iw3sp.exe: forwards Direct3DCreate9 to the system d3d9, installs the GSC bridge,
 * and hooks IDirect3DDevice9::Present to run networking every rendered frame (also while paused/loading menus). */
#include "rt.h"
#include "game.h"
#include "net.h"
#include "bridge.h"

typedef void *(WINAPI *Direct3DCreate9_t)(u32);
typedef s32 (WINAPI *CreateDevice_t)(void *self, u32 adapter, u32 type, void *hwnd, u32 flags, void *pp, void **out);
typedef s32 (WINAPI *Present_t)(void *self, const void *src, const void *dst, void *hwnd, const void *dirty);

static Direct3DCreate9_t real_create;
static CreateDevice_t real_CreateDevice;
static Present_t real_Present;
static int g_enabled, g_started;

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

static s32 WINAPI hk_Present(void *self, const void *src, const void *dst, void *hwnd, const void *dirty)
{
	if (g_enabled) {
		net_frame_main();
		if (g_forceUnpause && net_active() && net_num_players() > 1) dvar_set_int("cl_paused", 0);
	}
	return real_Present(self, src, dst, hwnd, dirty);
}

static s32 WINAPI hk_CreateDevice(void *self, u32 adapter, u32 type, void *hwnd, u32 flags, void *pp, void **out)
{
	s32 hr = real_CreateDevice(self, adapter, type, hwnd, flags, pp, out);
	if (hr >= 0 && out && *out) {
		void **vt = *(void ***)*out;
		if (patch_vtable(vt, 17, (void *)hk_Present, (void **)&real_Present)) logf("proxy: Present hooked");
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
	memcpy(path + n, "coop_native.log", 16);
	log_open(path);
	logf("cod4 coop native %s", COOP_NATIVE_VERSION);
	if (!bridge_verify_exe()) { logf("proxy: unsupported iw3sp.exe build, coop disabled (pure d3d9 passthrough)"); return; }
	if (!bridge_install()) { logf("proxy: bridge install failed, coop disabled"); return; }
	logf("proxy: GSC bridge installed");
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

BOOL WINAPI DllMain(HMODULE h, u32 reason, void *res)
{
	(void)h; (void)res;
	if (reason == 0 /* DLL_PROCESS_DETACH */ && g_enabled && res == NULL) net_leave();
	return 1;
}

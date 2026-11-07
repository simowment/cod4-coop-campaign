/* Background test mode (+set coop_background 1): lets automated tests run the game without touching the
 * user's desktop. Off by default; players never see it.
 *  - the game window is moved off-screen and focus is handed back to whatever window was active
 *  - the game never pauses for lost focus (cl_paused forced to 0 unless the load barrier holds it)
 *  - coop_cmd_<tag>.txt in the game folder: its text is run as console commands, then the file is deleted
 *  - coop_shot_<tag>.req in the game folder: the next frame is saved as coop_shot_<tag>.bmp
 * <tag> is +set coop_tag (default "0"), so several instances can share one game folder. */
#include "rt.h"
#include "game.h"
#include "devmode.h"
int g_devmode;
static void *g_prevFg, *g_gameWnd;

DLLIMPORT u32 WINAPI GetFileAttributesA(const char *);
DLLIMPORT BOOL WINAPI DeleteFileA(const char *);
DLLIMPORT void *WINAPI GetForegroundWindow(void);
DLLIMPORT BOOL WINAPI SetForegroundWindow(void *);
DLLIMPORT BOOL WINAPI SetWindowPos(void *, void *, int, int, int, int, u32);
DLLIMPORT BOOL WINAPI IsWindow(void *);
DLLIMPORT s32 WINAPI SetWindowLongA(void *, int, s32);
DLLIMPORT s32 WINAPI CallWindowProcA(void *, void *, u32, u32, s32);
static void *g_oldProc;
DLLIMPORT BOOL WINAPI PostMessageA(void *, u32, u32, s32);
DLLIMPORT HANDLE WINAPI CreateThread(void *, u32, void *, void *, u32, u32 *);
DLLIMPORT void WINAPI Sleep(u32);

/* Started from a background process the game never gets activated (foreground lock), and an inactive
   iw3sp does not run frames. Keep telling it that it is the active app. Posting is thread-safe. */
static u32 WINAPI activator_thread(void *arg)
{
	(void)arg;
	for (;;) {
		void *w = *(void *volatile *)&g_gameWnd;
		if (w && IsWindow(w)) {
			PostMessageA(w, 0x001C /* WM_ACTIVATEAPP */, 1, 0);
			PostMessageA(w, 0x0006 /* WM_ACTIVATE */, 1 /* WA_ACTIVE */, 0);
		}
		Sleep(2000);
	}
	return 0;
}

/* The game freezes when its window is not the active one. In background mode it is never active (the
   user keeps their focus), so tell the game it still is: rewrite deactivation into activation. Input
   still only reaches the focused window, and +set in_mouse 0 keeps the cursor untouched. */
static s32 WINAPI bg_wndproc(void *h, u32 msg, u32 wp, s32 lp)
{
	switch (msg) {
	case 0x0006: /* WM_ACTIVATE */
		if ((wp & 0xffff) == 0) wp = (wp & 0xffff0000u) | 1; /* WA_INACTIVE -> WA_ACTIVE */
		break;
	case 0x001C: /* WM_ACTIVATEAPP */
		if (!wp) wp = 1;
		break;
	case 0x0086: /* WM_NCACTIVATE */
		if (!wp) wp = 1;
		break;
	case 0x0008: /* WM_KILLFOCUS */
		return 0;
	}
	return CallWindowProcA(g_oldProc, h, msg, wp, lp);
}

static char g_dir[300], g_tag[32];

static double g_lastPoll, g_lastFocus;

typedef u32 (WINAPI *Release_t)(void *);
#define VT(o) (*(void ***)(o))
#define RELEASE(o) ((Release_t)VT(o)[2])(o)

static void path_of(char *out, int cap, const char *stem, const char *ext)
{
	fmt(out, cap, "%s%s_%s%s", g_dir, stem, g_tag, ext);
}

void devmode_init(void)
{
	char v[64];
	u32 n = GetModuleFileNameA(NULL, g_dir, sizeof g_dir - 64);
	while (n && g_dir[n - 1] != '\\' && g_dir[n - 1] != '/') n--;
	g_dir[n] = 0;
	strlcpy_(g_tag, cmdline_get("coop_tag", v, sizeof v) ? v : "0", sizeof g_tag);
	for (char *p = g_tag; *p; p++) if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9'))) *p = '_';
	g_devmode = cmdline_get("coop_background", v, sizeof v) && v[0] == '1';
	if (g_devmode) g_prevFg = GetForegroundWindow(); /* before the game creates its window */
}

const char *devmode_tag(void) { return g_tag; }

/* Background test instances must never pause: the game pauses itself every frame when its window does not
   have focus, and whichever instance pauses inside its own frame order freezes. Turn every
   `push "cl_paused"; mov eax, 1; call Dvar_SetIntByName` into `mov eax, 0`. Test mode only. */
void devmode_patch_pause(void)
{
	static const u32 sites[] = { 0x445e2c, 0x566f25, 0x567b61, 0x567bc5, 0x5c6fe0 };
	int n = 0;
	if (!g_devmode) return;
	for (u32 i = 0; i < sizeof sites / sizeof sites[0]; i++) {
		u8 *p = (u8 *)sites[i];
		if (p[-5] != 0x68 || *(u32 *)(p - 4) != 0x689e40 || p[0] != 0xb8 || *(u32 *)(p + 1) != 1) continue;
		u32 old;
		if (!VirtualProtect(p + 1, 4, 0x40, &old)) continue;
		*(u32 *)(p + 1) = 0;
		VirtualProtect(p + 1, 4, old, &old);
		n++;
	}
	logf("devmode: %d pause sites disabled", n);
}

static void park_window(void)
{
	if (!g_gameWnd || !IsWindow(g_gameWnd)) return;
	/* position comes from vid_xpos/vid_ypos (a virtual monitor); we only give focus back */
	if (GetForegroundWindow() == g_gameWnd && g_prevFg && IsWindow(g_prevFg)) SetForegroundWindow(g_prevFg);
}

void devmode_on_device(void *device, void *hwnd)
{
	(void)device;
	if (!g_devmode) return;
	g_gameWnd = hwnd;
	if (!g_oldProc) {
		g_oldProc = (void *)SetWindowLongA(hwnd, -4 /* GWL_WNDPROC */, (s32)bg_wndproc);
		u32 tid;
		CreateThread(NULL, 0, (void *)activator_thread, NULL, 0, &tid);
	}
	park_window();
	logf("devmode: background window, tag '%s'", g_tag);
}

static int write_file(const char *path, const void *a, u32 an, const void *b, u32 bn)
{
	HANDLE f = CreateFileA(path, 0x40000000, 0, 0, 2, 0x80, 0);
	if (f == INVALID_HANDLE_VALUE) return 0;
	u32 w;
	WriteFile(f, a, an, &w, 0);
	if (b && bn) WriteFile(f, b, bn, &w, 0);
	CloseHandle(f);
	return 1;
}

static void run_cmd_file(void)
{
	char path[340], buf[1100];
	path_of(path, sizeof path, "coop_cmd", ".txt");
	if (GetFileAttributesA(path) == 0xffffffffu) return;
	HANDLE f = CreateFileA(path, 0x80000000, 1, 0, 3, 0x80, 0);
	if (f == INVALID_HANDLE_VALUE) return;
	u32 r = 0;
	ReadFile(f, buf, sizeof buf - 2, &r, 0);
	CloseHandle(f);
	DeleteFileA(path);
	buf[r] = 0;
	for (u32 i = 0; i < r; i++) if (buf[i] == '\r') buf[i] = '\n';
	if (r && buf[r - 1] != '\n') { buf[r] = '\n'; buf[r + 1] = 0; }
	logf("devmode: exec %s", buf);
	cbuf_add_text(buf);
}

/* backbuffer -> system memory -> top-down 32-bit BMP */
static void take_shot(void *dev)
{
	typedef s32 (WINAPI *GetBackBuffer_t)(void *, u32, u32, u32, void **);
	typedef s32 (WINAPI *CreateOffscreen_t)(void *, u32, u32, u32, u32, void **, void *);
	typedef s32 (WINAPI *GetRTData_t)(void *, void *, void *);
	typedef s32 (WINAPI *GetDesc_t)(void *, u32 *);
	typedef s32 (WINAPI *LockRect_t)(void *, s32 *, void *, u32);
	typedef s32 (WINAPI *UnlockRect_t)(void *);
	char path[340];
	void *bb = NULL, *sys = NULL;
	u32 desc[8];
	if (((GetBackBuffer_t)VT(dev)[18])(dev, 0, 0, 0, &bb) < 0 || !bb) { logf("devmode: GetBackBuffer failed"); return; }
	((GetDesc_t)VT(bb)[12])(bb, desc); /* Format, Type, Usage, Pool, MSType, MSQuality, Width, Height */
	u32 fmtc = desc[0], w = desc[6], h = desc[7];
	if (((CreateOffscreen_t)VT(dev)[36])(dev, w, h, fmtc, 2 /* D3DPOOL_SYSTEMMEM */, &sys, NULL) < 0 || !sys) { RELEASE(bb); logf("devmode: offscreen surface failed"); return; }
	void *src = bb, *resolved = NULL;
	if (desc[4] != 0) {
		/* multisampled backbuffer: resolve into a plain render target first (CreateRenderTarget 28, StretchRect 34) */
		typedef s32 (WINAPI *CreateRT_t)(void *, u32, u32, u32, u32, u32, BOOL, void **, void *);
		typedef s32 (WINAPI *StretchRect_t)(void *, void *, void *, void *, void *, u32);
		if (((CreateRT_t)VT(dev)[28])(dev, w, h, fmtc, 0, 0, 0, &resolved, NULL) < 0 || !resolved
			|| ((StretchRect_t)VT(dev)[34])(dev, bb, NULL, resolved, NULL, 0) < 0) {
			logf("devmode: MSAA resolve failed");
			if (resolved) RELEASE(resolved);
			RELEASE(sys); RELEASE(bb); return;
		}
		src = resolved;
	}
	if (((GetRTData_t)VT(dev)[32])(dev, src, sys) < 0) {
		logf("devmode: GetRenderTargetData failed (format %u, ms %u)", fmtc, desc[4]);
		if (resolved) RELEASE(resolved);
		RELEASE(sys); RELEASE(bb); return;
	}
	if (resolved) RELEASE(resolved);
	s32 lr[2];
	if (((LockRect_t)VT(sys)[13])(sys, lr, NULL, 0x10 /* READONLY */) >= 0) {
		static u8 hdr[54];
		u32 rowBytes = w * 4, size = rowBytes * h;
		memset(hdr, 0, sizeof hdr);
		hdr[0] = 'B'; hdr[1] = 'M';
		*(u32 *)(hdr + 2) = 54 + size; *(u32 *)(hdr + 10) = 54;
		*(u32 *)(hdr + 14) = 40; *(s32 *)(hdr + 18) = (s32)w; *(s32 *)(hdr + 22) = -(s32)h;
		*(u16 *)(hdr + 26) = 1; *(u16 *)(hdr + 28) = 32; *(u32 *)(hdr + 34) = size;
		path_of(path, sizeof path, "coop_shot", ".bmp");
		u8 *bits = (u8 *)lr[1];
		if (lr[0] == (s32)rowBytes) write_file(path, hdr, 54, bits, size);
		else {
			/* pitch differs: write row by row */
			HANDLE f = CreateFileA(path, 0x40000000, 0, 0, 2, 0x80, 0);
			if (f != INVALID_HANDLE_VALUE) {
				u32 wr;
				WriteFile(f, hdr, 54, &wr, 0);
				for (u32 y = 0; y < h; y++) WriteFile(f, bits + y * lr[0], rowBytes, &wr, 0);
				CloseHandle(f);
			}
		}
		((UnlockRect_t)VT(sys)[14])(sys);
		logf("devmode: screenshot %ux%u -> %s", w, h, path);
	}
	RELEASE(sys);
	RELEASE(bb);
}

/* main thread, once per game frame: window upkeep and console commands */
void devmode_main(void)
{
	if (!g_devmode) return;
	double now = now_ms();
	if (now - g_lastFocus > 1000.0) { g_lastFocus = now; park_window(); }
	if (now - g_lastPoll < 200.0) return;
	g_lastPoll = now;
	run_cmd_file();
}

/* render thread, inside Present: the only safe place to read the backbuffer */
static double g_lastShotPoll;
void devmode_render(void *dev)
{
	if (!g_devmode || !dev) return;
	double now = now_ms();
	if (now - g_lastShotPoll < 200.0) return;
	g_lastShotPoll = now;
	char req[340];
	path_of(req, sizeof req, "coop_shot", ".req");
	if (GetFileAttributesA(req) != 0xffffffffu) {
		DeleteFileA(req);
		take_shot(dev);
	}
}

/* Offline protocol test: runs net.c in a console process with the game calls stubbed.
 *   harness.exe +set coop_host 1 +set coop_wait 2 +set coop_name Host  -log host.log -map bog_a
 *   harness.exe +set coop_connect 127.0.0.1 +set coop_name Client     -log client.log
 * Each sends a pose that moves in a circle and one reliable event per second; logs what it receives.
 */
#include "../src/rt.h"
#include "../src/net.h"

DLLIMPORT void WINAPI Sleep(u32);
DLLIMPORT void WINAPI ExitProcess(u32);

static char g_map[64];
static int g_loadPending;
void harness_cbuf(const char *s)
{
	logf("CBUF: %s", s);
	/* "map X\n" -> pretend the level loaded a moment later */
	if (!strncmp(s, "map ", 4)) {
		int i = 0; s += 4;
		while (*s && *s != '\n' && i < 63) g_map[i++] = *s++;
		g_map[i] = 0;
		g_loadPending = 1;
	}
}

static float fsin(float x) { /* small taylor, |x| <= pi */ float x2 = x * x; return x * (1 - x2 / 6 * (1 - x2 / 20 * (1 - x2 / 42))); }

void harness_main(void)
{
	char v[128];
	log_open(cmdline_get("log", v, sizeof v) ? v : "harness.log");
	extern int harness_loss_pct;
	if (cmdline_get("loss", v, sizeof v)) harness_loss_pct = atoi_(v);
	net_init();
	int isHost = cmdline_get("coop_host", v, sizeof v) != NULL;
	if (isHost && cmdline_get("map", v, sizeof v)) { strlcpy_(g_map, v, sizeof g_map); g_loadPending = 1; }
	double start = now_ms(), lastEvt = start, lastLog = start;
	int n = 0, inLevel = 0;
	while (now_ms() - start < 12000.0) {
		net_frame_main();
		if (g_loadPending && now_ms() - start > 300.0) {
			g_loadPending = 0; inLevel = 1;
			net_set_map(g_map, "");
			logf("LEVEL loaded %s, barrier=%d", g_map, net_barrier());
		}
		if (inLevel && !net_barrier()) {
			double t = (now_ms() - start) / 1000.0;
			float a = (float)(t - (int)(t / 6.283) * 6.283) - 3.1415f;
			Pose p = { 100.0f * fsin(a), 50.0f, 10.0f, 0.0f, (float)(t * 30.0), 0, 100, 0 };
			net_set_pose(&p);
			if (now_ms() - lastEvt > 100.0) {
				char e[64]; fmt(e, sizeof e, "%s|T|evt%d", g_map, n++);
				net_send_event(e);
				lastEvt = now_ms();
			}
		}
		char in[256];
		while (net_pop_event(in, sizeof in)) logf("RECV %s", in);
		if (now_ms() - lastLog > 500.0) {
			lastLog = now_ms();
			for (int s = 0; s < NET_MAX_PLAYERS; s++) {
				Pose q;
				if (s != net_local_slot() && net_slot_connected(s) && net_get_pose(s, &q))
					logf("POSE slot %d (%s) x=%f yaw=%f ping=%d age=%f", s, net_slot_name(s), q.x, q.yaw, net_slot_ping(s), net_slot_age(s));
			}
		}
		Sleep(5);
	}
	logf("players=%d slot=%d barrier=%d", net_num_players(), net_local_slot(), net_barrier());
	net_leave();
	ExitProcess(0);
}

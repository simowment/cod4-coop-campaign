/* Coop session: UDP star topology, host (slot 0) relays. Runs on the game's main thread, non-blocking. */
#include "net.h"
#include "game.h"

/* ---- winsock (resolved at runtime; the exe imports none) ---- */
typedef struct { u16 family; u16 port; u32 addr; u8 zero[8]; } sockaddr_in;
typedef struct { u16 h_addrtype_dummy; } hostent_dummy;
static int (WINAPI *pWSAStartup)(u16, void *);
static u32 (WINAPI *psocket)(int, int, int);
static int (WINAPI *pbind)(u32, const void *, int);
static int (WINAPI *psendto)(u32, const void *, int, int, const void *, int);
static int (WINAPI *precvfrom)(u32, void *, int, int, void *, int *);
static int (WINAPI *pioctlsocket)(u32, s32, u32 *);
static int (WINAPI *pclosesocket)(u32);
static u32 (WINAPI *pinet_addr)(const char *);
static void *(WINAPI *pgethostbyname)(const char *);
static int (WINAPI *pWSAGetLastError)(void);

static u16 bswap16(u16 v) { return (u16)((v >> 8) | (v << 8)); }

/* ---- protocol ---- */
#define MAGIC 0x3443
#define PROTO 1
enum { PT_HELLO = 1, PT_WELCOME = 2, PT_REJECT = 3, PT_DATA = 4, PT_BYE = 5 };
#define SEND_INTERVAL 50.0
#define HELLO_INTERVAL 500.0
#define TIMEOUT_MS 30000.0
#define INTERP_DELAY 100.0
#define MAX_PACKET 1200
#define RQ 256 /* reliable queue size */

#pragma pack(push, 1)
typedef struct { u16 magic; u8 ver; u8 type; u32 session; u8 slot; u8 nposes; u16 ack; } PktHdr; /* 12 */
typedef struct { u32 sendT; u32 echoT; u16 held; } DataHdr; /* 10 */
typedef struct { u8 slot; u8 health; u16 weapon; u32 flags; u32 t; float x, y, z, pitch, yaw; } WirePose; /* 32 */
#pragma pack(pop)

typedef struct { u16 id; u8 origin; u8 len; char txt[NET_EVT_MAX]; } REvt;

typedef struct {
	int used;
	sockaddr_in addr;
	double lastRecv;
	/* outgoing reliable */
	REvt out[RQ];
	u16 nextOut;   /* next id to assign */
	u16 ackedOut;  /* highest id peer confirmed */
	/* incoming reliable */
	u16 lastIn;    /* last in-order id delivered */
	/* timing */
	u32 lastRemoteSendT; double lastRemoteRecvLocal;
	double rtt;
} Link;

typedef struct { double localRecv; u32 remoteT; Pose p; } Sample;
typedef struct {
	int connected;
	char name[32];
	Sample s[16]; int head, count;
	double offset; int haveOffset;
	double lastPose;
	int ping;
	char readyMap[64];
} Slot;

static struct {
	int configured, joined, host;
	u32 sock;
	u16 port;
	u32 session;
	int localSlot, maxPlayers;
	char localName[32];
	sockaddr_in hostAddr;
	double lastSend, lastHello;
	Link links[NET_MAX_PLAYERS]; /* host: index = client slot; client: links[0] = host */
	Slot slots[NET_MAX_PLAYERS];
	Pose localPose; int havePose;
	char localMap[64], hostMap[64];
	char pendingMap[64]; double lastMapCmd;
	/* inbound queue to GSC */
	char inq[256][NET_EVT_MAX + 8]; int inHead, inCount;
	double hostOffset; int haveHostOffset;
	int barrier; double barrierStart; double pendingSince;
	int minPlayers; int levelsLoaded;
} N;

static int seq_gt(u16 a, u16 b) { return (s16)(a - b) > 0; }

static void inq_push(const char *origin, const char *payload)
{
	if (N.inCount >= 256) { logf("net: inbound queue full, dropping '%s'", payload); return; }
	int idx = (N.inHead + N.inCount) & 255;
	fmt(N.inq[idx], sizeof N.inq[idx], "%s|%s", origin, payload);
	N.inCount++;
}

static void link_reset(Link *l)
{
	memset(l, 0, sizeof *l);
	l->nextOut = 1;
}

static int link_queue(Link *l, int origin, const char *txt)
{
	if ((u16)(l->nextOut - l->ackedOut) >= RQ - 1) { logf("net: reliable queue full"); return 0; }
	REvt *e = &l->out[l->nextOut % RQ];
	e->id = l->nextOut++;
	e->origin = (u8)origin;
	int n = (int)strlen(txt);
	if (n > NET_EVT_MAX) n = NET_EVT_MAX;
	e->len = (u8)n;
	memcpy(e->txt, txt, n);
	return 1;
}

#ifdef NET_HARNESS
int harness_loss_pct;
static u32 lcg = 12345;
#endif
static int sendto_addr(const sockaddr_in *a, const void *buf, int len)
{
#ifdef NET_HARNESS
	lcg = lcg * 1103515245u + 12345u;
	if ((int)((lcg >> 16) % 100) < harness_loss_pct) return len;
#endif
	return psendto(N.sock, buf, len, 0, a, sizeof *a);
}

static void fill_hdr(PktHdr *h, int type, int nposes, u16 ack)
{
	h->magic = MAGIC; h->ver = PROTO; h->type = (u8)type; h->session = N.session;
	h->slot = (u8)N.localSlot; h->nposes = (u8)nposes; h->ack = ack;
}

static void pose_to_wire(WirePose *w, int slot, const Pose *p, u32 t)
{
	w->slot = (u8)slot; w->health = (u8)(p->health < 0 ? 0 : p->health > 255 ? 255 : p->health);
	w->weapon = (u16)p->weapon; w->flags = (u32)p->flags; w->t = t;
	w->x = p->x; w->y = p->y; w->z = p->z; w->pitch = p->pitch; w->yaw = p->yaw;
}

static void slot_add_sample(int slot, const WirePose *w)
{
	Slot *s = &N.slots[slot];
	double now = now_ms();
	double off = now - (double)w->t;
	if (!s->haveOffset || off < s->offset) { s->offset = off; s->haveOffset = 1; }
	else s->offset += (off - s->offset) * 0.002; /* slow drift upward if latency grows */
	/* drop out-of-order samples */
	if (s->count) {
		Sample *last = &s->s[(s->head + s->count - 1) & 15];
		if ((s32)(w->t - last->remoteT) <= 0) return;
	}
	Sample *n;
	if (s->count < 16) n = &s->s[(s->head + s->count++) & 15];
	else { n = &s->s[s->head]; s->head = (s->head + 1) & 15; }
	n->localRecv = now; n->remoteT = w->t;
	n->p.x = w->x; n->p.y = w->y; n->p.z = w->z; n->p.pitch = w->pitch; n->p.yaw = w->yaw;
	n->p.flags = (s32)w->flags; n->p.health = w->health; n->p.weapon = w->weapon;
	s->lastPose = now;
}

/* Build and send a DATA packet to one link. includeSlotsMask: which slots' poses to include. */
static void send_data(Link *l, int linkSlot, u32 mask)
{
	static u8 buf[MAX_PACKET];
	PktHdr *h = (PktHdr *)buf;
	DataHdr *d = (DataHdr *)(buf + sizeof(PktHdr));
	int off = sizeof(PktHdr) + sizeof(DataHdr);
	int np = 0;
	u32 now = (u32)now_ms();
	(void)linkSlot;
	for (int s = 0; s < NET_MAX_PLAYERS; s++) {
		if (!(mask & (1u << s))) continue;
		if (s == N.localSlot) {
			if (!N.havePose) continue;
			pose_to_wire((WirePose *)(buf + off), s, &N.localPose, now);
		} else {
			Slot *sl = &N.slots[s];
			if (!sl->connected || !sl->count) continue;
			Sample *last = &sl->s[(sl->head + sl->count - 1) & 15];
			pose_to_wire((WirePose *)(buf + off), s, &last->p, last->remoteT);
		}
		off += sizeof(WirePose); np++;
	}
	d->sendT = now;
	d->echoT = l->lastRemoteSendT;
	{
		double held = now_ms() - l->lastRemoteRecvLocal;
		d->held = (u16)(held < 0 ? 0 : held > 65000 ? 65000 : held);
	}
	/* reliable events: everything not yet acked, oldest first, while it fits */
	u8 *nev = buf + off++;
	*nev = 0;
	for (u16 id = (u16)(l->ackedOut + 1); id != l->nextOut; id++) {
		REvt *e = &l->out[id % RQ];
		if (off + 4 + e->len > MAX_PACKET) break;
		buf[off] = (u8)(e->id & 255); buf[off + 1] = (u8)(e->id >> 8);
		buf[off + 2] = e->origin; buf[off + 3] = e->len;
		memcpy(buf + off + 4, e->txt, e->len);
		off += 4 + e->len;
		(*nev)++;
		if (*nev == 255) break;
	}
	fill_hdr(h, PT_DATA, np, l->lastIn);
	sendto_addr(&l->addr, buf, off);
}

static void broadcast_from(int origin, const char *txt, int exceptSlot)
{
	if (N.host) {
		for (int s = 1; s < NET_MAX_PLAYERS; s++)
			if (N.links[s].used && s != exceptSlot) link_queue(&N.links[s], origin, txt);
	} else if (N.links[0].used) {
		link_queue(&N.links[0], origin, txt);
	}
}

static void sys_event(const char *payload) { inq_push("s", payload); }

static void handle_control(int origin, const char *txt)
{
	/* ~MAP|name  ~JOIN|slot|name  ~NAME|slot|name  ~PART|slot */
	char buf[NET_EVT_MAX + 1];
	strlcpy_(buf, txt, sizeof buf);
	char *a = buf + 1, *b = 0, *c = 0;
	for (char *p = a; *p; p++) if (*p == '|') { *p = 0; if (!b) b = p + 1; else if (!c) { c = p + 1; break; } }
	(void)origin;
	if (!strcmp(a, "MAP") && b) {
		strlcpy_(N.hostMap, b, sizeof N.hostMap);
		logf("net: host map is '%s'", N.hostMap);
		if (!N.host && stricmp_(N.hostMap, N.localMap) != 0) { strlcpy_(N.pendingMap, N.hostMap, sizeof N.pendingMap); N.pendingSince = now_ms(); }
		char e[96]; fmt(e, sizeof e, "M|%s", N.hostMap); sys_event(e);
	} else if ((!strcmp(a, "JOIN") || !strcmp(a, "NAME")) && b && c) {
		int s = atoi_(b);
		if (s >= 0 && s < NET_MAX_PLAYERS && s != N.localSlot) {
			int was = N.slots[s].connected;
			N.slots[s].connected = 1;
			strlcpy_(N.slots[s].name, c, sizeof N.slots[s].name);
			if (!was) { char e[96]; fmt(e, sizeof e, "J|%d|%s", s, c); sys_event(e); }
		}
	} else if (!strcmp(a, "GO") && b) {
		if (N.barrier && !stricmp_(b, N.localMap)) { N.barrier = 0; logf("net: barrier released by host"); sys_event("G"); }
	} else if (!strcmp(a, "PART") && b) {
		int s = atoi_(b);
		if (s >= 0 && s < NET_MAX_PLAYERS && N.slots[s].connected) {
			N.slots[s].connected = 0; N.slots[s].count = 0;
			char e[32]; fmt(e, sizeof e, "P|%d", s); sys_event(e);
		}
	}
}

static void host_check_barrier(void)
{
	if (!N.host || !N.barrier) return;
	int ready = 1;
	for (int s = 1; s < NET_MAX_PLAYERS; s++) {
		if (!N.links[s].used) continue;
		if (stricmp_(N.slots[s].readyMap, N.localMap) != 0) return;
		ready++;
	}
	/* lobby: the first mission waits until coop_wait players are in */
	if (N.levelsLoaded <= 1 && ready < N.minPlayers) return;
	char t[96]; fmt(t, sizeof t, "~GO|%s", N.localMap);
	broadcast_from(0, t, -1);
	N.barrier = 0;
	logf("net: everyone loaded '%s', releasing barrier", N.localMap);
	sys_event("G");
}

static void host_control(int s, const char *txt)
{
	/* ~RDY|map from a client that finished loading */
	if (!strncmp(txt, "~RDY|", 5)) {
		strlcpy_(N.slots[s].readyMap, txt + 5, sizeof N.slots[s].readyMap);
		logf("net: slot %d ready in '%s'", s, N.slots[s].readyMap);
		if (stricmp_(N.slots[s].readyMap, N.localMap) != 0) return;
		if (N.barrier) { host_check_barrier(); return; }
		/* late joiner: let them in right away, and tell host GSC to send a catch-up */
		char t[96]; fmt(t, sizeof t, "~GO|%s", N.localMap); link_queue(&N.links[s], 0, t);
		char e[32]; fmt(e, sizeof e, "L|%d", s); sys_event(e);
	}
}

static void deliver(Link *l, int linkSlot, int origin, const char *txt)
{
	(void)l;
	if (txt[0] == '~') {
		if (N.host) host_control(linkSlot, txt);
		else if (origin == 0) handle_control(origin, txt); /* only the host may originate */
		return;
	}
	char o[8]; fmt(o, sizeof o, "%d", origin);
	inq_push(o, txt);
	if (N.host) broadcast_from(origin, txt, linkSlot); /* relay to everyone else */
}

static void host_drop(int s, const char *why)
{
	logf("net: dropping slot %d (%s)", s, why);
	link_reset(&N.links[s]);
	N.slots[s].connected = 0; N.slots[s].count = 0;
	char t[32]; fmt(t, sizeof t, "~PART|%d", s);
	broadcast_from(0, t, -1);
	char e[32]; fmt(e, sizeof e, "P|%d", s); sys_event(e);
	N.slots[s].readyMap[0] = 0;
	host_check_barrier();
}

static int addr_eq(const sockaddr_in *a, const sockaddr_in *b) { return a->addr == b->addr && a->port == b->port; }

static void on_packet(u8 *buf, int len, sockaddr_in *from)
{
	if (len < (int)sizeof(PktHdr)) return;
	PktHdr *h = (PktHdr *)buf;
	if (h->magic != MAGIC || h->ver != PROTO) return;
	double now = now_ms();

	if (N.host) {
		if (h->type == PT_HELLO) {
			char name[32]; int nl = len - (int)sizeof(PktHdr); if (nl > 31) nl = 31; if (nl < 0) nl = 0;
			memcpy(name, buf + sizeof(PktHdr), nl); name[nl] = 0;
			int s = -1;
			for (int i = 1; i < N.maxPlayers; i++) if (N.links[i].used && addr_eq(&N.links[i].addr, from)) s = i;
			int fresh = 0;
			if (s < 0) for (int i = 1; i < N.maxPlayers; i++) if (!N.links[i].used) { s = i; fresh = 1; break; }
			u8 out[96]; PktHdr *o = (PktHdr *)out;
			if (s < 0) { fill_hdr(o, PT_REJECT, 0, 0); sendto_addr(from, out, sizeof(PktHdr)); return; }
			if (fresh) {
				link_reset(&N.links[s]);
				N.links[s].used = 1; N.links[s].addr = *from; N.links[s].lastRecv = now;
				N.slots[s].connected = 1; N.slots[s].count = 0; N.slots[s].haveOffset = 0;
				strlcpy_(N.slots[s].name, name[0] ? name : "Player", sizeof N.slots[s].name);
				logf("net: slot %d joined as '%s'", s, N.slots[s].name);
				/* tell the newcomer about everyone, then everyone about the newcomer */
				char t[96];
				fmt(t, sizeof t, "~NAME|0|%s", N.localName); link_queue(&N.links[s], 0, t);
				for (int i = 1; i < NET_MAX_PLAYERS; i++)
					if (i != s && N.slots[i].connected) { fmt(t, sizeof t, "~NAME|%d|%s", i, N.slots[i].name); link_queue(&N.links[s], 0, t); }
				if (N.localMap[0]) { fmt(t, sizeof t, "~MAP|%s", N.localMap); link_queue(&N.links[s], 0, t); }
				fmt(t, sizeof t, "~JOIN|%d|%s", s, N.slots[s].name);
				broadcast_from(0, t, s);
				fmt(t, sizeof t, "J|%d|%s", s, N.slots[s].name); sys_event(t);
			}
			fill_hdr(o, PT_WELCOME, 0, 0);
			out[sizeof(PktHdr)] = (u8)s;
			out[sizeof(PktHdr) + 1] = (u8)N.maxPlayers;
			sendto_addr(from, out, sizeof(PktHdr) + 2);
			return;
		}
		if (h->session != N.session) return;
		int s = h->slot;
		if (s <= 0 || s >= NET_MAX_PLAYERS || !N.links[s].used || !addr_eq(&N.links[s].addr, from)) return;
		Link *l = &N.links[s];
		if (h->type == PT_BYE) { host_drop(s, "bye"); return; }
		if (h->type != PT_DATA) return;
		l->lastRecv = now;
		if (seq_gt(h->ack, l->ackedOut)) l->ackedOut = h->ack;
		int off = sizeof(PktHdr);
		if (len < off + (int)sizeof(DataHdr) + 1) return;
		DataHdr *d = (DataHdr *)(buf + off); off += sizeof(DataHdr);
		l->lastRemoteSendT = d->sendT; l->lastRemoteRecvLocal = now;
		if (d->echoT) { double r = (double)((u32)now - d->echoT) - d->held; if (r >= 0 && r < 5000) l->rtt = l->rtt ? l->rtt * 0.8 + r * 0.2 : r; N.slots[s].ping = (int)l->rtt; }
		for (int i = 0; i < h->nposes && off + (int)sizeof(WirePose) <= len; i++, off += sizeof(WirePose)) {
			WirePose *w = (WirePose *)(buf + off);
			if (w->slot == s) slot_add_sample(s, w); /* clients may only report their own pose */
		}
		if (off >= len) return;
		int nev = buf[off++];
		for (int i = 0; i < nev && off + 4 <= len; i++) {
			u16 id = (u16)(buf[off] | (buf[off + 1] << 8)); int ln = buf[off + 3];
			if (off + 4 + ln > len) break;
			char txt[NET_EVT_MAX + 1]; memcpy(txt, buf + off + 4, ln); txt[ln] = 0;
			off += 4 + ln;
			if (id == (u16)(l->lastIn + 1)) { l->lastIn = id; deliver(l, s, s, txt); }
		}
		return;
	}

	/* client */
	if (!addr_eq(from, &N.hostAddr)) return;
	Link *l = &N.links[0];
	if (h->type == PT_REJECT) { logf("net: host rejected us (full)"); sys_event("R"); N.configured = 0; return; }
	if (h->type == PT_WELCOME) {
		if (!N.joined) {
			N.joined = 1; N.session = h->session;
			N.localSlot = buf[sizeof(PktHdr)]; N.maxPlayers = buf[sizeof(PktHdr) + 1];
			link_reset(l); l->used = 1; l->addr = N.hostAddr; l->lastRecv = now;
			N.slots[0].connected = 1;
			logf("net: joined host as slot %d (session %x)", N.localSlot, N.session);
			char e[32]; fmt(e, sizeof e, "W|%d", N.localSlot); sys_event(e);
		}
		return;
	}
	if (!N.joined || h->session != N.session) return;
	if (h->type == PT_BYE) { logf("net: host ended session"); sys_event("H"); N.joined = 0; N.configured = 0; return; }
	if (h->type != PT_DATA) return;
	l->lastRecv = now;
	if (seq_gt(h->ack, l->ackedOut)) l->ackedOut = h->ack;
	int off = sizeof(PktHdr);
	if (len < off + (int)sizeof(DataHdr) + 1) return;
	DataHdr *d = (DataHdr *)(buf + off); off += sizeof(DataHdr);
	l->lastRemoteSendT = d->sendT; l->lastRemoteRecvLocal = now;
	{
		double ho = now - (double)d->sendT;
		if (!N.haveHostOffset || ho < N.hostOffset) { N.hostOffset = ho; N.haveHostOffset = 1; }
		else N.hostOffset += (ho - N.hostOffset) * 0.002;
	}
	if (d->echoT) { double r = (double)((u32)now - d->echoT) - d->held; if (r >= 0 && r < 5000) l->rtt = l->rtt ? l->rtt * 0.8 + r * 0.2 : r; N.slots[0].ping = (int)l->rtt; }
	for (int i = 0; i < h->nposes && off + (int)sizeof(WirePose) <= len; i++, off += sizeof(WirePose)) {
		WirePose *w = (WirePose *)(buf + off);
		if (w->slot < NET_MAX_PLAYERS && w->slot != N.localSlot) { N.slots[w->slot].connected = 1; slot_add_sample(w->slot, w); }
	}
	if (off >= len) return;
	int nev = buf[off++];
	for (int i = 0; i < nev && off + 4 <= len; i++) {
		u16 id = (u16)(buf[off] | (buf[off + 1] << 8)); int origin = buf[off + 2]; int ln = buf[off + 3];
		if (off + 4 + ln > len) break;
		char txt[NET_EVT_MAX + 1]; memcpy(txt, buf + off + 4, ln); txt[ln] = 0;
		off += 4 + ln;
		if (id == (u16)(l->lastIn + 1)) { l->lastIn = id; deliver(l, 0, origin, txt); }
	}
}

static int resolve(const char *hostport, sockaddr_in *out, u16 defport)
{
	char h[128]; strlcpy_(h, hostport, sizeof h);
	u16 port = defport;
	for (char *p = h; *p; p++) if (*p == ':') { *p = 0; port = (u16)atoi_(p + 1); break; }
	memset(out, 0, sizeof *out);
	out->family = 2; out->port = bswap16(port);
	u32 a = pinet_addr(h);
	if (a == 0xffffffffu) {
		u8 *he = pgethostbyname(h);
		if (!he) return 0;
		/* hostent: name, aliases, short addrtype, short length, char **addr_list */
		char **list = *(char ***)(he + 12);
		if (!list || !list[0]) return 0;
		memcpy(&a, list[0], 4);
	}
	out->addr = a;
	return 1;
}

void net_init(void)
{
	char v[128];
	memset(&N, 0, sizeof N);
	N.maxPlayers = NET_MAX_PLAYERS;
	N.port = 28970;
	strlcpy_(N.localName, "Player", sizeof N.localName);
	if (cmdline_get("coop_name", v, sizeof v)) strlcpy_(N.localName, v, sizeof N.localName);
	for (char *p = N.localName; *p; p++) if (*p == '|' || *p == '~') *p = '_';
	if (cmdline_get("coop_port", v, sizeof v)) N.port = (u16)atoi_(v);
	if (cmdline_get("coop_wait", v, sizeof v)) { N.minPlayers = atoi_(v); if (N.minPlayers > NET_MAX_PLAYERS) N.minPlayers = NET_MAX_PLAYERS; }
	if (cmdline_get("coop_maxplayers", v, sizeof v)) { int m = atoi_(v); if (m >= 2 && m <= NET_MAX_PLAYERS) N.maxPlayers = m; }
	const char *host = cmdline_get("coop_host", v, sizeof v);
	int wantHost = host && v[0] && v[0] != '0';
	char conn[128];
	const char *join = cmdline_get("coop_connect", conn, sizeof conn);
	if (!wantHost && !(join && conn[0])) { logf("net: no coop_host/coop_connect on command line, solo"); return; }

	HMODULE ws = LoadLibraryA("ws2_32.dll");
	if (!ws) { logf("net: ws2_32 missing"); return; }
	pWSAStartup = GetProcAddress(ws, "WSAStartup");
	psocket = GetProcAddress(ws, "socket");
	pbind = GetProcAddress(ws, "bind");
	psendto = GetProcAddress(ws, "sendto");
	precvfrom = GetProcAddress(ws, "recvfrom");
	pioctlsocket = GetProcAddress(ws, "ioctlsocket");
	pclosesocket = GetProcAddress(ws, "closesocket");
	pinet_addr = GetProcAddress(ws, "inet_addr");
	pgethostbyname = GetProcAddress(ws, "gethostbyname");
	pWSAGetLastError = GetProcAddress(ws, "WSAGetLastError");
	static u8 wsadata[512];
	if (pWSAStartup(0x0202, wsadata) != 0) { logf("net: WSAStartup failed"); return; }
	N.sock = psocket(2, 2, 17);
	if (N.sock == 0xffffffffu) { logf("net: socket failed"); return; }
	u32 nb = 1; pioctlsocket(N.sock, (s32)0x8004667E, &nb);
	sockaddr_in me; memset(&me, 0, sizeof me); me.family = 2;
	me.port = bswap16(wantHost ? N.port : 0);
	if (pbind(N.sock, &me, sizeof me) != 0) { logf("net: bind %u failed (%d)", (u32)N.port, pWSAGetLastError()); return; }

	N.configured = 1;
	for (int i = 0; i < NET_MAX_PLAYERS; i++) link_reset(&N.links[i]);
	if (wantHost) {
		N.host = 1; N.joined = 1; N.localSlot = 0;
		N.session = (u32)(now_ms() * 7919.0) ^ GetTickCount() ^ 0x5eed1234u;
		N.slots[0].connected = 1; strlcpy_(N.slots[0].name, N.localName, 32);
		logf("net: hosting on UDP %u, max %d players, session %x", (u32)N.port, N.maxPlayers, N.session);
	} else {
		if (!resolve(conn, &N.hostAddr, N.port)) { logf("net: cannot resolve '%s'", conn); N.configured = 0; return; }
		N.localSlot = -1;
		logf("net: connecting to %s as '%s'", conn, N.localName);
	}
}

void net_tick(void)
{
	if (!N.configured) return;
	static u8 buf[1500];
	for (int k = 0; k < 64; k++) {
		sockaddr_in from; int fl = sizeof from;
		int n = precvfrom(N.sock, buf, sizeof buf, 0, &from, &fl);
		if (n <= 0) break;
		on_packet(buf, n, &from);
		if (!N.configured) return;
	}
	double now = now_ms();
	if (!N.host && !N.joined) {
		if (now - N.lastHello >= HELLO_INTERVAL) {
			u8 out[64]; PktHdr *h = (PktHdr *)out; int nl = (int)strlen(N.localName);
			fill_hdr(h, PT_HELLO, 0, 0); h->slot = 0xff;
			memcpy(out + sizeof(PktHdr), N.localName, nl);
			sendto_addr(&N.hostAddr, out, sizeof(PktHdr) + nl);
			N.lastHello = now;
		}
		return;
	}
	/* timeouts */
	if (N.host) {
		for (int s = 1; s < NET_MAX_PLAYERS; s++)
			if (N.links[s].used && now - N.links[s].lastRecv > TIMEOUT_MS) host_drop(s, "timeout");
	} else if (now - N.links[0].lastRecv > TIMEOUT_MS) {
		logf("net: host timed out"); sys_event("H"); N.joined = 0; N.configured = 0; return;
	}
	if (N.barrier && now - N.barrierStart > (N.levelsLoaded <= 1 && N.minPlayers > 1 ? 300000.0 : 90000.0)) { N.barrier = 0; logf("net: barrier timeout"); sys_event("G"); }
	int pending = 0;
	for (int s = 0; s < NET_MAX_PLAYERS; s++) if (N.links[s].used && N.links[s].ackedOut != (u16)(N.links[s].nextOut - 1)) pending = 1;
	if (now - N.lastSend < (pending ? 16.0 : SEND_INTERVAL)) return;
	N.lastSend = now;
	if (N.host) {
		for (int s = 1; s < NET_MAX_PLAYERS; s++)
			if (N.links[s].used) send_data(&N.links[s], s, 0xfu & ~(1u << s));
	} else {
		send_data(&N.links[0], 0, 1u << N.localSlot);
	}
}

void net_frame_main(void)
{
	net_tick();
	if (!N.configured || N.host) return;
	if (N.pendingMap[0] && stricmp_(N.pendingMap, N.localMap) != 0) {
		double now = now_ms();
		/* at the menu follow at once; in a level give the game's own transition 8 s to get there first */
		if ((!N.localMap[0] || now - N.pendingSince > 8000.0) && now - N.lastMapCmd > 20000.0) {
			char cmd[96]; fmt(cmd, sizeof cmd, "map %s\n", N.pendingMap);
			logf("net: following host -> %s", cmd);
			cbuf_add_text(cmd);
			N.lastMapCmd = now;
		}
	}
}

void net_leave(void)
{
	if (!N.configured) return;
	u8 out[16]; PktHdr *h = (PktHdr *)out; fill_hdr(h, PT_BYE, 0, 0);
	if (N.host) { for (int s = 1; s < NET_MAX_PLAYERS; s++) if (N.links[s].used) sendto_addr(&N.links[s].addr, out, sizeof(PktHdr)); }
	else if (N.joined) sendto_addr(&N.hostAddr, out, sizeof(PktHdr));
	logf("net: left session");
	N.configured = 0; N.joined = 0;
}

int net_active(void) { return N.configured && N.joined; }
int net_is_host(void) { return N.host; }
int net_local_slot(void) { return net_active() ? N.localSlot : -1; }
int net_num_players(void)
{
	if (!net_active()) return 1;
	int c = 0;
	for (int s = 0; s < NET_MAX_PLAYERS; s++) if (s == N.localSlot || N.slots[s].connected) c++;
	return c;
}
int net_slot_connected(int s) { return s >= 0 && s < NET_MAX_PLAYERS && net_active() && s != N.localSlot && N.slots[s].connected; }
const char *net_slot_name(int s)
{
	if (s < 0 || s >= NET_MAX_PLAYERS) return "";
	if (s == N.localSlot) return N.localName;
	return N.slots[s].name;
}
int net_slot_ping(int s) { return (s >= 0 && s < NET_MAX_PLAYERS) ? (N.host ? (int)N.links[s].rtt : (int)N.links[0].rtt) : 0; }
double net_slot_age(int s) { return (s >= 0 && s < NET_MAX_PLAYERS && N.slots[s].count) ? now_ms() - N.slots[s].lastPose : 1e9; }
double net_host_time(void) { return N.host || !N.haveHostOffset ? now_ms() : now_ms() - N.hostOffset + N.links[0].rtt * 0.5; }

void net_set_pose(const Pose *p) { N.localPose = *p; N.havePose = 1; }

static float lerp_angle(float a, float b, float t)
{
	float d = b - a;
	while (d > 180.0f) d -= 360.0f;
	while (d < -180.0f) d += 360.0f;
	return a + d * t;
}

int net_get_pose(int slot, Pose *out)
{
	if (slot < 0 || slot >= NET_MAX_PLAYERS) return 0;
	Slot *s = &N.slots[slot];
	if (!s->count) return 0;
	double target = now_ms() - s->offset - INTERP_DELAY; /* in remote clock */
	Sample *newest = &s->s[(s->head + s->count - 1) & 15];
	if (target >= (double)newest->remoteT || s->count == 1) { *out = newest->p; return 1; }
	for (int i = s->count - 2; i >= 0; i--) {
		Sample *a = &s->s[(s->head + i) & 15];
		Sample *b = &s->s[(s->head + i + 1) & 15];
		if (target >= (double)a->remoteT) {
			double span = (double)(b->remoteT - a->remoteT);
			float t = span > 0 ? (float)((target - (double)a->remoteT) / span) : 1.0f;
			out->x = a->p.x + (b->p.x - a->p.x) * t;
			out->y = a->p.y + (b->p.y - a->p.y) * t;
			out->z = a->p.z + (b->p.z - a->p.z) * t;
			out->pitch = lerp_angle(a->p.pitch, b->p.pitch, t);
			out->yaw = lerp_angle(a->p.yaw, b->p.yaw, t);
			out->flags = b->p.flags; out->health = b->p.health; out->weapon = b->p.weapon;
			return 1;
		}
	}
	*out = s->s[s->head].p;
	return 1;
}

int net_send_event(const char *txt)
{
	if (!net_active() || !txt[0] || txt[0] == '~') return 0;
	broadcast_from(N.localSlot, txt, -1);
	return 1;
}

int net_pop_event(char *out, int cap)
{
	if (!N.inCount) { out[0] = 0; return 0; }
	strlcpy_(out, N.inq[N.inHead], cap);
	N.inHead = (N.inHead + 1) & 255; N.inCount--;
	return 1;
}

void net_set_map(const char *map)
{
	strlcpy_(N.localMap, map, sizeof N.localMap);
	if (N.pendingMap[0] && !stricmp_(N.pendingMap, map)) N.pendingMap[0] = 0;
	logf("net: local level '%s'", map);
	if (!net_active()) return;
	N.levelsLoaded++;
	if (net_num_players() > 1 || (N.host && N.levelsLoaded == 1 && N.minPlayers > 1)) { N.barrier = 1; N.barrierStart = now_ms(); }
	if (N.host) {
		char t[96]; fmt(t, sizeof t, "~MAP|%s", map);
		broadcast_from(0, t, -1);
		strlcpy_(N.hostMap, map, sizeof N.hostMap);
		host_check_barrier();
	} else {
		char t[96]; fmt(t, sizeof t, "~RDY|%s", map);
		link_queue(&N.links[0], N.localSlot, t);
	}
}
int net_barrier(void) { return N.barrier; }
const char *net_host_map(void) { return N.host ? N.localMap : N.hostMap; }

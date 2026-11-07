#include "rt.h"

typedef __builtin_va_list va_list;
#define va_start __builtin_va_start
#define va_arg __builtin_va_arg
#define va_end __builtin_va_end

void *memcpy(void *d, const void *s, size_t n) { u8 *a = d; const u8 *b = s; while (n--) *a++ = *b++; return d; }
void *memset(void *d, int c, size_t n) { u8 *a = d; while (n--) *a++ = (u8)c; return d; }
void *memmove(void *d, const void *s, size_t n)
{
	u8 *a = d; const u8 *b = s;
	if (a < b) while (n--) *a++ = *b++;
	else { a += n; b += n; while (n--) *--a = *--b; }
	return d;
}
int memcmp(const void *x, const void *y, size_t n)
{
	const u8 *a = x, *b = y;
	for (; n; n--, a++, b++) if (*a != *b) return *a - *b;
	return 0;
}
size_t strlen(const char *s) { size_t n = 0; while (s[n]) n++; return n; }
int strcmp(const char *a, const char *b) { while (*a && *a == *b) a++, b++; return (u8)*a - (u8)*b; }
int strncmp(const char *a, const char *b, size_t n)
{
	for (; n; n--, a++, b++) { if (*a != *b || !*a) return (u8)*a - (u8)*b; }
	return 0;
}
static int lc(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }
int stricmp_(const char *a, const char *b) { while (*a && lc(*a) == lc(*b)) a++, b++; return lc((u8)*a) - lc((u8)*b); }
void strlcpy_(char *d, const char *s, size_t cap)
{
	size_t i = 0;
	if (!cap) return;
	for (; s && s[i] && i + 1 < cap; i++) d[i] = s[i];
	d[i] = 0;
}
int atoi_(const char *s)
{
	int sign = 1, v = 0;
	while (*s == ' ') s++;
	if (*s == '-') sign = -1, s++;
	while (*s >= '0' && *s <= '9') v = v * 10 + (*s++ - '0');
	return v * sign;
}

typedef struct { char *p; int left; int n; } outbuf;
static void put(outbuf *o, char c) { if (o->left > 1) { *o->p++ = c; o->left--; } o->n++; }
static void puts_(outbuf *o, const char *s) { if (!s) s = "(null)"; while (*s) put(o, *s++); }
static void putu(outbuf *o, u32 v, int base)
{
	char t[16]; int i = 0;
	do { u32 d = v % base; t[i++] = (char)(d < 10 ? '0' + d : 'a' + d - 10); v /= base; } while (v);
	while (i) put(o, t[--i]);
}
static int vfmt(char *out, int cap, const char *f, va_list ap)
{
	outbuf o = { out, cap, 0 };
	for (; *f; f++) {
		if (*f != '%') { put(&o, *f); continue; }
		f++;
		switch (*f) {
		case 'd': { int v = va_arg(ap, int); if (v < 0) { put(&o, '-'); v = -v; } putu(&o, (u32)v, 10); break; }
		case 'u': putu(&o, va_arg(ap, u32), 10); break;
		case 'x': putu(&o, va_arg(ap, u32), 16); break;
		case 'p': puts_(&o, "0x"); putu(&o, (u32)va_arg(ap, void *), 16); break;
		case 's': puts_(&o, va_arg(ap, const char *)); break;
		case 'c': put(&o, (char)va_arg(ap, int)); break;
		case 'f': {
			double v = va_arg(ap, double);
			if (v < 0) { put(&o, '-'); v = -v; }
			if (v > 2.0e9) v = 2.0e9;
			u32 ip = (u32)v; u32 fr = (u32)((v - (double)ip) * 1000.0 + 0.5);
			if (fr >= 1000) { ip++; fr -= 1000; }
			putu(&o, ip, 10); put(&o, '.');
			put(&o, (char)('0' + fr / 100)); put(&o, (char)('0' + (fr / 10) % 10)); put(&o, (char)('0' + fr % 10));
			break;
		}
		case '%': put(&o, '%'); break;
		default: put(&o, '%'); put(&o, *f); break;
		}
	}
	if (cap > 0) *o.p = 0;
	return o.n;
}
int fmt(char *out, int cap, const char *f, ...)
{
	va_list ap; va_start(ap, f);
	int n = vfmt(out, cap, f, ap);
	va_end(ap);
	return n;
}

static double qpf_inv;
double now_ms(void)
{
	s64 c;
	if (qpf_inv == 0.0) { s64 f; QueryPerformanceFrequency(&f); qpf_inv = 1000.0 / (double)f; }
	QueryPerformanceCounter(&c);
	return (double)c * qpf_inv;
}

static HANDLE g_log = 0;
void log_open(const char *path)
{
	/* GENERIC_WRITE, FILE_SHARE_READ, CREATE_ALWAYS, NORMAL */
	g_log = CreateFileA(path, 0x40000000, 1, 0, 2, 0x80, 0);
	if (g_log == INVALID_HANDLE_VALUE) g_log = 0;
}
void logf(const char *f, ...)
{
	static char buf[1024];
	char head[32];
	va_list ap; va_start(ap, f);
	int hn = fmt(head, sizeof head, "[%u] ", (u32)now_ms());
	int n = vfmt(buf, sizeof buf - 2, f, ap);
	va_end(ap);
	if (n > (int)sizeof buf - 3) n = sizeof buf - 3;
	buf[n++] = '\r'; buf[n++] = '\n'; buf[n] = 0;
	OutputDebugStringA(buf);
	if (g_log) { u32 w; WriteFile(g_log, head, hn, &w, 0); WriteFile(g_log, buf, n, &w, 0); FlushFileBuffers(g_log); }
}

/* Tokenize the command line (quotes respected) and find "+set key value" / "+key value" / "-key value". */
const char *cmdline_get(const char *key, char *buf, int cap)
{
	const char *p = GetCommandLineA();
	char tok[3][128]; int have = 0;
	while (*p) {
		while (*p == ' ' || *p == '\t') p++;
		if (!*p) break;
		char t[128]; int n = 0;
		if (*p == '"') { p++; while (*p && *p != '"') { if (n < 127) t[n++] = *p; p++; } if (*p) p++; }
		else while (*p && *p != ' ' && *p != '\t') { if (n < 127) t[n++] = *p; p++; }
		t[n] = 0;
		/* shift window */
		if (have == 3) { memcpy(tok[0], tok[1], 128); memcpy(tok[1], tok[2], 128); have = 2; }
		memcpy(tok[have++], t, 128);
		if (have == 3 && stricmp_(tok[0], "+set") == 0 && stricmp_(tok[1], key) == 0) { strlcpy_(buf, tok[2], cap); return buf; }
		if (have >= 2) {
			const char *k = tok[have - 2];
			if ((k[0] == '+' || k[0] == '-') && stricmp_(k + 1, key) == 0) { strlcpy_(buf, tok[have - 1], cap); return buf; }
		}
	}
	return NULL;
}

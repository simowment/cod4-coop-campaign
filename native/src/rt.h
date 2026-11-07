/* Freestanding runtime for the iw3sp coop proxy (i386, no CRT). */
#pragma once

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
typedef signed char s8;
typedef short s16;
typedef int s32;
typedef long long s64;
typedef u32 size_t;
typedef int BOOL;
typedef void *HANDLE;
typedef void *HMODULE;

#define WINAPI __attribute__((stdcall))
#define DLLIMPORT __attribute__((dllimport))
#define NULL ((void *)0)

/* kernel32 */
DLLIMPORT HMODULE WINAPI LoadLibraryA(const char *);
DLLIMPORT void *WINAPI GetProcAddress(HMODULE, const char *);
DLLIMPORT u32 WINAPI GetSystemDirectoryA(char *, u32);
DLLIMPORT u32 WINAPI GetModuleFileNameA(HMODULE, char *, u32);
DLLIMPORT HMODULE WINAPI GetModuleHandleA(const char *);
DLLIMPORT const char *WINAPI GetCommandLineA(void);
DLLIMPORT HANDLE WINAPI CreateFileA(const char *, u32, u32, void *, u32, u32, HANDLE);
DLLIMPORT BOOL WINAPI WriteFile(HANDLE, const void *, u32, u32 *, void *);
DLLIMPORT BOOL WINAPI ReadFile(HANDLE, void *, u32, u32 *, void *);
DLLIMPORT u32 WINAPI GetFileSize(HANDLE, u32 *);
DLLIMPORT BOOL WINAPI CloseHandle(HANDLE);
DLLIMPORT BOOL WINAPI FlushFileBuffers(HANDLE);
DLLIMPORT BOOL WINAPI VirtualProtect(void *, size_t, u32, u32 *);
DLLIMPORT BOOL WINAPI QueryPerformanceCounter(s64 *);
DLLIMPORT BOOL WINAPI QueryPerformanceFrequency(s64 *);
DLLIMPORT u32 WINAPI GetTickCount(void);
DLLIMPORT void WINAPI OutputDebugStringA(const char *);
DLLIMPORT int WINAPI MessageBoxA(void *, const char *, const char *, u32);

#define INVALID_HANDLE_VALUE ((HANDLE)(s32)-1)

/* mini libc */
void *memcpy(void *d, const void *s, size_t n);
void *memset(void *d, int c, size_t n);
void *memmove(void *d, const void *s, size_t n);
int memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, size_t n);
int stricmp_(const char *a, const char *b);
void strlcpy_(char *d, const char *s, size_t cap);
int atoi_(const char *s);
int fmt(char *out, int cap, const char *f, ...); /* %d %u %x %s %c %f(.3) */

/* time, logging */
double now_ms(void);
void log_open(const char *path);
void logf(const char *f, ...);

/* command line: value after "+set <key>" or "-<key>", NULL if absent */
const char *cmdline_get(const char *key, char *buf, int cap);

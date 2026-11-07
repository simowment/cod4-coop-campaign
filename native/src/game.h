/* iw3sp.exe 1.0 (SHA256 d07c39ee...e116, 3,017,216 bytes) addresses. Verified by disassembly, see MODLOG.md. */
#pragma once
#include "rt.h"

#define IW3SP_EXE_SIZE 3017216u

/* builtin table entries {const char *name; void (*fn)(void); int developer;} */
#define BT_OPENFILE     0x6de7b4
#define BT_CLOSEFILE    0x6de7c0
#define BT_FPRINTLN     0x6de7cc
#define BT_FPRINTFIELDS 0x6de7d8
#define BT_FREADLN      0x6de7e4
#define BT_FGETARG      0x6de7f0
#define STUB_RET        0x4da560 /* bare ret shared by compiled-out builtins */

/* script VM */
typedef struct { union { s32 u; float f; }; s32 type; } VarValue;
#define VM_TOP        (*(VarValue **)0x1287250)
#define VM_STACK_END  (*(VarValue **)0x1287244)
/* 0x128725c = args passed to the running builtin (engine: outparamcount, read by Scr_GetNumParam)
   0x1287258 = values pushed back (engine: inparamcount, bumped by Scr_Add*) */
#define VM_PUSHCOUNT  (*(s32 *)0x1287258)
#define VM_NUMPARAM   (*(s32 *)0x128725c)
#define SL_BASE       (*(char **)0xfdbdcc) /* string = base + id*12 + 4 */

enum { VT_UNDEFINED = 0, VT_STRING = 2, VT_ISTRING = 3, VT_VECTOR = 4, VT_FLOAT = 5, VT_INT = 6 };

#define FN_Scr_ClearOutParams 0x551d90 /* cdecl void(void) */
#define FN_Scr_AddInt         0x5587c0 /* cdecl void(int) */
#define FN_Scr_AddString      0x558950 /* usercall esi=const char* */
#define FN_Cbuf_AddText       0x52ff90 /* usercall eax=text, ecx=localClientNum */
#define FN_Dvar_SetIntByName  0x589090 /* usercall eax=value, [esp+4]=name (cdecl cleanup) */
#define FN_Dvar_FindVar       0x587560 /* cdecl dvar_t*(const char*) */

static inline int scr_nparams(void) { return VM_NUMPARAM; }
static inline VarValue *scr_param(int i) { return VM_TOP - i; }
static inline int scr_type(int i) { return i < VM_NUMPARAM ? scr_param(i)->type : VT_UNDEFINED; }

static inline const char *scr_str(int i)
{
	if (i >= VM_NUMPARAM) return "";
	VarValue *v = scr_param(i);
	if (v->type != VT_STRING && v->type != VT_ISTRING) return "";
	if (!v->u) return "";
	return SL_BASE + v->u * 12 + 4;
}
static inline float scr_float(int i)
{
	if (i >= VM_NUMPARAM) return 0.0f;
	VarValue *v = scr_param(i);
	if (v->type == VT_FLOAT) return v->f;
	if (v->type == VT_INT) return (float)v->u;
	return 0.0f;
}
static inline int scr_int(int i)
{
	if (i >= VM_NUMPARAM) return 0;
	VarValue *v = scr_param(i);
	if (v->type == VT_INT) return v->u;
	if (v->type == VT_FLOAT) return (int)v->f;
	return 0;
}

static inline void scr_add_int(int v) { ((void (*)(int))FN_Scr_AddInt)(v); }
static inline void scr_add_float(float f)
{
	((void (*)(void))FN_Scr_ClearOutParams)();
	if (VM_TOP == VM_STACK_END) return; /* would overflow; engine errors here, we just drop */
	VM_PUSHCOUNT += 1;
	VM_TOP = VM_TOP + 1;
	VM_TOP->type = VT_FLOAT;
	VM_TOP->f = f;
}
/* NOTE: Scr_ClearOutParams frees the builtin's args. Read every param before pushing a return value. */
static inline void scr_add_string(const char *s)
{
	u32 fn = FN_Scr_AddString;
	__asm__ volatile("call *%%eax" : "+a"(fn), "+S"(s) : : "ecx", "edx", "memory", "cc");
}
static inline void cbuf_add_text(const char *s)
{
	u32 fn = FN_Cbuf_AddText, lc = 0;
	__asm__ volatile("call *%%edx" : "+a"(s), "+c"(lc), "+d"(fn) : : "memory", "cc");
}
static inline void dvar_set_int(const char *name, int value)
{
	u32 fn = FN_Dvar_SetIntByName, junk;
	__asm__ volatile(
		"pushl %3; call *%%edx; addl $4, %%esp"
		: "+a"(value), "+d"(fn), "=c"(junk) : "b"(name) : "memory", "cc");
}

#!/usr/bin/env python3
"""Compile the actual added provider callbacks against an ordered TLMM shim.

No duplicate implementation: extract the contiguous production callback block
from the pinned-source patch, then check electrical ordering and failed cleanup.
Run on Linux with python3 test_touch_bus.py (CC defaults to gcc).
"""
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
added = "\n".join(line[1:] for line in (HERE / "timelm-touch.patch").read_text().splitlines()
                  if line.startswith("+") and not line.startswith("+++"))
begin = added.index("/* Private fixed-pin open-drain interface.")
end = added.index("/* End fixed touch bus callbacks. */", begin)
production = added[begin:end]

SHIM = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "PinConfig.h"
typedef uint32_t ULONG, *PULONG;
typedef uintptr_t ULONG_PTR;
typedef int32_t LONG, NTSTATUS;
typedef void VOID, *PVOID;
typedef unsigned char BOOLEAN, *PBOOLEAN;
typedef unsigned KIRQL, KSPIN_LOCK;
typedef void *WDFDEVICE;
#define TRUE 1
#define FALSE 0
#define STATUS_SUCCESS ((NTSTATUS)0)
#define STATUS_DEVICE_NOT_READY ((NTSTATUS)-1)
#define STATUS_IO_DEVICE_ERROR ((NTSTATUS)-2)
#define STATUS_NOT_SUPPORTED ((NTSTATUS)-3)
#define STATUS_DEVICE_BUSY ((NTSTATUS)-4)
#define STATUS_DEVICE_CONFIGURATION_ERROR ((NTSTATUS)-5)
#define STATUS_INVALID_PARAMETER ((NTSTATUS)-6)
#define NT_SUCCESS(s) ((s)>=0)
#define BIT(n) (1u << (n))
#define MUX_MASK 0x3cu
#define OE_BIT 9
#define OUT_BIT 1
#define IN_BIT 0
#define SOUTH 0x400000u
#define CTL_REG(n) ((n)*0x1000u)
#define IO_REG(n) (CTL_REG(n)+4u)
typedef struct {
 ULONG_PTR Base; ULONG Length; volatile LONG TouchBusActive;
 ULONG TouchBusSaved[2]; KSPIN_LOCK TouchGpioLock;
 BOOLEAN TouchGpioLockReady, TouchGpioEnabled; ULONG TouchPinsConnected;
 ULONG TouchGpioSavedCtl[2], TouchGpioSavedIo[2]; WDFDEVICE TouchDevice;
} GPIO_DEVICE_CONTEXT, *PGPIO_DEVICE_CONTEXT;
static ULONG registers[(SOUTH+IO_REG(37)+4u)/4u];
static unsigned writes, drop_write, high_drives, scl_rises, references;
static unsigned log_pins[100], log_count;
static int external_low[2];
static ULONG *ctl(unsigned pin) { return &registers[(SOUTH+CTL_REG(pin))/4]; }
static ULONG *io(unsigned pin) { return &registers[(SOUTH+IO_REG(pin))/4]; }
static int level(unsigned pin) {
 return !external_low[pin-36] && !((*ctl(pin)&0x200u) && !(*io(pin)&2u));
}
static ULONG Read32(PULONG address) {
 for(unsigned pin=36;pin<=37;++pin)
  if(address==io(pin) && *address!=0xffffffffu)
   return (*address&~1u)|(level(pin)?1u:0u);
 return *address;
}
static void Write32(PULONG address, ULONG value) {
 int before=level(37); ++writes;
 assert(log_count<sizeof(log_pins)/sizeof(log_pins[0]));
 log_pins[log_count++]=(address==ctl(36)||address==io(36))?36:37;
 if(writes==drop_write) return;
 *address=(address==io(36)||address==io(37)) ? (value&~1u) : value;
 for(unsigned pin=36;pin<=37;++pin)
  if(!(*ctl(pin)&MUX_MASK)&&(*ctl(pin)&0x200u)&&(*io(pin)&2u)) ++high_drives;
 if(!before&&level(37)) ++scl_rises;
}
static void KeAcquireSpinLock(KSPIN_LOCK *lock,KIRQL *old) { assert(!*lock); *lock=1; *old=0; }
static void KeReleaseSpinLock(KSPIN_LOCK *lock,KIRQL old) { (void)old; assert(*lock); *lock=0; }
static LONG InterlockedCompareExchange(volatile LONG *p,LONG to,LONG expected) {
 LONG old=*p; if(old==expected)*p=to; return old;
}
static LONG InterlockedExchange(volatile LONG *p,LONG to) { LONG old=*p; *p=to; return old; }
static void WdfObjectReference(WDFDEVICE d) { assert(d); ++references; }
static void WdfObjectDereference(WDFDEVICE d) { assert(d&&references); --references; }
'''

TEST = r'''
static void reset(GPIO_DEVICE_CONTEXT *c) {
 memset(c,0,sizeof(*c)); memset(registers,0,sizeof(registers));
 writes=drop_write=high_drives=scl_rises=log_count=references=0;
 external_low[0]=external_low[1]=0;
 c->Base=(ULONG_PTR)registers; c->Length=sizeof(registers);
 c->TouchGpioLockReady=c->TouchGpioEnabled=TRUE;
 c->TouchPinsConnected=3; c->TouchDevice=c;
 *ctl(36)=0xabcd0004u; *ctl(37)=0xcdef0004u;
 *io(36)=*io(37)=2u; /* saved high latches, inputs: safe to restore */
}
int main(void) {
 GPIO_DEVICE_CONTEXT c; BOOLEAN scl,sda;
 reset(&c); c.TouchGpioEnabled=FALSE;
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_NOT_SUPPORTED && writes==0);
 reset(&c); c.TouchPinsConnected=1;
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_DEVICE_NOT_READY && writes==0);
 reset(&c); c.TouchBusActive=1;
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_DEVICE_BUSY && writes==0);
 reset(&c); c.TouchBusActive=-1;
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_DEVICE_BUSY && writes==0);
 reset(&c); *ctl(36)=8;
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_DEVICE_CONFIGURATION_ERROR && writes==0 && c.TouchBusActive==0);
 reset(&c); *ctl(36)=0x200; *io(36)=2;
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_DEVICE_CONFIGURATION_ERROR && writes==0);
 reset(&c); *io(37)=0xffffffffu;
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_DEVICE_CONFIGURATION_ERROR && writes==0);
 reset(&c);
 assert(GPIOTouchSetLines(&c,FALSE,FALSE)==STATUS_DEVICE_NOT_READY && writes==0);
 assert(GPIOTouchGpioMode(&c,FALSE)==STATUS_SUCCESS && writes==0);
 GPIOTouchReference(&c); assert(references==1); GPIOTouchDereference(&c); assert(!references);
 assert(GPIOTouchBus(&c,TRUE)==STATUS_SUCCESS && c.TouchBusActive==1);
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_DEVICE_BUSY);
 assert(GPIOTouchBus(&c,FALSE)==STATUS_SUCCESS && !c.TouchBusActive);
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_SUCCESS && c.TouchBusActive==2);
 assert(GPIOTouchBus(&c,TRUE)==STATUS_DEVICE_BUSY);
 assert(GPIOTouchBus(&c,FALSE)==STATUS_DEVICE_BUSY);
 assert((*ctl(36)&0x3ffu)==0 && (*ctl(37)&0x3ffu)==0 && !high_drives);
 assert((*io(36)&2u)==0 && (*io(37)&2u)==0);
 assert(GPIOTouchGetLines(&c,&scl,&sda)==STATUS_SUCCESS && scl && sda);
 log_count=0;
 assert(GPIOTouchSetLines(&c,FALSE,FALSE)==STATUS_SUCCESS);
 assert(log_count==2 && log_pins[0]==37 && log_pins[1]==36);
 unsigned edges=scl_rises;
 assert(GPIOTouchSetLines(&c,FALSE,FALSE)==STATUS_SUCCESS && scl_rises==edges);
 assert(GPIOTouchGetLines(&c,&scl,&sda)==STATUS_SUCCESS && !scl && !sda);
 log_count=0;
 assert(GPIOTouchSetLines(&c,TRUE,FALSE)==STATUS_SUCCESS);
 assert(log_count==2 && log_pins[0]==36 && log_pins[1]==37);
 external_low[1]=1;
 assert(GPIOTouchGetLines(&c,&scl,&sda)==STATUS_SUCCESS && !scl && !sda);
 external_low[1]=0; external_low[0]=1;
 assert(GPIOTouchSetLines(&c,TRUE,TRUE)==STATUS_SUCCESS);
 assert(GPIOTouchGetLines(&c,&scl,&sda)==STATUS_SUCCESS && scl && !sda);
 external_low[0]=0;
 *ctl(36)|=0x04000000u;
 assert(GPIOTouchGpioMode(&c,FALSE)==STATUS_SUCCESS && !c.TouchBusActive);
 assert(*ctl(36)==0xafcd0004u && *ctl(37)==0xcdef0004u);
 assert((*io(36)&2u)==2 && (*io(37)&2u)==2 && !high_drives);
 reset(&c); drop_write=2;
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_IO_DEVICE_ERROR && c.TouchBusActive==2);
 drop_write=0;
 assert(GPIOTouchGpioMode(&c,FALSE)==STATUS_SUCCESS && !c.TouchBusActive && !high_drives);
 reset(&c);
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_SUCCESS);
 assert(GPIOTouchSetLines(&c,FALSE,FALSE)==STATUS_SUCCESS);
 drop_write=writes+1;
 assert(GPIOTouchGpioMode(&c,FALSE)==STATUS_IO_DEVICE_ERROR && c.TouchBusActive==2);
 assert(GPIOTouchGpioMode(&c,TRUE)==STATUS_DEVICE_BUSY);
 drop_write=0;
 assert(GPIOTouchGpioMode(&c,FALSE)==STATUS_SUCCESS && !c.TouchBusActive && !high_drives);
 assert(GPIOTouchGetLines(&c,NULL,&sda)==STATUS_INVALID_PARAMETER);
 c.Base=0;
 assert(GPIOTouchSetLines(&c,TRUE,TRUE)==STATUS_DEVICE_NOT_READY);
 puts("Actual GPIO v3 provider: ownership, electrical order, input levels, rollback and retention passed");
 return 0;
}
'''

with tempfile.TemporaryDirectory(prefix="timelm-gpio-v3-") as tmp:
    path = Path(tmp)
    source = path / "test.c"
    source.write_text(SHIM + production + TEST)
    executable = path / "test"
    subprocess.run([os.environ.get("CC", "gcc"), "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-Wno-unused-function", "-fsanitize=address,undefined", "-g", "-I", str(HERE),
                    str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)

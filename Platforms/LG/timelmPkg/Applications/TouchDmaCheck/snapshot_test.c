// SPDX-License-Identifier: BSD-2-Clause-Patent
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "Snapshot.h"
static TD_U32 Registers[1024], Reads;
static TD_U32 Read(void *Context, TD_U32 Offset)
{
  (void)Context;
  assert(!(Offset&3u) && Offset < 0x1000u);
  ++Reads;
  return Registers[Offset/4];
}
static void Init(void)
{
  memset(Registers,0,sizeof(Registers)); Reads=0;
  Registers[0x20/4]=0x4c017e57; Registers[0x24/4]=0x6000004a;
}
int main(void)
{
  TD_SNAPSHOT S;
  Init(); Registers[0]=0x2d0406;
  Registers[0x808/4]=0x800004e0; Registers[0xc08/4]=2;
  assert(TouchDmaSnapshot(0,Read,&S) && S.Valid==1 && S.Matches==0 && !S.Bypass && S.DefaultFault);
  Init(); Registers[0x800/4]=0x80000056; Registers[0xc00/4]=0x10000;
  assert(TouchDmaSnapshot(0,Read,&S) && S.Bypass && S.Matches==1);
  Registers[0xc00/4]=0;
  assert(TouchDmaSnapshot(0,Read,&S) && S.Conflict && !S.Bypass);
  Registers[0xc00/4]=0x20000;
  assert(TouchDmaSnapshot(0,Read,&S) && S.Conflict && !S.Bypass);
  Registers[0xc00/4]=0x10000; Registers[0]=1;
  assert(TouchDmaSnapshot(0,Read,&S) && !S.Bypass);
  Init(); Registers[0x800/4]=0x80010056; Registers[0xc00/4]=0x10000;
  Registers[0x804/4]=0x80000056;
  assert(TouchDmaSnapshot(0,Read,&S) && S.Matches==2 && S.Conflict && !S.Bypass);
  Init(); Registers[0]=0x2d0406;
  Registers[0x800/4]=0x800004a0; Registers[0xc00/4]=0;
  assert(TouchDmaSnapshot(0,Read,&S) && S.Valid==1 && S.Matches==0 && !S.Bypass);
  Registers[0xc04/4]=0x10000;
  Registers[0x804/4]=0x80000056;
  assert(TouchDmaSnapshot(0,Read,&S) && S.Valid==2 && S.Matches==1 && S.Bypass);
  Init(); Registers[0x20/4]=0xffffffff;
  assert(!TouchDmaSnapshot(0,Read,&S) && Reads==3 && !S.Valid);
  Init(); Registers[0x24/4]=0;
  assert(!TouchDmaSnapshot(0,Read,&S) && Reads==3);
  puts("Read-only touch DMA snapshot tests passed");
  return 0;
}

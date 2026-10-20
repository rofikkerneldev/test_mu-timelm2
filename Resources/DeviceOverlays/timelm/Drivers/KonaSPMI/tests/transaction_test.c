// SPDX-License-Identifier: MIT
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../Transaction.h"

typedef struct { unsigned int reads,delays,ready,status; } MOCK;
static unsigned int Read(void *context)
{ MOCK *m=context; return ++m->reads>=m->ready ? m->status : 0; }
static void Delay(void *context) { ++((MOCK *)context)->delays; }
int main(void)
{
    unsigned int length,command=0,raw;
    unsigned char input[]={1,2,3,4,5,6,7,8}, output[8];
    for (length=1; length<=8; ++length) {
        assert(KonaSpmiCommand(1,0x105,length,&command));
        assert(command==(0x08000050u | (length-1u)));
        assert(KonaSpmiCommand(0,0x105,length,&command));
        assert(command==(0x50u | (length-1u)));
        memset(output,0,sizeof(output));
        KonaSpmiUnpack(KonaSpmiPack(input,length),output,length);
        if (length>4) KonaSpmiUnpack(KonaSpmiPack(input+4,length-4),output+4,length-4);
        assert(!memcmp(input,output,length));
        if (length<8) assert(output[length]==0);
    }
    command=0xdeadbeefu;
    assert(!KonaSpmiCommand(0,0x105,0,&command) && command==0xdeadbeefu);
    assert(!KonaSpmiCommand(0,0x105,9,&command));
    assert(!KonaSpmiCommand(2,0x105,1,&command));
    assert(!KonaSpmiCommand(0,0x10000,1,&command));
    assert(!KonaSpmiCommand(0,0xff,2,&command));
    assert(KonaSpmiCommand(0,0xffff,1,&command) && command==0xff0u);
    {
        MOCK m={0,0,3,1}; assert(KonaSpmiPoll(Read,Delay,&m,1000,&raw)==KonaSpmiDone);
        assert(m.reads==3 && m.delays==2 && raw==1);
    }
    {
        MOCK m={0,0,1,5}; assert(KonaSpmiPoll(Read,Delay,&m,1000,&raw)==KonaSpmiDenied);
        assert(m.reads==1 && m.delays==0 && raw==5);
    }
    {
        MOCK m={0,0,1,9}; assert(KonaSpmiPoll(Read,Delay,&m,1000,&raw)==KonaSpmiFailed);
    }
    {
        MOCK m={0,0,1001,1}; assert(KonaSpmiPoll(Read,Delay,&m,1000,&raw)==KonaSpmiTimeout);
        assert(m.reads==1000 && m.delays==999 && raw==0);
    }
    {
        MOCK m={0,0,1,0x80}; assert(KonaSpmiPoll(Read,Delay,&m,2,&raw)==KonaSpmiTimeout);
        assert(m.reads==2 && m.delays==1);
    }
    puts("SPMI: byte counts, peripheral boundaries, 1..8 byte packing, terminal errors and bounded polling passed");
}

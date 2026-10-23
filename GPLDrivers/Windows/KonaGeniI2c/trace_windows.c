/* SPDX-License-Identifier: GPL-2.0-only
 * Crash surviving trace for the GPIO bitbang trial.
 *
 * The registry is lost when the kernel bugchecks: the values the driver
 * writes during the device start are still in the memory hive and never
 * reach the disk. Every step of the bitbang path is therefore appended to a
 * file on the Windows volume and flushed to the disk before the next step
 * runs, so the last line of the file names the step that took the kernel
 * down.
 *
 * The device start can run before the file system of the Windows volume is
 * up. The lines are kept in a buffer until the file can be opened, so an
 * early step is never lost when the volume appears later.
 *
 * The trace is best effort. A file system that is not ready, a volume that
 * is not mounted or a failed write never changes the behaviour of the
 * driver: every error is swallowed on purpose. */
#include <ntddk.h>
#include "trace_windows.h"

#define TIMELM_TRACE_DIRECTORY L"\\DosDevices\\C:\\TimelmLogs"
#define TIMELM_TRACE_SUBDIR L"\\DosDevices\\C:\\TimelmLogs\\TouchGpioTrial"
#define TIMELM_TRACE_FILE L"\\DosDevices\\C:\\TimelmLogs\\TouchGpioTrial\\driver-trace.log"
#define TIMELM_TRACE_MAX 256
#define TIMELM_TRACE_BUFFER_LINES 64
#define TIMELM_TRACE_BUFFER_LINE 128

static char TimelmTraceBuffer[TIMELM_TRACE_BUFFER_LINES][TIMELM_TRACE_BUFFER_LINE];
static ULONG TimelmTraceBufferCount = 0;
/* The trace is called from the start and the release path of one device, so
 * the lines never run in parallel. The flag makes that explicit: a second
 * caller skips the trace instead of writing the buffer at the same time. */
static volatile LONG TimelmTraceBusy = 0;

static ULONG TimelmTraceLength(const char *text)
{
    ULONG length = 0;
    if (!text) return 0;
    while (text[length] && length < TIMELM_TRACE_MAX) ++length;
    return length;
}

static void TimelmTraceHex(char *out, ULONG *used, unsigned long value)
{
    static const char digits[] = "0123456789abcdef";
    char tmp[16];
    ULONG n = 0, i;
    if (!value) { out[(*used)++] = '0'; return; }
    while (value && n < sizeof(tmp)) { tmp[n++] = digits[value & 0xfu]; value >>= 4; }
    for (i = n; i > 0; --i) out[(*used)++] = tmp[i - 1];
}

static void TimelmTraceCreateDirectory(UNICODE_STRING path)
{
    OBJECT_ATTRIBUTES attributes;
    IO_STATUS_BLOCK iosb;
    HANDLE directory = NULL;
    RtlZeroMemory(&attributes, sizeof(attributes));
    attributes.Length = sizeof(attributes);
    attributes.ObjectName = &path;
    attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE;
    (void)ZwCreateFile(&directory, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
        &attributes, &iosb, NULL, FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ | FILE_SHARE_WRITE,
        FILE_OPEN_IF, FILE_DIRECTORY_FILE | FILE_SYNCHRONOUS_IO_NONALERT, NULL, 0);
    if (directory) (void)ZwClose(directory);
}

static void TimelmTraceEnsureDirectory(void)
{
    UNICODE_STRING directory = RTL_CONSTANT_STRING(TIMELM_TRACE_DIRECTORY);
    UNICODE_STRING subdirectory = RTL_CONSTANT_STRING(TIMELM_TRACE_SUBDIR);
    TimelmTraceCreateDirectory(directory);
    TimelmTraceCreateDirectory(subdirectory);
}

/* Appends every buffered line to the trace file and flushes it to the disk.
 * The buffer is only cleared when the write succeeded, so a line is never
 * lost and never written twice. */
static void TimelmTraceFlushBuffer(void)
{
    UNICODE_STRING path = RTL_CONSTANT_STRING(TIMELM_TRACE_FILE);
    OBJECT_ATTRIBUTES attributes;
    IO_STATUS_BLOCK iosb;
    HANDLE file = NULL;
    ULONG index;
    NTSTATUS status;
    if (TimelmTraceBufferCount == 0) return;
    RtlZeroMemory(&attributes, sizeof(attributes));
    attributes.Length = sizeof(attributes);
    attributes.ObjectName = &path;
    attributes.Attributes = OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE;
    status = ZwCreateFile(&file, FILE_APPEND_DATA | SYNCHRONIZE, &attributes, &iosb, NULL,
        FILE_ATTRIBUTE_NORMAL, FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_OPEN_IF,
        FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE, NULL, 0);
    if (!NT_SUCCESS(status)) return;
    for (index = 0; index < TimelmTraceBufferCount; ++index) {
        ULONG lineLength = TimelmTraceLength(TimelmTraceBuffer[index]);
        ULONG written = 0;
        if (!lineLength) continue;
        status = ZwWriteFile(file, &iosb, &written, NULL, TimelmTraceBuffer[index], lineLength, NULL, NULL);
        if (!NT_SUCCESS(status)) break;
    }
    if (NT_SUCCESS(status)) {
        (void)ZwFlushBuffersFile(file, &iosb);
        TimelmTraceBufferCount = 0;
    }
    (void)ZwClose(file);
}

static void TimelmTraceLine(const char *tag, unsigned long value, int hasValue)
{
    char line[TIMELM_TRACE_MAX];
    ULONG used = 0, length;
    LARGE_INTEGER ticks;
    if (KeGetCurrentIrql() > PASSIVE_LEVEL) return;
    ticks = KeQueryInterruptTimePrecise(NULL);
    length = TimelmTraceLength(tag);
    if (length > (ULONG)(TIMELM_TRACE_MAX - 40)) length = (ULONG)(TIMELM_TRACE_MAX - 40);
    TimelmTraceHex(line, &used, (unsigned long)ticks.QuadPart);
    line[used++] = ' ';
    if (length) { RtlCopyMemory(&line[used], tag, length); used += length; }
    if (hasValue) {
        line[used++] = ' ';
        TimelmTraceHex(line, &used, value);
    }
    line[used++] = '\r';
    line[used++] = '\n';
    line[used] = 0;
    if (InterlockedCompareExchange(&TimelmTraceBusy, 1, 0) != 0) return;
    TimelmTraceEnsureDirectory();
    if (TimelmTraceBufferCount >= TIMELM_TRACE_BUFFER_LINES) {
        /* The oldest line makes room for the newest one. */
        RtlCopyMemory(TimelmTraceBuffer[0], TimelmTraceBuffer[1],
            TIMELM_TRACE_BUFFER_LINES * TIMELM_TRACE_BUFFER_LINE - TIMELM_TRACE_BUFFER_LINE);
        --TimelmTraceBufferCount;
    }
    if (used > TIMELM_TRACE_BUFFER_LINE - 1) used = TIMELM_TRACE_BUFFER_LINE - 1;
    RtlCopyMemory(TimelmTraceBuffer[TimelmTraceBufferCount], line, used);
    TimelmTraceBuffer[TimelmTraceBufferCount][used] = 0;
    ++TimelmTraceBufferCount;
    TimelmTraceFlushBuffer();
    InterlockedExchange(&TimelmTraceBusy, 0);
}

void TimelmTrace(const char *tag)
{
    TimelmTraceLine(tag, 0, 0);
}

void TimelmTraceValue(const char *tag, unsigned long value)
{
    TimelmTraceLine(tag, value, 1);
}

void TimelmTraceStatus(const char *tag, long status)
{
    TimelmTraceLine(tag, (unsigned long)status, 1);
}

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
 * Every call is best effort. A failing trace never changes the trial.
 */
#ifndef TIMELM_TRACE_WINDOWS_H
#define TIMELM_TRACE_WINDOWS_H
#if defined(_WIN32) || defined(_WIN64)
/* The kernel build links trace_windows.c. */
void TimelmTrace(const char *tag);
void TimelmTraceValue(const char *tag, unsigned long value);
void TimelmTraceStatus(const char *tag, long status);
#else
/* The host build of the adapter runs on a machine without the kernel trace.
 * The stubs keep the production source free of test only #ifdef branches and
 * still compile the very same call sites. */
static inline void TimelmTrace(const char *tag) { (void)tag; }
static inline void TimelmTraceValue(const char *tag, unsigned long value) { (void)tag; (void)value; }
static inline void TimelmTraceStatus(const char *tag, long status) { (void)tag; (void)status; }
#endif
#endif

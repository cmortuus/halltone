// Lets a helper thread (the decode pump) run as part of the audio device's real-time workgroup,
// so the OS schedules it like the IO thread: when the screen locks and the app is backgrounded it
// isn't deprioritized long enough to let a small playback buffer run dry. Apple marks the
// workgroup API unavailable in Swift, hence C.
#include "CHalltone.h"
#include <AudioToolbox/AudioToolbox.h>
#include <os/workgroup.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>

_Static_assert(sizeof(os_workgroup_join_token_s) <= sizeof(((es_wg_membership *)0)->token),
               "es_wg_membership.token too small for os_workgroup_join_token_s");

static void es_make_current_thread_realtime(double period_ms) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    double ticks_per_ms = ((double)tb.denom / (double)tb.numer) * 1e6;
    thread_time_constraint_policy_data_t policy;
    policy.period = (uint32_t)(period_ms * ticks_per_ms);
    policy.computation = (uint32_t)(1.0 * ticks_per_ms);
    policy.constraint = (uint32_t)(period_ms * ticks_per_ms);
    policy.preemptible = 1;
    thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                      (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

int es_wg_join(void *audio_unit, double period_ms, es_wg_membership *m) {
    if (m == NULL || audio_unit == NULL) return -1;
    m->joined = 0;
    m->workgroup = NULL;
    es_make_current_thread_realtime(period_ms);
    os_workgroup_t wg = NULL;
    UInt32 size = sizeof(wg);
    OSStatus st = AudioUnitGetProperty((AudioUnit)audio_unit, kAudioOutputUnitProperty_OSWorkgroup,
                                       kAudioUnitScope_Global, 0, &wg, &size);
    if (st != noErr || wg == NULL) return (int)st ?: -2;
    int r = os_workgroup_join(wg, (os_workgroup_join_token_t)m->token);
    if (r != 0) { os_release(wg); return r; }
    m->workgroup = wg;
    m->joined = 1;
    return 0;
}

void es_wg_leave(es_wg_membership *m) {
    if (m == NULL || !m->joined) return;
    os_workgroup_leave((os_workgroup_t)m->workgroup, (os_workgroup_join_token_t)m->token);
    os_release((os_workgroup_t)m->workgroup);
    m->workgroup = NULL;
    m->joined = 0;
}

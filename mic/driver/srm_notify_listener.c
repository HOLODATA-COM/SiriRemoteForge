// Validation listener for the driver's demand-detection Darwin notification. Proves the signal
// crosses the coreaudiod sandbox into a normal user process: subscribes to the same name the
// plug-in posts (au.holodata.SiriRemoteMic.consumers) and prints the running-client count carried
// in the notification state on every fire. This is exactly what the on-demand supervisor will do.
#include <notify.h>
#include <dispatch/dispatch.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#define kConsumersNotification "au.holodata.SiriRemoteMic.consumers"

// Seconds since listener launch — lets a validation run correlate fires with client start/stop.
static double elapsed(void)
{
    static double sStart = 0.0;
    const double now = (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) * 1e-9;
    if (sStart == 0.0) { sStart = now; }
    return now - sStart;
}

int main(void)
{
    // A late-starting supervisor must not wait for the next edge: one notify_get_state gives
    // ground truth immediately. Exercise that path first, before subscribing.
    int checkToken = NOTIFY_TOKEN_INVALID;
    if (notify_register_check(kConsumersNotification, &checkToken) == NOTIFY_STATUS_OK)
    {
        uint64_t count = 0;
        notify_get_state(checkToken, &count);
        printf("initial state: active count=%llu\n", (unsigned long long)count);
        fflush(stdout);
    }

    int token = NOTIFY_TOKEN_INVALID;
    const uint32_t status = notify_register_dispatch(kConsumersNotification, &token,
        dispatch_get_main_queue(), ^(int firedToken) {
            // State is written by the plug-in BEFORE it posts, so the count read here is
            // always the post-transition total.
            uint64_t count = 0;
            notify_get_state(firedToken, &count);
            printf("[%7.3fs] fired: active count=%llu\n", elapsed(), (unsigned long long)count);
            fflush(stdout);
        });
    if (status != NOTIFY_STATUS_OK)
    {
        fprintf(stderr, "srm_notify_listener: notify_register_dispatch failed status=%u\n", status);
        return 1;
    }

    printf("srm_notify_listener: listening on %s\n", kConsumersNotification);
    fflush(stdout);
    dispatch_main();    // runs until killed
}

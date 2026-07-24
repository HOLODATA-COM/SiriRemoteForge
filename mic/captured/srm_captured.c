//
//  srm_captured.c — the "Siri Remote Mic" capture daemon.
//
//  Runs as root from a LaunchDaemon. It exists to answer demand: the HAL plug-in broadcasts
//  `au.holodata.SiriRemoteMic.consumers` whenever an app opens or closes the virtual mic device
//  (state = number of devices with IO running; treat >=1 as "in use"). This daemon watches that
//  notification and runs the heavy, privileged capture pipeline — PacketLogger (HCI sniff) feeding
//  srm_router (voice extraction → shared-memory ring the plug-in reads) — ONLY while some app is
//  actually using the device. Idle apps cost nothing; the moment one selects "Siri Remote Mic",
//  the remote's audio starts flowing with no manual scripts and no sudo prompt.
//
//  WHY ROOT: PacketLogger's HCI capture and the MobileBluetooth debug traces both require root.
//  A LaunchDaemon is the standard way to grant exactly that, once, instead of a per-use password.
//  The pipeline binaries are unchanged from the validated manual path; this only orchestrates them.
//
//  BUILD:   ./build.sh          INSTALL: ./install.sh (needs sudo)          REMOVE: ./uninstall.sh
//

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <notify.h>
#include <dispatch/dispatch.h>

extern char **environ;

// --- fixed paths (see install.sh — the router is copied next to this binary) -------------------
#define NOTIF_NAME    "au.holodata.SiriRemoteMic.consumers"
#define PKLG_PATH     "/tmp/srm_captured.pklg"
#define PACKETLOGGER  "/Applications/PacketLogger.app/Contents/Resources/packetlogger"
#define ROUTER_PATH   "/Library/Application Support/SiriRemoteMic/srm_router"
#define BT_DEBUG_DOMAIN "/Library/Preferences/com.apple.MobileBluetooth.debug"

// A brief grace period before tearing the pipeline down after the last app closes the device.
// Apps routinely close-then-reopen the input (device format changes, call renegotiation); without
// this every such blip would restart PacketLogger. 3 s is imperceptible yet absorbs the churn.
#define STOP_DEBOUNCE_SECONDS 3

static pid_t g_packetlogger = -1;
static pid_t g_router = -1;
static int   g_pipeline_up = 0;
static dispatch_source_t g_stop_timer = NULL;

static void logmsg(const char *fmt, ...)
{
    char ts[32];
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(ts, sizeof ts, "%H:%M:%S", &tmv);
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "[srm_captured %s] ", ts);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
    fflush(stderr);
}

// posix_spawn a child, return its pid (or -1). argv[0] is conventionally the program name.
static pid_t spawn_child(const char *path, char *const argv[])
{
    pid_t pid = -1;
    int rc = posix_spawn(&pid, path, NULL, NULL, argv, environ);
    if (rc != 0) {
        logmsg("spawn %s failed: %s", path, strerror(rc));
        return -1;
    }
    return pid;
}

static void spawn_and_wait(const char *path, char *const argv[])
{
    pid_t pid = spawn_child(path, argv);
    if (pid > 0) waitpid(pid, NULL, 0);
}

// Enable the Bluetooth HCI debug traces PacketLogger needs to see the remote's voice notifications
// (RawAudioTrace) and defeat the profile-required wall (HCISkipAuth). These reset on reboot, so the
// daemon re-asserts them; SIGUSR1 (-30) makes bluetoothd reload debug config WITHOUT disconnecting.
static void ensure_hci_traces(void)
{
    char *dargs[] = {
        "defaults", "write", BT_DEBUG_DOMAIN, "HCITraces", "-dict",
        "StackDebugEnabled", "-bool", "true",
        "HCILiveTraces",     "-bool", "true",
        "HCIFileTraces",     "-bool", "true",
        "RawAudioTrace",     "-bool", "true",
        "HIDTrace",          "-bool", "true",
        "HCISkipAuth",       "-bool", "true",
        NULL
    };
    spawn_and_wait("/usr/bin/defaults", dargs);
    char *kargs[] = { "killall", "-30", "bluetoothd", NULL };
    spawn_and_wait("/usr/bin/killall", kargs);
    logmsg("HCI debug traces asserted");
}

// The FIRST PacketLogger launch after a boot pays a ~6 s cold dyld/framework load (measured: the
// very first start_pipeline of a boot logs ~6 s "pipeline up"; every later one is ~0.2 s once its
// code is cached). Pay that cost ONCE here at daemon startup — which runs at boot, before any app
// needs the mic — so the user's first real demand starts warm (~0.2 s). A throwaway capture we
// immediately discard; nothing reads it. Runs synchronously before the demand watch is armed: a
// device already in use at boot is still handled, because main() reads demand STATE for ground
// truth after this returns (a missed edge during the warm-up does not lose the start).
static void prewarm_packetlogger(void)
{
    const char *warm = "/tmp/srm_prewarm.pklg";
    unlink(warm);
    char *plargs[] = { "packetlogger", "convert", "-o", (char *)warm, NULL };
    pid_t pid = spawn_child(PACKETLOGGER, plargs);
    if (pid <= 0) return;
    // Wait until it has faulted in its frameworks and written the first HCI bytes — that write IS
    // the cold cost being paid. Capped generously to tolerate a genuine post-boot cold launch.
    for (int i = 0; i < 200; ++i) {                 // up to 10 s
        struct stat st;
        if (stat(warm, &st) == 0 && st.st_size > 0) break;
        usleep(50 * 1000);
    }
    usleep(200 * 1000);                             // small margin past the first write
    kill(pid, SIGKILL);
    waitpid(pid, NULL, 0);                          // reaped here, before the SIGCHLD source exists
    unlink(warm);
    logmsg("PacketLogger pre-warmed");
}

static void start_pipeline(void)
{
    if (g_pipeline_up) return;
    g_pipeline_up = 1;
    logmsg("demand active → starting capture pipeline");

    unlink(PKLG_PATH);
    char *plargs[] = { "packetlogger", "convert", "-o", PKLG_PATH, NULL };
    g_packetlogger = spawn_child(PACKETLOGGER, plargs);
    if (g_packetlogger < 0) { g_pipeline_up = 0; return; }

    // Wait until PacketLogger's lossless file exists and is growing before the router tails it
    // (the router treats a missing/empty file as an error). ~5 s cap; it normally appears instantly.
    for (int i = 0; i < 100; ++i) {
        struct stat st;
        if (stat(PKLG_PATH, &st) == 0 && st.st_size > 0) break;
        usleep(50 * 1000);
    }

    char *rargs[] = { "srm_router", "--pklg", PKLG_PATH, NULL };
    g_router = spawn_child(ROUTER_PATH, rargs);
    if (g_router < 0) logmsg("router failed to start — pipeline degraded");
    else logmsg("pipeline up (packetlogger=%d router=%d)", g_packetlogger, g_router);
}

static void stop_pipeline(void)
{
    if (!g_pipeline_up) return;
    g_pipeline_up = 0;
    logmsg("demand idle → stopping capture pipeline");
    // SIGKILL, and NEVER a blocking waitpid here. This handler runs on the main dispatch queue; an
    // earlier version sent SIGINT then `waitpid(..., 0)` and hung the whole daemon when the router
    // didn't exit promptly from its tail loop — a stuck teardown froze all future demand handling.
    // SIGKILL can't be caught or delayed, and the SIGCHLD source below reaps the zombies async. The
    // router/PacketLogger have no state worth flushing here (the .pklg is transient), so this is safe.
    if (g_router > 0)       { kill(g_router, SIGKILL); g_router = -1; }
    if (g_packetlogger > 0) { kill(g_packetlogger, SIGKILL); g_packetlogger = -1; }
    unlink(PKLG_PATH);
}

static void cancel_stop_timer(void)
{
    if (g_stop_timer) { dispatch_source_cancel(g_stop_timer); g_stop_timer = NULL; }
}

// React to the plug-in's demand edge. state>=1 → in use, state==0 → idle. We also read state on
// startup for ground truth (an app may already be using the device before the daemon loaded).
static void handle_demand(int token)
{
    uint64_t state = 0;
    notify_get_state(token, &state);
    if (state >= 1) {
        cancel_stop_timer();        // a re-open cancels a pending teardown
        start_pipeline();
    } else {
        if (g_stop_timer) return;   // teardown already scheduled
        g_stop_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(g_stop_timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)STOP_DEBOUNCE_SECONDS * NSEC_PER_SEC),
                                  DISPATCH_TIME_FOREVER, (uint64_t)(0.5 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(g_stop_timer, ^{
            cancel_stop_timer();
            stop_pipeline();
        });
        dispatch_resume(g_stop_timer);
    }
}

static void on_term(int sig)
{
    (void)sig;
    stop_pipeline();
    _exit(0);
}

int main(void)
{
    signal(SIGTERM, on_term);
    signal(SIGINT, on_term);
    signal(SIGPIPE, SIG_IGN);

    logmsg("starting");
    ensure_hci_traces();
    prewarm_packetlogger();

    // Reap any child that dies on its own (e.g. PacketLogger quitting) so it can't linger as a
    // zombie; if it was our live pipeline, drop our bookkeeping so the next demand edge restarts it.
    dispatch_source_t sigchld = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGCHLD, 0,
                                                       dispatch_get_main_queue());
    dispatch_source_set_event_handler(sigchld, ^{
        int status;
        pid_t dead;
        while ((dead = waitpid(-1, &status, WNOHANG)) > 0) {
            if (dead == g_router)      { g_router = -1; }
            if (dead == g_packetlogger){ g_packetlogger = -1; }
            if (g_pipeline_up && g_router < 0 && g_packetlogger < 0) {
                logmsg("pipeline processes exited unexpectedly");
                g_pipeline_up = 0;
            }
        }
    });
    signal(SIGCHLD, SIG_DFL);   // let the dispatch source observe; default disposition delivers it
    dispatch_resume(sigchld);

    int token = 0;
    uint32_t rc = notify_register_dispatch(NOTIF_NAME, &token, dispatch_get_main_queue(), ^(int t) {
        handle_demand(t);
    });
    if (rc != NOTIFY_STATUS_OK) {
        logmsg("notify_register_dispatch(%s) failed: %u — cannot detect demand, exiting", NOTIF_NAME, rc);
        return 1;
    }

    handle_demand(token);   // ground truth at startup (device may already be in use)
    logmsg("watching demand on %s", NOTIF_NAME);
    dispatch_main();
    return 0;
}

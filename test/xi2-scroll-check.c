/* xi2-scroll-check.c
 *
 * Self-contained runtime prover for the XI2.1 ScrollClass patch
 * (patches/xserver-0006-scroll-valuators.patch). Talks to a live X display
 * over libX11/libXi/libXtst only -- no xinput/xdotool -- and performs
 * exactly one of three checks per run, printing the concrete numbers it
 * observed and exiting non-zero on any assertion failure.
 *
 * Build: cc xi2-scroll-check.c -lXtst -lXi -lX11 -o xi2-scroll-check
 * Usage:
 *   xi2-scroll-check a           -- assert the XTEST pointer's scroll class
 *   xi2-scroll-check b           -- legacy wheel-button emulation regression
 *   xi2-scroll-check c <delta>   -- XTestFakeDeviceMotionEvent injection
 */
#include <X11/Xlib.h>
#include <X11/extensions/XInput.h>
#include <X11/extensions/XInput2.h>
#include <X11/extensions/XTest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/time.h>

#define XTEST_POINTER_NAME "Virtual core XTEST pointer"

static Display *dpy;

static void die(const char *msg)
{
    fprintf(stderr, "xi2-scroll-check: %s\n", msg);
    exit(1);
}

/* Xlib's default error handler prints the error and then calls exit(1),
 * which would make an unpatched or misbehaving server kill this process
 * before check_c() gets to report anything -- confirmed by actually running
 * this against an unpatched Xvfb, where XTestFakeDeviceMotionEvent's
 * first_axis=2 is BadValue on a 2-axis device and the whole process died
 * before printing its own result. Report the protocol error and return 0 so
 * the check that triggered it can decide what it means. */
static int nonfatal_error_handler(Display *handler_dpy, XErrorEvent *err)
{
    char text[128];

    XGetErrorText(handler_dpy, err->error_code, text, sizeof(text));
    fprintf(stderr,
            "xi2-scroll-check: X protocol error: %s (request %d.%d)\n",
            text, err->request_code, err->minor_code);
    return 0;
}

/* Locate "Virtual core XTEST pointer" via XIQueryDevice, assert it is a
 * slave pointer (not just the master -- Chromium's device-data manager
 * ignores master scroll classes), and report every XIScrollClassInfo entry
 * found on it. Returns the device id. */
static int find_xtest_pointer(void)
{
    int ndevices, i, j, deviceid = -1, found = 0;
    XIDeviceInfo *devices = XIQueryDevice(dpy, XIAllDevices, &ndevices);

    if (!devices)
        die("XIQueryDevice failed");

    for (i = 0; i < ndevices; i++) {
        XIDeviceInfo *dev = &devices[i];

        if (strcmp(dev->name, XTEST_POINTER_NAME) != 0)
            continue;
        found = 1;

        if (dev->use != XISlavePointer) {
            fprintf(stderr,
                    "xi2-scroll-check: %s has use=%d, expected XISlavePointer(%d)\n",
                    XTEST_POINTER_NAME, dev->use, XISlavePointer);
            exit(1);
        }
        deviceid = dev->deviceid;
        printf("device: id=%d name=\"%s\" use=%d\n", dev->deviceid, dev->name, dev->use);

        for (j = 0; j < dev->num_classes; j++) {
            XIAnyClassInfo *cls = dev->classes[j];

            if (cls->type == XIScrollClass) {
                XIScrollClassInfo *scroll = (XIScrollClassInfo *) cls;

                printf("scroll-class: number=%d scroll_type=%d increment=%g flags=%d\n",
                       scroll->number, scroll->scroll_type, scroll->increment,
                       scroll->flags);
            }
        }
        break;
    }

    XIFreeDeviceInfo(devices);
    if (!found)
        die("could not find " XTEST_POINTER_NAME);
    return deviceid;
}

static int check_a(void)
{
    int ndevices, i, j;
    XIDeviceInfo *devices;
    int deviceid = find_xtest_pointer();
    int has_h = 0, has_v = 0;
    double h_inc = -1, v_inc = -1;
    int h_flags = 0, v_flags = 0;

    devices = XIQueryDevice(dpy, deviceid, &ndevices);
    if (!devices)
        die("XIQueryDevice(deviceid) failed");
    for (i = 0; i < ndevices; i++) {
        for (j = 0; j < devices[i].num_classes; j++) {
            XIAnyClassInfo *cls = devices[i].classes[j];

            if (cls->type != XIScrollClass)
                continue;
            {
                XIScrollClassInfo *scroll = (XIScrollClassInfo *) cls;

                if (scroll->scroll_type == XIScrollTypeHorizontal) {
                    has_h = 1;
                    h_inc = scroll->increment;
                    h_flags = scroll->flags;
                } else if (scroll->scroll_type == XIScrollTypeVertical) {
                    has_v = 1;
                    v_inc = scroll->increment;
                    v_flags = scroll->flags;
                }
            }
        }
    }
    XIFreeDeviceInfo(devices);

    if (!has_h)
        die("no horizontal scroll class on the XTEST pointer");
    if (!has_v)
        die("no vertical scroll class on the XTEST pointer");
    if (h_inc != 120.0)
        die("horizontal scroll increment is not 120.0");
    if (v_inc != 120.0)
        die("vertical scroll increment is not 120.0");
    if (h_flags & XIScrollFlagNoEmulation)
        die("horizontal axis has XIScrollFlagNoEmulation set; legacy wheel clients would break");
    if (v_flags & XIScrollFlagNoEmulation)
        die("vertical axis has XIScrollFlagNoEmulation set; legacy wheel clients would break");

    printf("check-a: PASS (horizontal increment=%g, vertical increment=%g)\n", h_inc, v_inc);
    return 0;
}

/* Select XI_Motion/XI_ButtonPress/XI_ButtonRelease from all devices on the
 * root window and read events for up to timeout_ms, invoking cb for each
 * XIDeviceEvent seen. Stops early if cb returns non-zero. */
static void pump_events(Window root, int timeout_ms, int (*cb)(XIDeviceEvent *))
{
    XIEventMask evmask;
    unsigned char mask[XIMaskLen(XI_LASTEVENT)];
    int xi_opcode, event, error;
    struct timeval deadline, now;

    if (!XQueryExtension(dpy, "XInputExtension", &xi_opcode, &event, &error))
        die("XInputExtension not available");

    memset(mask, 0, sizeof(mask));
    XISetMask(mask, XI_Motion);
    XISetMask(mask, XI_ButtonPress);
    XISetMask(mask, XI_ButtonRelease);
    evmask.deviceid = XIAllDevices;
    evmask.mask_len = sizeof(mask);
    evmask.mask = mask;
    if (XISelectEvents(dpy, root, &evmask, 1) != Success)
        die("XISelectEvents failed");
    XFlush(dpy);

    gettimeofday(&deadline, NULL);
    deadline.tv_sec += timeout_ms / 1000;
    deadline.tv_usec += (timeout_ms % 1000) * 1000;
    if (deadline.tv_usec >= 1000000) {
        deadline.tv_sec += 1;
        deadline.tv_usec -= 1000000;
    }

    for (;;) {
        gettimeofday(&now, NULL);
        if (now.tv_sec > deadline.tv_sec ||
            (now.tv_sec == deadline.tv_sec && now.tv_usec >= deadline.tv_usec))
            return;

        while (XPending(dpy)) {
            XEvent ev;
            XGenericEventCookie *cookie = (XGenericEventCookie *) &ev.xcookie;

            XNextEvent(dpy, &ev);
            if (ev.type != GenericEvent || cookie->extension != xi_opcode)
                continue;
            if (!XGetEventData(dpy, cookie))
                continue;
            if (cookie->evtype == XI_Motion || cookie->evtype == XI_ButtonPress ||
                cookie->evtype == XI_ButtonRelease) {
                if (cb((XIDeviceEvent *) cookie->data)) {
                    XFreeEventData(dpy, cookie);
                    return;
                }
            }
            XFreeEventData(dpy, cookie);
        }

        {
            fd_set fds;
            struct timeval tv = { 0, 20000 };

            FD_ZERO(&fds);
            FD_SET(ConnectionNumber(dpy), &fds);
            select(ConnectionNumber(dpy) + 1, &fds, NULL, NULL, &tv);
        }
    }
}

/* Reads the value packed for valuator index `axis` out of an XIValuatorState,
 * per the XI2 sparse-valuator encoding: `values[]` holds only the axes whose
 * bit is set in `mask`, in ascending axis-number order. Returns 0 and leaves
 * *out untouched if the axis bit is not set. */
static int valuator_value(XIValuatorState *v, int axis, double *out)
{
    int i, idx = 0;

    if (axis >= v->mask_len * 8 || !XIMaskIsSet(v->mask, axis))
        return 0;
    for (i = 0; i < axis; i++)
        if (XIMaskIsSet(v->mask, i))
            idx++;
    *out = v->values[idx];
    return 1;
}

struct check_b_state {
    int saw_motion;
    double motion_v3;
    int saw_emulated_button;
};

static struct check_b_state b_state;

static int check_b_callback(XIDeviceEvent *de)
{
    double value;

    if (de->evtype == XI_Motion) {
        if (valuator_value(&de->valuators, 3, &value)) {
            b_state.saw_motion = 1;
            b_state.motion_v3 = value;
            printf("check-b: motion event: valuator[3]=%g flags=0x%x\n",
                   value, de->flags);
        }
    } else if (de->evtype == XI_ButtonPress) {
        printf("check-b: button press: detail=%d flags=0x%x\n", de->detail,
               de->flags);
        if (de->detail == 5 && (de->flags & XIPointerEmulated))
            b_state.saw_emulated_button = 1;
    }
    return b_state.saw_motion && b_state.saw_emulated_button;
}

static int check_b(void)
{
    Window root = DefaultRootWindow(dpy);

    find_xtest_pointer();
    memset(&b_state, 0, sizeof(b_state));

    XTestFakeButtonEvent(dpy, 5, True, CurrentTime);
    XTestFakeButtonEvent(dpy, 5, False, CurrentTime);
    XFlush(dpy);

    pump_events(root, 2000, check_b_callback);

    if (!b_state.saw_motion)
        die("no motion event with a valuator[3] delta after button 5 click");
    if (b_state.motion_v3 != 120.0)
        die("legacy wheel click did not move valuator 3 by exactly 120");
    if (!b_state.saw_emulated_button)
        die("no XIPointerEmulated button-5 event alongside the motion");

    printf("check-b: PASS (valuator[3] delta=%g, emulated button seen)\n",
           b_state.motion_v3);
    return 0;
}

struct check_c_state {
    int saw_motion;
    double motion_v3;
    int xy_touched;
};

static struct check_c_state c_state;

static int check_c_callback(XIDeviceEvent *de)
{
    double value;

    if (de->evtype != XI_Motion)
        return 0;
    if (XIMaskIsSet(de->valuators.mask, 0) || XIMaskIsSet(de->valuators.mask, 1))
        c_state.xy_touched = 1;
    if (valuator_value(&de->valuators, 3, &value)) {
        c_state.saw_motion = 1;
        c_state.motion_v3 = value;
        printf("check-c: motion event: valuator[3]=%g\n", value);
        return 1;
    }
    return 0;
}

static int check_c(double delta)
{
    Window root = DefaultRootWindow(dpy);
    int deviceid = find_xtest_pointer();
    XDevice *xdev = XOpenDevice(dpy, deviceid);
    int axes[2];

    if (!xdev)
        die("XOpenDevice failed on the XTEST pointer");

    memset(&c_state, 0, sizeof(c_state));
    axes[0] = 0;
    axes[1] = (int) delta;
    if (!XTestFakeDeviceMotionEvent(dpy, xdev, True, 2, axes, 2, 0))
        die("XTestFakeDeviceMotionEvent failed");
    XFlush(dpy);

    pump_events(root, 2000, check_c_callback);
    XCloseDevice(dpy, xdev);

    if (!c_state.saw_motion) {
        printf("check-c: delta=%g produced no motion event (see design doc's "
               "known-risk note; report this honestly, do not paper over it)\n",
               delta);
        return delta == 0.0 ? 0 : 1;
    }
    if (c_state.motion_v3 != delta)
        die("injected delta did not match the observed valuator[3] motion");
    if (c_state.xy_touched)
        die("injection moved x/y even though first_axis=2 excluded them");

    printf("check-c: PASS (delta=%g, observed valuator[3]=%g, x/y untouched)\n",
           delta, c_state.motion_v3);
    return 0;
}

int main(int argc, char **argv)
{
    int major = 2, minor = 1;
    int rc;

    if (argc < 2)
        die("usage: xi2-scroll-check a|b|c [delta]");

    dpy = XOpenDisplay(NULL);
    if (!dpy)
        die("cannot open display");
    XSetErrorHandler(nonfatal_error_handler);

    if (XIQueryVersion(dpy, &major, &minor) != Success || major < 2 ||
        (major == 2 && minor < 1))
        die("server does not support XI 2.1");

    if (strcmp(argv[1], "a") == 0) {
        rc = check_a();
    } else if (strcmp(argv[1], "b") == 0) {
        rc = check_b();
    } else if (strcmp(argv[1], "c") == 0) {
        double delta = argc >= 3 ? atof(argv[2]) : 37.0;

        rc = check_c(delta);
    } else {
        die("unknown check; expected a, b, or c");
        rc = 2;
    }

    XCloseDisplay(dpy);
    return rc;
}

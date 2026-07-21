#include <GL/gl.h>
#include <GL/glx.h>
#include <X11/Xlib.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int ascii_tolower(int value)
{
    if (value >= 'A' && value <= 'Z')
        return value + ('a' - 'A');
    return value;
}

static int contains_case_insensitive(const char *text, const char *needle,
                                     size_t needle_length)
{
    const char *candidate;
    size_t index;

    if (needle_length == 0)
        return 1;

    for (candidate = text; *candidate != '\0'; candidate++) {
        for (index = 0; index < needle_length; index++) {
            if (candidate[index] == '\0' ||
                ascii_tolower((unsigned char)candidate[index]) !=
                    ascii_tolower((unsigned char)needle[index]))
                break;
        }
        if (index == needle_length)
            return 1;
    }
    return 0;
}

static int contains_rejected_renderer(const char *renderer, const char *list)
{
    const char *entry = list;

    while (*entry != '\0') {
        const char *end = strchr(entry, ',');
        size_t length = end == NULL ? strlen(entry) : (size_t)(end - entry);

        while (length > 0 && (*entry == ' ' || *entry == '\t')) {
            entry++;
            length--;
        }
        while (length > 0 && (entry[length - 1] == ' ' || entry[length - 1] == '\t'))
            length--;
        if (length > 0 && contains_case_insensitive(renderer, entry, length))
            return 1;
        if (end == NULL)
            break;
        entry = end + 1;
    }
    return 0;
}

static int fail(const char *message)
{
    fprintf(stderr, "glx-render-test: %s\n", message);
    return 1;
}

int main(void)
{
    int attributes[] = {
        GLX_RGBA,
        GLX_RED_SIZE, 8,
        GLX_GREEN_SIZE, 8,
        GLX_BLUE_SIZE, 8,
        GLX_DEPTH_SIZE, 0,
        None
    };
    fprintf(stderr, "step: XOpenDisplay\n");
    Display *display = XOpenDisplay(NULL);
    if (display == NULL)
        return fail("cannot open DISPLAY");

    fprintf(stderr, "step: glXChooseVisual\n");
    XVisualInfo *visual = glXChooseVisual(display, DefaultScreen(display), attributes);
    if (visual == NULL)
        return fail("no suitable GLX visual");

    XSetWindowAttributes window_attributes = {0};
    window_attributes.border_pixel = 0;
    window_attributes.colormap = XCreateColormap(
        display, RootWindow(display, visual->screen), visual->visual, AllocNone);
    window_attributes.event_mask = StructureNotifyMask;
    fprintf(stderr, "step: XCreateWindow\n");
    Window window = XCreateWindow(
        display, RootWindow(display, visual->screen), 0, 0, 64, 64, 0,
        visual->depth, InputOutput, visual->visual,
        CWBorderPixel | CWColormap | CWEventMask, &window_attributes);
    XMapWindow(display, window);
    XSync(display, False);

    fprintf(stderr, "step: glXCreateContext\n");
    GLXContext context = glXCreateContext(display, visual, NULL, False);
    if (context == NULL)
        return fail("cannot create indirect GLX context");
    fprintf(stderr, "step: glXIsDirect\n");
    if (glXIsDirect(display, context))
        return fail("context unexpectedly uses direct rendering");
    fprintf(stderr, "step: glXMakeCurrent\n");
    if (!glXMakeCurrent(display, window, context))
        return fail("cannot make GLX context current");

    fprintf(stderr, "step: glGetString\n");
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    const char *expected_renderer = getenv("XVFB_STATIC_EXPECT_RENDERER");
    const char *rejected_renderers = getenv("XVFB_STATIC_REJECT_RENDERERS");
    if (expected_renderer == NULL)
        expected_renderer = "llvmpipe";
    if (renderer == NULL ||
        !contains_case_insensitive(renderer, expected_renderer,
                                   strlen(expected_renderer)))
        return fail("GL_RENDERER does not identify the expected renderer");
    if (rejected_renderers != NULL &&
        contains_rejected_renderer(renderer, rejected_renderers))
        return fail("GL_RENDERER identifies a forbidden renderer");

    fprintf(stderr, "step: render\n");
    glViewport(0, 0, 64, 64);
    glClearColor(0.0f, 0.0f, 1.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glColor3f(1.0f, 0.0f, 0.0f);
    glBegin(GL_TRIANGLES);
    glVertex2f(-0.8f, -0.8f);
    glVertex2f(0.8f, -0.8f);
    glVertex2f(0.0f, 0.8f);
    glEnd();
    glFinish();

    fprintf(stderr, "step: readback\n");
    unsigned char center[4] = {0};
    unsigned char corner[4] = {0};
    glReadPixels(32, 32, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, center);
    glReadPixels(2, 60, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner);
    if (center[0] < 200 || center[1] > 30 || center[2] > 30)
        return fail("triangle center pixel is not red");
    if (corner[0] > 30 || corner[1] > 30 || corner[2] < 200)
        return fail("clear-color corner pixel is not blue");

    printf("renderer=%s center=%u,%u,%u corner=%u,%u,%u\n",
           renderer,
           center[0], center[1], center[2],
           corner[0], corner[1], corner[2]);
    glXMakeCurrent(display, None, NULL);
    glXDestroyContext(display, context);
    XDestroyWindow(display, window);
    XCloseDisplay(display);
    return 0;
}

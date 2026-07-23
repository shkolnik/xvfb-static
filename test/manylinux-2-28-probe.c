#define _GNU_SOURCE

#include <dlfcn.h>
#include <gnu/libc-version.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>

static void *thread_main(void *argument)
{
    return argument;
}

int main(void)
{
    static int thread_value = 42;
    struct stat root_status;
    pthread_t thread;
    void *thread_result = NULL;
    void *process_handle;
    volatile double side = 3.0;

    process_handle = dlopen(NULL, RTLD_NOW);
    if (process_handle == NULL) {
        return 1;
    }
    if (stat("/", &root_status) != 0 || !S_ISDIR(root_status.st_mode)) {
        dlclose(process_handle);
        return 2;
    }
    if (hypot(side, 4.0) != 5.0) {
        dlclose(process_handle);
        return 3;
    }
    if (pthread_create(&thread, NULL, thread_main, &thread_value) != 0) {
        dlclose(process_handle);
        return 4;
    }
    if (pthread_join(thread, &thread_result) != 0) {
        dlclose(process_handle);
        return 5;
    }
    dlclose(process_handle);

    printf("glibc %s\n", gnu_get_libc_version());
    return thread_result == &thread_value ? 0 : 6;
}

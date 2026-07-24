#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
    (void)argc;

    const char *executable =
        "/Applications/RawTherapee.app/Contents/MacOS/rawtherapee-cli";

    argv[0] = (char *)executable;
    execv(executable, argv);

    fprintf(
        stderr,
        "rawtherapee-cli: cannot execute %s: %s\n",
        executable,
        strerror(errno)
    );
    return 127;
}

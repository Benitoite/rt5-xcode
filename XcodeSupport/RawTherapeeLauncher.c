#include <mach-o/dyld.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef RAWTHERAPEE_BUNDLE_IDENTIFIER
#define RAWTHERAPEE_BUNDLE_IDENTIFIER "com.rawtherapee.rawtherapee5"
#endif

/*
 * Alternate entry points inside an application bundle are signed as
 * standalone Mach-O executables. App Sandbox needs an embedded bundle
 * identifier to create their container even though the enclosing .app also
 * has an Info.plist.
 */
__attribute__((used, section("__TEXT,__info_plist")))
static const char embeddedInfoPlist[] =
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    "<plist version=\"1.0\"><dict>"
    "<key>CFBundleIdentifier</key><string>"
    RAWTHERAPEE_BUNDLE_IDENTIFIER
    "</string>"
    "</dict></plist>";

static const char *const installedContentsPath =
    "/Applications/RawTherapee.app/Contents";

static void fail(const char *message)
{
    fprintf(stderr, "RawTherapee launcher: %s\n", message);
    exit(EXIT_FAILURE);
}

static char *copy_string(const char *value)
{
    char *copy = strdup(value);
    if (!copy) {
        fail("out of memory");
    }
    return copy;
}

static char *join_path(const char *left, const char *right)
{
    const size_t leftLength = strlen(left);
    const size_t rightLength = strlen(right);
    const bool needsSlash = leftLength > 0 && left[leftLength - 1] != '/';
    char *result = malloc(leftLength + rightLength + (needsSlash ? 2 : 1));

    if (!result) {
        fail("out of memory");
    }

    memcpy(result, left, leftLength);
    if (needsSlash) {
        result[leftLength] = '/';
    }
    memcpy(result + leftLength + (needsSlash ? 1 : 0), right, rightLength);
    result[leftLength + rightLength + (needsSlash ? 1 : 0)] = '\0';
    return result;
}

static char *parent_directory(const char *path)
{
    char *result = copy_string(path);
    char *slash = strrchr(result, '/');

    if (!slash || slash == result) {
        free(result);
        fail("could not determine the application bundle path");
    }

    *slash = '\0';
    return result;
}

static char *launcher_path(void)
{
    uint32_t size = 0;
    if (_NSGetExecutablePath(NULL, &size) != -1 || size == 0) {
        fail("could not determine the launcher path");
    }

    char *unresolved = malloc(size);
    if (!unresolved) {
        fail("out of memory");
    }

    if (_NSGetExecutablePath(unresolved, &size) != 0) {
        free(unresolved);
        fail("could not determine the launcher path");
    }

    char resolved[PATH_MAX];
    if (!realpath(unresolved, resolved)) {
        free(unresolved);
        fail("could not resolve the launcher path");
    }

    free(unresolved);
    return copy_string(resolved);
}

static void set_bundle_environment(
    const char *contents,
    const char *resources,
    const char *frameworks
) {
    char *shared = join_path(resources, "share");
    char *gtk = join_path(shared, "gtk-3.0");
    char *schemas = join_path(shared, "glib-2.0/schemas");

    setenv("DYLD_FALLBACK_LIBRARY_PATH", frameworks, 1);
    setenv("XDG_CONFIG_DIRS", gtk, 1);
    setenv("XDG_CONFIG_HOME", shared, 1);
    setenv("XDG_DATA_DIRS", gtk, 1);
    setenv("XDG_DATA_HOME", shared, 1);
    setenv("GTK_PATH", gtk, 1);
    setenv("GSETTINGS_SCHEMA_DIR", schemas, 1);
    setenv("GDK_PIXBUF_MODULEDIR", frameworks, 1);
    setenv("LIBDIR", frameworks, 1);
    setenv("DATADIR", resources, 1);
    setenv("GDK_RENDERING", "similar", 1);
    setenv("GTK_OVERLAY_SCROLLING", "0", 1);
    setenv("RAWTHERAPEE_XCODE_BUNDLE", contents, 1);

    free(schemas);
    free(gtk);
    free(shared);
}

static char *relocate_database(
    const char *sourcePath,
    const char *contents,
    const char *label
) {
    FILE *source = fopen(sourcePath, "rb");
    if (!source) {
        fprintf(
            stderr,
            "RawTherapee launcher: cannot open %s: %s\n",
            sourcePath,
            strerror(errno)
        );
        return NULL;
    }

    const char *temporaryDirectory = getenv("TMPDIR");
    if (!temporaryDirectory || !temporaryDirectory[0]) {
        temporaryDirectory = "/tmp";
    }

    char destinationPath[PATH_MAX];
    const int pathLength = snprintf(
        destinationPath,
        sizeof(destinationPath),
        "%s%srawtherapee-%u-%d-%s",
        temporaryDirectory,
        temporaryDirectory[strlen(temporaryDirectory) - 1] == '/' ? "" : "/",
        (unsigned)getuid(),
        (int)getpid(),
        label
    );

    if (pathLength < 0 || (size_t)pathLength >= sizeof(destinationPath)) {
        fclose(source);
        fail("temporary path is too long");
    }

    const int descriptor =
        open(destinationPath, O_CREAT | O_TRUNC | O_WRONLY, S_IRUSR | S_IWUSR);
    if (descriptor < 0) {
        fclose(source);
        fail("could not create a relocated GTK database");
    }

    FILE *destination = fdopen(descriptor, "wb");
    if (!destination) {
        close(descriptor);
        fclose(source);
        fail("could not open a relocated GTK database");
    }

    const size_t installedLength = strlen(installedContentsPath);
    int character;
    while ((character = fgetc(source)) != EOF) {
        if (character != installedContentsPath[0]) {
            fputc(character, destination);
            continue;
        }

        char candidate[sizeof("/Applications/RawTherapee.app/Contents")];
        candidate[0] = (char)character;
        const size_t count =
            fread(candidate + 1, 1, installedLength - 1, source);

        if (count == installedLength - 1
            && memcmp(candidate, installedContentsPath, installedLength) == 0) {
            fwrite(contents, 1, strlen(contents), destination);
        } else {
            fwrite(candidate, 1, count + 1, destination);
        }
    }

    if (ferror(source) || fflush(destination) != 0) {
        fclose(source);
        fclose(destination);
        fail("could not write a relocated GTK database");
    }

    fclose(source);
    fclose(destination);
    return copy_string(destinationPath);
}

int main(int argc, char *argv[])
{
    char *executable = launcher_path();
    char *macOS = parent_directory(executable);
    char *contents = parent_directory(macOS);
    char *resources = join_path(contents, "Resources");
    char *frameworks = join_path(contents, "Frameworks");
    const char *invocation = strrchr(argv[0], '/');
    invocation = invocation ? invocation + 1 : argv[0];
    const bool isCLI = strstr(invocation, "-cli") != NULL;
    char *target =
        join_path(macOS, isCLI ? "rawtherapee-cli-bin" : "rawtherapee-bin");

    set_bundle_environment(contents, resources, frameworks);

    char *gtkDirectory = join_path(resources, "etc/gtk-3.0");
    char *pixbufSource = join_path(gtkDirectory, "gdk-pixbuf.loaders");
    char *modulesSource = join_path(gtkDirectory, "gtk.immodules");
    char *pixbufDatabase =
        relocate_database(pixbufSource, contents, "gdk-pixbuf.loaders");
    char *modulesDatabase =
        relocate_database(modulesSource, contents, "gtk.immodules");

    if (pixbufDatabase) {
        setenv("GDK_PIXBUF_MODULE_FILE", pixbufDatabase, 1);
    }
    if (modulesDatabase) {
        setenv("GTK_IM_MODULE_FILE", modulesDatabase, 1);
    }

    char **childArguments = calloc((size_t)argc + 1, sizeof(char *));
    if (!childArguments) {
        fail("out of memory");
    }

    childArguments[0] = target;
    for (int index = 1; index < argc; ++index) {
        childArguments[index] = argv[index];
    }

    if (chdir(macOS) != 0) {
        fail("could not select the bundle executable directory");
    }

    execv(target, childArguments);
    fprintf(
        stderr,
        "RawTherapee launcher: cannot execute %s: %s\n",
        target,
        strerror(errno)
    );
    return EXIT_FAILURE;
}

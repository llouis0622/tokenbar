#include "CSensors.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TB_HELPER_VERSION 1

static int parse_number(const char *text, long minimum, long maximum, long *value) {
    if (text == NULL || *text == '\0' || strlen(text) > 6) return 0;
    char *end = NULL;
    errno = 0;
    long parsed = strtol(text, &end, 10);
    if (errno != 0 || end == NULL || *end != '\0') return 0;
    if (parsed < minimum || parsed > maximum) return 0;
    *value = parsed;
    return 1;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "version") == 0) {
        printf("%d\n", TB_HELPER_VERSION);
        return 0;
    }
    if (geteuid() != 0) {
        fputs("root required\n", stderr);
        return 77;
    }
    int count = tb_fan_count();
    if (argc == 3 && strcmp(argv[1], "auto") == 0) {
        if (strcmp(argv[2], "all") == 0) {
            int ok = 1;
            for (int index = 0; index < count; index++) {
                if (!tb_fan_set_auto(index)) ok = 0;
            }
            return ok ? 0 : 1;
        }
        long index = 0;
        if (!parse_number(argv[2], 0, count - 1, &index)) return 64;
        return tb_fan_set_auto((int)index) ? 0 : 1;
    }
    if (argc == 4 && strcmp(argv[1], "set") == 0) {
        long index = 0;
        long rpm = 0;
        if (!parse_number(argv[2], 0, count - 1, &index)) return 64;
        if (!parse_number(argv[3], 0, 20000, &rpm)) return 64;
        return tb_fan_set_manual((int)index, (double)rpm) ? 0 : 1;
    }
    return 64;
}

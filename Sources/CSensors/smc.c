#include "CSensors.h"

#if defined(__APPLE__)

#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define TB_SMC_SELECTOR 2
#define TB_SMC_READ 5
#define TB_SMC_WRITE 6
#define TB_SMC_KEYINFO 9
#define TB_MAX_FANS 8
#define TB_UNLOCK_ATTEMPTS 24
#define TB_UNLOCK_INTERVAL_US 500000

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} tb_smc_version;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} tb_smc_plimit;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} tb_smc_keyinfo;

typedef struct {
    uint32_t key;
    tb_smc_version vers;
    tb_smc_plimit pLimitData;
    tb_smc_keyinfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} tb_smc_param;

_Static_assert(sizeof(tb_smc_param) == 80, "unexpected SMC parameter layout");

typedef struct {
    uint32_t type;
    uint32_t size;
    uint8_t bytes[32];
} tb_smc_value;

static uint32_t tb_code(const char *text) {
    return ((uint32_t)(uint8_t)text[0] << 24) | ((uint32_t)(uint8_t)text[1] << 16)
        | ((uint32_t)(uint8_t)text[2] << 8) | (uint32_t)(uint8_t)text[3];
}

static io_connect_t tb_connection(void) {
    static io_connect_t shared = 0;
    if (shared != 0) return shared;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == 0) return 0;
    io_connect_t opened = 0;
    kern_return_t status = IOServiceOpen(service, mach_task_self(), 0, &opened);
    IOObjectRelease(service);
    if (status != KERN_SUCCESS) return 0;
    shared = opened;
    return shared;
}

static int tb_call(tb_smc_param *input, tb_smc_param *output) {
    io_connect_t connection = tb_connection();
    if (connection == 0) return 0;
    size_t size = sizeof(tb_smc_param);
    memset(output, 0, sizeof(tb_smc_param));
    kern_return_t status = IOConnectCallStructMethod(connection, TB_SMC_SELECTOR, input, sizeof(tb_smc_param), output, &size);
    return status == KERN_SUCCESS && output->result == 0;
}

static int tb_keyinfo(const char *key, tb_smc_keyinfo *info) {
    tb_smc_param input;
    tb_smc_param output;
    memset(&input, 0, sizeof(input));
    input.key = tb_code(key);
    input.data8 = TB_SMC_KEYINFO;
    if (!tb_call(&input, &output)) return 0;
    if (output.keyInfo.dataSize == 0 || output.keyInfo.dataSize > 32) return 0;
    *info = output.keyInfo;
    return 1;
}

static int tb_read(const char *key, tb_smc_value *value) {
    tb_smc_keyinfo info;
    if (!tb_keyinfo(key, &info)) return 0;
    tb_smc_param input;
    tb_smc_param output;
    memset(&input, 0, sizeof(input));
    input.key = tb_code(key);
    input.keyInfo.dataSize = info.dataSize;
    input.data8 = TB_SMC_READ;
    if (!tb_call(&input, &output)) return 0;
    value->type = info.dataType;
    value->size = info.dataSize;
    memcpy(value->bytes, output.bytes, sizeof(value->bytes));
    return 1;
}

static int tb_decode(const tb_smc_value *value, double *number) {
    if (value->type == tb_code("flt ") && value->size == 4) {
        float raw;
        memcpy(&raw, value->bytes, sizeof(raw));
        *number = raw;
        return 1;
    }
    if (value->type == tb_code("fpe2") && value->size == 2) {
        *number = (double)(((uint32_t)value->bytes[0] << 8) | value->bytes[1]) / 4.0;
        return 1;
    }
    if (value->type == tb_code("ui8 ") && value->size == 1) {
        *number = value->bytes[0];
        return 1;
    }
    if (value->type == tb_code("ui16") && value->size == 2) {
        *number = (double)(((uint32_t)value->bytes[0] << 8) | value->bytes[1]);
        return 1;
    }
    return 0;
}

static int tb_read_number(const char *key, double *number) {
    tb_smc_value value;
    return tb_read(key, &value) && tb_decode(&value, number);
}

static int tb_write_number(const char *key, double number) {
    tb_smc_keyinfo info;
    if (!tb_keyinfo(key, &info)) return 0;
    tb_smc_param input;
    tb_smc_param output;
    memset(&input, 0, sizeof(input));
    input.key = tb_code(key);
    input.keyInfo.dataSize = info.dataSize;
    input.data8 = TB_SMC_WRITE;
    if (info.dataType == tb_code("flt ") && info.dataSize == 4) {
        float raw = (float)number;
        memcpy(input.bytes, &raw, sizeof(raw));
    } else if (info.dataType == tb_code("fpe2") && info.dataSize == 2) {
        uint32_t raw = (uint32_t)(number * 4.0);
        input.bytes[0] = (uint8_t)(raw >> 8);
        input.bytes[1] = (uint8_t)raw;
    } else if (info.dataType == tb_code("ui8 ") && info.dataSize == 1) {
        input.bytes[0] = (uint8_t)number;
    } else if (info.dataType == tb_code("ui16") && info.dataSize == 2) {
        uint32_t raw = (uint32_t)number;
        input.bytes[0] = (uint8_t)(raw >> 8);
        input.bytes[1] = (uint8_t)raw;
    } else {
        return 0;
    }
    return tb_call(&input, &output);
}

static int tb_fan_key(char *buffer, int index, const char *suffix) {
    if (index < 0 || index >= TB_MAX_FANS) return 0;
    snprintf(buffer, 5, "F%d%s", index, suffix);
    return 1;
}

static int tb_mode_key(char *buffer, int index) {
    tb_smc_keyinfo info;
    if (tb_fan_key(buffer, index, "md") && tb_keyinfo(buffer, &info)) return 1;
    return tb_fan_key(buffer, index, "Md") && tb_keyinfo(buffer, &info);
}

int tb_fan_count(void) {
    static int cached = -1;
    if (cached >= 0) return cached;
    double count = 0;
    if (!tb_read_number("FNum", &count) || count < 0) return 0;
    cached = count > TB_MAX_FANS ? TB_MAX_FANS : (int)count;
    return cached;
}

double tb_fan_actual(int index) {
    char key[5];
    double rpm = -1;
    if (index < 0 || index >= tb_fan_count()) return -1;
    if (!tb_fan_key(key, index, "Ac") || !tb_read_number(key, &rpm)) return -1;
    return rpm;
}

int tb_fan_read(int index, tb_fan_info *info) {
    char key[5];
    memset(info, 0, sizeof(*info));
    info->mode = -1;
    if (index < 0 || index >= tb_fan_count()) return 0;
    if (!tb_fan_key(key, index, "Ac") || !tb_read_number(key, &info->actual)) return 0;
    tb_fan_key(key, index, "Mn");
    tb_read_number(key, &info->minimum);
    tb_fan_key(key, index, "Mx");
    tb_read_number(key, &info->maximum);
    tb_fan_key(key, index, "Tg");
    tb_read_number(key, &info->target);
    double mode = -1;
    if (tb_mode_key(key, index) && tb_read_number(key, &mode)) info->mode = (int)mode;
    return 1;
}

static int tb_mode_is(const char *key, int expected) {
    double mode = -1;
    return tb_read_number(key, &mode) && (int)mode == expected;
}

int tb_fan_set_manual(int index, double rpm) {
    tb_fan_info info;
    char modeKey[5];
    char targetKey[5];
    if (!tb_fan_read(index, &info) || info.maximum <= info.minimum || info.minimum < 0) return 0;
    if (!(rpm == rpm)) return 0;
    if (rpm < info.minimum) rpm = info.minimum;
    if (rpm > info.maximum) rpm = info.maximum;
    if (!tb_mode_key(modeKey, index) || !tb_fan_key(targetKey, index, "Tg")) return 0;
    if (!tb_mode_is(modeKey, 1)) {
        int taken = tb_write_number(modeKey, 1) && tb_mode_is(modeKey, 1);
        tb_smc_keyinfo unlock;
        if (!taken && tb_keyinfo("Ftst", &unlock)) {
            tb_write_number("Ftst", 1);
            for (int attempt = 0; attempt < TB_UNLOCK_ATTEMPTS && !taken; attempt++) {
                usleep(TB_UNLOCK_INTERVAL_US);
                taken = tb_write_number(modeKey, 1) && tb_mode_is(modeKey, 1);
            }
        }
        if (!taken) return 0;
    }
    return tb_write_number(targetKey, rpm);
}

int tb_fan_set_auto(int index) {
    char key[5];
    int count = tb_fan_count();
    if (index < 0 || index >= count || !tb_mode_key(key, index)) return 0;
    int released = tb_mode_is(key, 1) ? tb_write_number(key, 0) : 1;
    int manual = 0;
    for (int other = 0; other < count; other++) {
        if (tb_mode_key(key, other) && tb_mode_is(key, 1)) manual++;
    }
    tb_smc_keyinfo unlock;
    double flag = 0;
    if (manual == 0 && tb_keyinfo("Ftst", &unlock) && tb_read_number("Ftst", &flag) && flag != 0) {
        tb_write_number("Ftst", 0);
    }
    return released;
}

#else

int tb_fan_count(void) { return 0; }
int tb_fan_read(int index, tb_fan_info *info) { (void)index; (void)info; return 0; }
double tb_fan_actual(int index) { (void)index; return -1; }
int tb_fan_set_manual(int index, double rpm) { (void)index; (void)rpm; return 0; }
int tb_fan_set_auto(int index) { (void)index; return 0; }

#endif

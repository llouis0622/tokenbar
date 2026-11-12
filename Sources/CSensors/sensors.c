#include "CSensors.h"

#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <string.h>

typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define TB_EVENT_TEMPERATURE 15
#define TB_FIELD_TEMPERATURE (TB_EVENT_TEMPERATURE << 16)

static IOHIDEventSystemClientRef tb_client(void) {
    static IOHIDEventSystemClientRef shared = NULL;
    if (shared != NULL) return shared;
    shared = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (shared == NULL) return NULL;
    int page = 0xff00;
    int usage = 5;
    CFNumberRef pageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &page);
    CFNumberRef usageNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
    const void *keys[2] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[2] = { pageNumber, usageNumber };
    CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                               &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(shared, match);
    CFRelease(match);
    CFRelease(pageNumber);
    CFRelease(usageNumber);
    return shared;
}

void tb_read_temperatures(double *cpu, double *gpu) {
    *cpu = -1;
    *gpu = -1;
    IOHIDEventSystemClientRef client = tb_client();
    if (client == NULL) return;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services == NULL) return;
    double coreSum = 0, dieSum = 0, gpuSum = 0;
    int coreCount = 0, dieCount = 0, gpuCount = 0;
    CFIndex total = CFArrayGetCount(services);
    for (CFIndex index = 0; index < total; index++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
        CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (product == NULL) continue;
        char name[128];
        int named = CFGetTypeID(product) == CFStringGetTypeID()
            && CFStringGetCString((CFStringRef)product, name, sizeof(name), kCFStringEncodingUTF8);
        CFRelease(product);
        if (!named) continue;
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, TB_EVENT_TEMPERATURE, 0, 0);
        if (event == NULL) continue;
        double value = IOHIDEventGetFloatValue(event, TB_FIELD_TEMPERATURE);
        CFRelease(event);
        if (!(value > 0 && value < 150)) continue;
        if (strstr(name, "GPU") != NULL) {
            gpuSum += value;
            gpuCount++;
        } else if (strstr(name, "ACC") != NULL) {
            coreSum += value;
            coreCount++;
        } else if (strstr(name, "tdie") != NULL) {
            dieSum += value;
            dieCount++;
        }
    }
    CFRelease(services);
    if (coreCount > 0) {
        *cpu = coreSum / coreCount;
    } else if (dieCount > 0) {
        *cpu = dieSum / dieCount;
    }
    if (gpuCount > 0) *gpu = gpuSum / gpuCount;
}

#else

void tb_read_temperatures(double *cpu, double *gpu) {
    *cpu = -1;
    *gpu = -1;
}

#endif

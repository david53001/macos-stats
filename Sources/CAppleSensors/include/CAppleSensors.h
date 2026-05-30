#ifndef CAPPLESENSORS_H
#define CAPPLESENSORS_H

#include <CoreFoundation/CoreFoundation.h>

typedef CFTypeRef IOHIDEventSystemClientRef;
typedef CFTypeRef IOHIDServiceClientRef;
typedef CFTypeRef IOHIDEventRef;

// Private IOKit thermal-sensor API (resolved from the IOKit framework at link time).
// Create/Copy functions follow the +1 create/copy rule; CF_IMPLICIT_BRIDGING lets
// Swift import them as managed CF objects (no Unmanaged dance).
CF_IMPLICIT_BRIDGING_ENABLED

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFStringRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type,
                                          int32_t options, int64_t options2);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

CF_IMPLICIT_BRIDGING_DISABLED

#endif

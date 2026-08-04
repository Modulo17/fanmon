#ifndef FANMON_BRIDGE_H
#define FANMON_BRIDGE_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>

/*
 * On Apple Silicon, on-die temperatures come from the IOKitHID event system
 * (the classic SMC "T…" temperature keys don't exist on M-series). The macOS
 * SDK now publicly declares the client/service types plus CreateSimpleClient,
 * CopyServices, and CopyProperty — so we include those headers and only
 * declare the three symbols that are still private. No entitlements or sudo
 * are needed to read.
 */
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>

typedef CFTypeRef IOHIDEventRef;

/* Full client (unlike the public CreateSimpleClient) — required for CopyEvent to
 * actually return sensor readings. Still private, so we declare it ourselves. */
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void          IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
double        IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

/*
 * SMC (System Management Controller) struct interface — used for fan RPM.
 * Layout must match the kernel's AppleSMC user-client exactly (80 bytes).
 */
typedef struct { char major; char minor; char build; char reserved[1]; UInt16 release; } SMCKeyData_vers_t;
typedef struct { UInt16 version; UInt16 length; UInt32 cpuPLimit; UInt32 gpuPLimit; UInt32 memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { UInt32 dataSize; UInt32 dataType; char dataAttributes; } SMCKeyData_keyInfo_t;

typedef struct {
    UInt32 key;
    SMCKeyData_vers_t        vers;
    SMCKeyData_pLimitData_t  pLimitData;
    SMCKeyData_keyInfo_t     keyInfo;
    char   result;
    char   status;
    char   data8;
    UInt32 data32;
    UInt8  bytes[32];
} SMCKeyData_t;

#endif /* FANMON_BRIDGE_H */

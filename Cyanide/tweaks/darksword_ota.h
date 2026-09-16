//
//  darksword_ota.h
//

#ifndef darksword_ota_h
#define darksword_ota_h

#import <stdbool.h>

bool darksword_ota_set_disabled(bool disabled);

// Reads current OTA state from the launchd disabled.plist. Returns:
//   -1 = could not determine (no KRW / no filesystem access / read failed)
//    0 = enabled (none of our update daemons are blocked)
//    1 = fully disabled (all of our update daemons are blocked)
//    2 = partially disabled (some but not all)
int darksword_ota_read_disabled(void);

#endif

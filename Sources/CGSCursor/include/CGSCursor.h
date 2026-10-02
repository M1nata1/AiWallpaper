// Declarations for the private CoreGraphics (CGS) cursor API. These symbols are not in any
// public SDK header, but they are exported by ApplicationServices/CoreGraphics and resolve at
// link time. They are the only known way to replace the system-wide pointer on macOS; the
// open-source tool Mousecape uses the same calls.
//
// Reset caveat, learned the hard way: unregistering is NOT enough to bring back a
// com.apple.coregraphics.* cursor that was overridden here. Back up the originals first
// (CGSCopyRegisteredCursorImages) and re-register them to reset. Registrations last only for
// the login session, so logging out is the guaranteed full reset.
#ifndef CGS_CURSOR_H
#define CGS_CURSOR_H

#include <CoreGraphics/CoreGraphics.h>
#include <stdbool.h>

typedef int CGSConnectionID;
typedef int CGSCursorID;

CGSConnectionID CGSMainConnectionID(void);

CGError CGSRegisterCursorWithImages(CGSConnectionID cid, const char *cursorName, bool setGlobally,
                                    bool instantly, CGSize cursorSize, CGPoint hotspot,
                                    unsigned long frameCount, CGFloat frameDuration,
                                    CFArrayRef imageArray, int *seed);

CGError CGSCopyRegisteredCursorImages(CGSConnectionID cid, const char *cursorName, CGSize *imageSize,
                                      CGPoint *hotSpot, unsigned long *frameCount,
                                      CGFloat *frameDuration, CFArrayRef *imageArray);

// Pass true for the flag: with false the call returns success but leaves the cursor registered.
CGError CGSRemoveRegisteredCursor(CGSConnectionID cid, const char *cursorName, bool unknownFlag);
CGError CoreCursorUnregisterAll(CGSConnectionID cid);
CGError CoreCursorSet(CGSConnectionID cid, CGSCursorID cursorID);

#endif /* CGS_CURSOR_H */

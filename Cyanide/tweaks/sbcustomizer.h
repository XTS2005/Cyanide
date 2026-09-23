//
//  sbcustomizer.h
//  Native port of the sbcustomizer dock+grid+labels patch.
//

#ifndef sbcustomizer_h
#define sbcustomizer_h

#import <stdbool.h>

bool sbcustomizer_apply(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                        bool arrangePages, int firstPageIcons, int otherPageIcons,
                        bool autoDockApp, const char *dockAppBundleID);
bool sbcustomizer_apply_in_session(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                                   bool arrangePages, int firstPageIcons, int otherPageIcons,
                                   bool autoDockApp, const char *dockAppBundleID);

// Hide home-screen icon labels per SBIconView (setLabelHidden:+_updateLabel).
// iOS 17 has no config-level label toggle, so this is applied as the last
// home-screen step. Returns the number of icon views hidden. Session must be open.
int sbcustomizer_hide_home_labels_in_session(void);

// Cheap current-page identity for the Hide Labels loop's change detection.
uint64_t sbcustomizer_current_page_token(void);

#endif

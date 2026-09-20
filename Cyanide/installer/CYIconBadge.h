//
//  CYIconBadge.h
//  Cyanide
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

UIImage *CYIconBadgeImage(NSString *sfSymbol, UIColor *color, CGFloat size);
UIColor *CYSpectrumColor(NSUInteger index);
UIView *CYSectionHeaderView(NSString *title);

// Navigation bar that widens the content inset on root (tab) screens so the
// large title and the integrated search bar line up with the app's inset-grouped
// cards, consistently across every tab. It uses ONLY the public
// directionalLayoutMargins API (not the earlier private-view title hack), and
// leaves pushed screens — the ones with a back button — at the standard inset.
@interface CYNavigationBar : UINavigationBar
@end

NS_ASSUME_NONNULL_END

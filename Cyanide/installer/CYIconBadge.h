//
//  CYIconBadge.h
//  Cyanide
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

UIImage *CYIconBadgeImage(NSString *sfSymbol, UIColor *color, CGFloat size);
UIColor *CYSpectrumColor(NSUInteger index);
UIView *CYSectionHeaderView(NSString *title);

// Navigation bar that indents the large title so it lines up with the app's
// card/section-header text column (~37pt) instead of the standard ~17pt, which
// looked jammed against the edge next to the inset-grouped content. Only the
// large title label is shifted; the compact title and bar buttons are untouched.
@interface CYNavigationBar : UINavigationBar
@end

NS_ASSUME_NONNULL_END

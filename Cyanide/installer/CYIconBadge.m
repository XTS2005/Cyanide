//
//  CYIconBadge.m
//  Cyanide
//

#import "CYIconBadge.h"

UIImage *CYIconBadgeImage(NSString *sfSymbol, UIColor *color, CGFloat size)
{
    UIGraphicsImageRendererFormat *fmt = [[UIGraphicsImageRendererFormat alloc] init];
    fmt.opaque = NO;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(size, size) format:fmt];

    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [[color colorWithAlphaComponent:0.14] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size, size)] fill];

        UIImageSymbolConfiguration *symCfg = [UIImageSymbolConfiguration
            configurationWithPointSize:size * 0.42 weight:UIImageSymbolWeightSemibold];
        UIImage *sym = [[UIImage systemImageNamed:sfSymbol withConfiguration:symCfg]
            imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (!sym) return;

        CGSize symSize = [sym size];
        CGFloat x = (size - symSize.width) / 2.0;
        CGFloat y = (size - symSize.height) / 2.0;
        [sym drawInRect:CGRectMake(x, y, symSize.width, symSize.height)];
    }];
}

UIColor *CYSpectrumColor(NSUInteger index)
{
    static NSArray<UIColor *> *colors;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        colors = @[
            UIColor.systemBlueColor,
            UIColor.systemTealColor,
            UIColor.systemGreenColor,
            UIColor.systemOrangeColor,
            UIColor.systemPinkColor,
            UIColor.systemPurpleColor,
            UIColor.systemIndigoColor,
            UIColor.systemCyanColor,
            UIColor.systemRedColor,
            UIColor.systemMintColor,
        ];
    });
    return colors[index % colors.count];
}

UIView *CYSectionHeaderView(NSString *title)
{
    UIView *container = [[UIView alloc] init];

    UILabel *lbl = [[UILabel alloc] init];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightBold];
    lbl.textColor = UIColor.labelColor;
    [container addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor  constraintEqualToAnchor:container.leadingAnchor constant:20.0],
        [lbl.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-20.0],
        [lbl.topAnchor      constraintEqualToAnchor:container.topAnchor constant:16.0],
        [lbl.bottomAnchor   constraintEqualToAnchor:container.bottomAnchor constant:-6.0],
    ]];

    return container;
}

@implementation CYNavigationBar {
    BOOL _cyCapturedDefaultMargins;
    NSDirectionalEdgeInsets _cyDefaultMargins;
}

// The default large title leading inset (points). UIKit positions the label at
// roughly this offset inside its container; used to compute the centering shift.
static const CGFloat kCYLargeTitleInset = 16.0;

// Inset for the integrated search bar so it lines up with the inset-grouped
// table cards (which sit ~20pt from the edge) instead of the standard ~16pt.
static const CGFloat kCYSearchBarInset = 20.0;

// User preference: when NO, the bar behaves like a stock UINavigationBar
// (left-aligned titles, standard search-bar width). Default YES. Unset is
// treated as YES so this holds even before defaults registration runs. The key
// mirrors kSettingsCenteredNavTitles in SettingsViewController.
static BOOL cy_centered_titles_enabled(void)
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:@"CenteredNavTitles"];
    return (v == nil) ? YES : [v boolValue];
}

static BOOL cy_has_search_bar(UIView *root)
{
    NSMutableArray<UIView *> *stack = [root.subviews mutableCopy];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:UISearchBar.class]) return YES;
        [stack addObjectsFromArray:v.subviews];
    }
    return NO;
}

static UILabel *cy_first_label_in(UIView *root)
{
    NSMutableArray<UIView *> *stack = [@[root] mutableCopy];
    UILabel *best = nil;
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ([v isKindOfClass:UILabel.class]) {
            UILabel *l = (UILabel *)v;
            if (l.font.pointSize >= 28.0 && (!best || l.font.pointSize > best.font.pointSize)) best = l;
        }
        [stack addObjectsFromArray:v.subviews];
    }
    return best;
}

// UIKit lays out the large title inside a private "…LargeTitleView" subview of
// the bar; the label's own frame is still zero when the bar lays out, and the
// large title ignores the bar's layout margins (notably on iOS 26). Moving the
// whole LargeTitleView is robust across iOS versions and only affects the large
// title — the compact title and bar buttons keep their frames, so back buttons
// on pushed screens are untouched. Here we center the title: the label sits at a
// fixed leading inside the container, so shifting the container so the text is
// screen-centered centers the visible title. Setting an absolute origin makes
// this idempotent across repeated layout passes.
- (void)layoutSubviews
{
    [super layoutSubviews];

    // The integrated search bar honors the bar's layout margins (overriding the
    // getter is ignored — UIKit reads the stored value — so we assign it). Widen
    // the margins to line the search field up with the inset-grouped cards only
    // while a search bar is present (Packages root); restore the captured default
    // otherwise so pushed screens keep the standard back-button inset. Guarded so
    // repeated layout passes don't loop.
    if (!_cyCapturedDefaultMargins) {
        _cyDefaultMargins = self.directionalLayoutMargins;
        _cyCapturedDefaultMargins = YES;
    }
    BOOL centered = cy_centered_titles_enabled();

    NSDirectionalEdgeInsets target = _cyDefaultMargins;
    if (centered && cy_has_search_bar(self)) {
        target.leading = MAX(target.leading, kCYSearchBarInset);
        target.trailing = MAX(target.trailing, kCYSearchBarInset);
    }
    NSDirectionalEdgeInsets cur = self.directionalLayoutMargins;
    if (fabs(cur.leading - target.leading) > 0.5 || fabs(cur.trailing - target.trailing) > 0.5) {
        self.directionalLayoutMargins = target;
    }

    // Standard-appearance mode: leave the (already-default) large title where
    // UIKit placed it and skip centering.
    if (!centered) return;

    CGFloat barW = self.bounds.size.width;
    for (UIView *sub in self.subviews) {
        if (![NSStringFromClass(sub.class) containsString:@"LargeTitle"]) continue;
        UILabel *label = cy_first_label_in(sub);
        if (!label || label.text.length == 0 || !label.font) continue;
        CGFloat textW = ceil([label.text sizeWithAttributes:@{NSFontAttributeName: label.font}].width);
        CGFloat shift = (barW - textW) / 2.0 - kCYLargeTitleInset;
        if (shift < 0.0) shift = 0.0;
        CGRect f = sub.frame;
        if (fabs(f.origin.x - shift) > 0.5) {
            f.origin.x = shift;
            sub.frame = f;
        }
    }
}

@end

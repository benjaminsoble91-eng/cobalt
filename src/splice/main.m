// Splice (com.mymculture.splice) - drop in a decrypted .ipa and tweaks, get the modded .ipa back.
#import <UIKit/UIKit.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "Engine.h"
#import "Library.h"
#import <objc/runtime.h>

#define SPBlue   [UIColor colorWithRed:0.18 green:0.42 blue:1.00 alpha:1]
#define SPCyan   [UIColor colorWithRed:0.00 green:0.76 blue:1.00 alpha:1]

static UIImage *Sym(NSString *name, CGFloat size, UIImageSymbolWeight w) {
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:size weight:w];
    return [UIImage systemImageNamed:name withConfiguration:c] ?: [UIImage systemImageNamed:@"questionmark.square" withConfiguration:c];
}

static NSString *SizeString(unsigned long long b) {
    return [NSByteCountFormatter stringFromByteCount:(long long)b countStyle:NSByteCountFormatterCountStyleFile];
}

static UILabel *Label(NSString *text, UIFont *font, UIColor *color) {
    UILabel *l = [UILabel new];
    l.text = text; l.font = font; l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

#pragma mark - Views

@interface SPCard : UIView
@property (nonatomic, strong) UIStackView *stack;
@end
@implementation SPCard
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
        self.layer.cornerRadius = 20;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        _stack = [UIStackView new];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 12;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_stack];
        [NSLayoutConstraint activateConstraints:@[
            [_stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
            [_stack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-16],
            [_stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [_stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        ]];
        if (title) {
            UIImageView *iv = [[UIImageView alloc] initWithImage:Sym(symbol, 15, UIImageSymbolWeightSemibold)];
            iv.tintColor = SPBlue;
            [iv setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            UILabel *l = Label(title.uppercaseString, [UIFont systemFontOfSize:13 weight:UIFontWeightBold], UIColor.secondaryLabelColor);
            UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:@[iv, l]];
            h.spacing = 6;
            h.alignment = UIStackViewAlignmentCenter;
            [_stack addArrangedSubview:h];
        }
    }
    return self;
}
- (void)clearBody {
    // Keep the title row (first view).
    NSArray *views = self.stack.arrangedSubviews;
    for (NSUInteger i = 1; i < views.count; i++) { [views[i] removeFromSuperview]; }
}
@end

@interface SPDropZone : UIControl
@property (nonatomic, strong) CAShapeLayer *border;
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic) BOOL hovering;
@end
@implementation SPDropZone
- (instancetype)initWithSymbol:(NSString *)symbol title:(NSString *)title subtitle:(NSString *)subtitle height:(CGFloat)h {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.layer.cornerRadius = 16;
        self.backgroundColor = [SPBlue colorWithAlphaComponent:0.06];
        _border = [CAShapeLayer layer];
        _border.fillColor = UIColor.clearColor.CGColor;
        _border.strokeColor = [SPBlue colorWithAlphaComponent:0.55].CGColor;
        _border.lineWidth = 2;
        _border.lineDashPattern = @[@7, @5];
        [self.layer addSublayer:_border];
        _icon = [[UIImageView alloc] initWithImage:Sym(symbol, 30, UIImageSymbolWeightMedium)];
        _icon.tintColor = SPBlue;
        _icon.contentMode = UIViewContentModeCenter;
        UILabel *t = Label(title, [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold], UIColor.labelColor);
        UILabel *s = Label(subtitle, [UIFont systemFontOfSize:13], UIColor.secondaryLabelColor);
        t.textAlignment = s.textAlignment = NSTextAlignmentCenter;
        UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[_icon, t, s]];
        v.axis = UILayoutConstraintAxisVertical;
        v.spacing = 6;
        v.alignment = UIStackViewAlignmentCenter;
        v.userInteractionEnabled = NO;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:v];
        [NSLayoutConstraint activateConstraints:@[
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:h],
            [v.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [v.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
            [v.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [v.topAnchor constraintGreaterThanOrEqualToAnchor:self.topAnchor constant:14],
        ]];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.border.frame = self.bounds;
    self.border.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 1, 1) cornerRadius:15].CGPath;
}
- (void)setHovering:(BOOL)h {
    _hovering = h;
    [UIView animateWithDuration:0.15 animations:^{
        self.backgroundColor = [SPBlue colorWithAlphaComponent:h ? 0.18 : 0.06];
        self.transform = h ? CGAffineTransformMakeScale(1.02, 1.02) : CGAffineTransformIdentity;
    }];
}
- (void)setHighlighted:(BOOL)h {
    [super setHighlighted:h];
    self.alpha = h ? 0.6 : 1;
}
@end

@interface SPGradientButton : UIButton
@property (nonatomic, strong) CAGradientLayer *grad;
@end
@implementation SPGradientButton
+ (instancetype)buttonWithTitle:(NSString *)title symbol:(NSString *)symbol {
    SPGradientButton *b = [self buttonWithType:UIButtonTypeCustom];
    b.grad = [CAGradientLayer layer];
    b.grad.colors = @[(id)SPBlue.CGColor, (id)SPCyan.CGColor];
    b.grad.startPoint = CGPointMake(0, 0.5);
    b.grad.endPoint = CGPointMake(1, 0.5);
    b.grad.cornerRadius = 16;
    [b.layer insertSublayer:b.grad atIndex:0];
    [b setTitle:[@"  " stringByAppendingString:title] forState:UIControlStateNormal];
    [b setImage:Sym(symbol, 17, UIImageSymbolWeightBold) forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    b.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.layer.shadowColor = SPBlue.CGColor;
    b.layer.shadowOpacity = 0.35;
    b.layer.shadowRadius = 12;
    b.layer.shadowOffset = CGSizeMake(0, 6);
    [b.heightAnchor constraintEqualToConstant:56].active = YES;
    return b;
}
- (void)layoutSubviews { [super layoutSubviews]; self.grad.frame = self.bounds; }
- (void)setEnabled:(BOOL)e {
    [super setEnabled:e];
    self.grad.colors = e ? @[(id)SPBlue.CGColor, (id)SPCyan.CGColor] : @[(id)UIColor.systemGray3Color.CGColor, (id)UIColor.systemGray3Color.CGColor];
    self.layer.shadowOpacity = e ? 0.35 : 0;
}
- (void)setHighlighted:(BOOL)h { [super setHighlighted:h]; self.alpha = h ? 0.8 : 1; }
@end

#pragma mark - Library

@interface SPLibraryController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *files;
@end
@implementation SPLibraryController
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Modded Apps";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    [self reload];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)reload {
    NSString *dir = SPBuildsDir();
    NSMutableArray *f = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
        if ([n.pathExtension.lowercaseString isEqualToString:@"ipa"]) [f addObject:[dir stringByAppendingPathComponent:n]];
    [f sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *da = [NSFileManager.defaultManager attributesOfItemAtPath:a error:nil].fileModificationDate;
        NSDate *db = [NSFileManager.defaultManager attributesOfItemAtPath:b error:nil].fileModificationDate;
        return [db compare:da];
    }];
    self.files = f;
    [self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return MAX((NSInteger)self.files.count, 1); }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return self.files.count ? @"Tap to share: Open in TrollStore, save to Files, or send to your sideloader. Swipe to delete." : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    if (!self.files.count) {
        c.textLabel.text = @"Nothing built yet";
        c.textLabel.textColor = UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    NSString *p = self.files[ip.row];
    NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:p error:nil];
    c.textLabel.text = p.lastPathComponent.stringByDeletingPathExtension;
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", SizeString(a.fileSize),
                              [NSDateFormatter localizedStringFromDate:a.fileModificationDate dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    c.imageView.image = Sym(@"app.gift.fill", 24, UIImageSymbolWeightRegular) ?: Sym(@"shippingbox.fill", 24, UIImageSymbolWeightRegular);
    c.imageView.tintColor = SPBlue;
    c.accessoryView = [[UIImageView alloc] initWithImage:Sym(@"square.and.arrow.up", 16, UIImageSymbolWeightMedium)];
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (!self.files.count) return;
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:self.files[ip.row]]] applicationActivities:nil];
    a.popoverPresentationController.sourceView = [tv cellForRowAtIndexPath:ip];
    a.popoverPresentationController.sourceRect = [tv cellForRowAtIndexPath:ip].bounds;
    [self presentViewController:a animated:YES completion:nil];
}
- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip { return self.files.count > 0; }
- (void)tableView:(UITableView *)tv commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)ip {
    [NSFileManager.defaultManager removeItemAtPath:self.files[ip.row] error:nil];
    [self reload];
}
@end

#pragma mark - Build sheet

@interface SPBuildController : UIViewController
@property (nonatomic, strong) SPApp *app;
@property (nonatomic, strong) NSArray<SPTweak *> *tweaks;
@property (nonatomic, strong) SPBuildOptions *opts;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIImageView *badge;
@property (nonatomic, strong) UILabel *titleLabel, *stepLabel;
@property (nonatomic, strong) UIProgressView *bar;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) SPBuildResult *result;
@property (nonatomic, copy) void (^onFinish)(void);
@end

@implementation SPBuildController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    if (@available(iOS 13.0, *)) self.modalInPresentation = YES;
    UIScrollView *sv = [UIScrollView new];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sv];
    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 14;
    self.stack.alignment = UIStackViewAlignmentFill;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [sv addSubview:self.stack];
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:self.view.topAnchor], [sv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor constant:40],
        [self.stack.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor constant:-30],
        [self.stack.leadingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.leadingAnchor constant:24],
        [self.stack.trailingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.trailingAnchor constant:-24],
    ]];
    self.badge = [[UIImageView alloc] initWithImage:self.app.icon ?: Sym(@"app.fill", 60, UIImageSymbolWeightRegular)];
    self.badge.tintColor = SPBlue;
    self.badge.contentMode = UIViewContentModeScaleAspectFit;
    self.badge.layer.cornerRadius = 22;
    self.badge.layer.cornerCurve = kCACornerCurveContinuous;
    self.badge.clipsToBounds = YES;
    [self.badge.heightAnchor constraintEqualToConstant:96].active = YES;
    [self.badge.widthAnchor constraintEqualToConstant:96].active = YES;
    UIStackView *center = [[UIStackView alloc] initWithArrangedSubviews:@[self.badge]];
    center.alignment = UIStackViewAlignmentCenter;
    center.axis = UILayoutConstraintAxisVertical;
    [self.stack addArrangedSubview:center];
    self.titleLabel = Label([NSString stringWithFormat:@"Splicing %@", self.opts.displayName.length ? self.opts.displayName : self.app.name],
                            [UIFont systemFontOfSize:24 weight:UIFontWeightBold], UIColor.labelColor);
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.stack addArrangedSubview:self.titleLabel];
    self.stepLabel = Label(@"Starting…", [UIFont systemFontOfSize:15], UIColor.secondaryLabelColor);
    self.stepLabel.textAlignment = NSTextAlignmentCenter;
    [self.stack addArrangedSubview:self.stepLabel];
    self.bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.bar.progressTintColor = SPBlue;
    [self.stack addArrangedSubview:self.bar];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [self.spinner startAnimating];
    [self.stack addArrangedSubview:self.spinner];
    [self run];
}

- (void)run {
    SPApp *app = self.app; NSArray *tweaks = self.tweaks; SPBuildOptions *opts = self.opts;
    __weak typeof(self) ws = self;
    [UIApplication.sharedApplication setIdleTimerDisabled:YES];
    __block UIBackgroundTaskIdentifier bg = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        [UIApplication.sharedApplication endBackgroundTask:bg];
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block CFAbsoluteTime last = 0;
        NSError *err = nil;
        SPBuildResult *res = SPBuild(app, tweaks, opts, ^(NSString *step, double f) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (f >= 0 && now - last < 0.05) return;
            last = now;
            dispatch_async(dispatch_get_main_queue(), ^{
                ws.stepLabel.text = f >= 0 ? [NSString stringWithFormat:@"%@ · %d%%", step, (int)(f * 100)] : step;
                if (f >= 0) [ws.bar setProgress:(float)f animated:YES];
            });
        }, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIApplication.sharedApplication setIdleTimerDisabled:NO];
            [UIApplication.sharedApplication endBackgroundTask:bg];
            UINotificationFeedbackGenerator *h = [UINotificationFeedbackGenerator new];
            [h notificationOccurred:res ? UINotificationFeedbackTypeSuccess : UINotificationFeedbackTypeError];
            if (res) [ws showResult:res]; else [ws showError:err];
        });
    });
}

- (UIButton *)plainButton:(NSString *)title action:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintEqualToConstant:48].active = YES;
    return b;
}

- (void)addNotes:(NSArray<NSString *> *)lines color:(UIColor *)color symbol:(NSString *)symbol {
    if (!lines.count) return;
    SPCard *card = [[SPCard alloc] initWithTitle:nil symbol:nil];
    for (NSString *w in lines) {
        UIImageView *iv = [[UIImageView alloc] initWithImage:Sym(symbol, 13, UIImageSymbolWeightBold)];
        iv.tintColor = color;
        [iv setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UILabel *l = Label(w, [UIFont systemFontOfSize:14], UIColor.labelColor);
        UIStackView *h = [[UIStackView alloc] initWithArrangedSubviews:@[iv, l]];
        h.spacing = 8; h.alignment = UIStackViewAlignmentFirstBaseline;
        [card.stack addArrangedSubview:h];
    }
    [self.stack addArrangedSubview:card];
}

- (void)showResult:(SPBuildResult *)res {
    self.result = res;
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    self.bar.hidden = YES;
    self.titleLabel.text = @"Your modded app is ready";
    unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:res.ipaPath error:nil] fileSize];
    self.stepLabel.text = [NSString stringWithFormat:@"%@\n%@", res.ipaPath.lastPathComponent, SizeString(size)];
    UIImageView *check = [[UIImageView alloc] initWithImage:Sym(@"checkmark.seal.fill", 34, UIImageSymbolWeightBold)];
    check.tintColor = UIColor.systemGreenColor;
    [self.stack insertArrangedSubview:check atIndex:1];
    [self addNotes:res.injected color:UIColor.systemGreenColor symbol:@"checkmark.circle.fill"];
    [self addNotes:res.warnings color:UIColor.systemOrangeColor symbol:@"exclamationmark.triangle.fill"];
    SPGradientButton *share = [SPGradientButton buttonWithTitle:@"Share / Install" symbol:@"square.and.arrow.up"];
    [share addTarget:self action:@selector(share:) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:share];
    UILabel *hint = Label(@"Open in TrollStore to install, or send it to your sideloader to sign it. It's also kept in Modded Apps.",
                          [UIFont systemFontOfSize:13], UIColor.secondaryLabelColor);
    hint.textAlignment = NSTextAlignmentCenter;
    [self.stack addArrangedSubview:hint];
    [self.stack addArrangedSubview:[self plainButton:@"Done" action:@selector(close)]];
}

- (void)showError:(NSError *)err {
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    self.bar.hidden = YES;
    self.badge.image = Sym(@"xmark.octagon.fill", 60, UIImageSymbolWeightRegular);
    self.badge.tintColor = UIColor.systemRedColor;
    self.badge.layer.cornerRadius = 0;
    self.titleLabel.text = @"Couldn't build it";
    self.stepLabel.text = err.localizedDescription ?: @"Something went wrong.";
    self.stepLabel.textColor = UIColor.labelColor;
    [self.stack addArrangedSubview:[self plainButton:@"Close" action:@selector(close)]];
}

- (void)share:(UIView *)sender {
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:self.result.ipaPath]] applicationActivities:nil];
    a.popoverPresentationController.sourceView = sender;
    a.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)close {
    void (^f)(void) = self.onFinish;
    [self dismissViewControllerAnimated:YES completion:^{ if (f) f(); }];
}
@end

#pragma mark - Admin panel (password: see SPAdmin)

typedef NS_ENUM(NSInteger, SPAdminSection) { SPSecAdd, SPSecApps, SPSecTweaks, SPSecGitHub, SPSecCount };

@interface SPAdminController : UITableViewController <UIDocumentPickerDelegate>
@property (nonatomic, strong) NSArray<SPSharedApp *> *apps, *tweaks;
@property (nonatomic, strong) UIAlertController *progressAlert;
@property (nonatomic) BOOL working, pickingTweak;
@property (nonatomic, copy) void (^onChange)(NSArray<SPSharedApp *> *apps, NSArray<SPSharedApp *> *tweaks);
@end

@implementation SPAdminController
- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Admin";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    [self reload];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)changed {
    if (self.onChange) self.onChange(self.apps ?: @[], self.tweaks ?: @[]);
    [self.tableView reloadData];
}
- (void)reload {
    [SPLibrary fetchCatalog:^(NSArray<SPSharedApp *> *apps, NSArray<SPSharedApp *> *tweaks, NSError *err) {
        [self.refreshControl endRefreshing];
        if (apps) { self.apps = apps; self.tweaks = tweaks; [self changed]; }
    }];
}

- (void)alert:(NSString *)t message:(NSString *)m {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (NSArray<SPSharedApp *> *)listFor:(NSInteger)s { return s == SPSecApps ? self.apps : self.tweaks; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return SPSecCount; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == SPSecAdd) return 2;
    if (s == SPSecApps || s == SPSecTweaks) return MAX((NSInteger)[self listFor:s].count, 1);
    return 2;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == SPSecApps) return [NSString stringWithFormat:@"Shared apps (%lu)", (unsigned long)self.apps.count];
    if (s == SPSecTweaks) return [NSString stringWithFormat:@"Shared tweaks (%lu)", (unsigned long)self.tweaks.count];
    if (s == SPSecGitHub) return @"GitHub";
    return @"Share with everyone";
}
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == SPSecAdd) return @"Apps show under the App card and tweaks under the Tweaks card in everyone's Splice, within a few minutes.";
    if ((s == SPSecApps || s == SPSecTweaks) && [self listFor:s].count) return @"Swipe left to remove one for everyone.";
    if (s == SPSecGitHub) return @"The built-in token is locked with the admin password and only unlocks after you enter it.";
    return nil;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (ip.section == SPSecAdd) {
        BOOL tweak = ip.row == 1;
        c.textLabel.text = tweak ? @"Add a tweak" : @"Add a decrypted app";
        c.detailTextLabel.text = tweak ? @".deb or .dylib" : @".ipa";
        c.textLabel.textColor = SPBlue;
        c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        c.imageView.image = Sym(tweak ? @"puzzlepiece.extension.fill" : @"plus.app.fill", 22, UIImageSymbolWeightMedium);
        c.imageView.tintColor = tweak ? UIColor.systemPurpleColor : SPBlue;
    } else if (ip.section == SPSecApps || ip.section == SPSecTweaks) {
        NSArray *list = [self listFor:ip.section];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        if (!list.count) {
            c.textLabel.text = ip.section == SPSecApps ? @"No apps shared yet" : @"No tweaks shared yet";
            c.textLabel.textColor = UIColor.secondaryLabelColor;
            return c;
        }
        SPSharedApp *a = list[ip.row];
        c.textLabel.text = a.name;
        c.detailTextLabel.text = a.isTweak
            ? [NSString stringWithFormat:@"v%@ · %@ · %@", a.version, SizeString((unsigned long long)a.size), a.fileName ?: @""]
            : [NSString stringWithFormat:@"v%@ · %@ · %@", a.version, SizeString((unsigned long long)a.size), a.bundleID];
        if (a.isTweak) {
            c.imageView.image = Sym(@"puzzlepiece.extension.fill", 20, UIImageSymbolWeightMedium);
            c.imageView.tintColor = UIColor.systemPurpleColor;
        } else {
            c.imageView.image = [UIImage systemImageNamed:@"app.fill"];
            c.imageView.tintColor = UIColor.systemGray3Color;
            c.imageView.layer.cornerRadius = 8;
            c.imageView.clipsToBounds = YES;
            [SPLibrary loadIcon:a.iconURL into:c.imageView];
        }
    } else if (ip.row == 0) {
        BOOL builtIn = [SPAdmin usingBuiltInToken], has = [SPAdmin token] != nil;
        c.textLabel.text = builtIn ? @"Built-in token" : has ? @"Your saved token" : @"No token";
        c.detailTextLabel.text = has ? @"Tap to copy it" : @"Tap to set one";
        c.imageView.image = Sym(has ? @"checkmark.shield.fill" : @"key.fill", 18, UIImageSymbolWeightMedium);
        c.imageView.tintColor = has ? UIColor.systemGreenColor : SPBlue;
        c.accessoryView = has ? [[UIImageView alloc] initWithImage:Sym(@"doc.on.doc", 15, UIImageSymbolWeightMedium)] : nil;
    } else {
        BOOL builtIn = [SPAdmin usingBuiltInToken];
        c.textLabel.text = builtIn ? @"Use a different token" : @"Go back to the built-in token";
        c.textLabel.textColor = SPBlue;
        if (!builtIn && ![SPAdmin builtInToken]) { c.textLabel.text = @"Remove saved token"; c.textLabel.textColor = UIColor.systemRedColor; }
    }
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (self.working) return;
    if (ip.section == SPSecAdd) {
        self.pickingTweak = ip.row == 1;
        if (![SPAdmin token]) { [self askToken:^{ [self pick]; }]; return; }
        [self pick];
    } else if (ip.section == SPSecGitHub && ip.row == 0) {
        NSString *t = [SPAdmin token];
        if (!t) { [self askToken:nil]; return; }
        UIPasteboard.generalPasteboard.string = t;
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
        [self alert:@"Copied" message:@"The token is on your clipboard."];
    } else if (ip.section == SPSecGitHub) {
        if ([SPAdmin usingBuiltInToken]) [self askToken:nil];
        else { [SPAdmin setToken:nil]; [tv reloadData]; }   // falls back to the built-in token
    }
}

- (void)askToken:(void (^)(void))then {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"GitHub token"
        message:@"Paste a fine-grained token for benjaminsoble91-eng/cobalt with Contents: Read and write."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"github_pat_…";
        f.secureTextEntry = YES;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *t = [a.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!t.length) return;
        self.working = YES;
        [self showProgress:@"Checking the token…"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *problem = [SPAdmin validateToken:t];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.working = NO;
                [self hideProgress:^{
                    if (problem) { [self alert:@"Token didn't work" message:problem]; return; }
                    [SPAdmin setToken:t];
                    [self.tableView reloadData];
                    if (then) then();
                }];
            });
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showProgress:(NSString *)text {
    if (self.progressAlert) { self.progressAlert.message = text; return; }
    self.progressAlert = [UIAlertController alertControllerWithTitle:@"Sharing" message:text preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:self.progressAlert animated:YES completion:nil];
}
- (void)hideProgress:(void (^)(void))then {
    UIAlertController *a = self.progressAlert;
    self.progressAlert = nil;
    if (a.presentingViewController) [a dismissViewControllerAnimated:YES completion:then];
    else if (then) then();
}

- (void)pick {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"] inMode:UIDocumentPickerModeOpen];
    p.delegate = self;
    [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    NSString *ext = url.pathExtension.lowercaseString;
    BOOL tweak = [ext isEqualToString:@"deb"] || [ext isEqualToString:@"dylib"];
    BOOL app = [ext isEqualToString:@"ipa"] || [ext isEqualToString:@"tipa"];
    if (!tweak && !app) { [self alert:@"Can't share that" message:@"Pick a decrypted .ipa, or a tweak (.deb or .dylib)."]; return; }
    self.working = YES;
    [UIApplication.sharedApplication setIdleTimerDisabled:YES];
    [self showProgress:@"Getting ready…"];
    __block UIBackgroundTaskIdentifier bg = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
        [UIApplication.sharedApplication endBackgroundTask:bg];
    }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        __block CFAbsoluteTime last = 0;
        void (^prog)(NSString *, double) = ^(NSString *step, double f) {
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (f >= 0 && f < 1 && now - last < 0.25) return;
            last = now;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showProgress:f >= 0 ? [NSString stringWithFormat:@"%@… %d%%", step, (int)(f * 100)] : [step stringByAppendingString:@"…"]];
            });
        };
        NSError *err = nil;
        SPSharedApp *entry = tweak ? [SPAdmin publishTweak:url.path progress:prog error:&err]
                                   : [SPAdmin publishIPA:url.path progress:prog error:&err];
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.working = NO;
            [UIApplication.sharedApplication setIdleTimerDisabled:NO];
            [UIApplication.sharedApplication endBackgroundTask:bg];
            [self hideProgress:^{
                if (!entry) { [self alert:@"Couldn't share it" message:err.localizedDescription]; return; }
                NSMutableArray *list = [NSMutableArray arrayWithObject:entry];
                for (SPSharedApp *a in (tweak ? self.tweaks : self.apps)) if (![a.entryID isEqualToString:entry.entryID]) [list addObject:a];
                if (tweak) self.tweaks = list; else self.apps = list;
                [self changed];
                [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeSuccess];
                [self alert:@"Shared" message:[NSString stringWithFormat:@"%@ %@ is live. Everyone's Splice will show it within a few minutes.", entry.name, entry.version]];
            }];
        });
    });
}

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)ip {
    return (ip.section == SPSecApps || ip.section == SPSecTweaks) && [self listFor:ip.section].count > 0;
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (![self tableView:tv canEditRowAtIndexPath:ip]) return nil;
    SPSharedApp *a = [self listFor:ip.section][ip.row];
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Remove"
                                                                    handler:^(UIContextualAction *x, UIView *v, void (^done)(BOOL)) {
        done(NO);
        if (self.working) return;
        if (![SPAdmin token]) { [self askToken:nil]; return; }
        self.working = YES;
        [self showProgress:[NSString stringWithFormat:@"Removing %@…", a.name]];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSError *err = nil;
            BOOL ok = [SPAdmin remove:a error:&err];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.working = NO;
                [self hideProgress:^{
                    if (!ok) { [self alert:@"Couldn't remove it" message:err.localizedDescription]; return; }
                    NSMutableArray *list = [(a.isTweak ? self.tweaks : self.apps) mutableCopy];
                    [list removeObject:a];
                    if (a.isTweak) self.tweaks = list; else self.apps = list;
                    [self changed];
                }];
            });
        });
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}
@end

#pragma mark - Main screen

typedef NS_ENUM(NSInteger, SPPick) { SPPickApp, SPPickTweak };

@interface SPMainController : UIViewController <UIDocumentPickerDelegate, UIDropInteractionDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) SPCard *appCard, *tweakCard, *optionsCard;
@property (nonatomic, strong) SPGradientButton *buildButton;
@property (nonatomic, strong) UILabel *buildHint;
@property (nonatomic, strong) SPApp *app;
@property (nonatomic, strong) NSMutableArray<SPTweak *> *tweaks;
@property (nonatomic, strong) SPBuildOptions *opts;
@property (nonatomic, strong) UITextField *nameField, *idField;
@property (nonatomic) SPPick pick;
@property (nonatomic, strong) UIView *hud;
@property (nonatomic, strong) UILabel *hudLabel;
@property (nonatomic, strong) NSMutableArray<NSURL *> *queue;
@property (nonatomic) BOOL busy;
@property (nonatomic, strong) NSArray<SPSharedApp *> *shared, *sharedTweaks;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic) NSUInteger failedUnlocks;
@property (nonatomic, strong) NSDate *lockedUntil;
- (void)openURLs:(NSArray<NSURL *> *)urls;
@end

@implementation SPMainController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Splice";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tweaks = [NSMutableArray array];
    self.queue = [NSMutableArray array];
    self.opts = [SPBuildOptions new];
    self.opts.anyDevice = YES;
    self.opts.removeWatch = YES;
    self.opts.compress = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:Sym(@"tray.full.fill", 17, UIImageSymbolWeightMedium)
                                                                              style:UIBarButtonItemStylePlain target:self action:@selector(showLibrary)];
    self.navigationItem.leftBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithImage:Sym(@"info.circle", 17, UIImageSymbolWeightMedium) style:UIBarButtonItemStylePlain target:self action:@selector(about)],
        [[UIBarButtonItem alloc] initWithImage:Sym(@"lock.fill", 16, UIImageSymbolWeightMedium) style:UIBarButtonItemStylePlain target:self action:@selector(unlockAdmin)],
    ];

    UIScrollView *sv = [UIScrollView new];
    sv.alwaysBounceVertical = YES;
    sv.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:sv];
    self.scroll = sv;
    sv.refreshControl = [UIRefreshControl new];
    [sv.refreshControl addTarget:self action:@selector(loadShared) forControlEvents:UIControlEventValueChanged];
    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 16;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [sv addSubview:self.stack];
    UILayoutGuide *g = self.view.readableContentGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:self.view.topAnchor], [sv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor], [sv.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor constant:8],
        [self.stack.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor constant:-32],
        [self.stack.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [self.stack.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
    ]];

    UILabel *tag = Label(@"Drop in a decrypted app and its tweaks. Get the full modded app back.",
                         [UIFont systemFontOfSize:15], UIColor.secondaryLabelColor);
    [self.stack addArrangedSubview:tag];
    self.appCard = [[SPCard alloc] initWithTitle:@"App" symbol:@"app.fill"];
    self.tweakCard = [[SPCard alloc] initWithTitle:@"Tweaks" symbol:@"puzzlepiece.extension.fill"];
    self.optionsCard = [[SPCard alloc] initWithTitle:@"Options" symbol:@"slider.horizontal.3"];
    for (SPCard *c in @[self.appCard, self.tweakCard, self.optionsCard]) [self.stack addArrangedSubview:c];
    [self.appCard addInteraction:[[UIDropInteraction alloc] initWithDelegate:self]];
    [self.tweakCard addInteraction:[[UIDropInteraction alloc] initWithDelegate:self]];

    self.buildButton = [SPGradientButton buttonWithTitle:@"Build Modded App" symbol:@"hammer.fill"];
    [self.buildButton addTarget:self action:@selector(build) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:self.buildButton];
    self.buildHint = Label(@"", [UIFont systemFontOfSize:13], UIColor.secondaryLabelColor);
    self.buildHint.textAlignment = NSTextAlignmentCenter;
    [self.stack addArrangedSubview:self.buildHint];

    [self buildOptions];
    [self refresh];
    [self loadShared];
}

#pragma mark Cards

- (UIView *)rowWithIcon:(UIImage *)icon tint:(UIColor *)tint round:(BOOL)round title:(NSString *)title detail:(NSString *)detail action:(SEL)action tag:(NSInteger)tag {
    UIImageView *iv = [[UIImageView alloc] initWithImage:icon];
    iv.tintColor = tint;
    iv.contentMode = round ? UIViewContentModeScaleAspectFill : UIViewContentModeCenter;
    iv.backgroundColor = round ? UIColor.clearColor : [tint colorWithAlphaComponent:0.12];
    iv.layer.cornerRadius = round ? 13 : 10;
    iv.layer.cornerCurve = kCACornerCurveContinuous;
    iv.clipsToBounds = YES;
    CGFloat s = round ? 58 : 42;
    [iv.widthAnchor constraintEqualToConstant:s].active = YES;
    [iv.heightAnchor constraintEqualToConstant:s].active = YES;
    UILabel *t = Label(title, [UIFont systemFontOfSize:round ? 18 : 16 weight:UIFontWeightSemibold], UIColor.labelColor);
    UILabel *d = Label(detail, [UIFont systemFontOfSize:13], UIColor.secondaryLabelColor);
    t.numberOfLines = 2;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[t, d]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;
    UIButton *x = [UIButton buttonWithType:UIButtonTypeSystem];
    [x setImage:Sym(@"xmark.circle.fill", 22, UIImageSymbolWeightRegular) forState:UIControlStateNormal];
    x.tintColor = UIColor.tertiaryLabelColor;
    x.tag = tag;
    [x addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [x setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[iv, text, x]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UILabel *)note:(NSString *)text color:(UIColor *)color {
    UILabel *l = Label(text, [UIFont systemFontOfSize:13 weight:UIFontWeightMedium], color);
    return l;
}

- (void)refresh {
    // App card
    [self.appCard clearBody];
    if (!self.app) {
        SPDropZone *z = [[SPDropZone alloc] initWithSymbol:@"square.and.arrow.down.on.square" title:@"Add a decrypted app"
                                                  subtitle:@"Tap to choose an .ipa, or drop it here" height:150];
        [z addTarget:self action:@selector(pickApp) forControlEvents:UIControlEventTouchUpInside];
        [self.appCard.stack addArrangedSubview:z];
        if (self.shared.count) [self.appCard.stack addArrangedSubview:[self sharedStripFor:self.shared tweaks:NO]];
    } else {
        NSString *detail = [NSString stringWithFormat:@"Version %@\n%@", self.app.version, self.app.bundleID];
        [self.appCard.stack addArrangedSubview:[self rowWithIcon:self.app.icon ?: Sym(@"app.fill", 30, UIImageSymbolWeightRegular)
                                                            tint:SPBlue round:YES title:self.app.name detail:detail action:@selector(removeApp) tag:0]];
        if (self.app.encrypted)
            [self.appCard.stack addArrangedSubview:[self note:@"This app is still encrypted, so it can't be modded. Decrypt it first (for example with TrollDecrypt), then add the decrypted .ipa." color:UIColor.systemRedColor]];
        else if (self.app.existingTweaks)
            [self.appCard.stack addArrangedSubview:[self note:@"This app already looks modded. Tweaks you add now are added on top." color:UIColor.systemOrangeColor]];
    }

    // Tweak card
    [self.tweakCard clearBody];
    for (NSUInteger i = 0; i < self.tweaks.count; i++) {
        SPTweak *t = self.tweaks[i];
        NSArray *skipped = nil;
        NSArray *use = [t dylibsForApp:self.app skipped:&skipped];
        NSMutableArray *bits = [NSMutableArray array];
        if (t.version.length) [bits addObject:[@"v" stringByAppendingString:t.version]];
        [bits addObject:use.count == 1 ? [use.firstObject lastPathComponent] : [NSString stringWithFormat:@"%lu libraries", (unsigned long)use.count]];
        if (t.frameworks.count || t.libraries.count) [bits addObject:@"+ support files"];
        UIView *row = [self rowWithIcon:Sym(@"puzzlepiece.extension.fill", 19, UIImageSymbolWeightMedium) ?: Sym(@"cube.box.fill", 19, UIImageSymbolWeightMedium)
                                   tint:UIColor.systemPurpleColor round:NO title:t.name
                                 detail:[bits componentsJoinedByString:@" · "] action:@selector(removeTweak:) tag:(NSInteger)i];
        [self.tweakCard.stack addArrangedSubview:row];
        if (self.app && !use.count)
            [self.tweakCard.stack addArrangedSubview:[self note:[NSString stringWithFormat:@"Made for other apps, not %@. It'll be skipped.", self.app.name] color:UIColor.systemOrangeColor]];
        NSArray *deps = [t dependencyWarnings];
        if (deps.count)
            [self.tweakCard.stack addArrangedSubview:[self note:[NSString stringWithFormat:@"Also needs %@. Add its .deb too if the app crashes.", [deps componentsJoinedByString:@", "]] color:UIColor.secondaryLabelColor]];
    }
    SPDropZone *tz = [[SPDropZone alloc] initWithSymbol:@"plus.circle.fill" title:self.tweaks.count ? @"Add another tweak" : @"Add a tweak"
                                               subtitle:@".deb or .dylib, tap or drop" height:self.tweaks.count ? 84 : 120];
    [tz addTarget:self action:@selector(pickTweak) forControlEvents:UIControlEventTouchUpInside];
    [self.tweakCard.stack addArrangedSubview:tz];
    NSMutableArray *offer = [NSMutableArray array];   // shared tweaks not added yet
    for (SPSharedApp *st in self.sharedTweaks) {
        BOOL have = NO;
        for (SPTweak *t in self.tweaks)
            if ((st.packageID.length && [t.packageID isEqualToString:st.packageID]) || [t.fileName isEqualToString:st.fileName]) have = YES;
        if (!have) [offer addObject:st];
    }
    if (offer.count) [self.tweakCard.stack addArrangedSubview:[self sharedStripFor:offer tweaks:YES]];

    // Options placeholders follow the app
    self.nameField.placeholder = self.app ? self.app.name : @"Same as the app";
    self.idField.placeholder = self.app ? self.app.bundleID : @"Same as the app";

    BOOL ready = self.app && !self.app.encrypted && self.tweaks.count && !self.busy;
    self.buildButton.enabled = ready;
    self.buildHint.text = !self.app ? @"Add an app to get started." : self.app.encrypted ? @"Decrypt the app first." :
                          !self.tweaks.count ? @"Add at least one tweak." : @"Builds an .ipa you can install with TrollStore or any sideloader.";
}

- (UIView *)switchRow:(NSString *)title detail:(NSString *)detail on:(BOOL)on action:(SEL)sel {
    UILabel *t = Label(title, [UIFont systemFontOfSize:16], UIColor.labelColor);
    UILabel *d = Label(detail, [UIFont systemFontOfSize:12], UIColor.secondaryLabelColor);
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[t, d]];
    text.axis = UILayoutConstraintAxisVertical;
    text.spacing = 2;
    UISwitch *sw = [UISwitch new];
    sw.on = on;
    sw.onTintColor = SPBlue;
    [sw addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    [sw setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[text, sw]];
    row.spacing = 12;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

- (UITextField *)field:(NSString *)label into:(UIStackView *)stack {
    UILabel *l = Label(label, [UIFont systemFontOfSize:13 weight:UIFontWeightMedium], UIColor.secondaryLabelColor);
    UITextField *f = [UITextField new];
    f.borderStyle = UITextBorderStyleNone;
    f.backgroundColor = UIColor.tertiarySystemFillColor;
    f.layer.cornerRadius = 10;
    f.font = [UIFont systemFontOfSize:16];
    f.clearButtonMode = UITextFieldViewModeWhileEditing;
    f.returnKeyType = UIReturnKeyDone;
    f.delegate = self;
    f.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    f.leftViewMode = UITextFieldViewModeAlways;
    [f.heightAnchor constraintEqualToConstant:42].active = YES;
    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[l, f]];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 6;
    [stack addArrangedSubview:v];
    return f;
}

- (void)buildOptions {
    UIStackView *s = self.optionsCard.stack;
    self.nameField = [self field:@"App name" into:s];
    self.idField = [self field:@"Bundle ID (change it to keep the original app installed too)" into:s];
    self.idField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.idField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.idField.keyboardType = UIKeyboardTypeURL;
    [s addArrangedSubview:[self switchRow:@"Remove app extensions" detail:@"Widgets, share sheets etc. Helps with free Apple IDs (fewer app IDs)." on:self.opts.removeExtensions action:@selector(toggleExt:)]];
    [s addArrangedSubview:[self switchRow:@"Remove Watch app" detail:@"Not needed on your phone." on:self.opts.removeWatch action:@selector(toggleWatch:)]];
    [s addArrangedSubview:[self switchRow:@"Allow any device" detail:@"Drops the app's device restrictions." on:self.opts.anyDevice action:@selector(toggleDevice:)]];
    [s addArrangedSubview:[self switchRow:@"Compress the .ipa" detail:@"Smaller file. Turn off for a much faster build." on:self.opts.compress action:@selector(toggleCompress:)]];
}

- (void)toggleExt:(UISwitch *)s { self.opts.removeExtensions = s.on; }
- (void)toggleWatch:(UISwitch *)s { self.opts.removeWatch = s.on; }
- (void)toggleDevice:(UISwitch *)s { self.opts.anyDevice = s.on; }
- (void)toggleCompress:(UISwitch *)s { self.opts.compress = s.on; }
- (BOOL)textFieldShouldReturn:(UITextField *)f { [f resignFirstResponder]; return YES; }

#pragma mark Shared apps

- (void)loadShared {
    [SPLibrary fetchCatalog:^(NSArray<SPSharedApp *> *apps, NSArray<SPSharedApp *> *tweaks, NSError *err) {
        [self.scroll.refreshControl endRefreshing];
        if (!apps) return;   // offline: just don't show the rows
        self.shared = apps;
        self.sharedTweaks = tweaks;
        [self refresh];
    }];
}

- (UIView *)sharedStripFor:(NSArray<SPSharedApp *> *)items tweaks:(BOOL)tweaks {
    UILabel *head = Label(tweaks ? @"Or add a shared tweak" : @"Or pick a shared app", [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold], UIColor.secondaryLabelColor);
    UIStackView *row = [UIStackView new];
    row.spacing = 14;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSUInteger i = 0; i < items.count; i++) {
        SPSharedApp *a = items[i];
        UIImageView *iv = [[UIImageView alloc] initWithImage:Sym(tweaks ? @"puzzlepiece.extension.fill" : @"app.fill", tweaks ? 26 : 34, UIImageSymbolWeightRegular)];
        iv.tintColor = tweaks ? UIColor.systemPurpleColor : UIColor.systemGray3Color;
        iv.backgroundColor = tweaks ? [UIColor.systemPurpleColor colorWithAlphaComponent:0.12] : UIColor.clearColor;
        iv.contentMode = tweaks ? UIViewContentModeCenter : UIViewContentModeScaleAspectFill;
        iv.layer.cornerRadius = 14;
        iv.layer.cornerCurve = kCACornerCurveContinuous;
        iv.clipsToBounds = YES;
        [iv.widthAnchor constraintEqualToConstant:62].active = YES;
        [iv.heightAnchor constraintEqualToConstant:62].active = YES;
        if (!tweaks) [SPLibrary loadIcon:a.iconURL into:iv];
        UILabel *n = Label(a.name, [UIFont systemFontOfSize:12 weight:UIFontWeightMedium], UIColor.labelColor);
        n.numberOfLines = 1;
        n.textAlignment = NSTextAlignmentCenter;
        UILabel *v = Label(a.version, [UIFont systemFontOfSize:11], UIColor.secondaryLabelColor);
        v.numberOfLines = 1;
        v.textAlignment = NSTextAlignmentCenter;
        UIStackView *tile = [[UIStackView alloc] initWithArrangedSubviews:@[iv, n, v]];
        tile.axis = UILayoutConstraintAxisVertical;
        tile.alignment = UIStackViewAlignmentCenter;
        tile.spacing = 4;
        tile.userInteractionEnabled = NO;
        tile.translatesAutoresizingMaskIntoConstraints = NO;
        [tile.widthAnchor constraintEqualToConstant:74].active = YES;
        UIControl *tap = [UIControl new];
        tap.tag = (NSInteger)i;
        objc_setAssociatedObject(tap, "item", a, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [tap addSubview:tile];
        [NSLayoutConstraint activateConstraints:@[
            [tile.topAnchor constraintEqualToAnchor:tap.topAnchor], [tile.bottomAnchor constraintEqualToAnchor:tap.bottomAnchor],
            [tile.leadingAnchor constraintEqualToAnchor:tap.leadingAnchor], [tile.trailingAnchor constraintEqualToAnchor:tap.trailingAnchor],
        ]];
        [tap addTarget:self action:@selector(sharedTapped:) forControlEvents:UIControlEventTouchUpInside];
        [row addArrangedSubview:tap];
    }
    UIScrollView *sc = [UIScrollView new];
    sc.showsHorizontalScrollIndicator = NO;
    [sc addSubview:row];
    [NSLayoutConstraint activateConstraints:@[
        [row.topAnchor constraintEqualToAnchor:sc.contentLayoutGuide.topAnchor],
        [row.bottomAnchor constraintEqualToAnchor:sc.contentLayoutGuide.bottomAnchor],
        [row.leadingAnchor constraintEqualToAnchor:sc.contentLayoutGuide.leadingAnchor],
        [row.trailingAnchor constraintEqualToAnchor:sc.contentLayoutGuide.trailingAnchor],
        [row.heightAnchor constraintEqualToAnchor:sc.frameLayoutGuide.heightAnchor],
        [sc.heightAnchor constraintEqualToConstant:104],
    ]];
    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:@[head, sc]];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 8;
    return v;
}

- (void)sharedTapped:(UIControl *)c {
    SPSharedApp *a = objc_getAssociatedObject(c, "item");
    if (self.busy || !a) return;
    self.busy = YES;
    [self refresh];
    NSString *what = [NSString stringWithFormat:@"Downloading %@", a.name];
    [self showHUD:[what stringByAppendingString:@"…"]];
    __block CFAbsoluteTime last = 0;
    [SPLibrary download:a progress:^(double f) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last < 0.1) return;
        last = now;
        [self showHUD:[NSString stringWithFormat:@"%@\n%d%%%@", what, (int)(f * 100),
                       a.size ? [@" of " stringByAppendingString:SizeString((unsigned long long)a.size)] : @""]];
    } completion:^(NSString *path, NSError *err) {
        self.busy = NO;
        [self hideHUD];
        if (!path) { [self alert:[NSString stringWithFormat:@"Couldn't download %@", a.name] message:err.localizedDescription]; [self refresh]; return; }
        self.pick = a.isTweak ? SPPickTweak : SPPickApp;
        [self openURLs:@[[NSURL fileURLWithPath:path]]];
    }];
}

#pragma mark Admin

- (void)unlockAdmin {
    if (self.lockedUntil && [self.lockedUntil timeIntervalSinceNow] > 0) {
        [self alert:@"Locked" message:[NSString stringWithFormat:@"Too many wrong tries. Try again in %d seconds.", (int)ceil([self.lockedUntil timeIntervalSinceNow])]];
        return;
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Admin" message:@"Enter the password to manage shared apps."
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"Password";
        f.secureTextEntry = YES;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Unlock" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        if (![SPAdmin unlock:a.textFields.firstObject.text ?: @""]) {
            [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeError];
            if (++self.failedUnlocks >= 5) {
                self.failedUnlocks = 0;
                self.lockedUntil = [NSDate dateWithTimeIntervalSinceNow:60];
            }
            [self alert:@"Wrong password" message:@""];
            return;
        }
        self.failedUnlocks = 0;
        SPAdminController *admin = [SPAdminController new];
        admin.apps = self.shared;
        admin.tweaks = self.sharedTweaks;
        __weak typeof(self) ws = self;
        admin.onChange = ^(NSArray<SPSharedApp *> *apps, NSArray<SPSharedApp *> *tweaks) { ws.shared = apps; ws.sharedTweaks = tweaks; [ws refresh]; };
        [self presentViewController:[[UINavigationController alloc] initWithRootViewController:admin] animated:YES completion:nil];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Actions

- (void)about {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Splice"
        message:@"Splice puts tweaks into an app so you can install the modded app without a jailbreak.\n\n"
                 "1. Add a decrypted .ipa (TrollDecrypt, or one you already have).\n"
                 "2. Add the tweak's .deb (or just its .dylib). Add more than one if you like.\n"
                 "3. Build, then install with TrollStore or sign it with your sideloader.\n\n"
                 "Splice adds its own small substrate so tweaks work without a jailbreak. Hooks on Objective-C methods "
                 "(what almost every app tweak uses) work fully; hooks on C functions only catch calls made through a library import. "
                 "Tweak settings that live in the Settings app won't show up - use the tweak's in-app settings if it has them.\n\n"
                 "You can also share .ipa, .deb and .dylib files to Splice from Files or Filza, or tap one of the shared apps under the App card to download it."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showLibrary {
    [self presentViewController:[[UINavigationController alloc] initWithRootViewController:[SPLibraryController new]] animated:YES completion:nil];
}

- (void)alert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    UIViewController *top = self;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:a animated:YES completion:nil];
}

- (void)presentPicker:(BOOL)multiple {
    UIDocumentPickerViewController *p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"public.data", @"public.item"] inMode:UIDocumentPickerModeOpen];
    p.delegate = self;
    p.allowsMultipleSelection = NO;   // one tap = add it (multi-select needed an extra Open tap)
    [self presentViewController:p animated:YES completion:nil];
}
- (void)pickApp { self.pick = SPPickApp; [self presentPicker:NO]; }
- (void)pickTweak { self.pick = SPPickTweak; [self presentPicker:YES]; }

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [self openURLs:urls];
}

- (void)removeApp { self.app = nil; [self refresh]; }
- (void)removeTweak:(UIButton *)b {
    if (b.tag < (NSInteger)self.tweaks.count) [self.tweaks removeObjectAtIndex:(NSUInteger)b.tag];
    [self refresh];
}

#pragma mark Importing

- (void)showHUD:(NSString *)text {
    if (!self.hud) {
        UIVisualEffectView *v = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
        v.layer.cornerRadius = 22; v.clipsToBounds = YES;
        v.translatesAutoresizingMaskIntoConstraints = NO;
        UIActivityIndicatorView *sp = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
        [sp startAnimating];
        self.hudLabel = Label(text, [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold], UIColor.labelColor);
        self.hudLabel.textAlignment = NSTextAlignmentCenter;
        UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[sp, self.hudLabel]];
        s.axis = UILayoutConstraintAxisVertical; s.spacing = 12; s.alignment = UIStackViewAlignmentCenter;
        s.translatesAutoresizingMaskIntoConstraints = NO;
        [v.contentView addSubview:s];
        UIView *dim = [UIView new];
        dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
        dim.translatesAutoresizingMaskIntoConstraints = NO;
        [dim addSubview:v];
        [self.navigationController.view addSubview:dim];
        [NSLayoutConstraint activateConstraints:@[
            [dim.topAnchor constraintEqualToAnchor:self.navigationController.view.topAnchor],
            [dim.bottomAnchor constraintEqualToAnchor:self.navigationController.view.bottomAnchor],
            [dim.leadingAnchor constraintEqualToAnchor:self.navigationController.view.leadingAnchor],
            [dim.trailingAnchor constraintEqualToAnchor:self.navigationController.view.trailingAnchor],
            [v.centerXAnchor constraintEqualToAnchor:dim.centerXAnchor], [v.centerYAnchor constraintEqualToAnchor:dim.centerYAnchor],
            [v.widthAnchor constraintEqualToConstant:220],
            [s.topAnchor constraintEqualToAnchor:v.contentView.topAnchor constant:24],
            [s.bottomAnchor constraintEqualToAnchor:v.contentView.bottomAnchor constant:-24],
            [s.leadingAnchor constraintEqualToAnchor:v.contentView.leadingAnchor constant:16],
            [s.trailingAnchor constraintEqualToAnchor:v.contentView.trailingAnchor constant:-16],
        ]];
        self.hud = dim;
    }
    self.hudLabel.text = text;
}
- (void)hideHUD { [self.hud removeFromSuperview]; self.hud = nil; }

// Copy a file we were handed somewhere stable before working on it.
static NSString *Stash(NSURL *url) {
    if ([url.path hasPrefix:SPWorkRoot()]) return url.path;   // our own drop/download copy
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSString *dir = [SPWorkRoot() stringByAppendingPathComponent:[@"in-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *dst = [dir stringByAppendingPathComponent:url.lastPathComponent ?: @"file"];
    // Coordinated read so files from iCloud Drive / other providers are downloaded first.
    __block BOOL ok = NO;
    NSError *ce = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&ce byAccessor:^(NSURL *u) {
        ok = [NSFileManager.defaultManager copyItemAtURL:u toURL:[NSURL fileURLWithPath:dst] error:nil];
    }];
    if (!ok) ok = [NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    return ok ? dst : nil;
}

- (void)openURLs:(NSArray<NSURL *> *)urls {
    [self.queue addObjectsFromArray:urls];
    [self drainQueue];
}

- (void)drainQueue {
    if (self.busy || !self.queue.count) return;
    NSURL *url = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    NSString *ext = url.pathExtension.lowercaseString;
    BOOL isApp = [ext isEqualToString:@"ipa"] || [ext isEqualToString:@"tipa"] || ([ext isEqualToString:@"zip"] && self.pick == SPPickApp);
    BOOL isTweak = [ext isEqualToString:@"deb"] || [ext isEqualToString:@"dylib"];
    if (!isApp && !isTweak) {
        [self alert:@"Not something Splice can use" message:[NSString stringWithFormat:@"%@ isn't an .ipa, .deb or .dylib.", url.lastPathComponent]];
        [self drainQueue];
        return;
    }
    self.busy = YES;
    [self refresh];
    [self showHUD:isApp ? [NSString stringWithFormat:@"Unpacking %@…", url.lastPathComponent.stringByDeletingPathExtension]
                        : [NSString stringWithFormat:@"Reading %@…", url.lastPathComponent]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *local = url.isFileURL ? Stash(url) : nil;
        NSError *err = nil;
        id obj = nil;
        if (!local) err = [NSError errorWithDomain:@"Splice" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Couldn't read that file."}];
        else obj = isApp ? [SPApp importIPA:local error:&err] : [SPTweak importFile:local error:&err];
        if (local) [NSFileManager.defaultManager removeItemAtPath:local.stringByDeletingLastPathComponent error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [self hideHUD];
            if (!obj) [self alert:[NSString stringWithFormat:@"Couldn't add %@", url.lastPathComponent] message:err.localizedDescription];
            else if (isApp) self.app = obj;
            else {
                SPTweak *t = obj;
                NSUInteger dupe = [self.tweaks indexOfObjectPassingTest:^BOOL(SPTweak *o, NSUInteger i, BOOL *stop) {
                    return (t.packageID.length && [o.packageID isEqualToString:t.packageID]) || [o.fileName isEqualToString:t.fileName];
                }];
                if (dupe != NSNotFound) [self.tweaks replaceObjectAtIndex:dupe withObject:t];
                else [self.tweaks addObject:t];
            }
            [UIView animateWithDuration:0.25 animations:^{ [self refresh]; [self.view layoutIfNeeded]; }];
            [self drainQueue];
        });
    });
}

#pragma mark Drag and drop

- (SPDropZone *)zoneIn:(UIView *)card {
    for (UIView *v in [(SPCard *)card stack].arrangedSubviews) if ([v isKindOfClass:SPDropZone.class]) return (SPDropZone *)v;
    return nil;
}
- (BOOL)dropInteraction:(UIDropInteraction *)i canHandleSession:(id<UIDropSession>)s {
    return [s hasItemsConformingToTypeIdentifiers:@[@"public.data"]];
}
- (UIDropProposal *)dropInteraction:(UIDropInteraction *)i sessionDidUpdate:(id<UIDropSession>)s {
    [self zoneIn:i.view].hovering = YES;
    return [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
}
- (void)dropInteraction:(UIDropInteraction *)i sessionDidExit:(id<UIDropSession>)s { [self zoneIn:i.view].hovering = NO; }
- (void)dropInteraction:(UIDropInteraction *)i sessionDidEnd:(id<UIDropSession>)s { [self zoneIn:i.view].hovering = NO; }
- (void)dropInteraction:(UIDropInteraction *)i performDrop:(id<UIDropSession>)s {
    self.pick = i.view == self.appCard ? SPPickApp : SPPickTweak;
    for (UIDragItem *item in s.items) {
        NSString *suggested = item.itemProvider.suggestedName;
        [item.itemProvider loadFileRepresentationForTypeIdentifier:@"public.data" completionHandler:^(NSURL *url, NSError *e) {
            if (!url) return;
            // The file is only valid inside this block - copy it out with its real name.
            NSString *name = url.lastPathComponent;
            if (suggested.length && !name.pathExtension.length) name = suggested;
            NSString *dir = [SPWorkRoot() stringByAppendingPathComponent:[@"drop-" stringByAppendingString:NSUUID.UUID.UUIDString]];
            [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *dst = [dir stringByAppendingPathComponent:name];
            if (![NSFileManager.defaultManager copyItemAtURL:url toURL:[NSURL fileURLWithPath:dst] error:nil]) return;
            dispatch_async(dispatch_get_main_queue(), ^{ [self openURLs:@[[NSURL fileURLWithPath:dst]]]; });
        }];
    }
}

#pragma mark Build

- (void)build {
    [self.view endEditing:YES];
    SPBuildOptions *o = [SPBuildOptions new];
    o.displayName = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    o.bundleID = [self.idField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    o.removeExtensions = self.opts.removeExtensions;
    o.removeWatch = self.opts.removeWatch;
    o.anyDevice = self.opts.anyDevice;
    o.compress = self.opts.compress;
    if (o.bundleID.length) {
        NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"] invertedSet];
        if ([o.bundleID rangeOfCharacterFromSet:bad].location != NSNotFound || [o.bundleID hasPrefix:@"."] || [o.bundleID hasSuffix:@"."]) {
            [self alert:@"Bundle ID" message:@"Use only letters, numbers, dots and dashes, like com.me.instagram."];
            return;
        }
    }
    SPBuildController *b = [SPBuildController new];
    b.app = self.app; b.tweaks = [self.tweaks copy]; b.opts = o;
    b.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:b animated:YES completion:nil];
}

@end

#pragma mark - App delegate

@interface SPAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) SPMainController *main;
@end

@implementation SPAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    [NSFileManager.defaultManager removeItemAtPath:SPWorkRoot() error:nil];   // leftovers from last time
    SPBuildsDir();
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.tintColor = SPBlue;
    self.main = [SPMainController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.main];
    nav.navigationBar.prefersLargeTitles = YES;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;   // a file opened from Files/Filza arrives through application:openURL:options:
}
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    if (!url.isFileURL) return NO;
    [self.main openURLs:@[url]];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SPAppDelegate.class));
    }
}

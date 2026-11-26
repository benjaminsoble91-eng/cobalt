// BlobKeeper (com.mymculture.blobkeeper)
// Saves this device's onboard blob: the IM4M ticket from its last restore/update, which the system
// keeps on disk. A root helper finds and copies the ticket and reads the boot-nonce generator from
// NVRAM; the app checks the ticket, wraps it as a .shsh2 (the format futurerestore/turdus use), and
// lets you share it or save it to Files.
// JBROOT is "" on rootful jailbreaks and "/var/jb" on rootless ones (set by build.sh).

#import <UIKit/UIKit.h>
#import <spawn.h>
#import <sys/wait.h>
#import <dlfcn.h>
#import <sys/utsname.h>
#include "ticket.h"

#ifndef JBROOT
#define JBROOT ""
#endif

extern char **environ;
#define BK_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *attr, uid_t persona_id, uint32_t flags);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *attr, uid_t uid);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *attr, gid_t gid);

#pragma mark - Colours

static UIColor *Hex(uint32_t rgb) {
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0 green:((rgb >> 8) & 0xff) / 255.0 blue:(rgb & 0xff) / 255.0 alpha:1];
}
#define BK_BG_TOP    Hex(0x0e1a46)
#define BK_BG_BOT    Hex(0x0a1230)
#define BK_CARD      [Hex(0x1a2a63) colorWithAlphaComponent:0.72]
#define BK_ACCENT    Hex(0x6ea2ff)
#define BK_BLUE      Hex(0x2e6bff)
#define BK_TEXT      Hex(0xeaf1ff)
#define BK_SUBTEXT   Hex(0x9fb3e6)
#define BK_GOOD      Hex(0x34d399)
#define BK_WARN      Hex(0xfbbf24)
#define BK_BAD       Hex(0xf87171)

#pragma mark - Device info (MobileGestalt)

static NSString *MG(NSString *key) {
    static CFTypeRef (*copyAnswer)(CFStringRef) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
        if (h) copyAnswer = (CFTypeRef (*)(CFStringRef))dlsym(h, "MGCopyAnswer");
    });
    if (!copyAnswer) return nil;
    id v = CFBridgingRelease(copyAnswer((__bridge CFStringRef)key));
    if ([v isKindOfClass:NSString.class]) return v;
    if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
    return nil;
}

static NSString *FriendlyModel(NSString *productType) {
    NSDictionary *names = @{
        @"iPhone12,8": @"iPhone SE (2nd gen)", @"iPhone14,6": @"iPhone SE (3rd gen)",
        @"iPhone8,1": @"iPhone 6s", @"iPhone8,2": @"iPhone 6s Plus", @"iPhone8,4": @"iPhone SE",
        @"iPhone9,1": @"iPhone 7", @"iPhone9,3": @"iPhone 7", @"iPhone9,2": @"iPhone 7 Plus", @"iPhone9,4": @"iPhone 7 Plus",
        @"iPhone10,1": @"iPhone 8", @"iPhone10,4": @"iPhone 8", @"iPhone10,2": @"iPhone 8 Plus", @"iPhone10,5": @"iPhone 8 Plus",
        @"iPhone10,3": @"iPhone X", @"iPhone10,6": @"iPhone X", @"iPhone11,2": @"iPhone XS", @"iPhone11,4": @"iPhone XS Max",
        @"iPhone11,6": @"iPhone XS Max", @"iPhone11,8": @"iPhone XR", @"iPhone12,1": @"iPhone 11", @"iPhone12,3": @"iPhone 11 Pro",
        @"iPhone12,5": @"iPhone 11 Pro Max", @"iPhone13,1": @"iPhone 12 mini", @"iPhone13,2": @"iPhone 12",
        @"iPhone13,3": @"iPhone 12 Pro", @"iPhone13,4": @"iPhone 12 Pro Max", @"iPhone14,4": @"iPhone 13 mini",
        @"iPhone14,5": @"iPhone 13", @"iPhone14,2": @"iPhone 13 Pro", @"iPhone14,3": @"iPhone 13 Pro Max",
        @"iPhone14,7": @"iPhone 14", @"iPhone14,8": @"iPhone 14 Plus", @"iPhone15,2": @"iPhone 14 Pro", @"iPhone15,3": @"iPhone 14 Pro Max",
        @"iPad6,3": @"iPad Pro 9.7\"", @"iPad6,4": @"iPad Pro 9.7\"",
    };
    return names[productType] ?: productType ?: @"Unknown";
}

@interface BKDevice : NSObject
@property (nonatomic, copy) NSString *productType, *board, *version, *build, *ecidHex;
@property (nonatomic) uint64_t ecid;
@end
@implementation BKDevice
+ (instancetype)current {
    BKDevice *d = [BKDevice new];
    struct utsname u; uname(&u);
    d.productType = MG(@"ProductType") ?: [NSString stringWithUTF8String:u.machine];
    d.board = [MG(@"HWModelStr") lowercaseString];
    d.version = MG(@"ProductVersion") ?: UIDevice.currentDevice.systemVersion;
    d.build = MG(@"BuildVersion");
    NSString *e = MG(@"UniqueChipID");
    if (e.length) { d.ecid = strtoull(e.UTF8String, NULL, 10); d.ecidHex = [NSString stringWithFormat:@"%llX", d.ecid]; }
    return d;
}
@end

#pragma mark - Root helper

static NSString *JBPath(NSString *p) { return [@JBROOT stringByAppendingString:p]; }

static NSString *BlobDir(void) {
    return @"/var/mobile/Documents/BlobKeeper";
}

// Runs the helper once, as root through the persona API (works for platform apps on Dopamine)
// or plainly, relying on the helper's setuid bit (other jailbreaks).
static int RunHelperOnce(NSArray<NSString *> *args, BOOL persona, NSString **out, NSString **err) {
    NSString *helper = JBPath(@"/usr/libexec/blobkeeper-helper");
    NSMutableArray *all = [NSMutableArray arrayWithObject:helper];
    [all addObjectsFromArray:args];
    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] UTF8String]);

    int outp[2], errp[2];
    pipe(outp); pipe(errp);
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, outp[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, errp[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, outp[0]);
    posix_spawn_file_actions_addclose(&fa, errp[0]);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    if (persona) {
        posix_spawnattr_set_persona_np(&attr, 99, BK_PERSONA_FLAGS_OVERRIDE);
        posix_spawnattr_set_persona_uid_np(&attr, 0);
        posix_spawnattr_set_persona_gid_np(&attr, 0);
    }
    pid_t pid = 0;
    int rc = posix_spawn(&pid, argv[0], &fa, &attr, argv, environ);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&fa);
    close(outp[1]); close(errp[1]);

    // Output is small (a few lines), so reading stdout then stderr can't deadlock.
    NSMutableData *o = [NSMutableData data], *e = [NSMutableData data];
    char chunk[4096]; ssize_t n;
    while ((n = read(outp[0], chunk, sizeof(chunk))) > 0) [o appendBytes:chunk length:n];
    while ((n = read(errp[0], chunk, sizeof(chunk))) > 0) [e appendBytes:chunk length:n];
    close(outp[0]); close(errp[0]);

    int status = -1;
    if (rc == 0) {
        waitpid(pid, &status, 0);
        status = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }
    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);
    if (out) *out = [[NSString alloc] initWithData:o encoding:NSUTF8StringEncoding] ?: @"";
    if (err) *err = [[NSString alloc] initWithData:e encoding:NSUTF8StringEncoding] ?: @"";
    return rc == 0 ? status : -1;
}

static int RunHelper(NSArray<NSString *> *args, NSString **out, NSString **err) {
    int rc = RunHelperOnce(args, YES, out, err);
    if (rc == -1 || rc == 3) rc = RunHelperOnce(args, NO, out, err);   // persona refused / didn't give root
    return rc;
}

static NSDictionary<NSString *, NSString *> *ParseKV(NSString *s) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
        NSRange r = [line rangeOfString:@"="];
        if (r.location != NSNotFound) d[[line substringToIndex:r.location]] = [line substringFromIndex:r.location + 1];
    }
    return d;
}

static NSString *HexString(const uint8_t *b, size_t n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

#pragma mark - Step row

typedef NS_ENUM(NSInteger, BKStepState) { BKStepIdle, BKStepRunning, BKStepDone, BKStepWarn, BKStepFailed };

@interface BKStepRow : UIView
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *title, *detail;
- (void)setState:(BKStepState)state detail:(NSString *)detail;
@end

@implementation BKStepRow
- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super init])) {
        _icon = [UIImageView new];
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.color = BK_ACCENT;
        _title = [UILabel new];
        _title.text = title;
        _title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _title.textColor = BK_TEXT;
        _detail = [UILabel new];
        _detail.font = [UIFont systemFontOfSize:13];
        _detail.textColor = BK_SUBTEXT;
        _detail.numberOfLines = 0;
        for (UIView *v in @[_icon, _spinner, _title, _detail]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self addSubview:v]; }
        [NSLayoutConstraint activateConstraints:@[
            [_icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_icon.topAnchor constraintEqualToAnchor:self.topAnchor constant:1],
            [_icon.widthAnchor constraintEqualToConstant:22], [_icon.heightAnchor constraintEqualToConstant:22],
            [_spinner.centerXAnchor constraintEqualToAnchor:_icon.centerXAnchor],
            [_spinner.centerYAnchor constraintEqualToAnchor:_icon.centerYAnchor],
            [_title.leadingAnchor constraintEqualToAnchor:_icon.trailingAnchor constant:12],
            [_title.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_title.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_detail.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
            [_detail.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_detail.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:2],
            [_detail.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
        [self setState:BKStepIdle detail:nil];
    }
    return self;
}
- (void)setState:(BKStepState)state detail:(NSString *)detail {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold];
    NSString *sym = @"circle"; UIColor *tint = [BK_SUBTEXT colorWithAlphaComponent:0.5];
    switch (state) {
        case BKStepIdle: break;
        case BKStepRunning: sym = nil; break;
        case BKStepDone: sym = @"checkmark.circle.fill"; tint = BK_GOOD; break;
        case BKStepWarn: sym = @"exclamationmark.circle.fill"; tint = BK_WARN; break;
        case BKStepFailed: sym = @"xmark.circle.fill"; tint = BK_BAD; break;
    }
    if (sym) {
        [self.spinner stopAnimating];
        self.icon.hidden = NO;
        self.icon.image = [UIImage systemImageNamed:sym withConfiguration:cfg];
        self.icon.tintColor = tint;
        if (state != BKStepIdle) {
            self.icon.transform = CGAffineTransformMakeScale(0.4, 0.4);
            [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.8 options:0
                             animations:^{ self.icon.transform = CGAffineTransformIdentity; } completion:nil];
        }
    } else {
        self.icon.hidden = YES;
        [self.spinner startAnimating];
    }
    self.title.textColor = state == BKStepIdle ? [BK_TEXT colorWithAlphaComponent:0.55] : BK_TEXT;
    self.detail.text = detail;
    self.detail.hidden = detail.length == 0;
}
@end

#pragma mark - Main screen

@interface BKViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) BKDevice *device;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UIButton *saveButton;
@property (nonatomic, strong) CAGradientLayer *buttonGradient;
@property (nonatomic, strong) UIView *stepsCard, *resultCard;
@property (nonatomic, strong) NSArray<BKStepRow *> *steps;
@property (nonatomic, strong) UILabel *resultTitle, *resultFile, *resultNonce, *resultGen, *resultNote;
@property (nonatomic, strong) UILabel *ecidValue;
@property (nonatomic) BOOL ecidShown;
@property (nonatomic, strong) NSArray<NSURL *> *lastFiles;
@property (nonatomic, strong) UITableView *savedTable;
@property (nonatomic, strong) NSLayoutConstraint *savedHeight;
@property (nonatomic, strong) UILabel *savedEmpty;
@property (nonatomic, strong) NSArray<NSURL *> *saved;
@property (nonatomic) BOOL busy;
@end

@implementation BKViewController

- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

- (UIView *)card {
    UIView *c = [UIView new];
    c.backgroundColor = BK_CARD;
    c.layer.cornerRadius = 20;
    c.layer.cornerCurve = kCACornerCurveContinuous;
    c.layer.borderWidth = 1;
    c.layer.borderColor = [BK_ACCENT colorWithAlphaComponent:0.18].CGColor;
    return c;
}

- (UIStackView *)vstack:(CGFloat)spacing in:(UIView *)card {
    UIStackView *s = [UIStackView new];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = spacing;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [s.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [s.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [s.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    return s;
}

- (UILabel *)label:(NSString *)t size:(CGFloat)size weight:(UIFontWeight)w color:(UIColor *)c {
    UILabel *l = [UILabel new];
    l.text = t;
    l.font = [UIFont systemFontOfSize:size weight:w];
    l.textColor = c;
    l.numberOfLines = 0;
    return l;
}

- (UILabel *)sectionHeader:(NSString *)t {
    UILabel *l = [self label:t.uppercaseString size:12 weight:UIFontWeightBold color:BK_SUBTEXT];
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:l.text];
    [a addAttribute:NSKernAttributeName value:@1.2 range:NSMakeRange(0, a.length)];
    l.attributedText = a;
    return l;
}

- (UIView *)infoRow:(NSString *)name value:(NSString *)value valueLabel:(UILabel **)outLabel {
    UIStackView *row = [UIStackView new];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentFirstBaseline;
    UILabel *n = [self label:name size:15 weight:UIFontWeightRegular color:BK_SUBTEXT];
    UILabel *v = [self label:value size:15 weight:UIFontWeightSemibold color:BK_TEXT];
    v.textAlignment = NSTextAlignmentRight;
    [n setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [row addArrangedSubview:n];
    [row addArrangedSubview:v];
    if (outLabel) *outLabel = v;
    return row;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.device = [BKDevice current];

    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.colors = @[(id)BK_BG_TOP.CGColor, (id)BK_BG_BOT.CGColor];
    bg.frame = UIScreen.mainScreen.bounds;
    [self.view.layer insertSublayer:bg atIndex:0];
    self.view.backgroundColor = BK_BG_BOT;

    self.scroll = [UIScrollView new];
    self.scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.scroll.alwaysBounceVertical = YES;
    [self.view addSubview:self.scroll];
    self.stack = [UIStackView new];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 16;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scroll addSubview:self.stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.topAnchor constant:12],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [self.stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [self.stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
    ]];

    // Header
    UIStackView *header = [UIStackView new];
    header.axis = UILayoutConstraintAxisVertical;
    header.spacing = 4;
    [header addArrangedSubview:[self label:@"BlobKeeper" size:34 weight:UIFontWeightHeavy color:UIColor.whiteColor]];
    [header addArrangedSubview:[self label:@"Save this device's onboard blob so you can come back to this iOS version later."
                                      size:15 weight:UIFontWeightRegular color:BK_SUBTEXT]];
    [self.stack addArrangedSubview:header];
    [self.stack setCustomSpacing:22 afterView:header];

    // Device card
    UIView *dev = [self card];
    UIStackView *ds = [self vstack:12 in:dev];
    [ds addArrangedSubview:[self sectionHeader:@"This device"]];
    [ds addArrangedSubview:[self infoRow:@"Model" value:FriendlyModel(self.device.productType) valueLabel:nil]];
    NSString *ios = self.device.build ? [NSString stringWithFormat:@"%@ (%@)", self.device.version, self.device.build] : self.device.version;
    [ds addArrangedSubview:[self infoRow:@"iOS" value:ios valueLabel:nil]];
    if (self.device.board) [ds addArrangedSubview:[self infoRow:@"Board" value:self.device.board valueLabel:nil]];
    UILabel *ecidLabel = nil;
    UIView *ecidRow = [self infoRow:@"ECID" value:self.device.ecidHex ? @"Tap to show" : @"From ticket" valueLabel:&ecidLabel];
    self.ecidValue = ecidLabel;
    self.ecidValue.textColor = BK_ACCENT;
    [ecidRow addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleECID)]];
    [ds addArrangedSubview:ecidRow];
    [self.stack addArrangedSubview:dev];

    // Big button
    self.saveButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.saveButton setTitle:@"Save My Blob" forState:UIControlStateNormal];
    [self.saveButton setImage:[UIImage systemImageNamed:@"arrow.down.doc.fill"
                                     withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightBold]]
                     forState:UIControlStateNormal];
    self.saveButton.tintColor = UIColor.whiteColor;
    self.saveButton.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    self.saveButton.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 0);
    self.saveButton.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    self.saveButton.layer.cornerRadius = 18;
    self.saveButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.saveButton.clipsToBounds = YES;
    self.buttonGradient = [CAGradientLayer layer];
    self.buttonGradient.colors = @[(id)Hex(0x5b8cff).CGColor, (id)BK_BLUE.CGColor];
    self.buttonGradient.startPoint = CGPointMake(0, 0);
    self.buttonGradient.endPoint = CGPointMake(1, 1);
    [self.saveButton.layer insertSublayer:self.buttonGradient atIndex:0];
    [self.saveButton.heightAnchor constraintEqualToConstant:60].active = YES;
    [self.saveButton addTarget:self action:@selector(press:) forControlEvents:UIControlEventTouchDown];
    [self.saveButton addTarget:self action:@selector(release:) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.saveButton addTarget:self action:@selector(go) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:self.saveButton];

    // Steps card
    self.stepsCard = [self card];
    UIStackView *ss = [self vstack:16 in:self.stepsCard];
    [ss addArrangedSubview:[self sectionHeader:@"Steps"]];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *t in @[@"Find the onboard ticket", @"Check the ticket", @"Read the generator", @"Save the .shsh2"]) {
        BKStepRow *r = [[BKStepRow alloc] initWithTitle:t];
        [rows addObject:r];
        [ss addArrangedSubview:r];
    }
    self.steps = rows;
    [self.stack addArrangedSubview:self.stepsCard];

    // Result card (hidden until a run finishes)
    self.resultCard = [self card];
    self.resultCard.hidden = YES;
    self.resultCard.alpha = 0;
    UIStackView *rs = [self vstack:10 in:self.resultCard];
    self.resultTitle = [self label:@"" size:20 weight:UIFontWeightBold color:UIColor.whiteColor];
    [rs addArrangedSubview:self.resultTitle];
    self.resultFile = [self label:@"" size:13 weight:UIFontWeightMedium color:BK_ACCENT];
    self.resultFile.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    [rs addArrangedSubview:self.resultFile];
    UILabel *nonceName = [self sectionHeader:@"ApNonce"];
    [rs addArrangedSubview:nonceName];
    [rs setCustomSpacing:4 afterView:nonceName];
    self.resultNonce = [self label:@"" size:12 weight:UIFontWeightRegular color:BK_TEXT];
    self.resultNonce.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    [rs addArrangedSubview:self.resultNonce];
    UILabel *genName = [self sectionHeader:@"Generator"];
    [rs addArrangedSubview:genName];
    [rs setCustomSpacing:4 afterView:genName];
    self.resultGen = [self label:@"" size:12 weight:UIFontWeightRegular color:BK_TEXT];
    self.resultGen.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightSemibold];
    [rs addArrangedSubview:self.resultGen];
    self.resultNote = [self label:@"" size:13 weight:UIFontWeightRegular color:BK_SUBTEXT];
    [rs addArrangedSubview:self.resultNote];
    UIStackView *buttons = [UIStackView new];
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.spacing = 10;
    buttons.distribution = UIStackViewDistributionFillEqually;
    [buttons addArrangedSubview:[self smallButton:@"Share" symbol:@"square.and.arrow.up" action:@selector(shareLast:)]];
    [buttons addArrangedSubview:[self smallButton:@"Save to Files" symbol:@"folder.fill" action:@selector(exportLast)]];
    [rs addArrangedSubview:buttons];
    [rs setCustomSpacing:16 afterView:self.resultNote];
    [self.stack addArrangedSubview:self.resultCard];

    // Saved blobs
    UIView *savedCard = [self card];
    UIStackView *sv = [self vstack:8 in:savedCard];
    [sv addArrangedSubview:[self sectionHeader:@"Saved blobs"]];
    self.savedEmpty = [self label:@"Nothing saved yet." size:14 weight:UIFontWeightRegular color:BK_SUBTEXT];
    [sv addArrangedSubview:self.savedEmpty];
    self.savedTable = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.savedTable.backgroundColor = UIColor.clearColor;
    self.savedTable.separatorColor = [BK_ACCENT colorWithAlphaComponent:0.15];
    self.savedTable.separatorInset = UIEdgeInsetsZero;
    self.savedTable.scrollEnabled = NO;
    self.savedTable.dataSource = self;
    self.savedTable.delegate = self;
    self.savedTable.rowHeight = 58;
    self.savedHeight = [self.savedTable.heightAnchor constraintEqualToConstant:0];
    self.savedHeight.active = YES;
    [sv addArrangedSubview:self.savedTable];
    [self.stack addArrangedSubview:savedCard];

    UILabel *foot = [self label:@"Blobs are kept in /var/mobile/Documents/BlobKeeper. Use Share or Save to Files to keep a copy off the phone too."
                           size:12 weight:UIFontWeightRegular color:[BK_SUBTEXT colorWithAlphaComponent:0.7]];
    foot.textAlignment = NSTextAlignmentCenter;
    [self.stack addArrangedSubview:foot];

    [self reloadSaved];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.view.layer.sublayers.firstObject.frame = self.view.bounds;
    self.buttonGradient.frame = self.saveButton.bounds;
}

- (UIButton *)smallButton:(NSString *)title symbol:(NSString *)sym action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:[@" " stringByAppendingString:title] forState:UIControlStateNormal];
    [b setImage:[UIImage systemImageNamed:sym] forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    b.backgroundColor = [BK_BLUE colorWithAlphaComponent:0.85];
    b.layer.cornerRadius = 12;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    [b.heightAnchor constraintEqualToConstant:44].active = YES;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)toggleECID {
    if (!self.device.ecidHex) return;
    self.ecidShown = !self.ecidShown;
    [UIView transitionWithView:self.ecidValue duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.ecidValue.text = self.ecidShown ? self.device.ecidHex : @"Tap to show";
        self.ecidValue.textColor = self.ecidShown ? BK_TEXT : BK_ACCENT;
    } completion:nil];
}

- (void)press:(UIButton *)b {
    [UIView animateWithDuration:0.12 animations:^{ b.transform = CGAffineTransformMakeScale(0.97, 0.97); }];
}
- (void)release:(UIButton *)b {
    [UIView animateWithDuration:0.2 animations:^{ b.transform = CGAffineTransformIdentity; }];
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    self.saveButton.enabled = !busy;
    [self.saveButton setTitle:busy ? @"Working…" : @"Save My Blob" forState:UIControlStateNormal];
    self.saveButton.alpha = busy ? 0.7 : 1;
}

#pragma mark Run

- (void)step:(NSInteger)i state:(BKStepState)s detail:(NSString *)d {
    dispatch_async(dispatch_get_main_queue(), ^{ [self.steps[i] setState:s detail:d]; });
}

- (void)go {
    [self release:self.saveButton];
    if (self.busy) return;
    self.busy = YES;
    [[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    for (BKStepRow *r in self.steps) [r setState:BKStepIdle detail:nil];
    [UIView animateWithDuration:0.25 animations:^{ self.resultCard.alpha = 0; } completion:^(BOOL f) { self.resultCard.hidden = YES; }];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *err = [self runAll];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            UINotificationFeedbackGenerator *h = [UINotificationFeedbackGenerator new];
            [h notificationOccurred:err ? UINotificationFeedbackTypeError : UINotificationFeedbackTypeSuccess];
            if (err) [self showError:err];
            [self reloadSaved];
        });
    });
}

// Returns nil on success, or an error message.
- (NSString *)runAll {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = BlobDir();
    NSString *tmp = [dir stringByAppendingPathComponent:@".work"];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];

    // 1. Find + copy the ticket (root helper)
    [self step:0 state:BKStepRunning detail:nil];
    usleep(350000);
    NSString *out = nil, *errs = nil;
    int rc = RunHelper(@[@"dump", tmp], &out, &errs);
    NSDictionary *kv = ParseKV(out);
    if (rc != 0 || !kv[@"ticket"]) {
        NSString *why;
        switch (rc) {
            case 3: why = @"Couldn't get root. Make sure the jailbreak is active, then try again."; break;
            case 4: why = @"No onboard ticket on this device. It's normally created by every restore or update."; break;
            case -1: why = @"The helper is missing or couldn't run. Reinstall BlobKeeper from Cobalt."; break;
            default: why = errs.length ? [errs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                                       : [NSString stringWithFormat:@"Helper failed (code %d).", rc];
        }
        [self step:0 state:BKStepFailed detail:why];
        return why;
    }
    NSString *source = kv[@"source"];
    [self step:0 state:BKStepDone detail:[source hasPrefix:@"/private/preboot"] ? @"Found in Preboot" : source];

    // 2. Check it
    [self step:1 state:BKStepRunning detail:nil];
    usleep(350000);
    NSData *ticket = [NSData dataWithContentsOfFile:kv[@"ticket"]];
    bk_ticket t;
    bk_parse_ticket(ticket.bytes, ticket.length, &t);
    if (!t.valid || !t.has_bnch) {
        NSString *why = @"The file found isn't a usable IM4M ticket.";
        [self step:1 state:BKStepFailed detail:why];
        return why;
    }
    uint64_t ecid = self.device.ecid;
    BOOL ecidMismatch = t.has_ecid && ecid && t.ecid != ecid;
    if (!ecid && t.has_ecid) {
        ecid = t.ecid;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.device.ecid = ecid;
            self.device.ecidHex = [NSString stringWithFormat:@"%llX", ecid];
            self.ecidValue.text = @"Tap to show";
        });
    }
    NSString *nonce = HexString(t.bnch, t.bnch_len);
    if (ecidMismatch) {
        [self step:1 state:BKStepWarn detail:@"The ticket's ECID doesn't match this device. Saving it anyway."];
    } else {
        [self step:1 state:BKStepDone detail:[NSString stringWithFormat:@"Valid IM4M · %lu-byte ApNonce", (unsigned long)t.bnch_len]];
    }

    // 3. Generator
    [self step:2 state:BKStepRunning detail:nil];
    usleep(350000);
    NSString *gen = kv[@"generator"];
    if (gen) [self step:2 state:BKStepDone detail:gen];
    else [self step:2 state:BKStepWarn detail:@"None set in NVRAM. The blob is still saved."];

    // 4. Save
    [self step:3 state:BKStepRunning detail:nil];
    usleep(300000);
    NSString *ver = self.device.build ? [NSString stringWithFormat:@"%@-%@", self.device.version, self.device.build] : self.device.version;
    NSString *base = [NSString stringWithFormat:@"%llu_%@_%@_%@_%@", ecid, self.device.productType,
                      self.device.board ?: @"unknown", ver, nonce];
    NSMutableDictionary *shsh = [NSMutableDictionary dictionaryWithObject:ticket forKey:@"ApImg4Ticket"];
    if (gen) shsh[@"generator"] = gen;
    NSError *perr = nil;
    NSData *plist = [NSPropertyListSerialization dataWithPropertyList:shsh format:NSPropertyListXMLFormat_v1_0 options:0 error:&perr];
    NSString *shshPath = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"shsh2"]];
    NSString *derPath = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"der"]];
    BOOL existed = [fm fileExistsAtPath:shshPath];
    if (!plist || ![plist writeToFile:shshPath atomically:YES] || ![ticket writeToFile:derPath atomically:YES]) {
        NSString *why = [NSString stringWithFormat:@"Couldn't write the file: %@", perr.localizedDescription ?: @"permission denied"];
        [self step:3 state:BKStepFailed detail:why];
        return why;
    }
    [fm removeItemAtPath:tmp error:nil];
    [self step:3 state:BKStepDone detail:existed ? @"Updated your existing copy" : @"Saved"];

    NSArray *files = @[[NSURL fileURLWithPath:shshPath], [NSURL fileURLWithPath:derPath]];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.lastFiles = files;
        self.resultTitle.text = ecidMismatch ? @"Saved, with a warning" : @"Blob saved";
        self.resultFile.text = shshPath.lastPathComponent;
        self.resultNonce.text = nonce;
        self.resultGen.text = gen ?: @"Not set";
        self.resultGen.textColor = gen ? BK_GOOD : BK_WARN;
        self.resultNote.text = gen
            ? @"The generator came from NVRAM. On A12 and newer phones it can't be checked against the ApNonce on the device itself, so double-check it before you rely on this blob."
            : @"No generator was set, so this blob doesn't have one yet. You'll need the matching generator before a restore can use it.";
        self.resultCard.hidden = NO;
        self.resultCard.transform = CGAffineTransformMakeTranslation(0, 20);
        [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:0 animations:^{
            self.resultCard.alpha = 1;
            self.resultCard.transform = CGAffineTransformIdentity;
        } completion:^(BOOL f) {
            CGRect r = [self.scroll convertRect:self.resultCard.bounds fromView:self.resultCard];
            [self.scroll scrollRectToVisible:CGRectInset(r, 0, -20) animated:YES];
        }];
    });
    return nil;
}

- (void)showError:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Couldn't save the blob" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark Share / export

- (void)share:(NSArray<NSURL *> *)urls from:(UIView *)src {
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
    vc.popoverPresentationController.sourceView = src;
    vc.popoverPresentationController.sourceRect = src.bounds;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)export:(NSArray<NSURL *> *)urls {
    UIDocumentPickerViewController *vc = [[UIDocumentPickerViewController alloc] initForExportingURLs:urls asCopy:YES];
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)shareLast:(UIButton *)b { if (self.lastFiles) [self share:self.lastFiles from:b]; }
- (void)exportLast { if (self.lastFiles) [self export:self.lastFiles]; }

#pragma mark Saved list

- (void)reloadSaved {
    NSURL *dir = [NSURL fileURLWithPath:BlobDir()];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray *all = [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSPredicate *p = [NSPredicate predicateWithFormat:@"pathExtension == 'shsh2'"];
    self.saved = [[all filteredArrayUsingPredicate:p] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *da, *db;
        [a getResourceValue:&da forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&db forKey:NSURLContentModificationDateKey error:nil];
        return [db compare:da];
    }];
    self.savedEmpty.hidden = self.saved.count > 0;
    self.savedHeight.constant = self.saved.count * self.savedTable.rowHeight;
    [self.savedTable reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return self.saved.count; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"b"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"b"];
    c.backgroundColor = UIColor.clearColor;
    UIView *sel = [UIView new];
    sel.backgroundColor = [BK_ACCENT colorWithAlphaComponent:0.12];
    c.selectedBackgroundView = sel;
    NSURL *u = self.saved[ip.row];
    // name: ECID_type_board_version-build_nonce
    NSArray *parts = [u.URLByDeletingPathExtension.lastPathComponent componentsSeparatedByString:@"_"];
    NSString *ver = parts.count > 3 ? [parts[3] stringByReplacingOccurrencesOfString:@"-" withString:@" ("] : @"?";
    if ([ver containsString:@"("]) ver = [ver stringByAppendingString:@")"];
    c.textLabel.text = [NSString stringWithFormat:@"iOS %@", ver];
    c.textLabel.textColor = BK_TEXT;
    c.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    NSString *nonce = parts.lastObject ?: @"";
    NSString *model = parts.count > 1 ? FriendlyModel(parts[1]) : @"";
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · nonce %@…", model, nonce.length > 12 ? [nonce substringToIndex:12] : nonce];
    c.detailTextLabel.textColor = BK_SUBTEXT;
    c.imageView.image = [UIImage systemImageNamed:@"doc.badge.gearshape.fill"];
    c.imageView.tintColor = BK_ACCENT;
    return c;
}

- (NSArray<NSURL *> *)filesFor:(NSURL *)shsh {
    NSURL *der = [shsh.URLByDeletingPathExtension URLByAppendingPathExtension:@"der"];
    return [NSFileManager.defaultManager fileExistsAtPath:der.path] ? @[shsh, der] : @[shsh];
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSURL *u = self.saved[ip.row];
    UIView *cell = [tv cellForRowAtIndexPath:ip];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:u.lastPathComponent message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Share" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self share:[self filesFor:u] from:cell]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Save to Files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self export:[self filesFor:u]]; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Copy Generator" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfURL:u];
        UIPasteboard.generalPasteboard.string = d[@"generator"] ?: @"";
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Delete" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
        for (NSURL *f in [self filesFor:u]) [NSFileManager.defaultManager removeItemAtURL:f error:nil];
        [self reloadSaved];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = cell;
    a.popoverPresentationController.sourceRect = cell.bounds;
    [self presentViewController:a animated:YES completion:nil];
}

@end

#pragma mark - App

@interface BKAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation BKAppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.window.tintColor = BK_ACCENT;
    self.window.rootViewController = [BKViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(BKAppDelegate.class));
    }
}

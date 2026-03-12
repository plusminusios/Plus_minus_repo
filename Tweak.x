// FaceIDFor6s v5 — полная перезапись

#import <LocalAuthentication/LocalAuthentication.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <notify.h>

// ─── Настройки ────────────────────────────────────────────────────────────────
#define kPref @"/var/mobile/Library/Preferences/com.yourname.faceidfor6s.plist"

static BOOL      gEnabled        = YES;
static NSInteger gRequiredFrames = 5;
static NSInteger gTimeout        = 5;

static void FIDLoadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPref];
    gEnabled        = d[@"enabled"]        ? [d[@"enabled"] boolValue]          : YES;
    gRequiredFrames = d[@"requiredFrames"] ? [d[@"requiredFrames"] integerValue] : 5;
    gTimeout        = d[@"timeout"]        ? [d[@"timeout"] integerValue]        : 5;
}

static void FIDSavePrefs(NSString *key, id value) {
    NSMutableDictionary *d = [[NSDictionary dictionaryWithContentsOfFile:kPref] mutableCopy]
                           ?: [NSMutableDictionary new];
    d[key] = value;
    [d writeToFile:kPref atomically:YES];
    notify_post("com.yourname.faceidfor6s/reload");
    FIDLoadPrefs();
}

// ─── Форварды ─────────────────────────────────────────────────────────────────
@interface SBFUserAuthenticationController : NSObject
- (void)_biometricAuthenticationDidSucceed;
- (void)_biometricAuthenticationDidFail;
@end

// ─── Сканер ───────────────────────────────────────────────────────────────────
@interface FIDScanner : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, assign) NSInteger         hits;
@property (nonatomic, assign) BOOL              done;
@property (nonatomic, copy)   void(^cb)(BOOL);
+ (instancetype)shared;
- (void)runWithCompletion:(void(^)(BOOL))cb;
- (void)stop;
@end

@implementation FIDScanner

+ (instancetype)shared {
    static FIDScanner *s; static dispatch_once_t t;
    dispatch_once(&t, ^{ s = [FIDScanner new]; });
    return s;
}

- (void)runWithCompletion:(void(^)(BOOL))cb {
    [self stop];
    self.hits = 0; self.done = NO; self.cb = cb;

    AVCaptureDevice *cam = [AVCaptureDevice
        defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                          mediaType:AVMediaTypeVideo
                           position:AVCaptureDevicePositionFront];
    if (!cam) { cb(NO); return; }

    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:nil];
    if (!input) { cb(NO); return; }

    self.session = [AVCaptureSession new];
    self.session.sessionPreset = AVCaptureSessionPreset640x480;

    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
    out.alwaysDiscardsLateVideoFrames = YES;
    [out setSampleBufferDelegate:self
                           queue:dispatch_queue_create("fid", DISPATCH_QUEUE_SERIAL)];

    if ([self.session canAddInput:input])  [self.session addInput:input];
    if ([self.session canAddOutput:out])   [self.session addOutput:out];
    [self.session startRunning];

    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gTimeout*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(ws) ss = ws;
        if (ss && !ss.done) { ss.done = YES; [ss stop]; cb(NO); }
    });
}

- (void)stop {
    if (self.session.isRunning) [self.session stopRunning];
    self.session = nil;
}

- (void)captureOutput:(AVCaptureOutput *)o
didOutputSampleBuffer:(CMSampleBufferRef)buf
       fromConnection:(AVCaptureConnection *)c {
    if (self.done) return;
    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(buf);
    if (!px) return;
    __weak typeof(self) ws = self;
    VNDetectFaceRectanglesRequest *req = [[VNDetectFaceRectanglesRequest alloc]
        initWithCompletionHandler:^(VNRequest *r, NSError *e) {
            __strong typeof(ws) ss = ws;
            if (!ss || ss.done || r.results.count == 0) return;
            ss.hits++;
            if (ss.hits >= gRequiredFrames) {
                ss.done = YES; [ss stop];
                dispatch_async(dispatch_get_main_queue(), ^{ if (ss.cb) ss.cb(YES); });
            }
        }];
    [[[VNImageRequestHandler alloc] initWithCVPixelBuffer:px options:@{}]
        performRequests:@[req] error:nil];
}

@end

// ─── Оверлей ──────────────────────────────────────────────────────────────────
@interface FIDOverlay : UIView
- (void)animate;
- (void)showOK:(BOOL)ok;
@end

@implementation FIDOverlay { UILabel *_lbl; CALayer *_line; CGRect _oval; }

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
    CGFloat w = MIN(f.size.width, f.size.height) * 0.55, h = w * 1.28;
    _oval = CGRectMake((f.size.width-w)/2, (f.size.height-h)/2-30, w, h);

    UIBezierPath *p = [UIBezierPath bezierPathWithRect:f];
    [p appendPath:[UIBezierPath bezierPathWithOvalInRect:_oval]];
    p.usesEvenOddFillRule = YES;
    CAShapeLayer *hole = [CAShapeLayer layer];
    hole.path = p.CGPath; hole.fillRule = kCAFillRuleEvenOdd;
    hole.fillColor = [UIColor colorWithWhite:0 alpha:0.85].CGColor;
    [self.layer addSublayer:hole];

    CAShapeLayer *brd = [CAShapeLayer layer];
    brd.path = [UIBezierPath bezierPathWithOvalInRect:_oval].CGPath;
    brd.strokeColor = [UIColor colorWithWhite:1 alpha:0.75].CGColor;
    brd.fillColor = UIColor.clearColor.CGColor;
    brd.lineWidth = 2.5;
    [self.layer addSublayer:brd];

    _line = [CALayer layer];
    _line.frame = CGRectMake(_oval.origin.x+4, _oval.origin.y, _oval.size.width-8, 2);
    _line.backgroundColor = [UIColor colorWithRed:0.1 green:0.6 blue:1 alpha:1].CGColor;
    _line.cornerRadius = 1;
    [self.layer addSublayer:_line];

    UILabel *title = [UILabel new];
    title.text = @"Face ID";
    title.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    title.font = [UIFont systemFontOfSize:12 weight:UIFontWeightLight];
    title.textAlignment = NSTextAlignmentCenter;
    title.frame = CGRectMake(0, _oval.origin.y-28, f.size.width, 18);
    [self addSubview:title];

    _lbl = [UILabel new];
    _lbl.text = @"Смотрите прямо в камеру";
    _lbl.textColor = UIColor.whiteColor;
    _lbl.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    _lbl.textAlignment = NSTextAlignmentCenter;
    _lbl.frame = CGRectMake(16, CGRectGetMaxY(_oval)+20, f.size.width-32, 22);
    [self addSubview:_lbl];
    return self;
}

- (void)animate {
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.y"];
    a.fromValue = @(_oval.origin.y+2); a.toValue = @(CGRectGetMaxY(_oval)-2);
    a.duration = 1.4; a.repeatCount = HUGE_VALF; a.autoreverses = YES;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_line addAnimation:a forKey:@"s"];
}

- (void)showOK:(BOOL)ok {
    [_line removeAllAnimations]; _line.hidden = YES;
    _lbl.text = ok ? @"✓  Готово" : @"✕  Не удалось. Попробуйте снова.";
    _lbl.textColor = ok
        ? [UIColor colorWithRed:0.2 green:0.88 blue:0.45 alpha:1]
        : [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
}

@end

// ─── Аутентификация ───────────────────────────────────────────────────────────
static void FIDRun(NSString *reason, void(^reply)(BOOL, NSError*)) {
    FIDLoadPrefs();
    if (!gEnabled) {
        reply(NO, [NSError errorWithDomain:LAErrorDomain
                                      code:LAErrorBiometryNotAvailable userInfo:nil]);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIWindowScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene*)sc).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (win) break;
        }
        if (!win) win = UIApplication.sharedApplication.windows.firstObject;
        if (!win) { reply(NO, nil); return; }

        FIDOverlay *ov = [[FIDOverlay alloc] initWithFrame:win.bounds];
        ov.alpha = 0;
        [win addSubview:ov];
        [UIView animateWithDuration:0.22 animations:^{ ov.alpha = 1; }
                         completion:^(BOOL _) {
            [ov animate];
            [[FIDScanner shared] runWithCompletion:^(BOOL ok) {
                [ov showOK:ok];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65*NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.22
                                    animations:^{ ov.alpha = 0; }
                                    completion:^(BOOL __) {
                        [ov removeFromSuperview];
                        reply(ok, ok ? nil :
                            [NSError errorWithDomain:LAErrorDomain
                                               code:LAErrorAuthenticationFailed
                                           userInfo:@{NSLocalizedDescriptionKey:@"Лицо не распознано"}]);
                    }];
                });
            }];
        }];
    });
}

// ════════════════════════════════════════════════════════════════════════════════
// HOOKS
// ════════════════════════════════════════════════════════════════════════════════

// ─── LAContext ────────────────────────────────────────────────────────────────
%hook LAContext

- (LABiometryType)biometryType {
    FIDLoadPrefs();
    return gEnabled ? LABiometryTypeFaceID : %orig;
}

- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError *__autoreleasing *)error {
    FIDLoadPrefs();
    if (gEnabled && (policy == LAPolicyDeviceOwnerAuthenticationWithBiometrics
                  || policy == LAPolicyDeviceOwnerAuthentication)) {
        if (error) *error = nil;
        return YES;
    }
    return %orig;
}

- (void)evaluatePolicy:(LAPolicy)policy
       localizedReason:(NSString *)reason
                 reply:(void(^)(BOOL,NSError*))reply {
    FIDLoadPrefs();
    if (gEnabled && policy == LAPolicyDeviceOwnerAuthenticationWithBiometrics) {
        FIDRun(reason, reply);
        return;
    }
    %orig;
}

%end

// ─── SpringBoard ──────────────────────────────────────────────────────────────
%hook SBFUserAuthenticationController

- (void)_evaluateBiometricAuthentication {
    FIDLoadPrefs();
    if (!gEnabled) { %orig; return; }
    FIDRun(@"Разблокировать iPhone", ^(BOOL ok, NSError *e) {
        if (ok) [self _biometricAuthenticationDidSucceed];
        else    [self _biometricAuthenticationDidFail];
    });
}

%end

// ─── Настройки: переименовываем Touch ID → Face ID ───────────────────────────
%hook NSBundle

- (NSString *)localizedStringForKey:(NSString *)key value:(NSString *)val table:(NSString *)table {
    NSString *result = %orig;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:@"com.apple.Preferences"]) return result;

    static NSDictionary *rep = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rep = @{
            @"Touch ID & Passcode"   : @"Face ID и пароль",
            @"Touch ID & Код-пароль" : @"Face ID и пароль",
            @"Touch ID и пароль"     : @"Face ID и пароль",
            @"Touch ID"              : @"Face ID",
            @"TOUCH ID"              : @"FACE ID",
            @"Add a Fingerprint"     : @"Добавить Face ID",
            @"Add a fingerprint"     : @"Добавить Face ID",
            @"Fingerprint"           : @"Face ID",
            @"fingerprint"           : @"Face ID",
        };
    });

    for (NSString *from in rep) {
        if ([result containsString:from]) {
            result = [result stringByReplacingOccurrencesOfString:from
                                                      withString:rep[from]];
        }
    }
    return result;
}

%end

// ─── Настройки: добавляем переключатель Face ID прямо в раздел ───────────────
%hook PasscodeOptionsController

- (NSString *)navigationTitle {
    return @"Face ID и пароль";
}

- (NSArray *)specifiers {
    NSMutableArray *specs = [NSMutableArray arrayWithArray:%orig];

    // Проверяем — не добавили ли уже
    for (id s in specs) {
        if ([[s name] isEqualToString:@"Face ID включён"]) return specs;
    }

    // Группа
    id grp = [%c(PSSpecifier) preferenceSpecifierNamed:@"Face ID"
                                               target:self set:nil get:nil
                                               detail:nil cell:1 edit:nil];

    // Переключатель
    id tog = [%c(PSSpecifier) preferenceSpecifierNamed:@"Face ID включён"
                                               target:self
                                                  set:@selector(fidSetEnabled:specifier:)
                                                  get:@selector(fidGetEnabled:)
                                               detail:nil cell:9 edit:nil];

    // Строгость
    id sens = [%c(PSSpecifier) preferenceSpecifierNamed:@"Строгость распознавания"
                                                target:self
                                                   set:@selector(fidSetFrames:specifier:)
                                                   get:@selector(fidGetFrames:)
                                                detail:nil cell:9 edit:nil];

    [specs insertObject:sens atIndex:0];
    [specs insertObject:tog  atIndex:0];
    [specs insertObject:grp  atIndex:0];
    return specs;
}

%new
- (id)fidGetEnabled:(id)spec { 
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPref];
    return d[@"enabled"] ?: @YES; 
}

%new
- (void)fidSetEnabled:(id)val specifier:(id)spec { 
    FIDSavePrefs(@"enabled", val); 
}

%new
- (id)fidGetFrames:(id)spec { 
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPref];
    return d[@"requiredFrames"] ?: @5; 
}

%new
- (void)fidSetFrames:(id)val specifier:(id)spec { 
    FIDSavePrefs(@"requiredFrames", val); 
}

%end

// ─── Инициализация ────────────────────────────────────────────────────────────
%ctor {
    FIDLoadPrefs();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        (CFNotificationCallback)FIDLoadPrefs,
        CFSTR("com.yourname.faceidfor6s/reload"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

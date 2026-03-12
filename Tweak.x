// FaceIDFor6s — Tweak.x v3
// Простой и надёжный эмулятор Face ID для iPhone 6s

#import <LocalAuthentication/LocalAuthentication.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>

// ─── Настройки ────────────────────────────────────────────────────────────────
#define kPrefPath @"/var/mobile/Library/Preferences/com.yourname.faceidfor6s.plist"

static BOOL      gEnabled        = YES;
static NSInteger gRequiredFrames = 5;
static NSInteger gTimeout        = 5;

static void FIDLoadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    gEnabled        = d[@"enabled"]        ? [d[@"enabled"] boolValue]          : YES;
    gRequiredFrames = d[@"requiredFrames"] ? [d[@"requiredFrames"] integerValue] : 5;
    gTimeout        = d[@"timeout"]        ? [d[@"timeout"] integerValue]        : 5;
}

// ─── Приватные классы SpringBoard ─────────────────────────────────────────────
@interface SBFUserAuthenticationController : NSObject
- (void)_biometricAuthenticationDidSucceed;
- (void)_biometricAuthenticationDidFail;
@end

@interface BiometricKitProxy : NSObject
+ (instancetype)sharedInstance;
@end

// ─── Сканер лица ──────────────────────────────────────────────────────────────
@interface FIDScanner : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, assign) NSInteger hits;
@property (nonatomic, assign) BOOL done;
@property (nonatomic, copy)   void(^completion)(BOOL);
+ (instancetype)shared;
- (void)scanWithCompletion:(void(^)(BOOL))completion;
- (void)stop;
@end

@implementation FIDScanner

+ (instancetype)shared {
    static FIDScanner *i = nil;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [FIDScanner new]; });
    return i;
}

- (void)scanWithCompletion:(void(^)(BOOL))completion {
    self.hits       = 0;
    self.done       = NO;
    self.completion = completion;

    AVCaptureDevice *cam = [AVCaptureDevice
        defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                          mediaType:AVMediaTypeVideo
                           position:AVCaptureDevicePositionFront];
    if (!cam) { completion(NO); return; }

    NSError *err = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
    if (!input) { completion(NO); return; }

    self.session = [AVCaptureSession new];
    self.session.sessionPreset = AVCaptureSessionPreset640x480;

    AVCaptureVideoDataOutput *out = [AVCaptureVideoDataOutput new];
    out.alwaysDiscardsLateVideoFrames = YES;
    dispatch_queue_t q = dispatch_queue_create("fid.cam", DISPATCH_QUEUE_SERIAL);
    [out setSampleBufferDelegate:self queue:q];

    if ([self.session canAddInput:input])  [self.session addInput:input];
    if ([self.session canAddOutput:out])   [self.session addOutput:out];
    [self.session startRunning];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.done) {
            self.done = YES;
            [self stop];
            completion(NO);
        }
    });
}

- (void)stop {
    if (self.session.isRunning) [self.session stopRunning];
    self.session = nil;
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)buf
       fromConnection:(AVCaptureConnection *)conn {

    if (self.done) return;
    CVPixelBufferRef px = CMSampleBufferGetImageBuffer(buf);
    if (!px) return;

    __weak typeof(self) ws = self;
    VNDetectFaceRectanglesRequest *req = [[VNDetectFaceRectanglesRequest alloc]
        initWithCompletionHandler:^(VNRequest *r, NSError *e) {
            __strong typeof(ws) ss = ws;
            if (!ss || ss.done) return;
            if (r.results.count > 0) {
                ss.hits++;
                if (ss.hits >= gRequiredFrames) {
                    ss.done = YES;
                    [ss stop];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (ss.completion) ss.completion(YES);
                    });
                }
            }
        }];

    VNImageRequestHandler *h = [[VNImageRequestHandler alloc]
        initWithCVPixelBuffer:px options:@{}];
    [h performRequests:@[req] error:nil];
}

@end

// ─── Оверлей ──────────────────────────────────────────────────────────────────
@interface FIDOverlay : UIView
- (void)startScan;
- (void)showResult:(BOOL)ok;
@end

@implementation FIDOverlay {
    UILabel  *_label;
    CALayer  *_line;
    CGRect    _oval;
}

- (instancetype)initWithFrame:(CGRect)f {
    self = [super initWithFrame:f];
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];

    CGFloat w = f.size.width * 0.55, h = w * 1.3;
    _oval = CGRectMake((f.size.width-w)/2, (f.size.height-h)/2 - 20, w, h);

    UIBezierPath *bg = [UIBezierPath bezierPathWithRect:f];
    [bg appendPath:[UIBezierPath bezierPathWithOvalInRect:_oval]];
    bg.usesEvenOddFillRule = YES;
    CAShapeLayer *hole = [CAShapeLayer layer];
    hole.path      = bg.CGPath;
    hole.fillRule  = kCAFillRuleEvenOdd;
    hole.fillColor = [UIColor colorWithWhite:0 alpha:0.82].CGColor;
    [self.layer addSublayer:hole];

    CAShapeLayer *border = [CAShapeLayer layer];
    border.path        = [UIBezierPath bezierPathWithOvalInRect:_oval].CGPath;
    border.strokeColor = [UIColor colorWithWhite:1 alpha:0.7].CGColor;
    border.fillColor   = UIColor.clearColor.CGColor;
    border.lineWidth   = 2.5;
    [self.layer addSublayer:border];

    _line = [CALayer layer];
    _line.frame = CGRectMake(_oval.origin.x+4, _oval.origin.y, _oval.size.width-8, 2);
    _line.backgroundColor = [UIColor colorWithRed:0.15 green:0.65 blue:1 alpha:1].CGColor;
    _line.cornerRadius = 1;
    [self.layer addSublayer:_line];

    _label = [UILabel new];
    _label.text          = @"Смотрите в камеру";
    _label.textColor     = UIColor.whiteColor;
    _label.font          = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.frame         = CGRectMake(0, CGRectGetMaxY(_oval)+22, f.size.width, 24);
    [self addSubview:_label];

    UILabel *icon = [UILabel new];
    icon.text          = @"Face ID";
    icon.textColor     = [UIColor colorWithWhite:1 alpha:0.5];
    icon.font          = [UIFont systemFontOfSize:13 weight:UIFontWeightLight];
    icon.textAlignment = NSTextAlignmentCenter;
    icon.frame         = CGRectMake(0, _oval.origin.y - 32, f.size.width, 20);
    [self addSubview:icon];

    return self;
}

- (void)startScan {
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.y"];
    a.fromValue      = @(_oval.origin.y + 2);
    a.toValue        = @(CGRectGetMaxY(_oval) - 2);
    a.duration       = 1.5;
    a.repeatCount    = HUGE_VALF;
    a.autoreverses   = YES;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_line addAnimation:a forKey:@"scan"];
}

- (void)showResult:(BOOL)ok {
    [_line removeAllAnimations];
    _line.hidden = YES;
    _label.text      = ok ? @"✓  Лицо распознано" : @"✕  Попробуйте ещё раз";
    _label.textColor = ok
        ? [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1]
        : [UIColor colorWithRed:1   green:0.3 blue:0.3 alpha:1];
}

@end

// ─── Главная функция аутентификации ──────────────────────────────────────────
static void FIDAuthenticate(NSString *reason, void(^reply)(BOOL, NSError*)) {
    FIDLoadPrefs();
    if (!gEnabled) {
        reply(NO, [NSError errorWithDomain:LAErrorDomain
                                      code:LAErrorBiometryNotAvailable userInfo:nil]);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = nil;
        for (UIWindowScene *s in UIApplication.sharedApplication.connectedScenes) {
            if (![s isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene*)s).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
            if (win) break;
        }
        if (!win) win = UIApplication.sharedApplication.windows.firstObject;
        if (!win) { reply(NO, nil); return; }

        FIDOverlay *ov = [[FIDOverlay alloc] initWithFrame:win.bounds];
        ov.alpha = 0;
        [win addSubview:ov];

        [UIView animateWithDuration:0.2 animations:^{ ov.alpha = 1; }
                         completion:^(BOOL _) {
            [ov startScan];
            [[FIDScanner shared] scanWithCompletion:^(BOOL ok) {
                [ov showResult:ok];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.6*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.2
                                    animations:^{ ov.alpha = 0; }
                                    completion:^(BOOL __) {
                        [ov removeFromSuperview];
                        reply(ok, ok ? nil :
                            [NSError errorWithDomain:LAErrorDomain
                                               code:LAErrorAuthenticationFailed
                                           userInfo:nil]);
                    }];
                });
            }];
        }];
    });
}

// ════════════════════════════════════════════════════════════════════════════════
// HOOKS
// ════════════════════════════════════════════════════════════════════════════════

%hook LAContext

- (LABiometryType)biometryType {
    FIDLoadPrefs();
    return gEnabled ? LABiometryTypeFaceID : %orig;
}

- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError *__autoreleasing *)error {
    FIDLoadPrefs();
    if (!gEnabled) return %orig;
    if (policy == LAPolicyDeviceOwnerAuthenticationWithBiometrics ||
        policy == LAPolicyDeviceOwnerAuthentication) {
        if (error) *error = nil;
        return YES;
    }
    return %orig;
}

- (void)evaluatePolicy:(LAPolicy)policy
       localizedReason:(NSString *)reason
                 reply:(void(^)(BOOL, NSError*))reply {
    FIDLoadPrefs();
    if (gEnabled && policy == LAPolicyDeviceOwnerAuthenticationWithBiometrics) {
        FIDAuthenticate(reason, reply);
        return;
    }
    %orig;
}

%end

%hook BiometricKitProxy
- (id)biometryType    { return @2;  }
- (BOOL)isFaceIDAvailable { return YES; }
- (BOOL)isSupported   { return YES; }
%end

%hook SBFUserAuthenticationController
- (void)_evaluateBiometricAuthentication {
    FIDLoadPrefs();
    if (!gEnabled) { %orig; return; }
    FIDAuthenticate(@"Разблокировать iPhone", ^(BOOL ok, NSError *e) {
        if (ok) [self _biometricAuthenticationDidSucceed];
        else    [self _biometricAuthenticationDidFail];
    });
}
%end

%ctor {
    FIDLoadPrefs();
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        (CFNotificationCallback)FIDLoadPrefs,
        CFSTR("com.yourname.faceidfor6s/reload"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

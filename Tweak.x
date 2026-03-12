// FaceIDFor6s — Tweak.x v2
// Эмулирует Face ID на iPhone 6s (iOS 15) через фронтальную камеру

#import <LocalAuthentication/LocalAuthentication.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>

// ─── Настройки ───────────────────────────────────────────────────────────────
#define kPrefPath    @"/var/mobile/Library/Preferences/com.yourname.faceidfor6s.plist"
#define kBundleID    @"com.yourname.faceidfor6s"

static BOOL  gEnabled         = YES;
static NSInteger gRequiredFrames = 6;
static NSInteger gTimeout        = 4;

static void FIDLoadPrefs(void) {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:kPrefPath];
    if (!d) return;
    if (d[@"enabled"]        != nil) gEnabled        = [d[@"enabled"] boolValue];
    if (d[@"requiredFrames"] != nil) gRequiredFrames = [d[@"requiredFrames"] integerValue];
    if (d[@"timeout"]        != nil) gTimeout        = [d[@"timeout"] integerValue];
}

// ─── Форвард-объявления ───────────────────────────────────────────────────────
@interface BiometricKitProxy : NSObject
+ (instancetype)sharedInstance;
- (BOOL)isFaceIDAvailable;
- (int)biometryType;
@end

@interface SBFUserAuthenticationController : NSObject
- (void)_biometricAuthenticationDidSucceed;
- (void)_biometricAuthenticationDidFail;
- (void)_evaluateBiometricAuthentication;
@end

// ─── Сканер лица ─────────────────────────────────────────────────────────────
@interface FIDCameraFaceScanner : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) AVCaptureSession        *session;
@property (nonatomic, strong) AVCaptureVideoDataOutput *output;
@property (nonatomic, strong) dispatch_queue_t         cameraQueue;
@property (nonatomic, copy)   void (^onFaceDetected)(BOOL detected);
@property (nonatomic, assign) NSInteger                detectionCount;
@property (nonatomic, assign) BOOL                     isScanning;
+ (instancetype)shared;
- (void)startScanWithCompletion:(void (^)(BOOL success))completion;
- (void)stop;
@end

@implementation FIDCameraFaceScanner

+ (instancetype)shared {
    static FIDCameraFaceScanner *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[FIDCameraFaceScanner alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cameraQueue = dispatch_queue_create("com.faceidfor6s.camera", DISPATCH_QUEUE_SERIAL);
        _isScanning  = NO;
    }
    return self;
}

- (void)startScanWithCompletion:(void (^)(BOOL success))completion {
    if (self.isScanning) {
        [self stop];
    }
    self.isScanning     = YES;
    self.detectionCount = 0;

    __weak typeof(self) ws = self;

    self.onFaceDetected = ^(BOOL detected) {
        __strong typeof(ws) ss = ws;
        if (!ss || !ss.isScanning) return;
        if (detected) {
            ss.detectionCount++;
            if (ss.detectionCount >= gRequiredFrames) {
                ss.isScanning = NO;
                [ss stop];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(YES); });
            }
        }
    };

    dispatch_async(self.cameraQueue, ^{
        __strong typeof(ws) ss = ws;
        if (!ss) return;

        ss.session = [[AVCaptureSession alloc] init];
        ss.session.sessionPreset = AVCaptureSessionPreset640x480;

        NSError *err = nil;
        AVCaptureDevice *cam =
            [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                               mediaType:AVMediaTypeVideo
                                                position:AVCaptureDevicePositionFront];
        if (!cam) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:cam error:&err];
        if (!input || err) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        ss.output = [[AVCaptureVideoDataOutput alloc] init];
        ss.output.alwaysDiscardsLateVideoFrames = YES;
        [ss.output setSampleBufferDelegate:ss queue:ss.cameraQueue];

        if ([ss.session canAddInput:input])    [ss.session addInput:input];
        if ([ss.session canAddOutput:ss.output]) [ss.session addOutput:ss.output];

        [ss.session startRunning];

        // Таймаут
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gTimeout * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(ws) s = ws;
            if (!s || !s.isScanning) return;
            s.isScanning = NO;
            [s stop];
            completion(NO);
        });
    });
}

- (void)stop {
    __weak typeof(self) ws = self;
    dispatch_async(self.cameraQueue, ^{
        __strong typeof(ws) ss = ws;
        if (ss.session.isRunning) [ss.session stopRunning];
        ss.session = nil;
        ss.output  = nil;
    });
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    if (!self.isScanning) return;

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    __weak typeof(self) ws = self;
    VNDetectFaceRectanglesRequest *req =
        [[VNDetectFaceRectanglesRequest alloc] initWithCompletionHandler:^(VNRequest *r, NSError *e) {
            __strong typeof(ws) ss = ws;
            if (ss.onFaceDetected) ss.onFaceDetected(r.results.count > 0);
        }];

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer options:@{}];
    [handler performRequests:@[req] error:nil];
}

@end

// ─── Оверлей сканера ──────────────────────────────────────────────────────────
@interface FIDOverlay : UIView
- (void)startAnimating;
- (void)showResult:(BOOL)success;
@end

@implementation FIDOverlay {
    CALayer  *_scanLine;
    UILabel  *_label;
    CGRect    _ovalRect;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.8];

    CGFloat w = frame.size.width  * 0.56;
    CGFloat h = w * 1.3;
    _ovalRect = CGRectMake((frame.size.width  - w) / 2,
                           (frame.size.height - h) / 2 - 30, w, h);

    // Вырез
    UIBezierPath *bg   = [UIBezierPath bezierPathWithRect:frame];
    UIBezierPath *oval = [UIBezierPath bezierPathWithOvalInRect:_ovalRect];
    [bg appendPath:oval];
    bg.usesEvenOddFillRule = YES;

    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.path      = bg.CGPath;
    mask.fillRule  = kCAFillRuleEvenOdd;
    mask.fillColor = [UIColor colorWithWhite:0 alpha:0.8].CGColor;
    [self.layer addSublayer:mask];

    // Рамка
    CAShapeLayer *border = [CAShapeLayer layer];
    border.path        = [UIBezierPath bezierPathWithOvalInRect:_ovalRect].CGPath;
    border.strokeColor = [UIColor colorWithWhite:1 alpha:0.6].CGColor;
    border.fillColor   = UIColor.clearColor.CGColor;
    border.lineWidth   = 2;
    [self.layer addSublayer:border];

    // Линия сканера
    _scanLine = [CALayer layer];
    _scanLine.frame = CGRectMake(_ovalRect.origin.x + 6, _ovalRect.origin.y,
                                  _ovalRect.size.width - 12, 2);
    _scanLine.backgroundColor = [UIColor colorWithRed:0.2 green:0.7 blue:1 alpha:1].CGColor;
    _scanLine.cornerRadius = 1;
    [self.layer addSublayer:_scanLine];

    // Иконка Face ID
    UILabel *icon = [[UILabel alloc] init];
    icon.text = @"󱄿";  // SF Symbol fallback
    icon.font = [UIFont systemFontOfSize:44];
    icon.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    icon.textAlignment = NSTextAlignmentCenter;
    icon.frame = CGRectMake(0, _ovalRect.origin.y - 70, frame.size.width, 55);
    [self addSubview:icon];

    // Надпись
    _label = [[UILabel alloc] init];
    _label.text          = @"Смотрите в камеру";
    _label.textColor     = UIColor.whiteColor;
    _label.font          = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.frame         = CGRectMake(0, CGRectGetMaxY(_ovalRect) + 20,
                                       frame.size.width, 24);
    [self addSubview:_label];

    return self;
}

- (void)startAnimating {
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"position.y"];
    anim.fromValue     = @(_ovalRect.origin.y + 2);
    anim.toValue       = @(CGRectGetMaxY(_ovalRect) - 2);
    anim.duration      = 1.6;
    anim.repeatCount   = HUGE_VALF;
    anim.autoreverses  = YES;
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_scanLine addAnimation:anim forKey:@"scan"];
}

- (void)showResult:(BOOL)success {
    [_scanLine removeAllAnimations];
    _scanLine.hidden = YES;
    if (success) {
        _label.text      = @"✓  Лицо распознано";
        _label.textColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.4 alpha:1];
    } else {
        _label.text      = @"✕  Не распознано. Попробуйте ещё.";
        _label.textColor = [UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
    }
}

@end

// ─── Менеджер аутентификации ──────────────────────────────────────────────────
@interface FIDAuthManager : NSObject
+ (void)authenticateWithReason:(NSString *)reason
                    reply:(void(^)(BOOL success, NSError *error))reply;
@end

@implementation FIDAuthManager

+ (UIWindow *)keyWindow {
    UIWindow *win = nil;
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (@available(iOS 15.0, *)) {
            win = ((UIWindowScene *)scene).keyWindow;
        }
        if (!win) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { win = w; break; }
            }
        }
        if (win) break;
    }
    return win;
}

+ (void)authenticateWithReason:(NSString *)reason
                         reply:(void(^)(BOOL success, NSError *error))reply {

    FIDLoadPrefs();
    if (!gEnabled) {
        // Твик выключен — возвращаем ошибку, система покажет PIN
        reply(NO, [NSError errorWithDomain:LAErrorDomain
                                      code:LAErrorBiometryNotAvailable
                                  userInfo:nil]);
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = [self keyWindow];
        if (!win) {
            reply(NO, [NSError errorWithDomain:LAErrorDomain
                                          code:LAErrorSystemCancel
                                      userInfo:nil]);
            return;
        }

        FIDOverlay *overlay = [[FIDOverlay alloc] initWithFrame:win.bounds];
        overlay.alpha = 0;
        [win addSubview:overlay];

        [UIView animateWithDuration:0.25 animations:^{ overlay.alpha = 1; }
                         completion:^(BOOL _) {
            [overlay startAnimating];
            [[FIDCameraFaceScanner shared]
             startScanWithCompletion:^(BOOL success) {
                [overlay showResult:success];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.7 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [UIView animateWithDuration:0.2
                                     animations:^{ overlay.alpha = 0; }
                                     completion:^(BOOL __) {
                        [overlay removeFromSuperview];
                        NSError *err = success ? nil
                            : [NSError errorWithDomain:LAErrorDomain
                                                  code:LAErrorAuthenticationFailed
                                              userInfo:@{
                            NSLocalizedDescriptionKey: @"Лицо не распознано"
                        }];
                        reply(success, err);
                    }];
                });
            }];
        }];
    });
}

@end

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
                 reply:(void(^)(BOOL success, NSError *error))reply {
    FIDLoadPrefs();
    if (gEnabled && policy == LAPolicyDeviceOwnerAuthenticationWithBiometrics) {
        [FIDAuthManager authenticateWithReason:reason reply:reply];
        return;
    }
    %orig;
}

%end

// ─── BiometricKit ─────────────────────────────────────────────────────────────
%hook BiometricKitProxy

- (BOOL)isFaceIDAvailable {
    FIDLoadPrefs();
    return gEnabled ? YES : %orig;
}

- (int)biometryType {
    FIDLoadPrefs();
    return gEnabled ? 2 : %orig;
}

%end

// ─── SpringBoard блокировки ───────────────────────────────────────────────────
%hook SBFUserAuthenticationController

- (void)_evaluateBiometricAuthentication {
    FIDLoadPrefs();
    if (!gEnabled) { %orig; return; }
    [FIDAuthManager
     authenticateWithReason:@"Разблокировать iPhone"
                      reply:^(BOOL success, NSError *error) {
        if (success) [self _biometricAuthenticationDidSucceed];
        else         [self _biometricAuthenticationDidFail];
    }];
}

%end

// ─── Инициализация ────────────────────────────────────────────────────────────
%ctor {
    FIDLoadPrefs();
    // Перечитывать настройки при изменении
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), NULL,
        (CFNotificationCallback)FIDLoadPrefs,
        CFSTR("com.yourname.faceidfor6s/reload"),
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

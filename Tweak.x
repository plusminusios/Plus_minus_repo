// FaceIDFor6s — Tweak.x
// Эмулирует Face ID на iPhone 6s (iOS 15) через фронтальную камеру
// Использует Vision.framework для обнаружения лица
// Автор: FaceIDFor6s Project

#import <LocalAuthentication/LocalAuthentication.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>

// ─── Форвард-объявления приватных классов BiometricKit ───────────────────────
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

@interface LAContext (Private)
- (BOOL)_isBiometryAvailable;
- (int)_biometryType;
@end

// ─── Контроллер сканера лица ─────────────────────────────────────────────────
@interface FIDCameraFaceScanner : NSObject
    <AVCaptureVideoDataOutputSampleBufferDelegate>

@property (nonatomic, strong) AVCaptureSession        *session;
@property (nonatomic, strong) AVCaptureVideoDataOutput *output;
@property (nonatomic, strong) dispatch_queue_t         queue;
@property (nonatomic, copy)   void (^onFaceDetected)(BOOL detected);
@property (nonatomic, assign) NSInteger               detectionCount;
@property (nonatomic, assign) NSInteger               requiredFrames;

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
        _queue          = dispatch_queue_create("com.faceidfor6s.cameraqueue",
                                               DISPATCH_QUEUE_SERIAL);
        _requiredFrames = 8; // сколько фреймов с лицом нужно для успеха
        _detectionCount = 0;
    }
    return self;
}

- (void)startScanWithCompletion:(void (^)(BOOL success))completion {
    self.detectionCount = 0;
    __weak typeof(self) weakSelf = self;
    self.onFaceDetected = ^(BOOL detected) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (detected) {
            strongSelf.detectionCount++;
            if (strongSelf.detectionCount >= strongSelf.requiredFrames) {
                [strongSelf stop];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(YES);
                });
            }
        }
    };

    __weak typeof(self) weakSelf2 = self;
    dispatch_async(self.queue, ^{
        __strong typeof(weakSelf2) strongSelf = weakSelf2;
        if (!strongSelf) return;
        // Настраиваем сессию захвата
        strongSelf.session = [[AVCaptureSession alloc] init];
        strongSelf.session.sessionPreset = AVCaptureSessionPresetMedium;

        AVCaptureDevice *frontCamera =
            [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInWideAngleCamera
                                               mediaType:AVMediaTypeVideo
                                                position:AVCaptureDevicePositionFront];
        if (!frontCamera) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        NSError *error = nil;
        AVCaptureDeviceInput *input =
            [AVCaptureDeviceInput deviceInputWithDevice:frontCamera error:&error];
        if (error || !input) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO); });
            return;
        }

        strongSelf.output = [[AVCaptureVideoDataOutput alloc] init];
        [strongSelf.output setSampleBufferDelegate:strongSelf queue:strongSelf.queue];
        strongSelf.output.alwaysDiscardsLateVideoFrames = YES;

        if ([strongSelf.session canAddInput:input])        [strongSelf.session addInput:input];
        if ([strongSelf.session canAddOutput:strongSelf.output]) [strongSelf.session addOutput:strongSelf.output];

        [strongSelf.session startRunning];

        // Таймаут 4 секунды
        __weak typeof(strongSelf) weakSelf3 = strongSelf;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf3) s = weakSelf3;
            if (!s) return;
            if (s.detectionCount < s.requiredFrames) {
                [s stop];
                completion(NO);
            }
        });
    });
}

- (void)stop {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.queue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf.session isRunning]) {
            [strongSelf.session stopRunning];
        }
    });
}

// ─── Vision: анализируем каждый фрейм ────────────────────────────────────────
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {

    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    __weak typeof(self) weakSelf = self;
    VNDetectFaceRectanglesRequest *request =
        [[VNDetectFaceRectanglesRequest alloc] initWithCompletionHandler:
         ^(VNRequest *req, NSError *err) {
            BOOL hasFace = (req.results.count > 0);
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf.onFaceDetected) strongSelf.onFaceDetected(hasFace);
        }];

    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer
                                                     options:@{}];
    [handler performRequests:@[request] error:nil];
}

@end

// ─── UI: полноэкранный оверлей со шторкой сканера ────────────────────────────
@interface FIDScannerOverlay : UIView
@property (nonatomic, strong) CAShapeLayer *ovalLayer;
@property (nonatomic, strong) CALayer      *scanLine;
@property (nonatomic, strong) UILabel      *hintLabel;
- (void)startAnimating;
- (void)showSuccess;
- (void)showFailure;
@end

@implementation FIDScannerOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.82];

        // Овальный вырез для лица
        CGFloat ovalW = frame.size.width  * 0.58;
        CGFloat ovalH = ovalW * 1.28;
        CGRect  ovalR = CGRectMake((frame.size.width  - ovalW) / 2.0,
                                   (frame.size.height - ovalH) / 2.0 - 40,
                                   ovalW, ovalH);

        UIBezierPath *fullPath = [UIBezierPath bezierPathWithRect:frame];
        UIBezierPath *ovalPath = [UIBezierPath bezierPathWithOvalInRect:ovalR];
        [fullPath appendPath:ovalPath];
        fullPath.usesEvenOddFillRule = YES;

        self.ovalLayer = [CAShapeLayer layer];
        self.ovalLayer.path          = fullPath.CGPath;
        self.ovalLayer.fillRule      = kCAFillRuleEvenOdd;
        self.ovalLayer.fillColor     = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.82].CGColor;
        [self.layer addSublayer:self.ovalLayer];

        // Рамка вокруг овала
        CAShapeLayer *border   = [CAShapeLayer layer];
        border.path            = [UIBezierPath bezierPathWithOvalInRect:ovalR].CGPath;
        border.strokeColor     = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        border.fillColor       = [UIColor clearColor].CGColor;
        border.lineWidth       = 2.5;
        [self.layer addSublayer:border];

        // Сканирующая линия
        self.scanLine               = [CALayer layer];
        self.scanLine.frame         = CGRectMake(ovalR.origin.x + 4,
                                                 ovalR.origin.y,
                                                 ovalR.size.width - 8, 2);
        self.scanLine.backgroundColor =
            [UIColor colorWithRed:0.3 green:0.75 blue:1.0 alpha:0.9].CGColor;
        self.scanLine.cornerRadius  = 1;
        [self.layer addSublayer:self.scanLine];

        // Подсказка
        self.hintLabel               = [[UILabel alloc] init];
        self.hintLabel.text          = @"Смотрите в камеру";
        self.hintLabel.textColor     = [UIColor whiteColor];
        self.hintLabel.font          = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        self.hintLabel.textAlignment = NSTextAlignmentCenter;
        self.hintLabel.frame         = CGRectMake(0,
                                                  CGRectGetMaxY(ovalR) + 24,
                                                  frame.size.width, 28);
        [self addSubview:self.hintLabel];
    }
    return self;
}

- (void)startAnimating {
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"position.y"];
    anim.fromValue  = @(self.scanLine.frame.origin.y);
    anim.toValue    = @(self.scanLine.frame.origin.y +
                        self.ovalLayer.bounds.size.height * 0.58);
    anim.duration   = 1.4;
    anim.repeatCount = HUGE_VALF;
    anim.autoreverses = YES;
    anim.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.scanLine addAnimation:anim forKey:@"scanAnim"];
}

- (void)showSuccess {
    self.hintLabel.text      = @"✓  Распознано";
    self.hintLabel.textColor = [UIColor colorWithRed:0.2 green:0.85 blue:0.4 alpha:1];
}

- (void)showFailure {
    self.hintLabel.text      = @"✕  Лицо не распознано";
    self.hintLabel.textColor = [UIColor colorWithRed:0.95 green:0.3 blue:0.3 alpha:1];
}

@end

// ─── Менеджер сканирования (показывает UI + запускает камеру) ─────────────────
@interface FIDAuthManager : NSObject
+ (void)authenticateWithReason:(NSString *)reason
                    completion:(void(^)(BOOL success, NSError *error))completion;
@end

@implementation FIDAuthManager

+ (void)authenticateWithReason:(NSString *)reason
                    completion:(void(^)(BOOL success, NSError *error))completion {

    dispatch_async(dispatch_get_main_queue(), ^{

        UIWindow *keyWindow = nil;
        for (UIWindowScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                if (@available(iOS 15.0, *)) {
                    keyWindow = ((UIWindowScene *)scene).keyWindow;
                } else {
                    keyWindow = [UIApplication sharedApplication].keyWindow;
                }
                break;
            }
        }
        if (!keyWindow) {
            completion(NO, [NSError errorWithDomain:@"FaceIDFor6s"
                                              code:-1
                                          userInfo:nil]);
            return;
        }

        FIDScannerOverlay *overlay =
            [[FIDScannerOverlay alloc] initWithFrame:keyWindow.bounds];
        overlay.alpha = 0;
        [keyWindow addSubview:overlay];

        [UIView animateWithDuration:0.28 animations:^{
            overlay.alpha = 1;
        } completion:^(BOOL _) {
            [overlay startAnimating];

            [[FIDCameraFaceScanner shared]
             startScanWithCompletion:^(BOOL success) {
                if (success) {
                    [overlay showSuccess];
                } else {
                    [overlay showFailure];
                }

                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.6 * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{

                    [UIView animateWithDuration:0.22 animations:^{
                        overlay.alpha = 0;
                    } completion:^(BOOL __) {
                        [overlay removeFromSuperview];
                        NSError *err = success ? nil
                            : [NSError errorWithDomain:LAErrorDomain
                                                  code:LAErrorAuthenticationFailed
                                              userInfo:@{
                                NSLocalizedDescriptionKey: @"Лицо не распознано"
                            }];
                        completion(success, err);
                    }];
                });
            }];
        }];
    });
}

@end

// ════════════════════════════════════════════════════════════════════════════
// HOOKS
// ════════════════════════════════════════════════════════════════════════════

// ─── LAContext: заставляем систему думать, что Face ID доступен ───────────────
%hook LAContext

// biometryType: сообщаем kLABiometryTypeFaceID = 2
- (LABiometryType)biometryType {
    return LABiometryTypeFaceID;
}

// canEvaluatePolicy: разрешаем биометрию
- (BOOL)canEvaluatePolicy:(LAPolicy)policy error:(NSError **)error {
    if (policy == LAPolicyDeviceOwnerAuthenticationWithBiometrics ||
        policy == LAPolicyDeviceOwnerAuthentication) {
        if (error) *error = nil;
        return YES;
    }
    return %orig;
}

// evaluatePolicy: заменяем на нашу камеру
- (void)evaluatePolicy:(LAPolicy)policy
       localizedReason:(NSString *)reason
                 reply:(void(^)(BOOL success, NSError *error))reply {

    if (policy == LAPolicyDeviceOwnerAuthenticationWithBiometrics) {
        [FIDAuthManager authenticateWithReason:reason
                                    completion:^(BOOL success, NSError *error) {
            reply(success, error);
        }];
        return;
    }
    %orig;
}

%end

// ─── BiometricKit: снимаем ограничение «железа» ──────────────────────────────
%hook BiometricKitProxy

- (BOOL)isFaceIDAvailable {
    return YES;
}

- (int)biometryType {
    return 2; // BKBiometryTypeFaceID
}

%end

// ─── SBFUserAuthenticationController (SpringBoard) ───────────────────────────
// Перехватываем запрос биометрии на экране блокировки
%hook SBFUserAuthenticationController

- (void)_evaluateBiometricAuthentication {
    [FIDAuthManager
     authenticateWithReason:@"Разблокировать iPhone"
                 completion:^(BOOL success, NSError *error) {
        if (success) {
            [self _biometricAuthenticationDidSucceed];
        } else {
            [self _biometricAuthenticationDidFail];
        }
    }];
}

%end

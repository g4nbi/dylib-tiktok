// VCam.m - ganti frame kamera app dengan video/foto pilihan lu
// Cara pakai di app: tahan 3 jari 1 detik di layar -> menu muncul.
//
// Build (butuh Mac + Xcode):
// xcrun -sdk iphoneos clang -arch arm64 -dynamiclib -fobjc-arc \
//   -miphoneos-version-min=15.0 -framework Foundation -framework UIKit \
//   -framework AVFoundation -framework CoreMedia -framework CoreVideo \
//   -framework VideoToolbox -framework PhotosUI VCam.m -o VCam.dylib

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>

static NSObject *gLock;
static NSMutableSet<NSString *> *gHooked;
static volatile BOOL gEnabled = NO;
static BOOL gIsImage = NO;
static NSURL *gURL;
static CVPixelBufferRef gStill = NULL;
static AVAssetReader *gReader;
static AVAssetReaderOutput *gOut;
static VTPixelTransferSessionRef gXfer = NULL;

#pragma mark - Sumber media

static CVPixelBufferRef PBFromImage(UIImage *img) {
    if (!img) return NULL;
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat defaultFormat];
    f.scale = 1; f.opaque = YES;
    // render ulang biar orientasi EXIF kepake
    UIImage *n = [[[UIGraphicsImageRenderer alloc] initWithSize:img.size format:f]
        imageWithActions:^(UIGraphicsImageRendererContext *c) { [img drawAtPoint:CGPointZero]; }];
    size_t w = CGImageGetWidth(n.CGImage), h = CGImageGetHeight(n.CGImage);
    CVPixelBufferRef pb = NULL;
    CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &pb);
    if (!pb) return NULL;
    CVPixelBufferLockBaseAddress(pb, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8,
        CVPixelBufferGetBytesPerRow(pb), cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), n.CGImage);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

static void OpenVideo(void) {
    AVURLAsset *a = [AVURLAsset URLAssetWithURL:gURL options:nil];
    NSArray *tracks = [a tracksWithMediaType:AVMediaTypeVideo];
    if (!tracks.count) { gEnabled = NO; return; }
    gReader = [AVAssetReader assetReaderWithAsset:a error:nil];
    AVAssetReaderVideoCompositionOutput *o = [AVAssetReaderVideoCompositionOutput
        assetReaderVideoCompositionOutputWithVideoTracks:tracks
        videoSettings:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    // videoComposition = rotasi video portrait kepake bener
    o.videoComposition = [AVMutableVideoComposition videoCompositionWithPropertiesOfAsset:a];
    [gReader addOutput:o];
    gOut = o;
    [gReader startReading];
}

// return +1 retained, caller yang release
static CVPixelBufferRef NextFrame(void) {
    @synchronized (gLock) {
        if (gIsImage) return gStill ? CVPixelBufferRetain(gStill) : NULL;
        for (int i = 0; i < 2; i++) {
            if (!gReader) OpenVideo();
            CMSampleBufferRef s = gOut ? [gOut copyNextSampleBuffer] : NULL;
            if (s) {
                CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(s);
                if (pb) CVPixelBufferRetain(pb);
                CFRelease(s);
                if (pb) return pb;
            }
            gReader = nil; gOut = nil; // video abis -> loop dari awal
        }
        return NULL;
    }
}

static void SetSource(NSURL *u, BOOL image) {
    @synchronized (gLock) {
        gReader = nil; gOut = nil;
        if (gStill) { CVPixelBufferRelease(gStill); gStill = NULL; }
        gURL = u; gIsImage = image;
        if (image) gStill = PBFromImage([UIImage imageWithContentsOfFile:u.path]);
        gEnabled = image ? (gStill != NULL) : YES;
    }
}

#pragma mark - Ganti frame kamera

// bikin sample buffer baru: isi = frame media, ukuran + format = punya kamera, timing = punya kamera
static CMSampleBufferRef Replace(CMSampleBufferRef sb) {
    if (!gEnabled) return NULL;
    CVPixelBufferRef like = CMSampleBufferGetImageBuffer(sb);
    if (!like) return NULL;
    CVPixelBufferRef src = NextFrame();
    if (!src) return NULL;

    CVPixelBufferRef dst = NULL;
    CVPixelBufferCreate(NULL, CVPixelBufferGetWidth(like), CVPixelBufferGetHeight(like),
        CVPixelBufferGetPixelFormatType(like),
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &dst);

    CMSampleBufferRef out = NULL;
    if (dst) {
        if (!gXfer) {
            VTPixelTransferSessionCreate(NULL, &gXfer);
            // Trim = crop biar fill layar. Ganti kVTScalingMode_Letterbox kalo mau ada bar hitam
            VTSessionSetProperty(gXfer, kVTPixelTransferPropertyKey_ScalingMode, kVTScalingMode_Trim);
        }
        if (VTPixelTransferSessionTransferImage(gXfer, src, dst) == noErr) {
            CMVideoFormatDescriptionRef fd = NULL;
            CMVideoFormatDescriptionCreateForImageBuffer(NULL, dst, &fd);
            CMSampleTimingInfo ti;
            CMSampleBufferGetSampleTimingInfo(sb, 0, &ti);
            CMSampleBufferCreateReadyWithImageBuffer(NULL, dst, fd, &ti, &out);
            if (fd) CFRelease(fd);
        }
        CVPixelBufferRelease(dst);
    }
    CVPixelBufferRelease(src);
    return out;
}

static void HookClass(Class c) {
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);
    @synchronized (gHooked) {
        NSString *name = NSStringFromClass(c);
        if ([gHooked containsObject:name]) return;
        [gHooked addObject:name];
    }
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    IMP neu = imp_implementationWithBlock(
        ^(id me, AVCaptureOutput *o, CMSampleBufferRef sb, AVCaptureConnection *cn) {
            CMSampleBufferRef r = Replace(sb);
            ((void (*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))orig)
                (me, sel, o, r ?: sb, cn);
            if (r) CFRelease(r);
        });
    class_replaceMethod(c, sel, neu, method_getTypeEncoding(m));
}

@interface AVCaptureVideoDataOutput (VCam) @end
@implementation AVCaptureVideoDataOutput (VCam)
- (void)vcam_setSampleBufferDelegate:(id)d queue:(dispatch_queue_t)q {
    if (d) HookClass(object_getClass(d));
    [self vcam_setSampleBufferDelegate:d queue:q]; // udah ketuker, ini manggil yang asli
}
@end

#pragma mark - UI (tahan 3 jari 1 detik)

static UIWindow *KeyWindow(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) return w;
    }
    return nil;
}

static UIViewController *Top(void) {
    UIViewController *v = KeyWindow().rootViewController;
    while (v.presentedViewController) v = v.presentedViewController;
    return v;
}

@interface VCamUI : NSObject <PHPickerViewControllerDelegate>
+ (instancetype)shared;
- (void)show;
@end

@implementation VCamUI
+ (instancetype)shared {
    static VCamUI *i; static dispatch_once_t t;
    dispatch_once(&t, ^{ i = [VCamUI new]; });
    return i;
}

- (void)show {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"VCam"
        message:gEnabled ? @"Aktif: kamera diganti media" : @"Mati: kamera asli"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Pilih video / foto"
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        PHPickerConfiguration *c = [PHPickerConfiguration new];
        c.filter = [PHPickerFilter anyFilterMatchingSubfilters:
                    @[PHPickerFilter.videosFilter, PHPickerFilter.imagesFilter]];
        c.selectionLimit = 1;
        c.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
        PHPickerViewController *p = [[PHPickerViewController alloc] initWithConfiguration:c];
        p.delegate = self;
        [Top() presentViewController:p animated:YES completion:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Matikan (kamera asli)"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) { gEnabled = NO; }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Tutup" style:UIAlertActionStyleCancel handler:nil]];
    [Top() presentViewController:a animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *p = results.firstObject.itemProvider;
    if (!p) return;
    BOOL vid = [p hasItemConformingToTypeIdentifier:@"public.movie"];
    [p loadFileRepresentationForTypeIdentifier:(vid ? @"public.movie" : @"public.image")
        completionHandler:^(NSURL *url, NSError *err) {
        if (!url) return;
        // file dari picker dihapus abis block ini, jadi copy dulu
        NSString *dst = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [@"vcam_src" stringByAppendingPathExtension:url.pathExtension]];
        [NSFileManager.defaultManager removeItemAtPath:dst error:nil];
        [NSFileManager.defaultManager copyItemAtPath:url.path toPath:dst error:nil];
        SetSource([NSURL fileURLWithPath:dst], !vid);
    }];
}
@end

#pragma mark - Entry

__attribute__((constructor)) static void VCamInit(void) {
    gLock = [NSObject new];
    gHooked = [NSMutableSet set];

    method_exchangeImplementations(
        class_getInstanceMethod(AVCaptureVideoDataOutput.class, @selector(setSampleBufferDelegate:queue:)),
        class_getInstanceMethod(AVCaptureVideoDataOutput.class, @selector(vcam_setSampleBufferDelegate:queue:)));

    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        static BOOL added;
        UIWindow *w = KeyWindow();
        if (added || !w) return;
        UILongPressGestureRecognizer *g = [[UILongPressGestureRecognizer alloc]
            initWithTarget:VCamUI.shared action:@selector(show)];
        g.numberOfTouchesRequired = 3;
        g.minimumPressDuration = 1.0;
        g.cancelsTouchesInView = NO;
        [w addGestureRecognizer:g];
        added = YES;
    }];
}

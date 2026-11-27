//
// AndroidMetalView - Goldfish MetalDisplay + FrameMailbox renderer.
// Uses persistent FrameMailbox dirty-rect coalescing, serial Metal upload/encode queue,
// single in-flight frame semaphore, and guest pixel-budget drawable scaling.
//

#import "AndroidMetalView.h"
#include "FrameMailbox.hpp"
#import <QuartzCore/CAMetalLayer.h>
#include <atomic>
#include <cmath>
#include <memory>
#include <mutex>
#include <simd/simd.h>

namespace {

static NSString *const kAndroidMetalShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct QuadUniforms {
    float4 ndcRect; // (left, bottom, right, top)
    float4 uvQuad[2]; // [0]=(tl_u,tl_v,tr_u,tr_v), [1]=(bl_u,bl_v,br_u,br_v)
};

vertex VertexOut androidFbVertex(uint vid [[vertex_id]],
                                 constant QuadUniforms &u [[buffer(0)]]) {
    float2 pos;
    float2 uv;
    switch (vid) {
        case 0: pos = float2(u.ndcRect.x, u.ndcRect.y); uv = u.uvQuad[1].xy; break; // bottom-left
        case 1: pos = float2(u.ndcRect.z, u.ndcRect.y); uv = u.uvQuad[1].zw; break; // bottom-right
        case 2: pos = float2(u.ndcRect.x, u.ndcRect.w); uv = u.uvQuad[0].xy; break; // top-left
        default: pos = float2(u.ndcRect.z, u.ndcRect.w); uv = u.uvQuad[0].zw; break; // top-right
    }
    return { float4(pos, 0.0, 1.0), uv };
}

fragment float4 androidFbFragment(VertexOut in [[stage_in]],
                                  texture2d<float> image [[texture(0)]]) {
    constexpr sampler sampleFilter(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(image.sample(sampleFilter, in.uv).rgb, 1.0);
}
)";

struct QuadUniforms {
    simd_float4 ndcRect;
    simd_float4 uvQuad[2];
};

static constexpr int kAndroidMetalSlots = 3;

static emu::DirtyRect unionRect(emu::DirtyRect a, emu::DirtyRect b) {
    if (a.width == 0 || a.height == 0) return b;
    if (b.width == 0 || b.height == 0) return a;
    uint32_t x = std::min(a.x, b.x);
    uint32_t y = std::min(a.y, b.y);
    uint32_t mx = std::max(a.x + a.width, b.x + b.width);
    uint32_t my = std::max(a.y + a.height, b.y + b.height);
    return {x, y, mx - x, my - y};
}

} // namespace

@implementation AndroidMetalView {
    id<MTLCommandQueue> _commands;
    id<MTLRenderPipelineState> _pipeline;
    id<MTLTexture> _textures[kAndroidMetalSlots];
    emu::DirtyRect _slotDirty[kAndroidMetalSlots];
    bool _slotHasFrame[kAndroidMetalSlots];
    int _writeSlot;
    int _presentSlot;
    std::unique_ptr<emu::FrameMailbox> _mailbox;
    std::mutex _mailboxMutex;
    dispatch_queue_t _renderQueue;
    dispatch_semaphore_t _available;
    std::atomic<bool> _dirty;
    std::atomic<bool> _needsPresent;
    BOOL _hasFrame;
    uint32_t _guestWidth;
    uint32_t _guestHeight;

    UIPinchGestureRecognizer *_pinchGesture;
    UIPanGestureRecognizer *_panGesture;
    CGSize _lastLayoutSize;
    CFTimeInterval _fpsWindowStart;
    NSUInteger _fpsFrameCounter;
    std::atomic<double> _fpsAtomic;
    std::atomic<NSUInteger> _totalFramesAtomic;
}

- (double)fps {
    return _fpsAtomic.load(std::memory_order_relaxed);
}

- (NSUInteger)totalFramesRendered {
    return _totalFramesAtomic.load(std::memory_order_relaxed);
}

- (instancetype)initWithFrame:(CGRect)frame {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    self = [super initWithFrame:frame device:device];
    if (self) {
        _guestWidth = 750;
        _guestHeight = 1334;
        _zoomScale = 1.0f;
        _panOffset = CGPointZero;
        _displayRotationDegrees = 0;
        _dirty.store(false, std::memory_order_relaxed);
        _needsPresent.store(false, std::memory_order_relaxed);
        _fpsAtomic.store(0.0, std::memory_order_relaxed);
        _totalFramesAtomic.store(0, std::memory_order_relaxed);

        self.backgroundColor = [UIColor blackColor];
        self.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        self.framebufferOnly = YES;
        self.preferredFramesPerSecond = 120;
        self.paused = NO;
        self.enableSetNeedsDisplay = NO;
        self.autoResizeDrawable = NO;
        self.multipleTouchEnabled = YES;
        self.delegate = self;

        if ([self.layer isKindOfClass:[CAMetalLayer class]]) {
            ((CAMetalLayer *)self.layer).presentsWithTransaction = NO;
        }

        _available = dispatch_semaphore_create(kAndroidMetalSlots);
        _renderQueue = dispatch_queue_create("com.classictouch.android.metal",
                                             dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                     QOS_CLASS_USER_INTERACTIVE, 0));

        if (device) {
            _commands = [device newCommandQueue];
            NSError *err = nil;
            id<MTLLibrary> lib = [device newLibraryWithSource:kAndroidMetalShaderSource options:nil error:&err];
            if (lib) {
                MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
                desc.vertexFunction = [lib newFunctionWithName:@"androidFbVertex"];
                desc.fragmentFunction = [lib newFunctionWithName:@"androidFbFragment"];
                desc.colorAttachments[0].pixelFormat = self.colorPixelFormat;
                _pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&err];
            }
            if (err) {
                NSLog(@"[AndroidMetalView] Metal init error: %@", err);
            }
            [self ensureBackingSizeWidth:_guestWidth height:_guestHeight];
        }

        _pinchGesture = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(handlePinchGesture:)];
        _pinchGesture.delegate = self;
        _pinchGesture.enabled = NO;
        [self addGestureRecognizer:_pinchGesture];

        _panGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanGesture:)];
        _panGesture.delegate = self;
        _panGesture.enabled = NO;
        _panGesture.maximumNumberOfTouches = 2;
        [self addGestureRecognizer:_panGesture];

        [self updateDrawableBudget];
    }
    return self;
}

- (void)ensureBackingSizeWidth:(uint32_t)w height:(uint32_t)h {
    if (w == 0 || h == 0 || w > 4096 || h > 4096) return;
    std::lock_guard<std::mutex> lock(_mailboxMutex);
    if (_mailbox && _mailbox->width() == w && _mailbox->height() == h && _textures[0]) {
        return;
    }
    _guestWidth = w;
    _guestHeight = h;
    _mailbox = std::make_unique<emu::FrameMailbox>(w, h);
    if (self.device) {
        MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                           width:w
                                                                                          height:h
                                                                                       mipmapped:NO];
        texDesc.usage = MTLTextureUsageShaderRead;
        for (int i = 0; i < kAndroidMetalSlots; i++) {
            _textures[i] = [self.device newTextureWithDescriptor:texDesc];
            _slotDirty[i] = {0, 0, w, h};
            _slotHasFrame[i] = false;
        }
    }
    _writeSlot = 0;
    _presentSlot = 0;
    _hasFrame = NO;
}

- (void)updateDrawableBudget {
    if (![NSThread isMainThread]) return;
    CGSize bounds = self.bounds.size;
    if (bounds.width <= 0 || bounds.height <= 0) return;

    CGFloat nativeScale = self.window.screen.nativeScale;
    if (nativeScale <= 0) nativeScale = [UIScreen mainScreen].nativeScale;
    if (nativeScale <= 0) nativeScale = 2.0;

    CGSize pixels = CGSizeMake(fmax(1.0, floor(bounds.width * nativeScale)),
                               fmax(1.0, floor(bounds.height * nativeScale)));
    if (!CGSizeEqualToSize(pixels, self.drawableSize)) {
        self.drawableSize = pixels;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize sz = self.bounds.size;
    if (!CGSizeEqualToSize(sz, _lastLayoutSize)) {
        _lastLayoutSize = sz;
        [self clampPanOffset];
        _needsPresent.store(true, std::memory_order_release);
    }
    [self updateDrawableBudget];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self updateDrawableBudget];
    _needsPresent.store(true, std::memory_order_release);
}

- (void)setPaused:(BOOL)paused {
    [super setPaused:paused];
    if (!paused) {
        _needsPresent.store(true, std::memory_order_release);
    }
}

- (void)setDisplayRotationDegrees:(NSInteger)displayRotationDegrees {
    NSInteger norm = ((displayRotationDegrees % 360) + 360) % 360;
    if (norm != 0 && norm != 90 && norm != 180 && norm != 270) norm = 0;
    if (_displayRotationDegrees != norm) {
        _displayRotationDegrees = norm;
        [self clampPanOffset];
        [self updateDrawableBudget];
        _needsPresent.store(true, std::memory_order_release);
    }
}

- (void)setZoomModeEnabled:(BOOL)zoomModeEnabled {
    _zoomModeEnabled = zoomModeEnabled;
    _pinchGesture.enabled = zoomModeEnabled;
    _panGesture.enabled = zoomModeEnabled;
    if (!zoomModeEnabled) {
        [self resetZoom];
    }
}

- (void)setZoomScale:(CGFloat)zoomScale {
    if (zoomScale < 1.0f) zoomScale = 1.0f;
    if (zoomScale > 6.0f) zoomScale = 6.0f;
    if (fabs(_zoomScale - zoomScale) > 0.001f) {
        _zoomScale = zoomScale;
        [self clampPanOffset];
        [self updateDrawableBudget];
        if (self.onZoomChanged) {
            self.onZoomChanged(_zoomScale, _panOffset);
        }
        _needsPresent.store(true, std::memory_order_release);
    }
}

- (void)setPanOffset:(CGPoint)panOffset {
    _panOffset = panOffset;
    [self clampPanOffset];
    if (self.onZoomChanged) {
        self.onZoomChanged(_zoomScale, _panOffset);
    }
    _needsPresent.store(true, std::memory_order_release);
}

- (void)resetZoom {
    _zoomScale = 1.0f;
    _panOffset = CGPointZero;
    [self updateDrawableBudget];
    if (self.onZoomChanged) {
        self.onZoomChanged(1.0f, CGPointZero);
    }
    _needsPresent.store(true, std::memory_order_release);
}

- (void)purgeTextureCaches {
    std::lock_guard<std::mutex> lock(_mailboxMutex);
    for (int i = 0; i < kAndroidMetalSlots; i++) {
        _textures[i] = nil;
        _slotDirty[i] = {};
        _slotHasFrame[i] = false;
    }
    _mailbox.reset();
    _hasFrame = NO;
}

- (void)clampPanOffset {
    if (_zoomScale <= 1.001f) {
        _panOffset = CGPointZero;
        return;
    }
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;

    uint32_t tw = _guestWidth > 0 ? _guestWidth : 540;
    uint32_t th = _guestHeight > 0 ? _guestHeight : 960;
    BOOL swapped = (_displayRotationDegrees == 90 || _displayRotationDegrees == 270);
    CGFloat dispW = swapped ? (CGFloat)th : (CGFloat)tw;
    CGFloat dispH = swapped ? (CGFloat)tw : (CGFloat)th;
    CGFloat guestAspect = dispW / dispH;
    CGFloat viewAspect = bounds.size.width / bounds.size.height;
    CGFloat baseW = (viewAspect > guestAspect) ? bounds.size.height * guestAspect : bounds.size.width;
    CGFloat baseH = (viewAspect > guestAspect) ? bounds.size.height : bounds.size.width / guestAspect;
    CGFloat scaledW = baseW * _zoomScale;
    CGFloat scaledH = baseH * _zoomScale;
    CGFloat maxOffsetX = fmax(0.0, (scaledW - bounds.size.width) * 0.5 + 40.0);
    CGFloat maxOffsetY = fmax(0.0, (scaledH - bounds.size.height) * 0.5 + 40.0);
    _panOffset.x = fmin(fmax(_panOffset.x, -maxOffsetX), maxOffsetX);
    _panOffset.y = fmin(fmax(_panOffset.y, -maxOffsetY), maxOffsetY);
}

- (void)handlePinchGesture:(UIPinchGestureRecognizer *)pinch {
    if (!_zoomModeEnabled) return;
    if (pinch.state == UIGestureRecognizerStateBegan || pinch.state == UIGestureRecognizerStateChanged) {
        CGFloat targetScale = _zoomScale * pinch.scale;
        if (targetScale < 1.0f) targetScale = 1.0f;
        if (targetScale > 6.0f) targetScale = 6.0f;
        _zoomScale = targetScale;
        pinch.scale = 1.0f;
        [self clampPanOffset];
        [self updateDrawableBudget];
        if (self.onZoomChanged) {
            self.onZoomChanged(_zoomScale, _panOffset);
        }
        _needsPresent.store(true, std::memory_order_release);
    }
}

- (void)handlePanGesture:(UIPanGestureRecognizer *)pan {
    if (!_zoomModeEnabled) return;
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [pan translationInView:self];
        _panOffset.x += translation.x;
        _panOffset.y += translation.y;
        [pan setTranslation:CGPointZero inView:self];
        [self clampPanOffset];
        if (self.onZoomChanged) {
            self.onZoomChanged(_zoomScale, _panOffset);
        }
        _needsPresent.store(true, std::memory_order_release);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (CGRect)activeScreenRect {
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return bounds;
    uint32_t tw = _guestWidth > 0 ? _guestWidth : 540;
    uint32_t th = _guestHeight > 0 ? _guestHeight : 960;
    BOOL swapped = (_displayRotationDegrees == 90 || _displayRotationDegrees == 270);
    CGFloat dispW = swapped ? (CGFloat)th : (CGFloat)tw;
    CGFloat dispH = swapped ? (CGFloat)tw : (CGFloat)th;
    CGFloat guestAspect = dispW / dispH;
    CGFloat viewAspect = bounds.size.width / bounds.size.height;
    CGFloat baseW = (viewAspect > guestAspect) ? bounds.size.height * guestAspect : bounds.size.width;
    CGFloat baseH = (viewAspect > guestAspect) ? bounds.size.height : bounds.size.width / guestAspect;
    CGFloat scale = (_zoomScale > 0.05f) ? _zoomScale : 1.0f;
    CGFloat scaledW = baseW * scale;
    CGFloat scaledH = baseH * scale;
    CGFloat originX = (bounds.size.width - scaledW) * 0.5f + _panOffset.x;
    CGFloat originY = (bounds.size.height - scaledH) * 0.5f + _panOffset.y;
    return CGRectMake(originX, originY, scaledW, scaledH);
}

- (void)updateFramePixels:(const void *)bgraPixels width:(int)w height:(int)h stride:(int)stride {
    [self updateDirtyPixels:bgraPixels x:0 y:0 width:w height:h stride:stride fullWidth:w fullHeight:h];
}

- (void)updateDirtyPixels:(const void *)bgraPixels
                        x:(int)x
                        y:(int)y
                    width:(int)w
                   height:(int)h
                   stride:(int)stride
                fullWidth:(int)fullW
               fullHeight:(int)fullH {
    if (!bgraPixels || w <= 0 || h <= 0 || fullW <= 0 || fullH <= 0 || stride < fullW * 4) {
        return;
    }
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= fullW || y >= fullH) return;
    if (w > fullW - x) w = fullW - x;
    if (h > fullH - y) h = fullH - y;

    bool ok = false;
    {
        std::unique_lock<std::mutex> lock(_mailboxMutex);
        if (!_mailbox || _mailbox->width() != (uint32_t)fullW || _mailbox->height() != (uint32_t)fullH || !_textures[0]) {
            lock.unlock();
            [self ensureBackingSizeWidth:(uint32_t)fullW height:(uint32_t)fullH];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self updateDrawableBudget];
            });
            lock.lock();
        }
        if (_mailbox) {
            ok = _mailbox->update(static_cast<const uint8_t *>(bgraPixels),
                                  (size_t)stride,
                                  {(uint32_t)x, (uint32_t)y, (uint32_t)w, (uint32_t)h});
        }
        if (ok) {
            _dirty.store(true, std::memory_order_release);
        }
    }
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    (void)view;
    (void)size;
    _needsPresent.store(true, std::memory_order_release);
}

- (void)drawInMTKView:(MTKView *)view {
    if (!_needsPresent.load(std::memory_order_acquire) && !_dirty.load(std::memory_order_acquire)) {
        return;
    }
    if (dispatch_semaphore_wait(_available, DISPATCH_TIME_NOW) != 0) {
        return;
    }
    MTLRenderPassDescriptor *pass = view.currentRenderPassDescriptor;
    id<CAMetalDrawable> drawable = view.currentDrawable;
    if (!pass || !drawable || !_pipeline || !_commands) {
        dispatch_semaphore_signal(_available);
        return;
    }

    CGRect bounds = self.bounds;
    CGRect active = [self activeScreenRect];
    CGFloat bw = bounds.size.width > 0 ? bounds.size.width : 1.0;
    CGFloat bh = bounds.size.height > 0 ? bounds.size.height : 1.0;

    QuadUniforms uniforms{};
    uniforms.ndcRect = simd_make_float4(
        (float)((active.origin.x / bw) * 2.0 - 1.0),
        (float)(1.0 - ((active.origin.y + active.size.height) / bh) * 2.0),
        (float)(((active.origin.x + active.size.width) / bw) * 2.0 - 1.0),
        (float)(1.0 - (active.origin.y / bh) * 2.0)
    );
    switch (_displayRotationDegrees) {
        case 90:
            uniforms.uvQuad[0] = simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f);
            uniforms.uvQuad[1] = simd_make_float4(1.0f, 1.0f, 1.0f, 0.0f);
            break;
        case 180:
            uniforms.uvQuad[0] = simd_make_float4(1.0f, 1.0f, 0.0f, 1.0f);
            uniforms.uvQuad[1] = simd_make_float4(1.0f, 0.0f, 0.0f, 0.0f);
            break;
        case 270:
            uniforms.uvQuad[0] = simd_make_float4(1.0f, 0.0f, 1.0f, 1.0f);
            uniforms.uvQuad[1] = simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f);
            break;
        default:
            uniforms.uvQuad[0] = simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f);
            uniforms.uvQuad[1] = simd_make_float4(0.0f, 1.0f, 1.0f, 1.0f);
            break;
    }

    BOOL force = _needsPresent.exchange(false, std::memory_order_acq_rel);
    dispatch_async(_renderQueue, ^{
        @autoreleasepool {
            [self renderPass:pass drawable:drawable uniforms:uniforms force:force];
        }
    });
}

struct UploadCapture {
    AndroidMetalView *view;
    int slot;
    id<MTLTexture> tex;
};

- (void)renderPass:(MTLRenderPassDescriptor *)pass
          drawable:(id<CAMetalDrawable>)drawable
          uniforms:(QuadUniforms)uniforms
             force:(BOOL)force {
    bool updated = false;
    id<MTLTexture> tex = nil;
    {
        std::lock_guard<std::mutex> lock(_mailboxMutex);
        _dirty.store(false, std::memory_order_release);
        if (_mailbox && _textures[0]) {
            int slot = _writeSlot;
            UploadCapture cap{self, slot, _textures[slot]};
            updated = _mailbox->consume([](void *context, const uint8_t *pixels, size_t stride, emu::DirtyRect dirty) {
                auto *c = static_cast<UploadCapture *>(context);
                AndroidMetalView *v = c->view;
                for (int i = 0; i < kAndroidMetalSlots; i++) {
                    if (!v->_slotHasFrame[i]) {
                        v->_slotDirty[i] = {0, 0, v->_mailbox->width(), v->_mailbox->height()};
                    } else {
                        v->_slotDirty[i] = unionRect(v->_slotDirty[i], dirty);
                    }
                }
                emu::DirtyRect upload = v->_slotDirty[c->slot];
                id<MTLTexture> t = c->tex;
                if (t && upload.width > 0 && upload.height > 0 &&
                    upload.x + upload.width <= t.width && upload.y + upload.height <= t.height) {
                    [t replaceRegion:MTLRegionMake2D(upload.x, upload.y, upload.width, upload.height)
                         mipmapLevel:0
                           withBytes:pixels + (size_t)upload.y * stride + (size_t)upload.x * 4
                         bytesPerRow:stride];
                    v->_slotHasFrame[c->slot] = true;
                    v->_slotDirty[c->slot] = {};
                }
            }, &cap);
            if (updated) {
                tex = _textures[slot];
                _presentSlot = slot;
                _writeSlot = (slot + 1) % kAndroidMetalSlots;
            } else {
                tex = _textures[_presentSlot];
            }
        }
    }

    if (updated) {
        _hasFrame = YES;
        _totalFramesAtomic.fetch_add(1, std::memory_order_relaxed);
        _fpsFrameCounter++;
        CFTimeInterval now = CACurrentMediaTime();
        if (_fpsWindowStart == 0.0) {
            _fpsWindowStart = now;
        } else if (now - _fpsWindowStart >= 1.0) {
            _fpsAtomic.store((double)_fpsFrameCounter / (now - _fpsWindowStart), std::memory_order_relaxed);
            _fpsFrameCounter = 0;
            _fpsWindowStart = now;
        }
    }

    if (!tex || (!_hasFrame) || (!force && !updated)) {
        dispatch_semaphore_signal(_available);
        return;
    }

    id<MTLCommandBuffer> command = [_commands commandBuffer];
    if (!command) {
        _needsPresent.store(true, std::memory_order_release);
        dispatch_semaphore_signal(_available);
        return;
    }
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) {
        _needsPresent.store(true, std::memory_order_release);
        dispatch_semaphore_signal(_available);
        return;
    }
    [encoder setRenderPipelineState:_pipeline];
    [encoder setVertexBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:tex atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    [command presentDrawable:drawable];

    dispatch_semaphore_t sema = _available;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status == MTLCommandBufferStatusError) {
            self->_needsPresent.store(true, std::memory_order_release);
        }
        dispatch_semaphore_signal(sema);
    }];
    [command commit];
}

- (void)dispatchTouchEvents:(NSSet<UITouch *> *)touches phase:(int)phase {
    if (!self.onTouchEvent) return;

    CGRect activeRect = [self activeScreenRect];
    if (activeRect.size.width <= 0 || activeRect.size.height <= 0) {
        activeRect = self.bounds;
    }

    for (UITouch *t in touches) {
        CGPoint p = [t locationInView:self];
        float normX = (float)((p.x - activeRect.origin.x) / activeRect.size.width);
        float normY = (float)((p.y - activeRect.origin.y) / activeRect.size.height);
        if (normX < 0.0f) normX = 0.0f;
        else if (normX > 1.0f) normX = 1.0f;
        if (normY < 0.0f) normY = 0.0f;
        else if (normY > 1.0f) normY = 1.0f;

        float guestX = normX;
        float guestY = normY;
        NSInteger rot = _displayRotationDegrees;
        if (rot == 90) {
            guestX = normY;
            guestY = 1.0f - normX;
        } else if (rot == 180) {
            guestX = 1.0f - normX;
            guestY = 1.0f - normY;
        } else if (rot == 270) {
            guestX = 1.0f - normY;
            guestY = normX;
        }
        self.onTouchEvent((int)(uintptr_t)t, phase, guestX, guestY);
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_zoomModeEnabled) {
        [super touchesBegan:touches withEvent:event];
        return;
    }
    [self.touchDelegate metalViewTouchesChanged:touches withEvent:event phase:0];
    [self dispatchTouchEvents:touches phase:0];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_zoomModeEnabled) {
        [super touchesMoved:touches withEvent:event];
        return;
    }
    [self.touchDelegate metalViewTouchesChanged:touches withEvent:event phase:1];
    [self dispatchTouchEvents:touches phase:1];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_zoomModeEnabled) {
        [super touchesEnded:touches withEvent:event];
        return;
    }
    [self.touchDelegate metalViewTouchesChanged:touches withEvent:event phase:2];
    [self dispatchTouchEvents:touches phase:2];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_zoomModeEnabled) {
        [super touchesCancelled:touches withEvent:event];
        return;
    }
    [self.touchDelegate metalViewTouchesChanged:touches withEvent:event phase:2];
    [self dispatchTouchEvents:touches phase:2];
}

@end

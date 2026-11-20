#import "ios_metal_view.h"
#import <simd/simd.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurfaceRef.h>

#define IOS_METAL_TEX_SLOTS 6
#define IOS_METAL_DIRECT_SLOTS 4

typedef struct {
    IOSurfaceRef surf;
    id<MTLTexture> tex;
    int w, h;
    uint64_t stamp;
} IOSMetalDirectCacheEntry;

typedef struct {
    vector_float2 position;
    vector_float2 uv;
} IOSMetalVertex;

@interface IOSMetalView () {
    id<MTLCommandQueue> _commandQueue;
    id<MTLRenderPipelineState> _pipelineState;
    os_unfair_lock _texLock;
    id<MTLTexture> _textures[IOS_METAL_TEX_SLOTS];
    int _texW[IOS_METAL_TEX_SLOTS];
    int _texH[IOS_METAL_TEX_SLOTS];
    bool _inFlight[IOS_METAL_TEX_SLOTS];
    int _latestW, _latestH;
    int _readyIdx;
    int _drawIdx;
    int _writeIdx;
    IOSMetalDirectCacheEntry _directCache[IOS_METAL_DIRECT_SLOTS];
    uint64_t _directStamp;
    id<MTLTexture> _directTex;
    BOOL _usingDirect;
    atomic_uint_fast64_t _frameSeq;
    uint64_t _presentedSeq;
    CGSize _lastLayoutSize;
    NSTimeInterval _lastFpsTime;
    NSUInteger _framesThisSecond;
    CGRect _cachedActiveRect;
}
@property (nonatomic, assign, readwrite) double fps;
@property (nonatomic, assign, readwrite) NSUInteger totalFramesRendered;
@end

static const char *kShaderSource =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VertexIn {\n"
    "    float2 position;\n"
    "    float2 uv;\n"
    "};\n"
    "struct VertexOut {\n"
    "    float4 position [[position]];\n"
    "    float2 uv;\n"
    "};\n"
    "vertex VertexOut vertexShader(uint vid [[vertex_id]], const device VertexIn *vertices [[buffer(0)]]) {\n"
    "    VertexOut out;\n"
    "    out.position = float4(vertices[vid].position, 0.0, 1.0);\n"
    "    out.uv = vertices[vid].uv;\n"
    "    return out;\n"
    "}\n"
    "fragment float4 fragmentShader(VertexOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
    "    constexpr sampler s(mag_filter::linear, min_filter::linear);\n"
    "    return tex.sample(s, in.uv);\n"
    "}\n";

@implementation IOSMetalView

- (instancetype)initWithFrame:(CGRect)frame device:(id<MTLDevice>)device {
    if (self = [super initWithFrame:frame device:device ? device : MTLCreateSystemDefaultDevice()]) {
        _texLock = OS_UNFAIR_LOCK_INIT;
        _readyIdx = -1;
        _drawIdx = -1;
        _writeIdx = -1;
        atomic_init(&_frameSeq, 0);
        _presentedSeq = 0;
        self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        self.framebufferOnly = YES;
        self.paused = NO;
        self.enableSetNeedsDisplay = NO;
        self.preferredFramesPerSecond = 60;
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor blackColor];
        
        _commandQueue = [self.device newCommandQueue];
        
        NSError *error = nil;
        id<MTLLibrary> library = [self.device newLibraryWithSource:[NSString stringWithUTF8String:kShaderSource] options:nil error:&error];
        if (library) {
            MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
            desc.vertexFunction = [library newFunctionWithName:@"vertexShader"];
            desc.fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
            desc.colorAttachments[0].pixelFormat = self.colorPixelFormat;
            _pipelineState = [self.device newRenderPipelineStateWithDescriptor:desc error:&error];
        }
    }
    return self;
}

- (void)setDisplayRotationDegrees:(NSInteger)displayRotationDegrees {
    NSInteger norm = ((displayRotationDegrees % 360) + 360) % 360;
    if (norm != 0 && norm != 90 && norm != 180 && norm != 270) {
        norm = 0;
    }
    if (_displayRotationDegrees != norm) {
        _displayRotationDegrees = norm;
        _presentedSeq = 0;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize sz = self.bounds.size;
    if (!CGSizeEqualToSize(sz, _lastLayoutSize)) {
        _lastLayoutSize = sz;
        _presentedSeq = 0;
    }
}

- (CGRect)activeScreenRect {
    CGRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return bounds;
    os_unfair_lock_lock(&_texLock);
    int tw = _latestW;
    int th = _latestH;
    os_unfair_lock_unlock(&_texLock);
    if (tw <= 0 || th <= 0) return bounds;

    NSInteger rot = _displayRotationDegrees;
    BOOL swapped = (rot == 90 || rot == 270);
    CGFloat dispW = swapped ? (CGFloat)th : (CGFloat)tw;
    CGFloat dispH = swapped ? (CGFloat)tw : (CGFloat)th;
    CGFloat guestAspect = dispW / dispH;
    CGFloat viewAspect = bounds.size.width / bounds.size.height;
    if (viewAspect > guestAspect) {
        CGFloat h = bounds.size.height;
        CGFloat w = h * guestAspect;
        return CGRectMake((bounds.size.width - w) * 0.5, 0.0, w, h);
    } else {
        CGFloat w = bounds.size.width;
        CGFloat h = w / guestAspect;
        return CGRectMake(0.0, (bounds.size.height - h) * 0.5, w, h);
    }
}

- (void)updateFramePixels:(const void *)bgraPixels width:(int)w height:(int)h stride:(int)stride {
    if (!bgraPixels || w <= 0 || h <= 0) return;

    os_unfair_lock_lock(&_texLock);
    int slot = (_writeIdx + 1) % IOS_METAL_TEX_SLOTS;
    int attempts = 0;
    while ((slot == _readyIdx || slot == _drawIdx || _inFlight[slot]) && attempts < IOS_METAL_TEX_SLOTS) {
        slot = (slot + 1) % IOS_METAL_TEX_SLOTS;
        attempts++;
    }
    _writeIdx = slot;
    id<MTLTexture> tex = _textures[slot];
    int curW = _texW[slot];
    int curH = _texH[slot];
    os_unfair_lock_unlock(&_texLock);

    if (!tex || curW != w || curH != h) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        tex = [self.device newTextureWithDescriptor:td];
    }
    if (tex) {
        [tex replaceRegion:MTLRegionMake2D(0, 0, w, h)
               mipmapLevel:0
                 withBytes:bgraPixels
               bytesPerRow:stride > 0 ? stride : w * 4];
    }

    os_unfair_lock_lock(&_texLock);
    _textures[slot] = tex;
    _texW[slot] = w;
    _texH[slot] = h;
    _latestW = w;
    _latestH = h;
    _readyIdx = slot;
    _usingDirect = NO;
    os_unfair_lock_unlock(&_texLock);

    atomic_fetch_add_explicit(&_frameSeq, 1, memory_order_release);
}

- (void)updateFrameIOSurface:(void *)iosurfaceRef width:(int)w height:(int)h {
    if (!iosurfaceRef || w <= 0 || h <= 0 || !self.device) return;
    IOSurfaceRef surf = (IOSurfaceRef)iosurfaceRef;

    os_unfair_lock_lock(&_texLock);
    id<MTLTexture> tex = nil;
    for (int i = 0; i < IOS_METAL_DIRECT_SLOTS; i++) {
        if (_directCache[i].surf == surf &&
            _directCache[i].w == w && _directCache[i].h == h) {
            tex = _directCache[i].tex;
            _directCache[i].stamp = ++_directStamp;
            break;
        }
    }
    os_unfair_lock_unlock(&_texLock);

    if (!tex) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        tex = [self.device newTextureWithDescriptor:td iosurface:surf plane:0];
        if (!tex) return;

        IOSurfaceRef oldSurf = NULL;
        os_unfair_lock_lock(&_texLock);
        int best = 0;
        uint64_t oldest = UINT64_MAX;
        for (int i = 0; i < IOS_METAL_DIRECT_SLOTS; i++) {
            if (!_directCache[i].surf) {
                best = i;
                break;
            }
            if (_directCache[i].stamp < oldest) {
                oldest = _directCache[i].stamp;
                best = i;
            }
        }
        oldSurf = _directCache[best].surf;
        CFRetain(surf);
        _directCache[best].surf = surf;
        _directCache[best].tex = tex;
        _directCache[best].w = w;
        _directCache[best].h = h;
        _directCache[best].stamp = ++_directStamp;
        os_unfair_lock_unlock(&_texLock);
        if (oldSurf) {
            CFRelease(oldSurf);
        }
    }

    os_unfair_lock_lock(&_texLock);
    _directTex = tex;
    _usingDirect = YES;
    _latestW = w;
    _latestH = h;
    os_unfair_lock_unlock(&_texLock);

    atomic_fetch_add_explicit(&_frameSeq, 1, memory_order_release);
}

- (void)dealloc {
    for (int i = 0; i < IOS_METAL_DIRECT_SLOTS; i++) {
        if (_directCache[i].surf) {
            CFRelease(_directCache[i].surf);
            _directCache[i].surf = NULL;
        }
    }
}

- (void)drawRect:(CGRect)rect {
    if (!self.window) return;
    uint64_t seq = atomic_load_explicit(&_frameSeq, memory_order_acquire);
    if (seq == _presentedSeq) return;

    os_unfair_lock_lock(&_texLock);
    int idx = -1;
    id<MTLTexture> tex = nil;
    if (_usingDirect && _directTex) {
        tex = _directTex;
    } else {
        idx = _readyIdx;
        tex = (idx >= 0) ? _textures[idx] : nil;
        if (tex) {
            _drawIdx = idx;
            _inFlight[idx] = true;
        }
    }
    os_unfair_lock_unlock(&_texLock);

    bool committed = false;
    if (tex && _pipelineState) {
        CGRect bounds = self.bounds;
        if (bounds.size.width > 0 && bounds.size.height > 0) {
            MTLRenderPassDescriptor *pass = self.currentRenderPassDescriptor;
            id<MTLDrawable> drawable = self.currentDrawable;
            if (pass && drawable) {
                _presentedSeq = seq;
                CGRect activeRect = bounds;
                int tw = (int)tex.width;
                int th = (int)tex.height;
                NSInteger rot = _displayRotationDegrees;
                BOOL swapped = (rot == 90 || rot == 270);
                if (tw > 0 && th > 0) {
                    CGFloat dispW = swapped ? (CGFloat)th : (CGFloat)tw;
                    CGFloat dispH = swapped ? (CGFloat)tw : (CGFloat)th;
                    CGFloat guestAspect = dispW / dispH;
                    CGFloat viewAspect = bounds.size.width / bounds.size.height;
                    if (viewAspect > guestAspect) {
                        CGFloat h = bounds.size.height;
                        CGFloat w = h * guestAspect;
                        activeRect = CGRectMake((bounds.size.width - w) * 0.5, 0.0, w, h);
                    } else {
                        CGFloat w = bounds.size.width;
                        CGFloat h = w / guestAspect;
                        activeRect = CGRectMake(0.0, (bounds.size.height - h) * 0.5, w, h);
                    }
                }
                _cachedActiveRect = activeRect;

                float x0 = (float)(2.0 * activeRect.origin.x / bounds.size.width - 1.0);
                float x1 = (float)(2.0 * (activeRect.origin.x + activeRect.size.width) / bounds.size.width - 1.0);
                float y0 = (float)(1.0 - 2.0 * activeRect.origin.y / bounds.size.height);
                float y1 = (float)(1.0 - 2.0 * (activeRect.origin.y + activeRect.size.height) / bounds.size.height);

                vector_float2 uvTL = {0.0f, 0.0f}, uvTR = {1.0f, 0.0f}, uvBL = {0.0f, 1.0f}, uvBR = {1.0f, 1.0f};
                if (rot == 90) {
                    uvTL = (vector_float2){0.0f, 1.0f};
                    uvTR = (vector_float2){0.0f, 0.0f};
                    uvBL = (vector_float2){1.0f, 1.0f};
                    uvBR = (vector_float2){1.0f, 0.0f};
                } else if (rot == 180) {
                    uvTL = (vector_float2){1.0f, 1.0f};
                    uvTR = (vector_float2){0.0f, 1.0f};
                    uvBL = (vector_float2){1.0f, 0.0f};
                    uvBR = (vector_float2){0.0f, 0.0f};
                } else if (rot == 270) {
                    uvTL = (vector_float2){1.0f, 0.0f};
                    uvTR = (vector_float2){1.0f, 1.0f};
                    uvBL = (vector_float2){0.0f, 0.0f};
                    uvBR = (vector_float2){0.0f, 1.0f};
                }

                IOSMetalVertex quadVertices[4] = {
                    { {x0, y0}, uvTL },
                    { {x1, y0}, uvTR },
                    { {x0, y1}, uvBL },
                    { {x1, y1}, uvBR }
                };

                id<MTLCommandBuffer> cb = [_commandQueue commandBuffer];
                id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
                [enc setRenderPipelineState:_pipelineState];
                [enc setVertexBytes:quadVertices length:sizeof(quadVertices) atIndex:0];
                [enc setFragmentTexture:tex atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                [enc endEncoding];
                [cb presentDrawable:drawable];

                if (idx >= 0) {
                    __weak typeof(self) weakSelf = self;
                    [cb addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
                        __strong typeof(weakSelf) strongSelf = weakSelf;
                        if (!strongSelf) return;
                        os_unfair_lock_lock(&strongSelf->_texLock);
                        strongSelf->_inFlight[idx] = false;
                        if (strongSelf->_drawIdx == idx) {
                            strongSelf->_drawIdx = -1;
                        }
                        os_unfair_lock_unlock(&strongSelf->_texLock);
                    }];
                }

                [cb commit];
                committed = true;

                self.totalFramesRendered++;
                _framesThisSecond++;
                CFTimeInterval now = CACurrentMediaTime();
                if (_lastFpsTime == 0.0) {
                    _lastFpsTime = now;
                } else if (now - _lastFpsTime >= 1.0) {
                    self.fps = (double)_framesThisSecond / (now - _lastFpsTime);
                    _framesThisSecond = 0;
                    _lastFpsTime = now;
                }
            }
        }
    }

    if (tex && !committed && idx >= 0) {
        os_unfair_lock_lock(&_texLock);
        _inFlight[idx] = false;
        if (_drawIdx == idx) {
            _drawIdx = -1;
        }
        os_unfair_lock_unlock(&_texLock);
    }
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
    [self.touchDelegate metalViewTouchesChanged:touches withEvent:event phase:0];
    [self dispatchTouchEvents:touches phase:0];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.touchDelegate metalViewTouchesChanged:touches withEvent:event phase:1];
    [self dispatchTouchEvents:touches phase:1];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.touchDelegate metalViewTouchesChanged:touches withEvent:event phase:2];
    [self dispatchTouchEvents:touches phase:2];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self.touchDelegate metalViewTouchesChanged:touches withEvent:event phase:2];
    [self dispatchTouchEvents:touches phase:2];
}

@end

//
// ClassicTouch - Native Classic iOS Emulator for Modern iOS & iPadOS
//
// Copyright (c) 2026 ClassicTouch Authors.
// SPDX-License-Identifier: GPL-2.0-only
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; version 2 of the License.
//

#import "ios_audio_bridge.h"
#import <AudioToolbox/AudioToolbox.h>
#import <pthread.h>
#import <stdatomic.h>

// 16384 stereo frames (~371.5 ms at 44.1 kHz) keeps SPSC storage power-of-2 while absorbing
// TCG execution bursts and eliminating audio dropouts during emulator bursts.
#define RING_BUFFER_FRAMES 16384
#define RING_MAX_CHANNELS 2
#define RING_TOTAL_SAMPLES (RING_BUFFER_FRAMES * RING_MAX_CHANNELS)
#define RING_MASK (RING_TOTAL_SAMPLES - 1)

@interface IOSAudioBridge () {
@public
    AudioComponentInstance _audioUnit;
    int16_t _ringBuffer[RING_TOTAL_SAMPLES];
    _Atomic(size_t) _head;
    _Atomic(size_t) _tail;
    _Atomic(BOOL) _acceptingPCM;
    size_t _channels;
    size_t _maxQueuedSamples;
    double _sampleRate;
    pthread_mutex_t _lifecycleMutex;
    BOOL _running;
    BOOL _interrupted;
}
@end

static OSStatus audioCallback(void *inRefCon,
                              AudioUnitRenderActionFlags *ioActionFlags,
                              const AudioTimeStamp *inTimeStamp,
                              UInt32 inBusNumber,
                              UInt32 inNumberFrames,
                              AudioBufferList *ioData) {
    (void)inTimeStamp;
    (void)inBusNumber;
    IOSAudioBridge *self = (__bridge IOSAudioBridge *)inRefCon;
    int16_t *out = (int16_t *)ioData->mBuffers[0].mData;
    size_t ch = self->_channels;
    size_t needed = (size_t)inNumberFrames * ch;

    size_t head = atomic_load_explicit(&self->_head, memory_order_acquire);
    size_t tail = atomic_load_explicit(&self->_tail, memory_order_relaxed);
    size_t available = (head - tail) & RING_MASK;
    size_t toCopy = needed < available ? needed : available;
    // Always keep aligned to complete frames.
    toCopy -= (toCopy % ch);

    if (toCopy > 0) {
        size_t first = RING_TOTAL_SAMPLES - tail;
        if (first > toCopy) first = toCopy;
        memcpy(out, &self->_ringBuffer[tail], first * sizeof(int16_t));
        size_t second = toCopy - first;
        if (second > 0) {
            memcpy(out + first, &self->_ringBuffer[0], second * sizeof(int16_t));
        }
        atomic_store_explicit(&self->_tail, (tail + toCopy) & RING_MASK, memory_order_release);
    } else if (ioActionFlags) {
        *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
    }

    if (toCopy < needed) {
        memset(out + toCopy, 0, (needed - toCopy) * sizeof(int16_t));
    }
    ioData->mBuffers[0].mDataByteSize = (UInt32)(needed * sizeof(int16_t));
    return noErr;
}

@implementation IOSAudioBridge

+ (instancetype)sharedBridge {
    static IOSAudioBridge *sInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInstance = [[IOSAudioBridge alloc] init];
    });
    return sInstance;
}

- (instancetype)init {
    if (self = [super init]) {
        pthread_mutex_init(&_lifecycleMutex, NULL);
        atomic_init(&_head, 0);
        atomic_init(&_tail, 0);
        atomic_init(&_acceptingPCM, NO);
        _channels = 2;
        _sampleRate = 44100.0;
        _maxQueuedSamples = RING_MASK;

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self
               selector:@selector(handleAudioInterruption:)
                   name:AVAudioSessionInterruptionNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(handleAudioRouteChange:)
                   name:AVAudioSessionRouteChangeNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(handleMediaServicesReset:)
                   name:AVAudioSessionMediaServicesWereResetNotification
                 object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopPlayback];
    pthread_mutex_destroy(&_lifecycleMutex);
}

- (double)sampleRate {
    return _sampleRate;
}

- (int)channels {
    return (int)_channels;
}

- (BOOL)start {
    return [self startPlaybackWithSampleRate:44100.0 channels:2];
}

- (void)stop {
    [self stopPlayback];
}

- (void)configureAudioSessionForRate:(double)targetRate {
    NSError *sessionErr = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback
                  withOptions:AVAudioSessionCategoryOptionMixWithOthers
                        error:&sessionErr]) {
        NSLog(@"[Audio] setCategory failed: %@", sessionErr);
    }
    NSError *srErr = nil;
    if (![session setPreferredSampleRate:targetRate error:&srErr]) {
        NSLog(@"[Audio] setPreferredSampleRate failed: %@", srErr);
    }
    NSError *ioErr = nil;
    if (![session setPreferredIOBufferDuration:0.01 error:&ioErr]) {
        NSLog(@"[Audio] setPreferredIOBufferDuration failed: %@", ioErr);
    }
    sessionErr = nil;
    if (![session setActive:YES error:&sessionErr]) {
        NSLog(@"[Audio] setActive failed: %@", sessionErr);
    }
}

- (BOOL)setupAndStartAudioUnitLocked {
    AudioComponentDescription desc;
    memset(&desc, 0, sizeof(desc));
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (!comp) {
        NSLog(@"[Audio] RemoteIO component not found");
        return NO;
    }

    OSStatus status = AudioComponentInstanceNew(comp, &_audioUnit);
    if (status != noErr) {
        NSLog(@"[Audio] AudioComponentInstanceNew failed: %d", (int)status);
        _audioUnit = NULL;
        return NO;
    }

    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = _sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = (UInt32)_channels;
    format.mBitsPerChannel = 16;
    format.mBytesPerFrame = (UInt32)(_channels * sizeof(int16_t));
    format.mBytesPerPacket = format.mBytesPerFrame;

    status = AudioUnitSetProperty(_audioUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &format,
                                  sizeof(format));
    if (status != noErr) {
        NSLog(@"[Audio] SetProperty(StreamFormat) failed: %d", (int)status);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
        return NO;
    }

    AURenderCallbackStruct cb;
    memset(&cb, 0, sizeof(cb));
    cb.inputProc = audioCallback;
    cb.inputProcRefCon = (__bridge void *)self;

    status = AudioUnitSetProperty(_audioUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input,
                                  0,
                                  &cb,
                                  sizeof(cb));
    if (status != noErr) {
        NSLog(@"[Audio] SetProperty(RenderCallback) failed: %d", (int)status);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
        return NO;
    }

    status = AudioUnitInitialize(_audioUnit);
    if (status != noErr) {
        NSLog(@"[Audio] AudioUnitInitialize failed: %d", (int)status);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
        return NO;
    }

    status = AudioOutputUnitStart(_audioUnit);
    if (status != noErr) {
        NSLog(@"[Audio] AudioOutputUnitStart failed: %d", (int)status);
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
        return NO;
    }
    return YES;
}

- (BOOL)startPlaybackWithSampleRate:(double)sampleRate channels:(int)channels {
    double targetRate = sampleRate > 0 ? sampleRate : 44100.0;
    size_t targetChannels = (channels == 1 || channels == 2) ? (size_t)channels : 2;

    pthread_mutex_lock(&_lifecycleMutex);
    if (_running) {
        if (fabs(_sampleRate - targetRate) < 1.0 && _channels == targetChannels) {
            pthread_mutex_unlock(&_lifecycleMutex);
            return YES;
        }
        atomic_store_explicit(&_acceptingPCM, NO, memory_order_release);
        if (_audioUnit) {
            AudioOutputUnitStop(_audioUnit);
            AudioUnitUninitialize(_audioUnit);
            AudioComponentInstanceDispose(_audioUnit);
            _audioUnit = NULL;
        }
        _running = NO;
    }

    _sampleRate = targetRate;
    _channels = targetChannels;
    // Buffer up to ~250 ms to keep game audio synchronized while absorbing TCG bursts.
    size_t targetFrames = (size_t)(_sampleRate * 0.25);
    size_t targetSamples = targetFrames * _channels;
    if (targetSamples > (RING_TOTAL_SAMPLES - _channels)) {
        targetSamples = RING_TOTAL_SAMPLES - _channels;
    }
    _maxQueuedSamples = targetSamples - (targetSamples % _channels);

    atomic_store_explicit(&_acceptingPCM, NO, memory_order_release);
    atomic_store_explicit(&_head, 0, memory_order_relaxed);
    atomic_store_explicit(&_tail, 0, memory_order_relaxed);
    _interrupted = NO;

    [self configureAudioSessionForRate:_sampleRate];
    if (![self setupAndStartAudioUnitLocked]) {
        pthread_mutex_unlock(&_lifecycleMutex);
        return NO;
    }

    _running = YES;
    atomic_store_explicit(&_acceptingPCM, YES, memory_order_release);
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSLog(@"[Audio] RemoteIO playback started (%.0f Hz, %zu ch, ioBuf=%.1f ms)",
          _sampleRate, _channels, session.IOBufferDuration * 1000.0);
    pthread_mutex_unlock(&_lifecycleMutex);
    return YES;
}

- (void)stopPlayback {
    pthread_mutex_lock(&_lifecycleMutex);
    atomic_store_explicit(&_acceptingPCM, NO, memory_order_release);
    if (!_running) {
        pthread_mutex_unlock(&_lifecycleMutex);
        return;
    }
    if (_audioUnit) {
        AudioOutputUnitStop(_audioUnit);
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }
    _running = NO;
    _interrupted = NO;
    atomic_store_explicit(&_head, 0, memory_order_relaxed);
    atomic_store_explicit(&_tail, 0, memory_order_relaxed);
    pthread_mutex_unlock(&_lifecycleMutex);
}

- (void)handleAudioInterruption:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    AVAudioSessionInterruptionType type =
        (AVAudioSessionInterruptionType)[info[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    pthread_mutex_lock(&_lifecycleMutex);
    if (!_running || !_audioUnit) {
        pthread_mutex_unlock(&_lifecycleMutex);
        return;
    }
    if (type == AVAudioSessionInterruptionTypeBegan) {
        _interrupted = YES;
        AudioOutputUnitStop(_audioUnit);
    } else if (type == AVAudioSessionInterruptionTypeEnded) {
        _interrupted = NO;
        [self configureAudioSessionForRate:_sampleRate];
        OSStatus st = AudioOutputUnitStart(_audioUnit);
        if (st != noErr) {
            NSLog(@"[Audio] Failed to restart AudioUnit after interruption: %d", (int)st);
        }
    }
    pthread_mutex_unlock(&_lifecycleMutex);
}

- (void)handleAudioRouteChange:(NSNotification *)notification {
    NSDictionary *info = notification.userInfo;
    AVAudioSessionRouteChangeReason reason =
        (AVAudioSessionRouteChangeReason)[info[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    if (reason != AVAudioSessionRouteChangeReasonOldDeviceUnavailable &&
        reason != AVAudioSessionRouteChangeReasonNewDeviceAvailable) {
        return;
    }
    pthread_mutex_lock(&_lifecycleMutex);
    if (_running && _audioUnit && !_interrupted) {
        NSError *err = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&err];
        AudioOutputUnitStart(_audioUnit);
    }
    pthread_mutex_unlock(&_lifecycleMutex);
}

- (void)handleMediaServicesReset:(NSNotification *)notification {
    (void)notification;
    pthread_mutex_lock(&_lifecycleMutex);
    if (!_running) {
        pthread_mutex_unlock(&_lifecycleMutex);
        return;
    }
    NSLog(@"[Audio] Media services reset; rebuilding RemoteIO unit");
    atomic_store_explicit(&_acceptingPCM, NO, memory_order_release);
    if (_audioUnit) {
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = NULL;
    }
    atomic_store_explicit(&_head, 0, memory_order_relaxed);
    atomic_store_explicit(&_tail, 0, memory_order_relaxed);
    [self configureAudioSessionForRate:_sampleRate];
    if ([self setupAndStartAudioUnitLocked]) {
        atomic_store_explicit(&_acceptingPCM, YES, memory_order_release);
    } else {
        _running = NO;
    }
    pthread_mutex_unlock(&_lifecycleMutex);
}

- (void)pushPCMData:(const int16_t *)samples count:(size_t)frameCount {
    if (!samples || frameCount == 0) return;
    if (!atomic_load_explicit(&_acceptingPCM, memory_order_acquire)) return;

    size_t ch = _channels;
    size_t samplesCount = frameCount * ch;
    size_t head = atomic_load_explicit(&_head, memory_order_relaxed);
    size_t tail = atomic_load_explicit(&_tail, memory_order_acquire);

    size_t used = (head - tail) & RING_MASK;
    size_t maxQueued = _maxQueuedSamples;
    if (used >= maxQueued) {
        return;
    }
    size_t freeSpace = maxQueued - used;
    if (samplesCount > freeSpace) {
        samplesCount = freeSpace;
        samplesCount -= (samplesCount % ch);
        if (samplesCount == 0) return;
    }

    size_t first = RING_TOTAL_SAMPLES - head;
    if (first > samplesCount) first = samplesCount;
    memcpy(&_ringBuffer[head], samples, first * sizeof(int16_t));
    size_t second = samplesCount - first;
    if (second > 0) {
        memcpy(&_ringBuffer[0], samples + first, second * sizeof(int16_t));
    }
    atomic_store_explicit(&_head, (head + samplesCount) & RING_MASK, memory_order_release);
}

@end

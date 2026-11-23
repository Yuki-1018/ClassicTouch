/*
* Copyright (C) 2011 The Android Open Source Project
*
* Licensed under the Apache License, Version 2.0 (the "License");
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
* http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
*/
#include "RenderThread.h"

#include "ChannelStream.h"
#include "ErrorLog.h"
#include "FrameBuffer.h"
#include "ReadBuffer.h"
#include "RenderControl.h"
#include "RendererImpl.h"
#include "RenderChannelImpl.h"
#include "RenderThreadInfo.h"
#include "TimeUtils.h"

#include "OpenGLESDispatch/EGLDispatch.h"
#include "OpenGLESDispatch/GLESv2Dispatch.h"
#include "OpenGLESDispatch/GLESv1Dispatch.h"
#include "../../../shared/OpenglCodecCommon/ChecksumCalculatorThreadInfo.h"

#include <atomic>
#include <memory>
#include <string.h>
#ifdef __APPLE__
#include <pthread/qos.h>
#endif

#define STREAM_BUFFER_SIZE 4 * 1024 * 1024

RenderThread::RenderThread(std::weak_ptr<emugl::RendererImpl> renderer,
                           std::shared_ptr<emugl::RenderChannelImpl> channel,
                           emugl::Mutex* lock)
    : m_lock(lock), mChannel(channel), mRenderer(renderer) {}

RenderThread::RenderThread(IOStream* stream, emugl::Mutex* lock)
    : m_lock(lock), m_stream(stream) {}

RenderThread::~RenderThread() {
    delete m_stream;
}

// static
std::unique_ptr<RenderThread> RenderThread::create(
        std::weak_ptr<emugl::RendererImpl> renderer,
        std::shared_ptr<emugl::RenderChannelImpl> channel,
        emugl::Mutex* lock) {
    return std::unique_ptr<RenderThread>(
            new RenderThread(renderer, channel, lock));
}

// static
RenderThread* RenderThread::create(IOStream* stream, emugl::Mutex* lock) {
    return new RenderThread(stream, lock);
}

void RenderThread::forceStop() {
    if (m_stream) {
        m_stream->forceStop();
    } else if (mChannel) {
        mChannel->forceStop();
    }
}

intptr_t RenderThread::main() {
#ifdef __APPLE__
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    if (m_stream) {
        RenderThreadInfo info;
        ChecksumCalculatorThreadInfo tChecksumInfo;
        info.m_glDec.initGL(gles1_dispatch_get_proc_func, NULL);
        info.m_gl2Dec.initGL(gles2_dispatch_get_proc_func, NULL);
        initRenderControlContext(&info.m_rcDec);
        ReadBuffer buffer(256 * 1024);
        bool running = true;
        while (running && buffer.getData(m_stream) > 0) {
            while (buffer.validData() >= 8) {
                uint32_t size = 0;
                memcpy(&size, buffer.buf() + 4, 4);
                if (size < 8 || size > 64u * 1024 * 1024) {
                    running = false;
                    break;
                }
                if (buffer.validData() < size) {
                    break;
                }
                size_t used = info.m_glDec.decode(buffer.buf(), size, m_stream);
                if (!used) used = info.m_gl2Dec.decode(buffer.buf(), size, m_stream);
                if (!used) used = info.m_rcDec.decode(buffer.buf(), size, m_stream);
                if (used != size) {
                    uint32_t opcode = 0;
                    memcpy(&opcode, buffer.buf(), 4);
                    fprintf(stderr, "[emugl] GPU rejected packet: opcode=%u size=%u consumed=%zu\n",
                            opcode, size, used);
                    running = false;
                    break;
                }
                buffer.consume(used);
            }
        }
        m_stream->forceStop();
        if (FrameBuffer::getFB()) {
            FrameBuffer::getFB()->bindContext(0, 0, 0);
            FrameBuffer::getFB()->drainWindowSurface();
            FrameBuffer::getFB()->drainRenderContext();
        }
        return 0;
    }

    uint32_t flags = 0;
    if (mChannel->readFromGuest(reinterpret_cast<char*>(&flags),
                                sizeof(flags), true) != sizeof(flags)) {
        return 0;
    }

    if ((flags & IOSTREAM_CLIENT_EXIT_SERVER) == IOSTREAM_CLIENT_EXIT_SERVER) {
        // The old code had a separate server thread, this flag meant 'exit the
        // server thread'. It's not used anymore, but let's just make sure...
        if (auto renderer = mRenderer.lock()) {
            renderer->stop();
        }
        return 0;
    }

    std::unique_ptr<IOStream> stream(new ChannelStream(mChannel, 384));
    if (!stream) {
        return 0;
    }

    RenderThreadInfo tInfo;
    ChecksumCalculatorThreadInfo tChecksumInfo;

    //
    // initialize decoders
    //
    tInfo.m_glDec.initGL(gles1_dispatch_get_proc_func, NULL);
    tInfo.m_gl2Dec.initGL(gles2_dispatch_get_proc_func, NULL);
    initRenderControlContext(&tInfo.m_rcDec);

    ReadBuffer readBuf(STREAM_BUFFER_SIZE);

    int stats_totalBytes = 0;
    long long stats_t0 = GetCurrentTimeMS();

    //
    // open dump file if RENDER_DUMP_DIR is defined
    //
    const char* dump_dir = getenv("RENDERER_DUMP_DIR");
    FILE* dumpFP = NULL;
    if (dump_dir) {
        size_t bsize = strlen(dump_dir) + 32;
        char* fname = new char[bsize];
        snprintf(fname, bsize, "%s/stream_%p", dump_dir, this);
        dumpFP = fopen(fname, "wb");
        if (!dumpFP) {
            fprintf(stderr, "Warning: stream dump failed to open file %s\n",
                    fname);
        }
        delete[] fname;
    }

    while (1) {
        int stat = readBuf.getData(stream.get());
        if (stat <= 0) {
            break;
        }

        //
        // log received bandwidth statistics
        //
        stats_totalBytes += readBuf.validData();
        long long dt = GetCurrentTimeMS() - stats_t0;
        if (dt > 1000) {
            // float dts = (float)dt / 1000.0f;
            // printf("Used Bandwidth %5.3f MB/s\n", ((float)stats_totalBytes /
            // dts) / (1024.0f*1024.0f));
            stats_totalBytes = 0;
            stats_t0 = GetCurrentTimeMS();
        }

        //
        // dump stream to file if needed
        //
        if (dumpFP) {
            int skip = readBuf.validData() - stat;
            fwrite(readBuf.buf() + skip, 1, readBuf.validData() - skip, dumpFP);
            fflush(dumpFP);
        }

        bool progress;
        do {
            progress = false;

            // HACK: Disable render thread locks
            // This increases FPS for Antutu Garden about 2 FPS on
            // Linux Quadro K2200.
            // m_lock->lock();
            //
            // try to process some of the command buffer using the GLESv1
            // decoder
            //
            size_t last = tInfo.m_glDec.decode(
                    readBuf.buf(), readBuf.validData(), stream.get());
            if (last > 0) {
                progress = true;
                readBuf.consume(last);
            }

            //
            // try to process some of the command buffer using the GLESv2
            // decoder
            //
            last = tInfo.m_gl2Dec.decode(readBuf.buf(), readBuf.validData(),
                                         stream.get());
            if (last > 0) {
                progress = true;
                readBuf.consume(last);
            }

            //
            // try to process some of the command buffer using the
            // renderControl decoder
            //
            last = tInfo.m_rcDec.decode(readBuf.buf(), readBuf.validData(),
                                        stream.get());
            if (last > 0) {
                readBuf.consume(last);
                progress = true;
            }

            if (!progress && readBuf.validData() >= 8) {
                uint32_t opcode = 0, pktSize = 0;
                memcpy(&opcode, readBuf.buf(), sizeof(opcode));
                memcpy(&pktSize, readBuf.buf() + 4, sizeof(pktSize));
                if (readBuf.validData() >= pktSize) {
                    static std::atomic<int> s_unhandled_logs{0};
                    if (s_unhandled_logs.fetch_add(1, std::memory_order_relaxed) < 16) {
                        fprintf(stderr, "[emugl] RenderThread: unhandled opcode=%u size=%u valid=%zu\n",
                                opcode, pktSize, readBuf.validData());
                    }
                }
            }

        } while (progress);
    }

    if (dumpFP) {
        fclose(dumpFP);
    }

    //
    // Release references to the current thread's context/surfaces if any
    //
    FrameBuffer::getFB()->bindContext(0, 0, 0);
    if (tInfo.currContext || tInfo.currDrawSurf || tInfo.currReadSurf) {
        fprintf(stderr,
                "ERROR: RenderThread exiting with current context/surfaces\n");
    }

    FrameBuffer::getFB()->drainWindowSurface();

    FrameBuffer::getFB()->drainRenderContext();

    DBG("Exited a RenderThread\n");

    return 0;
}

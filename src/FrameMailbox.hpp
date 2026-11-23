#pragma once
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

namespace emu {

struct DirtyRect {
    uint32_t x = 0;
    uint32_t y = 0;
    uint32_t width = 0;
    uint32_t height = 0;
};

struct FrameStats {
    uint64_t submitted = 0;
    uint64_t consumed = 0;
    uint64_t replaced = 0;
    uint64_t bytesCopied = 0;
};

// Persistent BGRA backing store ported from Android_On_iOS.
// Coalesces dirty rectangles across dropped presentations without stalling the producer.
class FrameMailbox {
    uint32_t width_ = 0;
    uint32_t height_ = 0;
    std::vector<uint8_t> pixels_;
    mutable std::mutex mutex_;
    bool pending_ = false;
    DirtyRect dirty_{};
    FrameStats stats_{};

public:
    FrameMailbox(uint32_t width, uint32_t height);
    uint32_t width() const { return width_; }
    uint32_t height() const { return height_; }
    bool update(const uint8_t *source, size_t stride, DirtyRect rect);
    bool consume(void (*upload)(void *context, const uint8_t *pixels, size_t stride, DirtyRect dirty),
                 void *context);
    FrameStats stats() const;
};

} // namespace emu

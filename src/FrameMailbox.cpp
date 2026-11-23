#include "FrameMailbox.hpp"
#include <algorithm>
#include <cstring>

namespace emu {

FrameMailbox::FrameMailbox(uint32_t w, uint32_t h) : width_(w), height_(h) {
    if (w > 0 && h > 0 && w <= 4096 && h <= 4096) {
        pixels_.resize(static_cast<size_t>(w) * h * 4);
    } else {
        width_ = 0;
        height_ = 0;
    }
}

bool FrameMailbox::update(const uint8_t *source, size_t stride, DirtyRect r) {
    if (!source || width_ == 0 || height_ == 0 || r.width == 0 || r.height == 0) {
        return false;
    }
    if (r.x >= width_ || r.y >= height_ ||
        r.width > width_ - r.x || r.height > height_ - r.y ||
        stride < static_cast<size_t>(width_) * 4) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    const size_t rowBytes = static_cast<size_t>(r.width) * 4;
    for (uint32_t y = r.y; y < r.y + r.height; ++y) {
        std::memcpy(pixels_.data() + (static_cast<size_t>(y) * width_ + r.x) * 4,
                    source + static_cast<size_t>(y) * stride + static_cast<size_t>(r.x) * 4,
                    rowBytes);
    }
    stats_.bytesCopied += static_cast<uint64_t>(r.width) * r.height * 4;
    ++stats_.submitted;
    if (pending_) {
        ++stats_.replaced;
        const uint32_t nx = std::min(r.x, dirty_.x);
        const uint32_t ny = std::min(r.y, dirty_.y);
        const uint32_t mx = std::max(r.x + r.width, dirty_.x + dirty_.width);
        const uint32_t my = std::max(r.y + r.height, dirty_.y + dirty_.height);
        dirty_ = {nx, ny, mx - nx, my - ny};
    } else {
        dirty_ = r;
    }
    pending_ = true;
    return true;
}

bool FrameMailbox::consume(void (*upload)(void *context, const uint8_t *pixels, size_t stride, DirtyRect dirty),
                           void *context) {
    if (!upload || width_ == 0 || height_ == 0) {
        return false;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    if (!pending_) {
        return false;
    }
    upload(context, pixels_.data(), static_cast<size_t>(width_) * 4, dirty_);
    pending_ = false;
    ++stats_.consumed;
    return true;
}

FrameStats FrameMailbox::stats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return stats_;
}

} // namespace emu

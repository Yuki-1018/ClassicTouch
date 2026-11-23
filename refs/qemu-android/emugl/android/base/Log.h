#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <sstream>

namespace android {
namespace base {
struct NullStream {
    template <typename T> NullStream& operator<<(const T&) { return *this; }
};
struct FatalStream {
    std::ostringstream ss;
    ~FatalStream() {
        fprintf(stderr, "[emugl FATAL] %s\n", ss.str().c_str());
        abort();
    }
    template <typename T> FatalStream& operator<<(const T& v) { ss << v; return *this; }
};
struct ErrStream {
    std::ostringstream ss;
    ~ErrStream() {
        fprintf(stderr, "[emugl] %s\n", ss.str().c_str());
    }
    template <typename T> ErrStream& operator<<(const T& v) { ss << v; return *this; }
};
} // namespace base
} // namespace android

#define LOG(level) ::android::base::ErrStream()
#define DLOG(level) ::android::base::NullStream()
#define PLOG(level) ::android::base::ErrStream()
#define VLOG(level) ::android::base::NullStream()
#define CHECK(cond) do { if (!(cond)) { ::android::base::FatalStream() << #cond; } } while (0)
#define DCHECK(cond) ((void)(cond))

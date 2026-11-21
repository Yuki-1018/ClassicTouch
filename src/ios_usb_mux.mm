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

#import "ios_usb_mux.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

static constexpr uint8_t kUsbDirIn = 0x80;
static constexpr uint8_t kUsbFlagSetup = 1 << 0;
static constexpr uint8_t kUsbFlagReset = 1 << 1;
static constexpr uint8_t kUsbFlagEnumDone = 1 << 2;
static constexpr int16_t kUsbRetNak = -2;
static constexpr int16_t kUsbRetStall = -3;

static constexpr uint32_t kUsbMtu = 16384;
static constexpr uint32_t kDevMru = 65536;
static constexpr uint32_t kMuxProtoVersion = 0;
static constexpr uint32_t kMuxProtoControl = 1;
static constexpr uint32_t kMuxProtoSetup = 2;
static constexpr uint32_t kMuxProtoTcp = IPPROTO_TCP;
static constexpr uint32_t kMuxMagic = 0xfeedfaceu;

static constexpr uint8_t kThFin = 0x01;
static constexpr uint8_t kThSyn = 0x02;
static constexpr uint8_t kThRst = 0x04;
static constexpr uint8_t kThAck = 0x10;

#pragma pack(push, 1)
struct TcpUsbHeader {
    uint8_t addr;
    uint8_t ep;
    uint8_t flags;
    int16_t length;
};

struct MuxHeader {
    uint32_t protocol;
    uint32_t length;
    uint32_t magic;
    uint16_t tx_seq;
    uint16_t rx_seq;
};

struct MuxVersionHeader {
    uint32_t major;
    uint32_t minor;
    uint32_t padding;
};

struct MuxTcpHeader {
    uint16_t th_sport;
    uint16_t th_dport;
    uint32_t th_seq;
    uint32_t th_ack;
    uint8_t th_x2_off; // lower 4 unused, upper 4 data offset in 32-bit words
    uint8_t th_flags;
    uint16_t th_win;
    uint16_t th_sum;
    uint16_t th_urp;
};
#pragma pack(pop)

static_assert(sizeof(TcpUsbHeader) == 5, "TcpUsbHeader must be 5 bytes");
static_assert(sizeof(MuxHeader) == 16, "MuxHeader must be 16 bytes");
static_assert(sizeof(MuxTcpHeader) == 20, "MuxTcpHeader must be 20 bytes");

enum class ConnState {
    Connecting,
    Connected,
    Refused,
    Closed
};

struct MuxConn {
    uint16_t sport = 0;
    uint16_t dport = 0;
    ConnState state = ConnState::Connecting;
    int hostFd = -1; // paired with clientFd; mux thread owns hostFd
    uint32_t txSeq = 0;
    uint32_t txAck = 0;
    uint32_t txAcked = 0;
    uint32_t txWin = 131072;
    uint32_t rxSeq = 0;
    uint32_t rxAck = 0;
    uint32_t rxWin = 0;
    std::vector<uint8_t> inBuf; // guest -> host
    std::chrono::steady_clock::time_point lastAckTime;
    bool ackPending = false;
    bool teardownSent = false;
    std::atomic<bool> abandoned{false};

    std::mutex waitMu;
    std::condition_variable waitCv;
};

static void setNoSigPipe(int fd) {
#ifdef SO_NOSIGPIPE
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
#else
    (void)fd;
#endif
}

static bool setNonBlocking(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0;
}

static bool writeExactFd(int fd, const void *buf, size_t len, const std::atomic<bool> &stopping) {
    const uint8_t *p = static_cast<const uint8_t *>(buf);
    size_t sent = 0;
    while (sent < len && !stopping.load()) {
        ssize_t n = send(fd, p + sent, len - sent, 0);
        if (n > 0) {
            sent += size_t(n);
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            pollfd pfd{fd, POLLOUT, 0};
            if (poll(&pfd, 1, 100) < 0 && errno != EINTR) return false;
        } else {
            return false;
        }
    }
    return sent == len;
}

static bool readExactFd(int fd, void *buf, size_t len, const std::atomic<bool> &stopping) {
    uint8_t *p = static_cast<uint8_t *>(buf);
    size_t got = 0;
    while (got < len && !stopping.load()) {
        ssize_t n = recv(fd, p + got, len - got, 0);
        if (n > 0) {
            got += size_t(n);
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            pollfd pfd{fd, POLLIN, 0};
            if (poll(&pfd, 1, 100) < 0 && errno != EINTR) return false;
        } else {
            return false;
        }
    }
    return got == len;
}

} // namespace

struct IOSUsbMuxState {
    int listenFd = -1;
    uint16_t tcpPort = 0;
    std::atomic<bool> stopping{false};
    std::thread worker;

    // Active QEMU connection + device info
    int qemuFd = -1;
    uint8_t usbAddr = 0;
    uint8_t epIn = 0x81;
    uint8_t epOut = 0x02;
    uint16_t bulkMps = 512;
    int muxVersion = 0;
    uint16_t devTxSeq = 0;
    uint16_t devRxSeq = 0;

    std::atomic<bool> active{false};
    std::mutex infoMu;
    std::string udid;

    // Pending connects queued by client threads for mux thread to issue
    std::mutex reqMu;
    std::deque<std::shared_ptr<MuxConn>> pendingConnects;
    uint16_t nextSport = 1;
    std::map<uint32_t, std::shared_ptr<MuxConn>> conns; // key: (sport << 16) | dport

    void closeConn(const std::shared_ptr<MuxConn> &c, bool sendRst);
    bool usbPacket(uint8_t ep, uint8_t flags, const void *outData, int16_t len,
                   std::vector<uint8_t> *inData, int16_t *outLen);
    bool usbTransfer(uint8_t ep, uint8_t flags, const void *outData, int16_t len,
                     std::vector<uint8_t> *inData, int16_t *outLen, int timeoutMs);
    bool usbControl(uint8_t bmRequestType, uint8_t bRequest, uint16_t wValue,
                    uint16_t wIndex, uint16_t wLength, std::vector<uint8_t> *outPayload);
    bool enumerateQemu();
    bool sendMuxPacket(uint32_t proto, const void *hdr, size_t hdrLen,
                       const void *payload, size_t payloadLen);
    bool sendTcp(const std::shared_ptr<MuxConn> &c, uint8_t flags,
                 const void *payload, size_t payloadLen);
    void handleMuxInput(const uint8_t *buf, size_t len);
    void handleTcpInput(const MuxTcpHeader *th, const uint8_t *payload, size_t payloadLen);
    void run();
};

bool IOSUsbMuxState::usbPacket(uint8_t ep, uint8_t flags, const void *outData, int16_t len,
                               std::vector<uint8_t> *inData, int16_t *outLen) {
    if (qemuFd < 0 || stopping.load()) return false;
    TcpUsbHeader hdr{usbAddr, ep, flags, len};
    if (!writeExactFd(qemuFd, &hdr, sizeof(hdr), stopping)) return false;
    if ((ep & kUsbDirIn) == 0 && len > 0 && outData) {
        if (!writeExactFd(qemuFd, outData, size_t(len), stopping)) return false;
    }
    TcpUsbHeader reply{};
    if (!readExactFd(qemuFd, &reply, sizeof(reply), stopping)) return false;
    if (reply.addr != 0) usbAddr = reply.addr;
    if (reply.ep != ep) return false;
    if (outLen) *outLen = reply.length;
    if ((ep & kUsbDirIn) != 0 && reply.length > 0) {
        if (reply.length > len) return false;
        inData->resize(size_t(reply.length));
        if (!readExactFd(qemuFd, inData->data(), size_t(reply.length), stopping)) return false;
    } else if (inData) {
        inData->clear();
    }
    return true;
}

bool IOSUsbMuxState::usbTransfer(uint8_t ep, uint8_t flags, const void *outData, int16_t len,
                                 std::vector<uint8_t> *inData, int16_t *outLen, int timeoutMs) {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (!stopping.load()) {
        int16_t rlen = 0;
        if (!usbPacket(ep, flags, outData, len, inData, &rlen)) return false;
        if (rlen >= 0) {
            if (outLen) *outLen = rlen;
            return true;
        }
        if (rlen != kUsbRetNak) {
            if (outLen) *outLen = rlen;
            return false;
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            if (outLen) *outLen = rlen;
            return false;
        }
        usleep(1000);
    }
    return false;
}

bool IOSUsbMuxState::usbControl(uint8_t bmRequestType, uint8_t bRequest, uint16_t wValue,
                                uint16_t wIndex, uint16_t wLength, std::vector<uint8_t> *outPayload) {
    uint8_t setup[8] = {
        bmRequestType, bRequest,
        uint8_t(wValue & 0xff), uint8_t(wValue >> 8),
        uint8_t(wIndex & 0xff), uint8_t(wIndex >> 8),
        uint8_t(wLength & 0xff), uint8_t(wLength >> 8),
    };
    if (!usbTransfer(0, kUsbFlagSetup, setup, 8, nullptr, nullptr, 5000)) return false;
    if ((bmRequestType & kUsbDirIn) != 0) {
        std::vector<uint8_t> acc;
        while (acc.size() < wLength && !stopping.load()) {
            uint16_t want = uint16_t(std::min<size_t>(64, wLength - acc.size()));
            std::vector<uint8_t> chunk;
            int16_t got = 0;
            if (!usbTransfer(0x80, 0, nullptr, int16_t(want), &chunk, &got, 5000)) return false;
            acc.insert(acc.end(), chunk.begin(), chunk.end());
            if (got < 64) break;
        }
        if (!usbTransfer(0, 0, nullptr, 0, nullptr, nullptr, 5000)) return false;
        if (outPayload) *outPayload = std::move(acc);
        return true;
    }
    return usbTransfer(0x80, 0, nullptr, 0, nullptr, nullptr, 5000);
}

bool IOSUsbMuxState::enumerateQemu() {
    usbAddr = 0;
    epIn = 0x81;
    epOut = 0x02;
    bulkMps = 512;
    muxVersion = 0;
    devTxSeq = 0;
    devRxSeq = 0;

    if (!usbPacket(0, kUsbFlagReset, nullptr, 0, nullptr, nullptr)) return false;
    usleep(50000);
    if (!usbPacket(0, kUsbFlagEnumDone, nullptr, 0, nullptr, nullptr)) return false;
    usleep(50000);

    std::vector<uint8_t> devDesc;
    for (int attempt = 0; attempt < 20 && !stopping.load(); attempt++) {
        if (usbControl(0x80, 6, 0x0100, 0, 18, &devDesc) && devDesc.size() >= 18 && devDesc[1] == 1) {
            break;
        }
        devDesc.clear();
        usleep(100000);
    }
    if (devDesc.size() < 18) return false;

    uint8_t numCfg = devDesc[17];
    uint8_t iSerial = devDesc[16];

    if (!usbControl(0x00, 5, 1, 0, 0, nullptr)) return false;
    usleep(50000); // Allow DCFG address update in guest USB stack

    int muxCfgVal = -1;
    for (uint8_t ci = 0; ci < numCfg && !stopping.load(); ci++) {
        std::vector<uint8_t> cfgHdr;
        if (!usbControl(0x80, 6, uint16_t(0x0200 | ci), 0, 9, &cfgHdr) || cfgHdr.size() < 9) continue;
        uint16_t totalLen = uint16_t(cfgHdr[2] | (cfgHdr[3] << 8));
        if (totalLen < 9 || totalLen > 4096) continue;
        std::vector<uint8_t> cfg;
        if (!usbControl(0x80, 6, uint16_t(0x0200 | ci), 0, totalLen, &cfg) || cfg.size() < 9) continue;

        bool inMux = false;
        bool hasMux = false;
        uint8_t candIn = 0, candOut = 0;
        uint16_t candMps = 512;
        for (size_t i = 0; i + 1 < cfg.size() && cfg[i] >= 2; i += cfg[i]) {
            uint8_t dlen = cfg[i], dtype = cfg[i + 1];
            if (i + dlen > cfg.size()) break;
            if (dtype == 4 && dlen >= 9) {
                inMux = (cfg[i + 5] == 255 && cfg[i + 6] == 254 && cfg[i + 7] == 2);
                if (inMux) hasMux = true;
            } else if (dtype == 5 && dlen >= 7 && inMux) {
                uint8_t ep = cfg[i + 2];
                uint16_t mps = uint16_t(cfg[i + 4] | (cfg[i + 5] << 8));
                if (ep & kUsbDirIn) candIn = ep;
                else candOut = ep;
                if (mps > 0) candMps = mps;
            }
        }
        if (hasMux && candIn && candOut) {
            muxCfgVal = cfg[5];
            epIn = candIn;
            epOut = candOut;
            bulkMps = candMps;
            break;
        }
    }
    if (muxCfgVal < 0) return false;
    if (!usbControl(0x00, 9, uint16_t(muxCfgVal), 0, 0, nullptr)) return false;

    // Vendor charging power notification (matches built-in host behavior)
    (void)usbControl(0x40, 0x40, 500, 1600, 0, nullptr);

    if (iSerial > 0) {
        std::vector<uint8_t> str0, strSer;
        (void)usbControl(0x80, 6, 0x0300, 0, 255, &str0);
        if (usbControl(0x80, 6, uint16_t(0x0300 | iSerial), 0x0409, 255, &strSer) && strSer.size() >= 2) {
            std::string decoded;
            for (size_t i = 2; i + 1 < strSer.size(); i += 2) {
                if (strSer[i] >= 0x20 && strSer[i] < 0x7f) decoded.push_back(char(strSer[i]));
            }
            std::lock_guard<std::mutex> lk(infoMu);
            udid = decoded;
        }
    }

    MuxVersionHeader vh{htonl(2), htonl(0), 0};
    return sendMuxPacket(kMuxProtoVersion, &vh, sizeof(vh), nullptr, 0);
}

bool IOSUsbMuxState::sendMuxPacket(uint32_t proto, const void *hdr, size_t hdrLen,
                                   const void *payload, size_t payloadLen) {
    size_t muxHdrSize = (muxVersion < 2) ? 8 : sizeof(MuxHeader);
    size_t total = muxHdrSize + hdrLen + payloadLen;
    if (total > kUsbMtu) return false;

    std::vector<uint8_t> pkt(total, 0);
    MuxHeader *m = reinterpret_cast<MuxHeader *>(pkt.data());
    m->protocol = htonl(proto);
    m->length = htonl(uint32_t(total));
    if (muxVersion >= 2) {
        m->magic = htonl(kMuxMagic);
        if (proto == kMuxProtoSetup) {
            devTxSeq = 0;
            devRxSeq = 0xffff;
        }
        m->tx_seq = htons(devTxSeq++);
        m->rx_seq = htons(devRxSeq);
    }
    if (hdr && hdrLen) memcpy(pkt.data() + muxHdrSize, hdr, hdrLen);
    if (payload && payloadLen) memcpy(pkt.data() + muxHdrSize + hdrLen, payload, payloadLen);

    int16_t outLen = 0;
    if (!usbTransfer(epOut, 0, pkt.data(), int16_t(total), nullptr, &outLen, 5000)) return false;
    if (bulkMps > 0 && (total % bulkMps) == 0) {
        (void)usbTransfer(epOut, 0, nullptr, 0, nullptr, &outLen, 2000);
    }
    return true;
}

bool IOSUsbMuxState::sendTcp(const std::shared_ptr<MuxConn> &c, uint8_t flags,
                             const void *payload, size_t payloadLen) {
    MuxTcpHeader th{};
    th.th_sport = htons(c->sport);
    th.th_dport = htons(c->dport);
    th.th_seq = htonl(c->txSeq);
    th.th_ack = htonl(c->txAck);
    th.th_x2_off = uint8_t((sizeof(MuxTcpHeader) / 4) << 4);
    th.th_flags = flags;
    th.th_win = htons(uint16_t(c->txWin >> 8));
    if (!sendMuxPacket(kMuxProtoTcp, &th, sizeof(th), payload, payloadLen)) return false;
    c->txAcked = c->txAck;
    c->lastAckTime = std::chrono::steady_clock::now();
    c->ackPending = false;
    return true;
}

void IOSUsbMuxState::closeConn(const std::shared_ptr<MuxConn> &c, bool sendRst) {
    if (sendRst && !c->teardownSent && active.load() && c->state != ConnState::Refused && c->state != ConnState::Closed) {
        c->teardownSent = true;
        (void)sendTcp(c, kThRst, nullptr, 0);
    }
    if (c->hostFd >= 0) {
        close(c->hostFd);
        c->hostFd = -1;
    }
    {
        std::lock_guard<std::mutex> lk(c->waitMu);
        if (c->state == ConnState::Connecting) c->state = ConnState::Refused;
        else c->state = ConnState::Closed;
    }
    c->waitCv.notify_all();
    conns.erase((uint32_t(c->sport) << 16) | c->dport);
}

void IOSUsbMuxState::handleTcpInput(const MuxTcpHeader *th, const uint8_t *payload, size_t payloadLen) {
    uint16_t sport = ntohs(th->th_dport);
    uint16_t dport = ntohs(th->th_sport);
    uint32_t key = (uint32_t(sport) << 16) | dport;

    auto it = conns.find(key);
    if (it == conns.end()) {
        if ((th->th_flags & kThRst) == 0) {
            MuxTcpHeader rst{};
            rst.th_sport = htons(sport);
            rst.th_dport = htons(dport);
            rst.th_ack = th->th_seq;
            rst.th_x2_off = uint8_t((sizeof(MuxTcpHeader) / 4) << 4);
            rst.th_flags = kThRst;
            (void)sendMuxPacket(kMuxProtoTcp, &rst, sizeof(rst), nullptr, 0);
        }
        return;
    }

    auto c = it->second;
    c->rxSeq = ntohl(th->th_seq);
    c->rxAck = ntohl(th->th_ack);
    c->rxWin = uint32_t(ntohs(th->th_win)) << 8;

    if (c->state == ConnState::Connecting) {
        if ((th->th_flags & (kThSyn | kThAck)) == (kThSyn | kThAck) && !(th->th_flags & kThRst)) {
            c->txSeq++;
            c->txAck = c->rxSeq + 1;
            if (!sendTcp(c, kThAck, nullptr, 0)) {
                closeConn(c, false);
                return;
            }
            {
                std::lock_guard<std::mutex> lk(c->waitMu);
                c->state = ConnState::Connected;
            }
            c->waitCv.notify_all();
        } else {
            {
                std::lock_guard<std::mutex> lk(c->waitMu);
                c->state = ConnState::Refused;
            }
            c->waitCv.notify_all();
            closeConn(c, false);
        }
        return;
    }

    if (c->state == ConnState::Connected) {
        if (payloadLen > 0) {
            c->inBuf.insert(c->inBuf.end(), payload, payload + payloadLen);
            c->txAck += uint32_t(payloadLen);
            c->ackPending = true;
        }
        if ((th->th_flags & (kThRst | kThFin)) != 0) {
            // Flush whatever payload just arrived before tearing down hostFd.
            if (!c->inBuf.empty() && c->hostFd >= 0) {
                size_t total = c->inBuf.size(), off = 0;
                while (off < total) {
                    ssize_t w = send(c->hostFd, c->inBuf.data() + off, total - off, 0);
                    if (w > 0) off += size_t(w);
                    else break;
                }
                c->inBuf.clear();
            }
            if ((th->th_flags & kThFin) && !(th->th_flags & kThRst)) {
                c->txAck++;
                (void)sendTcp(c, kThAck, nullptr, 0);
            }
            closeConn(c, false);
            return;
        }
        if (c->ackPending) {
            (void)sendTcp(c, kThAck, nullptr, 0);
        }
    }
}

void IOSUsbMuxState::handleMuxInput(const uint8_t *buf, size_t len) {
    if (len < 8) return;
    const MuxHeader *mhdr = reinterpret_cast<const MuxHeader *>(buf);
    uint32_t proto = ntohl(mhdr->protocol);
    uint32_t expected = ntohl(mhdr->length);
    if (expected != len) return;

    size_t muxHdrSize = (muxVersion < 2) ? 8 : sizeof(MuxHeader);
    if (len < muxHdrSize) return;
    if (muxVersion >= 2) {
        devRxSeq = ntohs(mhdr->rx_seq);
    }

    if (proto == kMuxProtoVersion) {
        if (len < muxHdrSize + sizeof(MuxVersionHeader)) return;
        const auto *vh = reinterpret_cast<const MuxVersionHeader *>(buf + muxHdrSize);
        uint32_t major = ntohl(vh->major);
        if (major != 1 && major != 2) return;
        muxVersion = int(major);
        if (muxVersion >= 2) {
            const uint8_t setupByte = 0x07;
            (void)sendMuxPacket(kMuxProtoSetup, nullptr, 0, &setupByte, 1);
        }
        active.store(true);
    } else if (proto == kMuxProtoControl) {
        // Control messages (log/warning) ignored cleanly
    } else if (proto == kMuxProtoTcp) {
        if (len < muxHdrSize + sizeof(MuxTcpHeader)) return;
        const auto *th = reinterpret_cast<const MuxTcpHeader *>(buf + muxHdrSize);
        const uint8_t *payload = buf + muxHdrSize + sizeof(MuxTcpHeader);
        size_t payloadLen = len - muxHdrSize - sizeof(MuxTcpHeader);
        handleTcpInput(th, payload, payloadLen);
    }
}

void IOSUsbMuxState::run() {
    while (!stopping.load()) {
        pollfd lpfd{listenFd, POLLIN, 0};
        int pr = poll(&lpfd, 1, 100);
        if (pr <= 0) continue;

        int client = accept(listenFd, nullptr, nullptr);
        if (client < 0) continue;
        int one = 1;
        setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
        setNoSigPipe(client);
        qemuFd = client;

        if (!enumerateQemu()) {
            close(qemuFd);
            qemuFd = -1;
            active.store(false);
            continue;
        }

        std::vector<uint8_t> pktBuf;
        uint32_t maxPayload = kUsbMtu - uint32_t(sizeof(MuxHeader)) - uint32_t(sizeof(MuxTcpHeader));
        auto lastPoll = std::chrono::steady_clock::now();

        while (!stopping.load() && qemuFd >= 0) {
            // 1. Drain any pending connect requests
            std::deque<std::shared_ptr<MuxConn>> newReqs;
            {
                std::lock_guard<std::mutex> lk(reqMu);
                newReqs.swap(pendingConnects);
            }
            for (auto &c : newReqs) {
                if (c->abandoned.load()) {
                    closeConn(c, false);
                    continue;
                }
                uint16_t sport = nextSport++;
                if (nextSport == 0) nextSport = 1;
                c->sport = sport;
                conns[(uint32_t(c->sport) << 16) | c->dport] = c;
                if (!active.load() || !sendTcp(c, kThSyn, nullptr, 0)) {
                    closeConn(c, false);
                }
            }

            // 2. Poll bulk IN endpoint to drive guest -> host traffic & keep USB alive
            std::vector<uint8_t> rxChunk;
            int16_t rlen = 0;
            bool ok = usbPacket(epIn, 0, nullptr, int16_t(kUsbMtu), &rxChunk, &rlen);
            if (!ok) {
                break;
            }
            bool hadTraffic = false;
            if (rlen > 0) {
                hadTraffic = true;
                pktBuf.insert(pktBuf.end(), rxChunk.begin(), rxChunk.end());
                if (pktBuf.size() > kDevMru) {
                    pktBuf.clear();
                }
                while (pktBuf.size() >= 8) {
                    const MuxHeader *m = reinterpret_cast<const MuxHeader *>(pktBuf.data());
                    uint32_t totalLen = ntohl(m->length);
                    if (totalLen < 8 || totalLen > kDevMru) {
                        pktBuf.clear();
                        break;
                    }
                    if (pktBuf.size() < totalLen) {
                        break;
                    }
                    handleMuxInput(pktBuf.data(), totalLen);
                    pktBuf.erase(pktBuf.begin(), pktBuf.begin() + totalLen);
                }
            }

            // 3. Pump connected sockets <-> MUX_PROTO_TCP
            std::vector<std::shared_ptr<MuxConn>> toPump;
            toPump.reserve(conns.size());
            for (auto &kv : conns) toPump.push_back(kv.second);

            for (auto &c : toPump) {
                if (c->abandoned.load()) {
                    closeConn(c, c->state == ConnState::Connected);
                    continue;
                }
                if (c->state != ConnState::Connected || c->hostFd < 0) continue;

                // Flush guest->host bytes
                if (!c->inBuf.empty()) {
                    ssize_t w = send(c->hostFd, c->inBuf.data(), c->inBuf.size(), 0);
                    if (w > 0) {
                        hadTraffic = true;
                        c->inBuf.erase(c->inBuf.begin(), c->inBuf.begin() + w);
                    } else if (w < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                        closeConn(c, true);
                        continue;
                    }
                }

                // Read host->guest bytes if window permits
                uint32_t sentInFlight = c->txSeq - c->rxAck;
                uint32_t sendable = (c->rxWin > sentInFlight) ? (c->rxWin - sentInFlight) : 0;
                uint32_t cap = std::min<uint32_t>(sendable, maxPayload);
                if (cap > 0) {
                    std::vector<uint8_t> out(cap);
                    ssize_t r = recv(c->hostFd, out.data(), cap, 0);
                    if (r > 0) {
                        hadTraffic = true;
                        if (!sendTcp(c, kThAck, out.data(), size_t(r))) {
                            closeConn(c, false);
                            break;
                        }
                        c->txSeq += uint32_t(r);
                    } else if (r == 0) {
                        closeConn(c, true);
                        continue;
                    } else if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                        closeConn(c, true);
                        continue;
                    }
                }

                if (c->ackPending) {
                    auto now = std::chrono::steady_clock::now();
                    if (now - c->lastAckTime >= std::chrono::milliseconds(20)) {
                        (void)sendTcp(c, kThAck, nullptr, 0);
                    }
                }
            }

            if (!hadTraffic) {
                auto now = std::chrono::steady_clock::now();
                auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(now - lastPoll).count();
                bool idle = conns.empty();
                {
                    std::lock_guard<std::mutex> lk(reqMu);
                    if (!pendingConnects.empty()) idle = false;
                }
                if (elapsed < (idle ? 20 : 4)) usleep(idle ? 20000 : 1500);
                lastPoll = std::chrono::steady_clock::now();
            } else {
                lastPoll = std::chrono::steady_clock::now();
            }
        }

        // Connection closed: tear down all guest connections cleanly
        active.store(false);
        std::vector<std::shared_ptr<MuxConn>> remaining;
        for (auto &kv : conns) remaining.push_back(kv.second);
        for (auto &c : remaining) closeConn(c, false);
        {
            std::lock_guard<std::mutex> lk(reqMu);
            while (!pendingConnects.empty()) {
                auto c = pendingConnects.front();
                pendingConnects.pop_front();
                if (c->hostFd >= 0) close(c->hostFd);
                c->hostFd = -1;
                std::lock_guard<std::mutex> wlk(c->waitMu);
                c->state = ConnState::Refused;
                c->waitCv.notify_all();
            }
        }
        if (qemuFd >= 0) {
            close(qemuFd);
            qemuFd = -1;
        }
    }
}

@interface IOSUsbMuxBridge () {
    std::unique_ptr<IOSUsbMuxState> _state;
}
@property (nonatomic, readwrite, copy) NSString *tcpAddress;
@end

@implementation IOSUsbMuxBridge

+ (nullable instancetype)startWithError:(NSError * _Nullable * _Nullable)error {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOSUsbMuxBridge" code:errno userInfo:@{NSLocalizedDescriptionKey: @"Failed to create USB bridge socket"}];
        }
        return nil;
    }

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;

    if (bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0 || listen(fd, 4) != 0) {
        int e = errno;
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:@"IOSUsbMuxBridge" code:e userInfo:@{NSLocalizedDescriptionKey: @"Failed to bind USB bridge port"}];
        }
        return nil;
    }

    socklen_t len = sizeof(addr);
    if (getsockname(fd, reinterpret_cast<sockaddr *>(&addr), &len) != 0) {
        int e = errno;
        close(fd);
        if (error) {
            *error = [NSError errorWithDomain:@"IOSUsbMuxBridge" code:e userInfo:@{NSLocalizedDescriptionKey: @"getsockname failed"}];
        }
        return nil;
    }

    uint16_t port = ntohs(addr.sin_port);
    IOSUsbMuxBridge *bridge = [[IOSUsbMuxBridge alloc] init];
    bridge->_state = std::make_unique<IOSUsbMuxState>();
    bridge->_state->listenFd = fd;
    bridge->_state->tcpPort = port;
    bridge.tcpAddress = [NSString stringWithFormat:@"127.0.0.1:%u", port];
    bridge->_state->worker = std::thread([s = bridge->_state.get()] { s->run(); });
    return bridge;
}

- (BOOL)deviceAttached {
    return _state && _state->active.load();
}

- (NSString *)deviceUDID {
    if (!_state) return nil;
    std::lock_guard<std::mutex> lk(_state->infoMu);
    if (_state->udid.empty()) return nil;
    return [NSString stringWithUTF8String:_state->udid.c_str()];
}

- (int)connectToGuestPort:(uint16_t)port timeout:(NSTimeInterval)timeout error:(NSError * _Nullable * _Nullable)error {
    if (!_state || !_state->active.load()) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOSUsbMuxBridge" code:ENOTCONN userInfo:@{NSLocalizedDescriptionKey: @"仮想iPhoneのUSB接続がまだ確立されていません。起動完了後にもう一度お試しください。"}];
        }
        return -1;
    }

    int fds[2] = {-1, -1};
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"IOSUsbMuxBridge" code:errno userInfo:@{NSLocalizedDescriptionKey: @"内部ソケットの作成に失敗しました"}];
        }
        return -1;
    }
    setNoSigPipe(fds[0]);
    setNoSigPipe(fds[1]);
    setNonBlocking(fds[0]);

    // Give caller synchronous timeouts on client fd (fds[1])
    int secs = std::max<int>(1, int(timeout));
    timeval tv{secs, 0};
    setsockopt(fds[1], SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fds[1], SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    auto conn = std::make_shared<MuxConn>();
    conn->dport = port;
    conn->hostFd = fds[0];

    {
        std::lock_guard<std::mutex> lk(_state->reqMu);
        _state->pendingConnects.push_back(conn);
    }

    std::unique_lock<std::mutex> lk(conn->waitMu);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(std::max<int>(500, int(timeout * 1000)));
    conn->waitCv.wait_until(lk, deadline, [&] {
        return conn->state != ConnState::Connecting || _state->stopping.load();
    });

    if (conn->state != ConnState::Connected) {
        conn->abandoned.store(true);
        close(fds[1]);
        if (error) {
            *error = [NSError errorWithDomain:@"IOSUsbMuxBridge"
                                         code:ECONNREFUSED
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"usbmux_err_guest_port_connect", nil), port]}];
        }
        return -1;
    }
    return fds[1];
}

- (void)stop {
    if (_state) {
        _state->stopping.store(true);
        if (_state->listenFd >= 0) {
            shutdown(_state->listenFd, SHUT_RDWR);
            close(_state->listenFd);
            _state->listenFd = -1;
        }
        if (_state->worker.joinable()) {
            _state->worker.join();
        }
        _state.reset();
    }
}

- (void)dealloc {
    [self stop];
}

@end

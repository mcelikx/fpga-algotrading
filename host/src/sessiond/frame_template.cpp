// =============================================================================
// frame_template.cpp — build the byte-exact frame the fabric splices into
// -----------------------------------------------------------------------------
// See frame_template.hpp for the layout contract, the patched-field list, and
// the hazards. No exceptions, no allocation on any path except describe().
// =============================================================================
#include "trading/sessiond/frame_template.hpp"

#include <cstdio>
#include <cstring>

namespace trading::sessiond {
namespace {

void put8(std::span<std::uint8_t> b, std::size_t off, std::uint8_t v) noexcept {
    b[off] = v;
}

// Big-endian stores. The wire is big-endian; we convert here, once, at the
// boundary, and nowhere else.
void putBe16(std::span<std::uint8_t> b, std::size_t off, std::uint16_t v) noexcept {
    b[off]     = static_cast<std::uint8_t>(v >> 8);
    b[off + 1] = static_cast<std::uint8_t>(v);
}

void putBe32(std::span<std::uint8_t> b, std::size_t off, std::uint32_t v) noexcept {
    b[off]     = static_cast<std::uint8_t>(v >> 24);
    b[off + 1] = static_cast<std::uint8_t>(v >> 16);
    b[off + 2] = static_cast<std::uint8_t>(v >> 8);
    b[off + 3] = static_cast<std::uint8_t>(v);
}

}  // namespace

// -----------------------------------------------------------------------------
// Checksum arithmetic
// -----------------------------------------------------------------------------
std::uint32_t onesSum(std::span<const std::uint8_t> bytes, unsigned start_parity) noexcept {
    std::uint32_t acc = 0;
    for (std::size_t i = 0; i < bytes.size(); ++i) {
        const unsigned parity = (start_parity + static_cast<unsigned>(i)) & 1U;
        // parity 0 -> the byte is the HIGH half of its 16-bit word.
        acc += parity ? static_cast<std::uint32_t>(bytes[i])
                      : static_cast<std::uint32_t>(bytes[i]) << 8;
    }
    return acc;
}

std::uint16_t onesFold(std::uint32_t acc) noexcept {
    acc = (acc & 0xFFFFU) + (acc >> 16);
    acc = (acc & 0xFFFFU) + (acc >> 16);   // the second fold can only add a 1
    return static_cast<std::uint16_t>(acc);
}

// -----------------------------------------------------------------------------
// CRC32 (IEEE 802.3, reflected)
// -----------------------------------------------------------------------------
namespace {

struct Crc32Table {
    std::uint32_t t[256]{};
    constexpr Crc32Table() {
        for (std::uint32_t i = 0; i < 256; ++i) {
            std::uint32_t c = i;
            for (int k = 0; k < 8; ++k) {
                c = (c & 1U) ? (0xEDB88320U ^ (c >> 1)) : (c >> 1);
            }
            t[i] = c;
        }
    }
};
constexpr Crc32Table kCrcTable{};

}  // namespace

std::uint32_t crc32Ieee(std::span<const std::uint8_t> bytes) noexcept {
    std::uint32_t crc = 0xFFFFFFFFU;
    for (const std::uint8_t b : bytes) {
        crc = kCrcTable.t[(crc ^ b) & 0xFFU] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFU;
}

std::uint32_t crc32IeeeWords(std::span<const std::uint32_t> words) noexcept {
    // Words are serialised little-endian: exactly the byte sequence the host
    // wrote through SESS_TMPL_DATA (cfg_tmpl_data[7:0] is the first byte).
    std::uint32_t crc = 0xFFFFFFFFU;
    for (const std::uint32_t w : words) {
        for (int s = 0; s < 32; s += 8) {
            const auto b = static_cast<std::uint8_t>(w >> s);
            crc = kCrcTable.t[(crc ^ b) & 0xFFU] ^ (crc >> 8);
        }
    }
    return crc ^ 0xFFFFFFFFU;
}

// -----------------------------------------------------------------------------
// FrameTemplate
// -----------------------------------------------------------------------------
trading::expected<FrameTemplate, SessionError> FrameTemplate::build(
        const FrameTemplateParams& p) noexcept {
    const MacAddress zero_mac{};
    if (p.src_mac == zero_mac || p.dst_mac == zero_mac || p.src_ip == 0 || p.dst_ip == 0 ||
        p.src_port == 0 || p.dst_port == 0 || p.tcp_window == 0) {
        // ⚠️ Every one of these produces a frame the venue discards without a
        //    word. Refuse at build time; there is no partially-valid template.
        return trading::fail(SessionError::InvalidConfig);
    }

    FrameTemplate t;
    t.params_ = p;
    auto b = std::span<std::uint8_t>(t.bytes_.data(), t.bytes_.size());

    // ── Ethernet ─────────────────────────────────────────────────────────────
    std::memcpy(b.data() + kOffEthDmac, p.dst_mac.data(), p.dst_mac.size());
    std::memcpy(b.data() + kOffEthSmac, p.src_mac.data(), p.src_mac.size());
    putBe16(b, kOffEthType, kEtherTypeIpv4);

    // ── IPv4 ─────────────────────────────────────────────────────────────────
    // IHL is 5 and stays 5. An IP option would shift every offset below it and
    // is a change-control event, not something the fabric absorbs
    // (manuals/02-networking/02-ip-udp-tcp-in-hardware.md §2).
    put8(b, kOffIpVerIhl, kIpVerIhlV4);
    put8(b, kOffIpDscp, p.ip_dscp);
    putBe16(b, kOffIpTotLen, 0);          // PATCHED by the fabric -> stored ZERO
    putBe16(b, kOffIpId, 0);              // PATCHED
    putBe16(b, kOffIpFlags, kIpFlagsDf);  // Don't Fragment; our frames are ~121 B
    put8(b, kOffIpTtl, p.ip_ttl);
    put8(b, kOffIpProto, kIpProtoTcp);
    putBe16(b, kOffIpCsum, 0);            // PATCHED
    putBe32(b, kOffIpSrc, p.src_ip);
    putBe32(b, kOffIpDst, p.dst_ip);

    // ── TCP ──────────────────────────────────────────────────────────────────
    putBe16(b, kOffTcpSport, p.src_port);
    putBe16(b, kOffTcpDport, p.dst_port);
    putBe32(b, kOffTcpSeq, 0);            // PATCHED
    putBe32(b, kOffTcpAck, 0);            // PATCHED
    put8(b, kOffTcpOffRsv, kTcpOffRsv5);
    put8(b, kOffTcpFlags, kTcpFlagsPshAck);
    putBe16(b, kOffTcpWin, p.tcp_window);
    putBe16(b, kOffTcpCsum, 0);           // PATCHED
    putBe16(b, kOffTcpUrg, 0);

    // ── SoupBinTCP framing prefix ────────────────────────────────────────────
    putBe16(b, kOffSoupLen, 0);           // PATCHED (ouch_len + kLengthBias)
    put8(b, kOffSoupType, static_cast<std::uint8_t>(soup::PacketType::UnsequencedData));

    // bytes_[57..59] stay zero: pad so the image is a whole number of words.

    // ── Partial checksums ────────────────────────────────────────────────────
    // IP: the whole header with total length / identification / checksum zeroed.
    // The fabric adds total_length + ip_id, folds, complements.
    t.ip_partial_ = onesFold(onesSum(
            std::span<const std::uint8_t>(t.bytes_.data() + kOffIpVerIhl, kIp4HdrLen),
            kOffIpVerIhl & 1U));

    // TCP: the pseudo-header's CONSTANT part (src IP, dst IP, {0x00, proto}) plus
    // the TCP header with seq/ack/checksum zeroed plus the Soup header with its
    // length zeroed. Excluded because they vary per order: the pseudo-header TCP
    // length word, seq, ack, the Soup length word, and the OUCH body.
    //
    // ⚠️ PARITY. kOffIpSrc (26), kOffTcpSport (34) and kOffSoupLen (54) are all
    //    even, and the pseudo-header is 12 bytes, so absolute byte parity in
    //    this buffer equals checksum-region parity for every span below. The
    //    static_asserts in the header pin that down. Get it backwards and every
    //    order is silently dropped by the venue.
    std::uint32_t acc = 0;
    acc += onesSum(std::span<const std::uint8_t>(t.bytes_.data() + kOffIpSrc, 8),
                   kOffIpSrc & 1U);                       // src IP + dst IP
    acc += static_cast<std::uint32_t>(kIpProtoTcp);       // {0x00, proto}
    acc += onesSum(std::span<const std::uint8_t>(t.bytes_.data() + kOffTcpSport, kTcpHdrLen),
                   kOffTcpSport & 1U);
    acc += onesSum(std::span<const std::uint8_t>(t.bytes_.data() + kOffSoupLen,
                                                 soup::kHeaderBytes),
                   kOffSoupLen & 1U);
    t.tcp_partial_ = onesFold(acc);

    // ── Word image ───────────────────────────────────────────────────────────
    for (std::size_t w = 0; w < kFrameHdrWords; ++w) {
        const std::size_t o = w * 4;
        t.words_[w] = static_cast<std::uint32_t>(t.bytes_[o]) |
                      (static_cast<std::uint32_t>(t.bytes_[o + 1]) << 8) |
                      (static_cast<std::uint32_t>(t.bytes_[o + 2]) << 16) |
                      (static_cast<std::uint32_t>(t.bytes_[o + 3]) << 24);
    }
    t.words_[kMetaTcpCsum] = t.tcp_partial_;
    t.words_[kMetaIpCsum]  = t.ip_partial_;
    t.words_[kMetaEpoch]   = p.session_epoch;
    // ⚠️ The valid bit is written LAST by SessionRegisters::writeFrameTemplate()
    //    so a half-written template can never emit. It is set in the image here
    //    only so the CRC covers its final value.
    t.words_[kMetaFlags]   = kMetaFlagValid;
    t.words_[kMetaRsvd]    = 0;

    return t;
}

std::uint32_t FrameTemplate::crc32() const noexcept {
    return crc32IeeeWords(std::span<const std::uint32_t>(words_.data(), words_.size()));
}

std::uint16_t FrameTemplate::finishTcpChecksum(std::uint16_t partial,
                                               std::uint32_t seq,
                                               std::uint32_t ack,
                                               std::uint16_t tcp_len_pseudo,
                                               std::uint16_t soup_len,
                                               std::uint32_t ouch_partial) noexcept {
    std::uint32_t acc = partial;
    acc += (seq >> 16) & 0xFFFFU;
    acc += seq & 0xFFFFU;
    acc += (ack >> 16) & 0xFFFFU;
    acc += ack & 0xFFFFU;
    acc += tcp_len_pseudo;   // pseudo-header TCP length
    acc += soup_len;         // the Soup length FIELD, at an even payload offset
    acc += ouch_partial;     // ouch_encoder.sv m_csum, unfolded, payload parity
    // ⚠️ 0x0000 is a legal TCP checksum. Do NOT substitute 0xFFFF (that rule is
    //    UDP's, and applying it here corrupts a legal frame).
    return static_cast<std::uint16_t>(~onesFold(acc));
}

std::uint16_t FrameTemplate::finishIpChecksum(std::uint16_t partial,
                                              std::uint16_t total_length,
                                              std::uint16_t ip_id) noexcept {
    std::uint32_t acc = partial;
    acc += total_length;
    acc += ip_id;
    return static_cast<std::uint16_t>(~onesFold(acc));
}

std::size_t FrameTemplate::buildReferenceFrame(std::span<std::uint8_t> out,
                                               std::span<const std::uint8_t> ouch_msg,
                                               std::uint32_t seq,
                                               std::uint32_t ack,
                                               std::uint16_t ip_id) const noexcept {
    const std::size_t frame_len = kFrameHdrLen + ouch_msg.size();
    if (out.size() < frame_len || ouch_msg.empty()) {
        return 0;
    }
    std::memcpy(out.data(), bytes_.data(), kFrameHdrLen);
    std::memcpy(out.data() + kFrameHdrLen, ouch_msg.data(), ouch_msg.size());

    const auto ip_total = static_cast<std::uint16_t>(kIp4HdrLen + kTcpHdrLen +
                                                     soup::kHeaderBytes + ouch_msg.size());
    const auto soup_len = static_cast<std::uint16_t>(ouch_msg.size() + soup::kLengthBias);
    const auto tcp_len  = static_cast<std::uint16_t>(kTcpHdrLen + soup::kHeaderBytes +
                                                     ouch_msg.size());

    putBe16(out, kOffIpTotLen, ip_total);
    putBe16(out, kOffIpId, ip_id);
    putBe32(out, kOffTcpSeq, seq);
    putBe32(out, kOffTcpAck, ack);
    putBe16(out, kOffSoupLen, soup_len);

    // Recompute BOTH checksums from scratch over the finished frame. This is
    // deliberately NOT the incremental path — comparing the two is the whole
    // point of this function.
    putBe16(out, kOffIpCsum, 0);
    const std::uint16_t ip_csum = static_cast<std::uint16_t>(
            ~onesFold(onesSum(out.subspan(kOffIpVerIhl, kIp4HdrLen), kOffIpVerIhl & 1U)));
    putBe16(out, kOffIpCsum, ip_csum);

    putBe16(out, kOffTcpCsum, 0);
    std::uint32_t acc = 0;
    acc += onesSum(out.subspan(kOffIpSrc, 8), kOffIpSrc & 1U);
    acc += static_cast<std::uint32_t>(kIpProtoTcp);
    acc += tcp_len;
    acc += onesSum(out.subspan(kOffTcpSport, kTcpHdrLen + soup::kHeaderBytes + ouch_msg.size()),
                   kOffTcpSport & 1U);
    putBe16(out, kOffTcpCsum, static_cast<std::uint16_t>(~onesFold(acc)));

    return frame_len;
}

std::string FrameTemplate::describe() const {
    char buf[320];
    const int n = std::snprintf(
            buf, sizeof(buf),
            "frame_template{epoch=%u src=%s:%u dst=%s:%u "
            "dmac=%02x:%02x:%02x:%02x:%02x:%02x ttl=%u win=%u "
            "hdr_bytes=%zu words=%zu tcp_partial=0x%04x ip_partial=0x%04x crc32=0x%08x}",
            static_cast<unsigned>(params_.session_epoch),
            formatIpv4(params_.src_ip).c_str(), static_cast<unsigned>(params_.src_port),
            formatIpv4(params_.dst_ip).c_str(), static_cast<unsigned>(params_.dst_port),
            params_.dst_mac[0], params_.dst_mac[1], params_.dst_mac[2],
            params_.dst_mac[3], params_.dst_mac[4], params_.dst_mac[5],
            static_cast<unsigned>(params_.ip_ttl), static_cast<unsigned>(params_.tcp_window),
            kFrameHdrLen, kTemplateWords,
            static_cast<unsigned>(tcp_partial_), static_cast<unsigned>(ip_partial_),
            crc32());
    return (n > 0) ? std::string(buf, static_cast<std::size_t>(n)) : std::string{};
}

}  // namespace trading::sessiond

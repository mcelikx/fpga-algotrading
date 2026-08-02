// =============================================================================
// session_state.cpp — string forms for the sessiond state/error enums
// -----------------------------------------------------------------------------
// These strings land in the audit log and in operator alerts. They are stable
// identifiers, not prose: do not reword them casually, something greps for them.
// =============================================================================
#include "trading/sessiond/session_state.hpp"

namespace trading::sessiond {

// NOTE: toString(SessionState) is NOT defined here. It lives in
// trading/types.hpp alongside the enum, and is found by ADL.

std::string_view toString(SessionError e) noexcept {
    switch (e) {
        case SessionError::None:                   return "none";
        case SessionError::NotConfigured:          return "not-configured";
        case SessionError::InvalidConfig:          return "invalid-config";
        case SessionError::SocketError:            return "socket-error";
        case SessionError::ConnectTimeout:         return "connect-timeout";
        case SessionError::PeerClosed:             return "peer-closed";
        case SessionError::SendOwnerViolation:     return "send-owner-violation";
        case SessionError::SeqStateUnavailable:    return "tcp-seq-state-unavailable";
        case SessionError::LoginTimeout:           return "login-timeout";
        case SessionError::LoginRejectedAuth:      return "login-rejected-not-authorized";
        case SessionError::LoginRejectedSession:   return "login-rejected-session-unavailable";
        case SessionError::LoginRejectedUnknown:   return "login-rejected-unknown";
        case SessionError::ReceiveTimeout:         return "receive-timeout";
        case SessionError::EndOfSession:           return "end-of-session";
        case SessionError::MalformedPacket:        return "malformed-packet";
        case SessionError::UnexpectedPacket:       return "unexpected-packet";
        case SessionError::WrongState:             return "wrong-state";
        case SessionError::SequenceGap:            return "sequence-gap";
        case SessionError::SequenceFault:          return "sequence-fault";
        case SessionError::DeviceIo:               return "device-io";
        case SessionError::TemplateVerifyMismatch: return "template-verify-mismatch";
        case SessionError::TemplateCrcMismatch:    return "template-crc-mismatch";
        case SessionError::FabricStateMismatch:    return "fabric-state-mismatch";
        case SessionError::LinkDown:               return "link-down";
        case SessionError::ControlPlaneRefused:    return "control-plane-refused";
        case SessionError::BufferOverflow:         return "rx-buffer-overflow";
    }
    return "unknown";
}

bool requiresOperator(SessionError e) noexcept {
    switch (e) {
        // ⚠️ Retrying a rejected login burns attempts against the venue and can
        //    lock the account. A human looks at this, not a retry loop.
        case SessionError::LoginRejectedAuth:
        case SessionError::LoginRejectedUnknown:
        // ⚠️ An unrecoverable sequence fault means our view of our own orders is
        //    wrong. Trading again before a human has reconciled is how a bad
        //    morning becomes a bad year. Maps to kill_src_e KILL_SEQ_FAULT.
        case SessionError::SequenceFault:
        // Fabric disagreements are never "retry and hope".
        case SessionError::TemplateCrcMismatch:
        case SessionError::TemplateVerifyMismatch:
        case SessionError::FabricStateMismatch:
        case SessionError::SendOwnerViolation:
        case SessionError::NotConfigured:
        case SessionError::InvalidConfig:
        case SessionError::ControlPlaneRefused:
            return true;
        default:
            return false;
    }
}

std::string_view toString(ResyncReason r) noexcept {
    switch (r) {
        case ResyncReason::Startup:         return "startup";
        case ResyncReason::TcpClosed:       return "tcp-closed";
        case ResyncReason::ReceiveTimeout:  return "receive-timeout";
        case ResyncReason::LoginRejected:   return "login-rejected";
        case ResyncReason::SequenceGap:     return "sequence-gap";
        case ResyncReason::SequenceFault:   return "sequence-fault";
        case ResyncReason::EndOfSession:    return "end-of-session";
        case ResyncReason::LinkDown:        return "link-down";
        case ResyncReason::TemplateFault:   return "template-fault";
        case ResyncReason::OperatorRequest: return "operator-request";
    }
    return "unknown";
}

std::string_view toString(SendOwner o) noexcept {
    switch (o) {
        case SendOwner::Host:   return "host";
        case SendOwner::Fabric: return "fabric";
    }
    return "invalid";
}

}  // namespace trading::sessiond

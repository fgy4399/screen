import Foundation
import WebRTC

protocol WhepPlayerDelegate: AnyObject {
    func whepPlayer(_ player: WhepPlayer, didChangeStatus status: String)
    func whepPlayer(_ player: WhepPlayer, didFailWith error: Error)
}

final class WhepPlayer: NSObject {
    weak var delegate: WhepPlayerDelegate?

    private let videoRenderer: RTCVideoRenderer
    private let workerQueue = DispatchQueue(label: "com.local.ScreenWhepPlayer.WhepPlayer")
    private let factory: RTCPeerConnectionFactory

    private var client: WhepClient?
    private var peerConnection: RTCPeerConnection?
    private var sessionResourceURL: URL?
    private var pendingLocalDescription: RTCSessionDescription?
    private var remoteVideoTrack: RTCVideoTrack?
    private var hasPostedOffer = false

    init(videoRenderer: RTCVideoRenderer) {
        self.videoRenderer = videoRenderer
        self.factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        super.init()
    }

    func start(endpoint: WhepEndpoint) {
        workerQueue.async {
            self.stopInternal(notify: false)
            self.client = WhepClient(endpoint: endpoint)
            self.hasPostedOffer = false
            self.notifyStatus("Creating peer connection")

            let peerConnection = self.makePeerConnection()
            self.peerConnection = peerConnection
            self.addReceiveOnlyTransceivers(to: peerConnection)
            self.createOffer(on: peerConnection)
        }
    }

    func stop() {
        workerQueue.async {
            self.stopInternal(notify: true)
        }
    }

    private func makePeerConnection() -> RTCPeerConnection {
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherOnce
        config.iceServers = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )

        guard let peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            fatalError("RTCPeerConnectionFactory failed to create a peer connection.")
        }

        return peerConnection
    }

    private func addReceiveOnlyTransceivers(to peerConnection: RTCPeerConnection) {
        let videoInit = RTCRtpTransceiverInit()
        videoInit.direction = .recvOnly
        _ = peerConnection.addTransceiver(of: .video, init: videoInit)

        let audioInit = RTCRtpTransceiverInit()
        audioInit.direction = .recvOnly
        _ = peerConnection.addTransceiver(of: .audio, init: audioInit)
    }

    private func createOffer(on peerConnection: RTCPeerConnection) {
        notifyStatus("Creating SDP offer")
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true"
            ],
            optionalConstraints: nil
        )

        peerConnection.offer(for: constraints) { [weak self, weak peerConnection] offer, error in
            guard let self else {
                return
            }

            self.workerQueue.async {
                if let error {
                    self.fail(error)
                    return
                }

                guard let peerConnection, let offer else {
                    self.fail(WhepRuntimeError.message("Failed to create an SDP offer."))
                    return
                }

                self.pendingLocalDescription = offer
                peerConnection.setLocalDescription(offer) { [weak self] error in
                    guard let self else {
                        return
                    }

                    self.workerQueue.async {
                        if let error {
                            self.fail(error)
                            return
                        }

                        self.notifyStatus("Posting initial WHEP offer")
                        self.postOfferIfReady()
                    }
                }
            }
        }
    }

    private func postOfferIfReady() {
        guard !hasPostedOffer else {
            return
        }

        guard let peerConnection else {
            return
        }

        guard let localDescription = peerConnection.localDescription ?? pendingLocalDescription else {
            return
        }

        hasPostedOffer = true
        notifyStatus("Posting WHEP offer")

        client?.createSession(offerSDP: localDescription.sdp) { [weak self] result in
            guard let self else {
                return
            }

            self.workerQueue.async {
                switch result {
                case let .success(session):
                    self.sessionResourceURL = session.resourceURL
                    self.setRemoteAnswer(session.answerSDP)
                case let .failure(error):
                    self.fail(error)
                }
            }
        }
    }

    private func setRemoteAnswer(_ answerSDP: String) {
        let validationSDP = normalizeSDPForValidation(answerSDP)
        let validation = validateAnswerSDP(validationSDP)
        guard validation.isValid else {
            fail(WhepRuntimeError.message("Invalid WHEP answer SDP: \(validation.summary)"))
            return
        }

        notifyStatus("Applying WHEP answer: \(validation.summary)")
        let answer = RTCSessionDescription(type: .answer, sdp: normalizeSDPForWebRTC(answerSDP))
        peerConnection?.setRemoteDescription(answer) { [weak self] error in
            guard let self else {
                return
            }

            self.workerQueue.async {
                if let error {
                    self.fail(WhepRuntimeError.message("setRemoteDescription failed: \(error.localizedDescription). Answer: \(validation.summary)"))
                    return
                }

                self.notifyStatus("Connecting")
            }
        }
    }

    private func stopInternal(notify: Bool) {
        if let resourceURL = sessionResourceURL {
            client?.deleteSession(resourceURL: resourceURL)
        }

        sessionResourceURL = nil
        pendingLocalDescription = nil
        hasPostedOffer = false
        remoteVideoTrack?.remove(videoRenderer)
        remoteVideoTrack = nil
        peerConnection?.close()
        peerConnection = nil
        client = nil

        if notify {
            notifyStatus("Stopped")
        }
    }

    private func attachRemoteVideoTrack(from stream: RTCMediaStream) {
        guard let videoTrack = stream.videoTracks.first else {
            return
        }

        attachRemoteVideoTrack(videoTrack)
    }

    private func attachRemoteVideoTrack(_ videoTrack: RTCVideoTrack) {
        remoteVideoTrack?.remove(videoRenderer)
        remoteVideoTrack = videoTrack
        videoTrack.add(videoRenderer)
        notifyStatus("Receiving video")
    }

    private func notifyStatus(_ status: String) {
        DispatchQueue.main.async {
            self.delegate?.whepPlayer(self, didChangeStatus: status)
        }
    }

    private func fail(_ error: Error) {
        DispatchQueue.main.async {
            self.delegate?.whepPlayer(self, didFailWith: error)
        }
    }

    private func validateAnswerSDP(_ answerSDP: String) -> (isValid: Bool, summary: String) {
        let lines = answerSDP.split(separator: "\n", omittingEmptySubsequences: true)
        let mediaLines = lines.filter { $0.hasPrefix("m=") }.map(String.init)
        let hasIceUfrag = lines.contains { $0.hasPrefix("a=ice-ufrag:") }
        let hasFingerprint = lines.contains { $0.hasPrefix("a=fingerprint:") }
        let hasSetup = lines.contains { $0.hasPrefix("a=setup:") }
        let firstLines = lines.prefix(5).joined(separator: " | ")
        let summary = "len=\(answerSDP.count), media=\(mediaLines.joined(separator: ",")), ice=\(hasIceUfrag), fingerprint=\(hasFingerprint), setup=\(hasSetup), head=\(firstLines)"

        let isValid = answerSDP.hasPrefix("v=0")
            && !mediaLines.isEmpty
            && hasIceUfrag
            && hasFingerprint
            && hasSetup

        return (isValid, summary)
    }

    private func normalizeSDPForValidation(_ sdp: String) -> String {
        sdp
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func normalizeSDPForWebRTC(_ sdp: String) -> String {
        let lines = normalizeSDPForValidation(sdp)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let trimmedLines = lines.last == "" ? Array(lines.dropLast()) : lines
        return trimmedLines.joined(separator: "\r\n") + "\r\n"
    }
}

extension WhepPlayer: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        notifyStatus("Signaling: \(stateChanged)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        workerQueue.async {
            self.attachRemoteVideoTrack(from: stream)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        notifyStatus("ICE: \(newState)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        notifyStatus("ICE gathering: \(newState)")

        if newState == .complete {
            workerQueue.async {
                self.postOfferIfReady()
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        workerQueue.async {
            guard let videoTrack = rtpReceiver.track as? RTCVideoTrack else {
                return
            }

            self.attachRemoteVideoTrack(videoTrack)
        }
    }
}

private enum WhepRuntimeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case let .message(message):
            return message
        }
    }
}

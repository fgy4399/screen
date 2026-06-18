import Foundation
import WebRTC

protocol WhepPlayerDelegate: AnyObject {
    func whepPlayer(_ player: WhepPlayer, didChangeStatus status: String)
    func whepPlayer(_ player: WhepPlayer, didFailWith error: Error)
    func whepPlayer(_ player: WhepPlayer, didUpdateDebugInfo debugInfo: String)
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
    private var lastOfferSDP: String?
    private var lastAnswerSDP: String?
    private var lastSanitizedAnswerSDP: String?
    private var lastSanitizationMode: String?
    private var localCandidates: [RTCIceCandidate] = []
    private var debugEvents: [String] = []
    private var pendingRemoteCandidates: [RTCIceCandidate] = []
    private var hasPostedOffer = false
    private var shouldPostOfferWhenIceReady = false
    private var didHitLocalIceTimeout = false
    private var connectionAttemptID = 0
    private var remoteDescriptionAttemptID = 0

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
            self.shouldPostOfferWhenIceReady = false
            self.didHitLocalIceTimeout = false
            self.connectionAttemptID += 1
            self.remoteDescriptionAttemptID += 1
            self.notifyStatus("Creating peer connection")

            guard let peerConnection = self.makePeerConnection() else {
                self.fail(WhepRuntimeError.message("Failed to create RTCPeerConnection."))
                return
            }

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

    private func makePeerConnection() -> RTCPeerConnection? {
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

        return factory.peerConnection(with: config, constraints: constraints, delegate: self)
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

                        self.shouldPostOfferWhenIceReady = true
                        self.notifyStatus("Gathering local ICE candidates")
                        self.postOfferAfterIceTimeout()
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

        let usableLocalCandidates = localCandidates.filter { isUsableCandidate($0.sdp) }
        guard peerConnection.iceGatheringState == .complete || !usableLocalCandidates.isEmpty || didHitLocalIceTimeout else {
            shouldPostOfferWhenIceReady = true
            notifyStatus("Waiting for local ICE candidates")
            return
        }

        hasPostedOffer = true
        shouldPostOfferWhenIceReady = false
        let offerSDP = prepareOfferSDP(localDescription.sdp, candidates: usableLocalCandidates)
        lastOfferSDP = offerSDP
        publishDebugInfo(extra: "Posting WHEP offer")
        notifyStatus("Posting WHEP offer")

        client?.createSession(offerSDP: offerSDP) { [weak self] result in
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
        lastAnswerSDP = answerSDP
        let answers = sanitizedAnswerCandidates(from: normalizeSDPForValidation(answerSDP))
        applyRemoteAnswer(answers, attemptIndex: 0)
    }

    private func applyRemoteAnswer(_ answers: [SanitizedAnswer], attemptIndex: Int) {
        guard answers.indices.contains(attemptIndex) else {
            fail(WhepRuntimeError.message("Invalid WHEP answer SDP: no usable sanitized answer variants."))
            return
        }

        let sanitized = answers[attemptIndex]
        let validationSDP = sanitized.sdp
        pendingRemoteCandidates = sanitized.candidates
        lastSanitizedAnswerSDP = validationSDP
        lastSanitizationMode = sanitized.mode.rawValue
        recordDebugEvent("Preparing remote description with \(sanitized.mode.rawValue) SDP")
        publishDebugInfo(extra: "Received WHEP answer, applying \(sanitized.mode.rawValue) SDP")

        let validation = validateAnswerSDP(validationSDP)
        guard validation.isValid else {
            fail(WhepRuntimeError.message("Invalid WHEP answer SDP: \(validation.summary)"))
            return
        }

        notifyStatus("Applying WHEP answer: \(validation.summary)")
        let answer = RTCSessionDescription(type: .answer, sdp: validationSDP)
        let remoteDescriptionAttemptID = self.remoteDescriptionAttemptID + 1
        self.remoteDescriptionAttemptID = remoteDescriptionAttemptID
        recordDebugEvent("Calling setRemoteDescription with \(sanitized.mode.rawValue) SDP")
        scheduleRemoteDescriptionTimeout(remoteDescriptionAttemptID)
        peerConnection?.setRemoteDescription(answer) { [weak self] error in
            guard let self else {
                return
            }

            self.workerQueue.async {
                guard self.remoteDescriptionAttemptID == remoteDescriptionAttemptID else {
                    return
                }

                if let error {
                    let errorDetail = self.describe(error)
                    let nextAttemptIndex = attemptIndex + 1
                    if self.isRemoteDescriptionParseFailure(error),
                       answers.indices.contains(nextAttemptIndex) {
                        self.publishDebugInfo(extra: "setRemoteDescription failed with \(sanitized.mode.rawValue): \(errorDetail). Retrying.")
                        self.applyRemoteAnswer(answers, attemptIndex: nextAttemptIndex)
                        return
                    }

                    self.fail(
                        WhepRuntimeError.message("setRemoteDescription failed: \(errorDetail). Debug copied. Answer: \(validation.summary)"),
                        debugExtra: "setRemoteDescription failed: \(errorDetail)"
                    )
                    return
                }

                self.recordDebugEvent("Applied remote description")
                self.addPendingRemoteCandidates()
                self.scheduleConnectionTimeout()
                self.publishDebugInfo(extra: "Connecting after applying WHEP answer")
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
        lastOfferSDP = nil
        lastAnswerSDP = nil
        lastSanitizedAnswerSDP = nil
        lastSanitizationMode = nil
        localCandidates = []
        debugEvents = []
        pendingRemoteCandidates = []
        hasPostedOffer = false
        shouldPostOfferWhenIceReady = false
        didHitLocalIceTimeout = false
        connectionAttemptID += 1
        remoteDescriptionAttemptID += 1
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
        recordDebugEvent("Attached remote video track")
        notifyStatus("Receiving video")
    }

    private func notifyStatus(_ status: String) {
        DispatchQueue.main.async {
            self.delegate?.whepPlayer(self, didChangeStatus: status)
        }
    }

    private func fail(_ error: Error, debugExtra: String? = nil) {
        let debugInfo = debugExtra.map { makeDebugInfo(extra: $0) }
        DispatchQueue.main.async {
            if let debugInfo {
                self.delegate?.whepPlayer(self, didUpdateDebugInfo: debugInfo)
            }

            self.delegate?.whepPlayer(self, didFailWith: error)
        }
    }

    private func publishDebugInfo(extra: String) {
        let debugInfo = makeDebugInfo(extra: extra)
        DispatchQueue.main.async {
            self.delegate?.whepPlayer(self, didUpdateDebugInfo: debugInfo)
        }
    }

    private func makeDebugInfo(extra: String) -> String {
        let candidates = pendingRemoteCandidates
            .map { "mid=\($0.sdpMid ?? "<nil>") index=\($0.sdpMLineIndex) sdp=\($0.sdp)" }
            .joined(separator: "\n")
        let localCandidateLines = localCandidates
            .map { "mid=\($0.sdpMid ?? "<nil>") index=\($0.sdpMLineIndex) sdp=\($0.sdp)" }
            .joined(separator: "\n")
        let events = debugEvents.joined(separator: "\n")
        let stateSummary = describeCurrentPeerConnectionState()
        let debugInfo = """
        \(extra)

        === State ===
        \(stateSummary)

        === Events ===
        \(events.isEmpty ? "<none>" : events)

        === Local offer SDP ===
        \(lastOfferSDP ?? "<nil>")

        === Raw remote answer SDP ===
        \(lastAnswerSDP ?? "<nil>")

        === Sanitized remote answer SDP ===
        mode=\(lastSanitizationMode ?? "<nil>")
        \(lastSanitizedAnswerSDP ?? "<nil>")

        === Pending remote candidates ===
        \(candidates.isEmpty ? "<none>" : candidates)

        === Local candidates ===
        \(localCandidateLines.isEmpty ? "<none>" : localCandidateLines)
        """
        return debugInfo
    }

    private func recordDebugEvent(_ event: String) {
        let timestamp = DateFormatter.debugTimestamp.string(from: Date())
        debugEvents.append("[\(timestamp)] \(event)")
        if debugEvents.count > 80 {
            debugEvents.removeFirst(debugEvents.count - 80)
        }

        publishDebugInfo(extra: event)
    }

    private func describe(_ error: Error) -> String {
        let nsError = error as NSError
        let userInfo = nsError.userInfo
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ", ")

        return "domain=\(nsError.domain), code=\(nsError.code), description=\(nsError.localizedDescription), userInfo={\(userInfo)}"
    }

    private func describeCurrentPeerConnectionState() -> String {
        guard let peerConnection else {
            return "peer=<nil>"
        }

        return "signaling=\(describe(peerConnection.signalingState)), ice=\(describe(peerConnection.iceConnectionState)), peer=\(describe(peerConnection.connectionState)), gathering=\(describe(peerConnection.iceGatheringState)), remoteVideo=\(remoteVideoTrack != nil)"
    }

    private func describe(_ state: RTCSignalingState) -> String {
        switch state {
        case .stable:
            return "stable"
        case .haveLocalOffer:
            return "have-local-offer"
        case .haveLocalPrAnswer:
            return "have-local-pranswer"
        case .haveRemoteOffer:
            return "have-remote-offer"
        case .haveRemotePrAnswer:
            return "have-remote-pranswer"
        case .closed:
            return "closed"
        @unknown default:
            return "unknown(\(state.rawValue))"
        }
    }

    private func describe(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new:
            return "new"
        case .checking:
            return "checking"
        case .connected:
            return "connected"
        case .completed:
            return "completed"
        case .failed:
            return "failed"
        case .disconnected:
            return "disconnected"
        case .closed:
            return "closed"
        case .count:
            return "count"
        @unknown default:
            return "unknown(\(state.rawValue))"
        }
    }

    private func describe(_ state: RTCIceGatheringState) -> String {
        switch state {
        case .new:
            return "new"
        case .gathering:
            return "gathering"
        case .complete:
            return "complete"
        @unknown default:
            return "unknown(\(state.rawValue))"
        }
    }

    private func describe(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new:
            return "new"
        case .connecting:
            return "connecting"
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .failed:
            return "failed"
        case .closed:
            return "closed"
        @unknown default:
            return "unknown(\(state.rawValue))"
        }
    }

    private func isRemoteDescriptionParseFailure(_ error: Error) -> Bool {
        let detail = describe(error).lowercased()
        return detail.contains("sessiondescription is null")
            || detail.contains("parse")
            || detail.contains("sdp")
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

    private func postOfferAfterIceTimeout() {
        workerQueue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self,
                  self.shouldPostOfferWhenIceReady,
                  !self.hasPostedOffer else {
                return
            }

            self.didHitLocalIceTimeout = true
            self.recordDebugEvent("Local ICE timeout; posting offer with \(self.localCandidates.count) candidates")
            self.postOfferIfReady()
        }
    }

    private func scheduleConnectionTimeout() {
        let attemptID = connectionAttemptID
        workerQueue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self,
                  self.connectionAttemptID == attemptID,
                  let peerConnection = self.peerConnection,
                  self.remoteVideoTrack == nil else {
                return
            }

            let iceState = peerConnection.iceConnectionState
            if iceState == .connected || iceState == .completed {
                self.recordDebugEvent("Connection timeout skipped: ICE \(self.describe(iceState)) but no video yet")
                return
            }

            self.recordDebugEvent("Connection timeout: \(self.describeCurrentPeerConnectionState())")
            self.fail(
                WhepRuntimeError.message("Connection timeout. Debug copied. Check MediaMTX UDP/TCP ICE reachability."),
                debugExtra: "Connection timeout"
            )
        }
    }

    private func scheduleRemoteDescriptionTimeout(_ attemptID: Int) {
        workerQueue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self,
                  self.remoteDescriptionAttemptID == attemptID,
                  self.peerConnection?.remoteDescription == nil else {
                return
            }

            self.recordDebugEvent("setRemoteDescription timeout: \(self.describeCurrentPeerConnectionState())")
            self.fail(
                WhepRuntimeError.message("setRemoteDescription timeout. Debug copied."),
                debugExtra: "setRemoteDescription timeout"
            )
        }
    }

    private func prepareOfferSDP(_ sdp: String, candidates: [RTCIceCandidate]) -> String {
        let normalizedSDP = normalizeSDPForValidation(sdp)
        let candidateLinesByMid = Dictionary(grouping: uniqueCandidates(candidates), by: { $0.sdpMid ?? "" })
        var offerLines: [String] = []
        var currentMid = ""
        var insertedMids = Set<String>()

        for rawLine in normalizedSDP.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !line.isEmpty else {
                continue
            }

            if line.hasPrefix("a=candidate:") || line.hasPrefix("a=end-of-candidates") {
                continue
            }

            if line.hasPrefix("m="), !currentMid.isEmpty {
                appendLocalCandidates(candidateLinesByMid[currentMid] ?? [], to: &offerLines)
                insertedMids.insert(currentMid)
                currentMid = ""
            }

            offerLines.append(line)

            if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
            }
        }

        if !currentMid.isEmpty, !insertedMids.contains(currentMid) {
            appendLocalCandidates(candidateLinesByMid[currentMid] ?? [], to: &offerLines)
            insertedMids.insert(currentMid)
        }

        let candidatesWithoutMid = candidateLinesByMid[""] ?? []
        appendLocalCandidates(candidatesWithoutMid, to: &offerLines)

        return offerLines.joined(separator: "\r\n") + "\r\n"
    }

    private func uniqueCandidates(_ candidates: [RTCIceCandidate]) -> [RTCIceCandidate] {
        var seen = Set<String>()
        var unique: [RTCIceCandidate] = []

        for candidate in candidates where seen.insert(candidate.sdp).inserted {
            unique.append(candidate)
        }

        return unique
    }

    private func appendLocalCandidates(_ candidates: [RTCIceCandidate], to lines: inout [String]) {
        var appendedCandidate = false
        for candidate in candidates where isRtpCandidate(candidate.sdp) && !isLoopbackOrDockerCandidate(candidate.sdp) {
            lines.append("a=\(candidate.sdp)")
            appendedCandidate = true
        }

        if appendedCandidate {
            lines.append("a=end-of-candidates")
        }
    }

    private func sanitizedAnswerCandidates(from sdp: String) -> [SanitizedAnswer] {
        var seenSDPs = Set<String>()
        var answers: [SanitizedAnswer] = []

        for mode in AnswerSanitizationMode.allCases {
            let sanitized = sanitizeAnswerSDP(sdp, mode: mode)
            guard seenSDPs.insert(sanitized.sdp).inserted else {
                continue
            }

            answers.append(sanitized)
        }

        return answers
    }

    private func sanitizeAnswerSDP(_ sdp: String, mode: AnswerSanitizationMode) -> SanitizedAnswer {
        var currentMid: String?
        var currentMLineIndex: Int32 = -1
        var candidates: [RTCIceCandidate] = []
        var answerLines: [String] = []

        for rawLine in sdp.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = normalizeAnswerLine(rawLine)
            guard !line.isEmpty else {
                continue
            }

            if line.hasPrefix("m=") {
                currentMLineIndex += 1
                answerLines.append(line)
                continue
            }

            if line.hasPrefix("a=mid:") {
                currentMid = String(line.dropFirst("a=mid:".count))
                answerLines.append(line)
                continue
            }

            if line.hasPrefix("a=candidate:") {
                let candidateSDP = String(line.dropFirst("a=".count))
                guard isUsableCandidate(candidateSDP) else {
                    continue
                }

                candidates.append(RTCIceCandidate(
                    sdp: candidateSDP,
                    sdpMLineIndex: currentMLineIndex,
                    sdpMid: currentMid
                ))
                continue
            }

            if line.hasPrefix("a=end-of-candidates")
                || line.hasPrefix("a=extmap-allow-mixed")
                || line.hasPrefix("a=extmap:")
                || shouldDropAnswerLine(line, mode: mode) {
                continue
            }

            answerLines.append(line)
        }

        return SanitizedAnswer(
            mode: mode,
            sdp: answerLines.joined(separator: "\r\n") + "\r\n",
            candidates: candidates
        )
    }

    private func normalizeAnswerLine(_ line: String) -> String {
        let line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))

        if line.hasPrefix("a=msid-semantic:WMS") {
            return line.replacingOccurrences(of: "a=msid-semantic:WMS", with: "a=msid-semantic: WMS")
        }

        guard line.hasPrefix("a=candidate:") else {
            return line
        }

        guard let range = line.range(of: " ufrag ") else {
            return line
        }

        return String(line[..<range.lowerBound])
    }

    private func shouldDropAnswerLine(_ line: String, mode: AnswerSanitizationMode) -> Bool {
        switch mode {
        case .unifiedPlan:
            return line.hasPrefix("a=ssrc:")
                && (line.contains(" msid:")
                    || line.contains(" mslabel:")
                    || line.contains(" label:"))
        case .ssrcMsid:
            return line.hasPrefix("a=msid:")
                || (line.hasPrefix("a=ssrc:")
                    && (line.contains(" mslabel:")
                        || line.contains(" label:")))
        case .minimalMsid:
            return line.hasPrefix("a=msid:")
                || (line.hasPrefix("a=ssrc:")
                    && (line.contains(" msid:")
                        || line.contains(" mslabel:")
                        || line.contains(" label:")))
        }
    }

    private func isRtpCandidate(_ candidateSDP: String) -> Bool {
        let fields = candidateSDP.split(separator: " ")
        guard fields.count > 1 else {
            return true
        }

        return fields[1] == "1"
    }

    private func isUsableCandidate(_ candidateSDP: String) -> Bool {
        isRtpCandidate(candidateSDP) && !isLoopbackOrDockerCandidate(candidateSDP)
    }

    private func isLoopbackOrDockerCandidate(_ candidateSDP: String) -> Bool {
        guard let host = candidateHost(from: candidateSDP) else {
            return false
        }

        return host == "127.0.0.1"
            || host == "::1"
            || host.hasPrefix("172.17.")
            || host.hasPrefix("172.18.")
            || host.hasPrefix("172.19.")
            || host.hasPrefix("172.20.")
    }

    private func candidateHost(from candidateSDP: String) -> String? {
        let fields = candidateSDP.split(separator: " ").map(String.init)
        guard fields.count > 4 else {
            return nil
        }

        return fields[4]
    }

    private func addPendingRemoteCandidates() {
        guard let peerConnection else {
            return
        }

        if pendingRemoteCandidates.isEmpty {
            recordDebugEvent("No remote ICE candidates after filtering")
            return
        }

        for candidate in pendingRemoteCandidates {
            peerConnection.add(candidate) { [weak self] error in
                guard let self else {
                    return
                }

                if let error {
                    self.fail(WhepRuntimeError.message("addIceCandidate failed: \(self.describe(error))"))
                } else {
                    self.recordDebugEvent("Added remote ICE candidate: \(candidate.sdp)")
                }
            }
        }
    }

}

extension WhepPlayer: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        workerQueue.async {
            let state = self.describe(stateChanged)
            self.recordDebugEvent("Signaling changed: \(state)")
            self.notifyStatus("Signaling: \(state)")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        workerQueue.async {
            self.attachRemoteVideoTrack(from: stream)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        workerQueue.async {
            let state = self.describe(newState)
            self.recordDebugEvent("ICE connection changed: \(state)")
            self.notifyStatus("ICE: \(state)")

            if newState == .failed || newState == .disconnected {
                self.publishDebugInfo(extra: "ICE connection \(state)")
                self.fail(WhepRuntimeError.message("ICE connection \(state). Debug copied. Check MediaMTX UDP 8189 reachability and candidates."))
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        workerQueue.async {
            let state = self.describe(newState)
            self.recordDebugEvent("ICE gathering changed: \(state)")
            self.notifyStatus("ICE gathering: \(state)")

            if newState == .complete, self.shouldPostOfferWhenIceReady {
                self.postOfferIfReady()
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        workerQueue.async {
            self.recordDebugEvent("Generated local ICE candidate: \(candidate.sdp)")
            guard self.isRtpCandidate(candidate.sdp) else {
                return
            }

            self.localCandidates.append(candidate)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        workerQueue.async {
            let state = self.describe(newState)
            self.recordDebugEvent("Peer connection changed: \(state)")
            self.notifyStatus("Peer: \(state)")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChangeLocalCandidate local: RTCIceCandidate, remoteCandidate remote: RTCIceCandidate, lastReceivedMs: Int32, changeReason reason: String) {
        workerQueue.async {
            self.recordDebugEvent("Selected ICE pair: local=\(local.sdp) remote=\(remote.sdp) lastReceivedMs=\(lastReceivedMs) reason=\(reason)")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didFailToGather candidate: RTCIceCandidateErrorEvent) {
        workerQueue.async {
            self.recordDebugEvent("Local ICE gather failed: url=\(candidate.url) address=\(candidate.address):\(candidate.port) code=\(candidate.errorCode) text=\(candidate.errorText)")
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        workerQueue.async {
            guard let videoTrack = rtpReceiver.track as? RTCVideoTrack else {
                return
            }

            self.attachRemoteVideoTrack(videoTrack)
        }
    }
}

private struct SanitizedAnswer {
    let mode: AnswerSanitizationMode
    let sdp: String
    let candidates: [RTCIceCandidate]
}

private enum AnswerSanitizationMode: String, CaseIterable {
    case ssrcMsid = "ssrc-msid"
    case unifiedPlan = "unified-plan"
    case minimalMsid = "minimal-msid"
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

private extension DateFormatter {
    static let debugTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

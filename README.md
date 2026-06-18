# Screen WHEP Player

Native iOS/iPadOS 14+ player prototype for MediaMTX WHEP streams.

## What it does

- Uses `stasel/WebRTC` as the native WebRTC framework, pinned to `148.0.0` because `149.0.0` currently fails SwiftPM binary checksum validation in this environment.
- Creates a receive-only `RTCPeerConnection`.
- Waits for local ICE gathering to complete.
- Sends the complete SDP offer to a WHEP endpoint with `POST application/sdp`.
- Applies the SDP answer returned by MediaMTX.
- Sends `DELETE` to the returned WHEP session `Location` when playback stops.

## Run

1. Open `ScreenWhepPlayer.xcodeproj` in Xcode 16+.
2. Select a simulator or real iPad target.
3. Enter a MediaMTX WHEP URL such as:

   ```text
   http://192.168.1.10:8889/mystream/whep
   ```

4. Tap `Start`.

## Build notes

- This repository pins `stasel/WebRTC` to exactly `148.0.0`. Do not change it to `149.0.0` until its SwiftPM artifact checksum is fixed upstream.
- The current machine resolved SwiftPM successfully, but `xcodebuild` could not compile because no usable iOS destination/runtime is installed. Xcode reported an empty simulator runtime list and an ineligible `Any iOS Device` placeholder.
- For local HTTP MediaMTX endpoints, `NSAllowsArbitraryLoads` is enabled in `Info.plist`.

## GitHub Actions

The workflow in `.github/workflows/ios.yml` has three jobs:

- `simulator-build` runs on every push and pull request. It builds an unsigned simulator `.app` and uploads `ScreenWhepPlayer-simulator.zip`. This artifact is for CI smoke testing only and cannot be installed on a real iPad.
- `unsigned-device-ipa` runs on push, pull request, and manual `workflow_dispatch`. It builds an unsigned real-device `.ipa` with `Payload/ScreenWhepPlayer.app`, suitable for TrollStore or later local/self-signing.
- `signed-ipa` runs only from manual `workflow_dispatch`. It archives and exports a real installable IPA when Apple signing secrets are configured.

For TrollStore-style installation, download `ScreenWhepPlayer-unsigned-ipa` from the workflow run artifacts. If you run the workflow manually, you can optionally set `bundle_id`; keep it stable between builds if you want upgrades to replace the same installed app. Leave `build_signed_ipa` as `false` unless you also want to run the Apple-signed export job.

Required repository secrets for `signed-ipa`:

- `IOS_CERTIFICATE_P12_BASE64`: base64-encoded Apple Distribution certificate `.p12`.
- `IOS_CERTIFICATE_PASSWORD`: password for the `.p12`.
- `IOS_PROVISION_PROFILE_BASE64`: base64-encoded `.mobileprovision` for the app.
- `IOS_TEAM_ID`: Apple Developer Team ID.
- `IOS_PROVISION_PROFILE_NAME`: provisioning profile name, not the file name.

Optional repository secrets:

- `IOS_BUNDLE_ID`: overrides the default `com.local.ScreenWhepPlayer`. The provisioning profile must match this bundle ID.
- `IOS_EXPORT_METHOD`: defaults to `ad-hoc`. Use `app-store-connect` for TestFlight/App Store export if the signing assets match.
- `IOS_KEYCHAIN_PASSWORD`: temporary CI keychain password.

## MediaMTX notes

- Keep the source stream WebRTC-friendly. Start with H264 without B-frames and Opus/AAC where possible.
- If the iPad is not on the same LAN as MediaMTX, configure `webrtcAdditionalHosts` and STUN/TURN in MediaMTX.
- This prototype intentionally uses non-trickle ICE for simpler first-pass compatibility. Add WHEP `PATCH application/trickle-ice-sdpfrag` later if connection setup latency matters.

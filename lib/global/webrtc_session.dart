import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'global_peer_store.dart';
import 'nostr_client.dart';
import 'rendezvous_service.dart';

const defaultStunServers = <String>[
  'stun:stun.l.google.com:19302',
  'stun:stun1.l.google.com:19302',
  'stun:stun.cloudflare.com:3478',
  'stun:global.stun.twilio.com:3478',
];

typedef RtcPeerConnectionFactory =
    Future<RTCPeerConnection> Function(
      Map<String, dynamic> configuration,
      Map<String, dynamic> constraints,
    );

enum WebRtcSessionState { idle, connecting, connected, failed, closed }

class WebRtcSession {
  WebRtcSession({
    RtcPeerConnectionFactory peerConnectionFactory = createPeerConnection,
  }) : _peerConnectionFactory = peerConnectionFactory;

  final RtcPeerConnectionFactory _peerConnectionFactory;
  final StreamController<WebRtcSessionState> _stateController =
      StreamController<WebRtcSessionState>.broadcast();
  final StreamController<List<int>> _incomingController =
      StreamController<List<int>>.broadcast();
  final Random _random = Random.secure();

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  StreamSubscription<RendezvousMessage>? _signalSub;
  WebRtcSessionState _state = WebRtcSessionState.idle;

  WebRtcSessionState get state => _state;
  Stream<WebRtcSessionState> get states => _stateController.stream;
  Stream<List<int>> get incoming => _incomingController.stream;

  Future<void> connectAsCaller(
    GlobalPeer peer,
    RendezvousService rendezvous, {
    String? sessionId,
  }) async {
    final session = sessionId ?? _randomSessionId();
    _setState(WebRtcSessionState.connecting);
    final pc = await _openPeerConnection(peer, rendezvous, session);
    _signalSub = _listenForSignals(peer, rendezvous, session);
    final init = RTCDataChannelInit()
      ..ordered = true
      ..binaryType = 'binary';
    _wireDataChannel(await pc.createDataChannel('localchat', init));

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await rendezvous.sendOffer(peer, offer.sdp ?? '', session);
  }

  Future<void> acceptAsCallee(
    GlobalPeer peer,
    RendezvousMessage offerEvent,
    RendezvousService rendezvous,
  ) async {
    final session = offerEvent.session;
    _setState(WebRtcSessionState.connecting);
    final pc = await _openPeerConnection(peer, rendezvous, session);
    _signalSub = _listenForSignals(peer, rendezvous, session);
    await pc.setRemoteDescription(
      RTCSessionDescription(offerEvent.sdp ?? '', 'offer'),
    );
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await rendezvous.sendAnswer(peer, answer.sdp ?? '', session);
  }

  Future<void> send(List<int> bytes) async {
    final channel = _dataChannel;
    if (channel == null || _state != WebRtcSessionState.connected) {
      throw StateError('WebRTC data channel is not connected');
    }
    await channel.send(
      RTCDataChannelMessage.fromBinary(Uint8List.fromList(bytes)),
    );
  }

  Future<void> close() async {
    _setState(WebRtcSessionState.closed);
    await _signalSub?.cancel();
    _signalSub = null;
    await _dataChannel?.close();
    _dataChannel = null;
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _peerConnection = null;
    await _incomingController.close();
    await _stateController.close();
  }

  Future<RTCPeerConnection> _openPeerConnection(
    GlobalPeer peer,
    RendezvousService rendezvous,
    String session,
  ) async {
    final pc = await _peerConnectionFactory(
      iceConfiguration(),
      const <String, dynamic>{},
    );
    _peerConnection = pc;

    pc.onIceCandidate = (candidate) {
      unawaited(rendezvous.sendIce(peer, candidateToJson(candidate), session));
    };
    pc.onDataChannel = _wireDataChannel;
    pc.onConnectionState = (state) {
      switch (state) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setState(WebRtcSessionState.connected);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _setState(WebRtcSessionState.failed);
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          _setState(WebRtcSessionState.closed);
          break;
        default:
          break;
      }
    };
    pc.onIceConnectionState = (state) {
      if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
        _setState(WebRtcSessionState.failed);
      }
    };
    return pc;
  }

  StreamSubscription<RendezvousMessage> _listenForSignals(
    GlobalPeer peer,
    RendezvousService rendezvous,
    String session,
  ) {
    return rendezvous.messages.listen((message) {
      if (message.from != peer.edPubHex || message.session != session) return;
      unawaited(_handleSignal(message));
    });
  }

  Future<void> _handleSignal(RendezvousMessage message) async {
    final pc = _peerConnection;
    if (pc == null) return;
    switch (message.kind) {
      case RendezvousMessageKind.webrtcAnswer:
        await pc.setRemoteDescription(
          RTCSessionDescription(message.sdp ?? '', 'answer'),
        );
        break;
      case RendezvousMessageKind.iceCandidate:
        final candidate = message.candidate;
        if (candidate != null) {
          await pc.addCandidate(candidateFromJson(candidate));
        }
        break;
      case RendezvousMessageKind.webrtcOffer:
      case RendezvousMessageKind.presence:
        break;
    }
  }

  void _wireDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onDataChannelState = (state) {
      switch (state) {
        case RTCDataChannelState.RTCDataChannelOpen:
          _setState(WebRtcSessionState.connected);
          break;
        case RTCDataChannelState.RTCDataChannelClosed:
          if (_state != WebRtcSessionState.closed) {
            _setState(WebRtcSessionState.failed);
          }
          break;
        default:
          break;
      }
    };
    channel.onMessage = (message) {
      if (_incomingController.isClosed) return;
      if (message.isBinary) {
        _incomingController.add(List<int>.from(message.binary));
      } else {
        _incomingController.add(utf8.encode(message.text));
      }
    };
    if (channel.state == RTCDataChannelState.RTCDataChannelOpen) {
      _setState(WebRtcSessionState.connected);
    }
  }

  void _setState(WebRtcSessionState next) {
    if (_state == next) return;
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  String _randomSessionId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return NostrHex.encode(bytes);
  }

  static Map<String, dynamic> iceConfiguration() {
    return <String, dynamic>{
      'iceServers': <Map<String, String>>[
        for (final url in defaultStunServers) <String, String>{'urls': url},
      ],
    };
  }

  static Map<String, Object?> candidateToJson(RTCIceCandidate candidate) {
    return <String, Object?>{
      'candidate': candidate.candidate,
      'sdpMid': candidate.sdpMid,
      'sdpMLineIndex': candidate.sdpMLineIndex,
    };
  }

  static RTCIceCandidate candidateFromJson(Map<String, Object?> json) {
    return RTCIceCandidate(
      json['candidate'] as String?,
      json['sdpMid'] as String?,
      (json['sdpMLineIndex'] as num?)?.toInt(),
    );
  }
}

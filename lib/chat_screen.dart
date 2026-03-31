import 'dart:async';
import 'dart:io';
import 'dart:math' show max, min;

import 'package:crypto/crypto.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:super_clipboard/super_clipboard.dart';
import 'package:uuid/uuid.dart';

import 'app_settings.dart';
import 'app_snackbar.dart';
import 'android_attachment_picker.dart';
import 'android_share_inbound.dart';
import 'chat_message_ordering.dart';
import 'chat_crypto.dart';
import 'connection_service.dart';
import 'device.dart';
import 'discovery_service.dart';
import 'message_model.dart';
import 'message_store.dart';
import 'deferred_staged_file.dart';
import 'transfer_manager.dart';

class ChatScreen extends StatefulWidget {
  final DeviceInfo me;
  final PeerDevice peer;
  final DiscoveryService discovery;
  final ConnectionService connections;
  final MessageStore store;

  const ChatScreen({
    super.key,
    required this.me,
    required this.peer,
    required this.discovery,
    required this.connections,
    required this.store,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const _uuid = Uuid();
  static const MethodChannel _appControlChannel =
      MethodChannel('local_chat/app_control');

  static const _pageSize = 50;

  /// First DB fetch: newest N messages (SQLite indexed).
  static const _initialHistoryWindow = 100;

  /// Each scroll-up load of older messages.
  static const _historyBatchSize = 50;

  static const double _bubbleImageW = 220;
  static const double _bubbleImageH = 160;

  final List<ChatMessage> _allMessages = [];

  /// Keeps outgoing timestamps strictly after the latest row (clock skew + rapid sends).
  int _sendTimestampSeq = 0;
  List<ChatMessage> _messages = [];
  int _displayCount = _pageSize;
  int _totalInDb = 0;
  bool _hasMoreOlder = false;
  bool _loadingOlder = false;
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();

  void Function(String, Map<String, dynamic>)? _prevOnMessage;
  void Function(String)? _prevOnDisconnected;
  void Function(Socket, String)? _prevOnIncoming;
  bool _connected = false;
  bool _loading = true;

  final List<DeferredStagedFile> _staged = [];

  /// Prevents overlapping native file/folder/gallery pickers (multiple explorer windows).
  bool _nativePickerOpen = false;

  /// Clipboard image filenames: Image_01, Image_02, … (non-web)
  int _clipboardPasteImageSeq = 1;

  /// Pasted image hashes currently represented in [_staged] (duplicate paste guard).
  final Set<String> _stagedClipboardHashes = {};

  String? _lastSnackMessage;
  DateTime? _lastSnackAt;

  StreamSubscription<void>? _transferSub;
  StreamSubscription<FileMessageEvent>? _fileMsgSub;
  Timer? _transferThrottle;
  Timer? _connTimer;
  Timer? _storeRevisionDebounce;
  Timer? _scrollLoadOlderDebounce;
  DateTime? _lastAutoReconnect;

  String get _peerId => widget.peer.userId;
  TransferManager get _tm => TransferManager.instance;

  /// Same as [compareChatMessagesChronological] — must match [MessageStore] SQL order.
  static int _compareMessages(ChatMessage a, ChatMessage b) =>
      compareChatMessagesChronological(a, b);

  void _insertMessageSorted(ChatMessage msg) {
    if (_allMessages.isEmpty) {
      _allMessages.add(msg);
      return;
    }
    final last = _allMessages.last;
    if (_compareMessages(last, msg) < 0) {
      _allMessages.add(msg);
      return;
    }
    var lo = 0;
    var hi = _allMessages.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_compareMessages(_allMessages[mid], msg) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _allMessages.insert(lo, msg);
  }

  void _growVisibleForNewMessage() {
    _displayCount = (_displayCount + 1).clamp(0, _allMessages.length);
  }

  /// Largest [ChatMessage.timestamp] in memory (not list position), so outgoing time
  /// stays strictly after every row after reloads / debounced DB sync.
  int _maxTimestampInThread() {
    if (_allMessages.isEmpty) return 0;
    var m = _allMessages.first.timestamp;
    for (final x in _allMessages) {
      if (x.timestamp > m) m = x.timestamp;
    }
    return m;
  }

  void _syncSendTimestampSeq() {
    _sendTimestampSeq = _maxTimestampInThread();
  }

  /// Strictly after every message in the thread and >= local clock (clock skew / races).
  /// Also uses [_sendTimestampSeq] so two sends before [_allMessages] reflects the first
  /// row still get strictly increasing times.
  int _nextOutgoingTimestamp() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final floor = _maxTimestampInThread();
    final base = max(now, floor + 1);
    final next = max(base, _sendTimestampSeq + 1);
    _sendTimestampSeq = next;
    return next;
  }

  void _onStoreRevision() {
    if (!mounted) return;
    _storeRevisionDebounce?.cancel();
    _storeRevisionDebounce = Timer(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      unawaited(_reloadMessagesFromStore());
    });
  }

  @override
  void initState() {
    super.initState();
    _connected = widget.connections.isConnected(_peerId);
    widget.store.messageHistoryRevision.addListener(_onStoreRevision);

    _prevOnMessage = widget.connections.onMessage;
    widget.connections.onMessage = (peerId, json) {
      _prevOnMessage?.call(peerId, json);
      if (peerId == _peerId && !_connected && mounted) {
        setState(() => _connected = true);
      }
      if (peerId != _peerId) return;
      final type = json['type'] as String?;
      if (type == 'message' || type == 'message_ack') {
        // Inserts/updates run in [MessageStore.add] / delivery handlers, which bump
        // [messageHistoryRevision]; debounced [_reloadMessagesFromStore] keeps UI in sync.
        return;
      }
      _handleJson(json);
    };

    _prevOnDisconnected = widget.connections.onDisconnected;
    widget.connections.onDisconnected = (peerId) {
      _prevOnDisconnected?.call(peerId);
      if (peerId == _peerId && mounted) {
        // After a real TCP loss, allow the next [_syncConnection] tick to retry
        // immediately. Throttle only limits repeated failed dials, not recovery
        // from an unrelated earlier attempt (same idea as MsgStream re-init).
        _lastAutoReconnect = null;
        setState(() => _connected = false);
        unawaited(_onChatTcpLost());
      }
    };

    _prevOnIncoming = widget.connections.onIncomingConnection;
    widget.connections.onIncomingConnection = (socket, peerId) {
      _prevOnIncoming?.call(socket, peerId);
      if (peerId == _peerId && mounted) {
        setState(() => _connected = true);
        unawaited(_syncOutboundMessagesAfterConnect());
      }
    };

    _transferSub = _tm.transferUpdates.listen((_) {
      if (_transferThrottle?.isActive ?? false) return;
      _transferThrottle = Timer(const Duration(milliseconds: 200), () {
        if (mounted) setState(() {});
      });
    });

    _fileMsgSub = _tm.fileMessages.listen((event) {
      if (event.peerId != _peerId) return;
      if (!mounted) return;
      final allIdx = _allMessages.indexWhere((m) => m.id == event.message.id);
      if (allIdx >= 0) {
        _allMessages[allIdx] = event.message;
      } else {
        _insertMessageSorted(event.message);
        _growVisibleForNewMessage();
        _totalInDb++;
      }
      setState(() => _rebuildVisible());
      _scrollToBottom();
    });

    _scroll.addListener(_onScroll);
    if (!_connected) _connect();
    unawaited(_loadHistory());

    _connTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _syncConnection(),
    );

    HardwareKeyboard.instance.addHandler(_handleComposerHardwareKey);

    if (!kIsWeb && Platform.isAndroid) {
      AndroidShareInbound.attachChat(_consumeAndroidShare);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(AndroidShareInbound.syncFromNative());
      });
    }
  }

  void _consumeAndroidShare(List<SharedInboundFile> files) {
    if (!mounted || files.isEmpty) return;
    _stageFiles(
      files
          .map(
            (e) => DeferredStagedFile(
              displayName: e.name,
              sourcePath: e.path,
              androidContentUri: e.contentUri,
            ),
          )
          .toList(),
    );
  }

  /// Desktop: Enter sends (Shift+Enter keeps newline). Uses hardware handler so
  /// it does not compete with a second [Focus] on the same [FocusNode].
  /// Ctrl/Cmd+Shift+V pastes an image from the clipboard into staging (not plain Ctrl+V — that stays text).
  bool _handleComposerHardwareKey(KeyEvent event) {
    if (!_isDesktop) return false;
    if (!_focus.hasFocus) return false;
    if (event is! KeyDownEvent) return false;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed) &&
        HardwareKeyboard.instance.isShiftPressed) {
      unawaited(_pasteClipboardImageToStaging());
      return true;
    }
    if (k != LogicalKeyboardKey.enter && k != LogicalKeyboardKey.numpadEnter) {
      return false;
    }
    if (HardwareKeyboard.instance.isShiftPressed) return false;
    if (!mounted) return false;
    final textReady = normalizeOutgoingMessageText(_input.text).isNotEmpty;
    final canSend = textReady || (_connected && _staged.isNotEmpty);
    if (!canSend) return false;
    unawaited(_sendAll());
    return true;
  }

  PeerDevice _resolveLivePeer() {
    for (final p in widget.discovery.peers) {
      if (p.userId == _peerId) return p;
    }
    return widget.peer;
  }

  /// Keeps UI state in sync with [ConnectionService.isConnected] (TCP, like
  /// MsgStream’s socket) and retries outbound connect when discovery still lists
  /// the peer (LAN present). No “internet” API — unreachable LAN matches TCP
  /// timeout / disconnect, same as `netstreamer.cpp`.
  void _syncConnection() {
    if (!mounted) return;
    final socketConnected = widget.connections.isConnected(_peerId);
    final wasConnected = _connected;
    final live = _resolveLivePeer();
    final inDiscovery = widget.discovery.peers.any((p) => p.userId == _peerId);
    final hasLanAddress = live.ip.trim().isNotEmpty;
    // UDP may have pruned the peer after Wi‑Fi flap; we still have IP from route/store.
    final canTryReconnect = inDiscovery || hasLanAddress;
    if (socketConnected != _connected) {
      setState(() => _connected = socketConnected);
    }
    if (socketConnected && !wasConnected) {
      unawaited(_syncOutboundMessagesAfterConnect());
    }
    if (!socketConnected && canTryReconnect) {
      final now = DateTime.now();
      if (_lastAutoReconnect != null &&
          now.difference(_lastAutoReconnect!) < const Duration(seconds: 4)) {
        return;
      }
      _lastAutoReconnect = now;
      unawaited(widget.connections.connectTo(live, forceNew: true));
    }
  }

  Future<void> _loadHistory() async {
    final window =
        await widget.store.loadRecentWindow(_peerId, _initialHistoryWindow);
    if (!mounted) return;
    _totalInDb = window.total;
    _allMessages
      ..clear()
      ..addAll(window.messages);
    _allMessages.sort(_compareMessages);
    _hasMoreOlder = _allMessages.length < _totalInDb;
    _displayCount = _pageSize.clamp(0, _allMessages.length);
    if (_allMessages.length <= _pageSize) {
      _displayCount = _allMessages.length;
    }
    _rebuildVisible();
    _syncSendTimestampSeq();
    unawaited(_rememberPeerRecord());
    setState(() => _loading = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
    if (_connected) unawaited(_syncOutboundMessagesAfterConnect());
  }

  void _rebuildVisible() {
    final start = (_allMessages.length - _displayCount).clamp(
      0,
      _allMessages.length,
    );
    _messages = _allMessages.sublist(start);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels > 50) return;

    if (_displayCount < _allMessages.length) {
      final prevMax = _scroll.position.maxScrollExtent;
      setState(() {
        _displayCount =
            (_displayCount + _pageSize).clamp(0, _allMessages.length);
        _rebuildVisible();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          final newMax = _scroll.position.maxScrollExtent;
          _scroll.jumpTo(_scroll.position.pixels + (newMax - prevMax));
        }
      });
      return;
    }

    if (_hasMoreOlder && !_loadingOlder) {
      _scrollLoadOlderDebounce?.cancel();
      _scrollLoadOlderDebounce = Timer(const Duration(milliseconds: 150), () {
        if (!mounted) return;
        if (_hasMoreOlder && !_loadingOlder) {
          unawaited(_loadOlderBatch());
        }
      });
    }
  }

  /// Loads the next chunk of older messages from SQLite (offset paging).
  Future<void> _loadOlderBatch() async {
    if (_loadingOlder || !_hasMoreOlder) return;
    _loadingOlder = true;
    try {
      final gap = max(0, _totalInDb - _allMessages.length);
      final want = min(_historyBatchSize, gap);
      if (want <= 0) {
        if (mounted) setState(() => _hasMoreOlder = false);
        return;
      }

      final prevMax = _scroll.hasClients
          ? _scroll.position.maxScrollExtent
          : 0.0;
      final prevPixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;

      final result = await widget.store.loadOlderBatch(
        _peerId,
        _allMessages.length,
        want,
      );
      if (!mounted) return;
      _totalInDb = result.total;
      final older = result.older;
      if (older.isEmpty) {
        if (mounted) {
          setState(() => _hasMoreOlder = _allMessages.length < _totalInDb);
        }
        return;
      }

      setState(() {
        _allMessages.insertAll(0, older);
        _allMessages.sort(_compareMessages);
        _displayCount += older.length;
        _rebuildVisible();
        _hasMoreOlder = _allMessages.length < _totalInDb;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final newMax = _scroll.position.maxScrollExtent;
        _scroll.jumpTo(prevPixels + (newMax - prevMax));
      });
    } finally {
      _loadingOlder = false;
    }
  }

  Future<void> _connect() async {
    final socket = await widget.connections.connectTo(
      _resolveLivePeer(),
      forceNew: false,
    );
    if (socket != null && mounted) {
      setState(() => _connected = true);
      unawaited(_rememberPeerRecord());
      unawaited(_syncOutboundMessagesAfterConnect());
    }
  }

  /// Keeps [_peers.json] in sync so the home screen shows the right name when
  /// this peer is offline.
  Future<void> _rememberPeerRecord() async {
    final live = _resolveLivePeer();
    await widget.store.savePeerInfo(
      _peerId,
      live.name,
      live.ip,
      live.port,
      lanStableTag: live.lanStableTag,
    );
  }

  @override
  void dispose() {
    _storeRevisionDebounce?.cancel();
    _scrollLoadOlderDebounce?.cancel();
    widget.store.messageHistoryRevision.removeListener(_onStoreRevision);
    HardwareKeyboard.instance.removeHandler(_handleComposerHardwareKey);
    if (!kIsWeb && Platform.isAndroid) {
      AndroidShareInbound.detachChat();
    }
    _connTimer?.cancel();
    _scroll.removeListener(_onScroll);
    widget.connections.onMessage = _prevOnMessage;
    widget.connections.onDisconnected = _prevOnDisconnected;
    widget.connections.onIncomingConnection = _prevOnIncoming;
    _transferSub?.cancel();
    _fileMsgSub?.cancel();
    _transferThrottle?.cancel();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _handleJson(Map<String, dynamic> json) {
    final msg = ChatMessage.fromJson(json, widget.me.userId);
    if (msg == null) return;
    if (!mounted) return;
    if (_allMessages.any((m) => m.id == msg.id)) return;
    _insertMessageSorted(msg);
    _growVisibleForNewMessage();
    _totalInDb++;
    setState(() => _rebuildVisible());
    _scrollToBottom();
  }

  Future<void> _reloadMessagesFromStore() async {
    final grow = _totalInDb > _allMessages.length ? 1 : 0;
    // Do not cap by [_totalInDb] here — it can be stale; [loadRecentWindow] clamps to DB total.
    final take = max(_allMessages.length + grow, _initialHistoryWindow);
    final window = await widget.store.loadRecentWindow(_peerId, take);
    if (!mounted) return;
    _totalInDb = window.total;
    _allMessages
      ..clear()
      ..addAll(window.messages);
    _allMessages.sort(_compareMessages);
    _hasMoreOlder = _allMessages.length < _totalInDb;
    _displayCount = _displayCount.clamp(0, _allMessages.length);
    if (_allMessages.length <= _pageSize) {
      _displayCount = _allMessages.length;
    }
    _syncSendTimestampSeq();
    setState(() => _rebuildVisible());
    _scrollToBottom();
  }

  Future<void> _setMessageDelivery(String id, MessageDelivery d) async {
    await widget.store.updateDeliveryState(_peerId, id, d);
    if (!mounted) return;
    final i = _allMessages.indexWhere((m) => m.id == id);
    if (i >= 0) {
      _allMessages[i] = _allMessages[i].copyWith(delivery: d);
      setState(() => _rebuildVisible());
    }
  }

  Future<void> _transmitEncryptedText(ChatMessage msg) async {
    final b64 = await ChatCrypto.encryptMessage(
      widget.me.userId,
      _peerId,
      msg.text,
    );
    if (b64 == null) {
      await _setMessageDelivery(msg.id, MessageDelivery.undelivered);
      return;
    }
    final ok = widget.connections.sendJson(_peerId, {
      'type': 'message',
      'id': msg.id,
      'from': widget.me.userId,
      'time': msg.timestamp,
      'enc': true,
      'ct': b64,
    });
    if (!ok) {
      await _setMessageDelivery(msg.id, MessageDelivery.undelivered);
    }
  }

  Future<void> _retryDeliveryConfirm(String messageId) async {
    if (!widget.connections.isConnected(_peerId)) {
      final sock = await widget.connections.connectTo(
        _resolveLivePeer(),
        forceNew: true,
      );
      if (sock == null || !mounted) return;
      setState(() => _connected = true);
    }
    if (!widget.connections.isConnected(_peerId)) return;
    final ok = widget.connections.sendJson(_peerId, {
      'type': 'message_ack_confirm',
      'id': messageId,
      'from': widget.me.userId,
    });
    if (ok) {
      await _setMessageDelivery(messageId, MessageDelivery.delivered);
    }
  }

  Future<void> _resendTextMessage(ChatMessage m) async {
    if (m.attachmentName != null) return;
    if (m.delivery == MessageDelivery.awaitingConfirm) {
      await _retryDeliveryConfirm(m.id);
      return;
    }
    if (!widget.connections.isConnected(_peerId)) {
      final sock = await widget.connections.connectTo(
        _resolveLivePeer(),
        forceNew: true,
      );
      if (sock == null || !mounted) return;
      setState(() => _connected = true);
    }
    if (!widget.connections.isConnected(_peerId)) return;
    await _setMessageDelivery(m.id, MessageDelivery.pending);
    final updated = m.copyWith(delivery: MessageDelivery.pending);
    await _transmitEncryptedText(updated);
  }

  /// TCP drop: "Sent" without ack cannot be trusted — show as undelivered.
  Future<void> _onChatTcpLost() async {
    await widget.store.markPendingOutgoingAsUndelivered(_peerId);
    if (!mounted) return;
    await _reloadMessagesFromStore();
  }

  /// After reconnect: resend ciphertext or finish the delivery handshake.
  Future<void> _syncOutboundMessagesAfterConnect() async {
    final list = await widget.store.loadOutboundTextNeedingSync(_peerId);
    for (final m in list) {
      if (m.delivery == MessageDelivery.awaitingConfirm) {
        await _retryDeliveryConfirm(m.id);
        continue;
      }
      await _resendTextMessage(m);
    }
    if (mounted) await _reloadMessagesFromStore();
  }

  // -----------------------------------------------------------------------
  // Staging — pick files / images into preview, send all on press
  // -----------------------------------------------------------------------
  Future<void> _withSingleNativePicker(Future<void> Function() action) async {
    if (_nativePickerOpen) return;
    setState(() => _nativePickerOpen = true);
    try {
      await action();
    } finally {
      if (mounted) {
        setState(() => _nativePickerOpen = false);
      } else {
        _nativePickerOpen = false;
      }
    }
  }

  /// Reads an image from the system clipboard ([super_clipboard]), writes a temp file, stages it.
  /// Desktop: also bound to Ctrl/Cmd+Shift+V in [_handleComposerHardwareKey] so Ctrl+V stays text paste.
  Future<void> _pasteClipboardImageToStaging() async {
    if (!mounted) return;
    if (kIsWeb) {
      _showCopyFeedback('Paste image is not supported in the web build');
      return;
    }
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      _showCopyFeedback('Clipboard is not available');
      return;
    }
    late final ClipboardReader reader;
    try {
      reader = await clipboard.read();
    } catch (_) {
      if (mounted) _showCopyFeedback('Could not read clipboard');
      return;
    }

    final ordered = <(FileFormat, String)>[
      (Formats.png, 'png'),
      (Formats.jpeg, 'jpg'),
      (Formats.webp, 'webp'),
      (Formats.gif, 'gif'),
      (Formats.bmp, 'bmp'),
      (Formats.tiff, 'tiff'),
      (Formats.heic, 'heic'),
      (Formats.heif, 'heif'),
    ];

    for (final entry in ordered) {
      final format = entry.$1;
      final ext = entry.$2;
      if (!reader.canProvide(format)) continue;

      final completer = Completer<Uint8List?>();
      final progress = reader.getFile(
        format,
        (file) async {
          try {
            final bytes = await file.readAll();
            if (!completer.isCompleted) completer.complete(bytes);
          } catch (_) {
            if (!completer.isCompleted) completer.complete(null);
          }
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(null);
        },
      );
      if (progress == null) continue;

      final bytes = await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => null,
      );
      if (bytes == null || bytes.isEmpty) continue;

      final hashHex = sha256.convert(bytes).toString();
      if (_stagedClipboardHashes.contains(hashHex)) {
        if (mounted) {
          _showCopyFeedback('Same image already in composer');
        }
        return;
      }

      try {
        final dir = await getTemporaryDirectory();
        final n = _clipboardPasteImageSeq;
        _clipboardPasteImageSeq++;
        final name = 'Image_${n.toString().padLeft(2, '0')}.$ext';
        final outPath = p.join(dir.path, name);
        await File(outPath).writeAsBytes(bytes);
        if (!mounted) return;
        _stageFiles([
          DeferredStagedFile(
            sourcePath: outPath,
            displayName: name,
            kind: StagedSourceKind.file,
            clipboardPasteHash: hashHex,
          ),
        ]);
        _showCopyFeedback('Image pasted');
      } catch (_) {
        if (mounted) {
          _showCopyFeedback('Could not save pasted image');
        }
      }
      return;
    }

    if (mounted) {
      _showCopyFeedback('No image in clipboard');
    }
  }

  void _stageFiles(List<DeferredStagedFile> files) {
    if (files.isEmpty) return;
    final existingKeys = _staged.map((e) => e.stagingDedupeKey).toSet();
    final added = <DeferredStagedFile>[];
    var duplicateCount = 0;
    for (final f in files) {
      final clipHash = f.clipboardPasteHash;
      if (clipHash != null &&
          clipHash.isNotEmpty &&
          _stagedClipboardHashes.contains(clipHash)) {
        duplicateCount++;
        continue;
      }
      final k = f.stagingDedupeKey;
      if (k.isEmpty) {
        added.add(f);
        continue;
      }
      if (existingKeys.contains(k)) {
        duplicateCount++;
        continue;
      }
      existingKeys.add(k);
      added.add(f);
    }
    // Defer so the picker can finish dismissing before a heavy ListView rebuild
    // (helps Android jank with many / large staged items).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (added.isNotEmpty) {
        setState(() {
          _staged.addAll(added);
          for (final f in added) {
            final h = f.clipboardPasteHash;
            if (h != null && h.isNotEmpty) {
              _stagedClipboardHashes.add(h);
            }
          }
        });
      }
      if (duplicateCount > 0) {
        _showCopyFeedback('Duplicate removed');
      }
    });
  }

  Future<void> _pickFiles() async {
    await _withSingleNativePicker(() async {
      // Android: native SAF picker returns content:// URIs only — no cache copy at pick time.
      // The file_picker plugin always streams content:// into app cache before returning.
      if (Platform.isAndroid) {
        final staged = await AndroidAttachmentPicker.pickFiles();
        if (staged.isEmpty) return;
        _stageFiles(staged);
        return;
      }
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: true,
        withData: false,
      );
      if (picked == null) return;
      _stageFiles(
        picked.files
            .where((f) => f.path != null)
            .map(
              (f) => DeferredStagedFile(
                sourcePath: f.path!,
                displayName: f.name,
                knownSizeBytes: f.size,
              ),
            )
            .toList(),
      );
    });
  }

  Future<void> _pickFolder() async {
    await _withSingleNativePicker(() async {
      final dirPath = await FilePicker.platform.getDirectoryPath();
      if (dirPath == null) return;
      final folderName = dirPath.split(Platform.pathSeparator).last;
      _stageFiles([
        DeferredStagedFile(
          sourcePath: dirPath,
          displayName: '$folderName.zip',
          kind: StagedSourceKind.folderToZip,
        ),
      ]);
    });
  }

  Future<void> _pickGallery() async {
    await _withSingleNativePicker(() async {
      final picker = ImagePicker();
      final images = await picker.pickMultiImage(limit: 20);
      if (images.isEmpty) return;
      _stageFiles(
        images
            .map(
              (x) =>
                  DeferredStagedFile(sourcePath: x.path, displayName: x.name),
            )
            .toList(),
      );
    });
  }

  void _onDropDone(DropDoneDetails details) {
    _stageFiles(
      details.files
          .map(
            (x) => DeferredStagedFile(sourcePath: x.path, displayName: x.name),
          )
          .toList(),
    );
  }

  // -----------------------------------------------------------------------
  // Send — text + all staged files via TransferManager
  // -----------------------------------------------------------------------
  /// Trims leading/trailing whitespace; normalizes NBSP; caps runs of 3+ newlines to 2.
  static String normalizeOutgoingMessageText(String raw) {
    var s = raw.replaceAll('\u00a0', ' ').trim();
    while (s.contains('\n\n\n')) {
      s = s.replaceAll('\n\n\n', '\n\n');
    }
    return s;
  }

  Future<void> _sendAll() async {
    final toSend = normalizeOutgoingMessageText(_input.text);
    final hasText = toSend.isNotEmpty;
    final hasFiles = _staged.isNotEmpty;

    if (!hasText && !hasFiles) return;
    if (hasFiles && !_connected) return;

    if (hasText) {
      final live = _resolveLivePeer();
      final msg = ChatMessage(
        id: _uuid.v4(),
        senderId: widget.me.userId,
        text: toSend,
        timestamp: _nextOutgoingTimestamp(),
        isMine: true,
        delivery: _connected
            ? MessageDelivery.pending
            : MessageDelivery.undelivered,
      );
      _insertMessageSorted(msg);
      _growVisibleForNewMessage();
      setState(() => _rebuildVisible());
      final inserted = await widget.store.add(
        _peerId,
        msg,
        peerDisplayName: live.name,
        peerIp: live.ip,
        peerTcpPort: live.port,
      );
      if (inserted) _totalInDb++;
      _input.clear();
      if (_connected) {
        await _transmitEncryptedText(msg);
      }
    }

    if (hasFiles) {
      final raw = List<DeferredStagedFile>.from(_staged);
      setState(() {
        _staged.clear();
        _stagedClipboardHashes.clear();
      });
      final seenKeys = <String>{};
      for (final df in raw) {
        final key = df.stagingDedupeKey;
        final dup = seenKeys.contains(key);
        if (!dup) seenKeys.add(key);
        await _sendDeferredFile(df, duplicatePathInBatch: dup);
      }
    }

    _focus.requestFocus();
    _scrollToBottom();
  }

  Future<void> _sendDeferredFile(
    DeferredStagedFile df, {
    required bool duplicatePathInBatch,
  }) async {
    final live = _resolveLivePeer();
    if (!widget.connections.isConnected(_peerId)) {
      await widget.connections.connectTo(live, forceNew: false);
    }
    final fileId = _uuid.v4();
    final ts = _nextOutgoingTimestamp();
    final msg = ChatMessage(
      id: fileId,
      senderId: widget.me.userId,
      text: 'File: ${df.displayName}',
      timestamp: ts,
      isMine: true,
      attachmentName: df.displayName,
      attachmentPath:
          df.kind == StagedSourceKind.file &&
              !duplicatePathInBatch &&
              df.androidContentUri == null &&
              (df.sourcePath != null && df.sourcePath!.isNotEmpty)
          ? df.sourcePath
          : null,
      attachmentSize: df.knownSizeBytes,
    );
    _insertMessageSorted(msg);
    _growVisibleForNewMessage();
    setState(() => _rebuildVisible());
    final inserted = await widget.store.add(
      _peerId,
      msg,
      peerDisplayName: live.name,
      peerIp: live.ip,
      peerTcpPort: live.port,
    );
    if (inserted) _totalInDb++;
    if (!mounted) return;
    await _tm.prepareAndSendOutbound(
      initialMessage: msg,
      peerId: _peerId,
      peerIp: live.ip,
      peerDisplayName: live.name,
      sourcePath: df.sourcePath ?? '',
      androidContentUri: df.androidContentUri,
      kind: df.kind,
      duplicatePathInBatch: duplicatePathInBatch,
    );
  }

  void _cancelTransfer(String fileId) {
    _tm.cancel(fileId);
  }

  String? _mimeTypeForPath(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.png':
        return 'image/png';
      case '.jpg':
      case '.jpeg':
        return 'image/jpeg';
      case '.gif':
        return 'image/gif';
      case '.webp':
        return 'image/webp';
      case '.bmp':
        return 'image/bmp';
      case '.heic':
      case '.heif':
        return 'image/heic';
      default:
        return null;
    }
  }

  Future<void> _openAttachmentPath(String path) async {
    final f = File(path);
    if (!await f.exists()) {
      if (mounted) _showCopyFeedback('File not found');
      return;
    }
    final mime = _mimeTypeForPath(path);
    final r = await OpenFilex.open(path, type: mime);
    if (!mounted) return;
    if (r.type != ResultType.done) {
      _showCopyFeedback('Could not open file');
    }
  }

  void _openFolder(String filePath) {
    final fallback = AppSettings.instance.downloadPath.value;
    final file = File(filePath);
    if (file.existsSync()) {
      if (Platform.isWindows) {
        Process.run('explorer.exe', ['/select,', filePath]);
      } else if (Platform.isMacOS) {
        Process.run('open', ['-R', filePath]);
      } else {
        unawaited(OpenFilex.open(file.parent.path));
      }
      return;
    }
    if (fallback.isNotEmpty) {
      final d = Directory(fallback);
      if (d.existsSync()) {
        if (Platform.isWindows) {
          Process.run('explorer.exe', [fallback]);
        } else if (Platform.isMacOS) {
          Process.run('open', [fallback]);
        } else {
          unawaited(OpenFilex.open(fallback));
        }
        return;
      }
    }
    final parent = file.parent.path;
    if (Directory(parent).existsSync()) {
      if (Platform.isWindows) {
        Process.run('explorer.exe', [parent]);
      } else if (Platform.isMacOS) {
        Process.run('open', [parent]);
      } else {
        unawaited(OpenFilex.open(parent));
      }
    } else if (mounted) {
      _showCopyFeedback('File not found');
    }
  }

  Future<void> _locateFileAndroid(String filePath) async {
    final f = File(filePath);
    final dl = AppSettings.instance.downloadPath.value;
    final String folderToOpen;
    if (await f.exists()) {
      folderToOpen = f.parent.path;
    } else if (dl.isNotEmpty && await Directory(dl).exists()) {
      folderToOpen = dl;
    } else {
      final parent = f.parent.path;
      if (await Directory(parent).exists()) {
        folderToOpen = parent;
      } else {
        if (mounted) _showCopyFeedback('File not found');
        return;
      }
    }
    try {
      await _appControlChannel.invokeMethod<void>('openFolderInFileManager', {
        'path': folderToOpen,
      });
    } catch (_) {
      try {
        await _appControlChannel.invokeMethod<void>('openApplicationDetailsSettings');
      } catch (_) {
        if (mounted) _showCopyFeedback('Could not open folder');
      }
    }
  }

  // -----------------------------------------------------------------------
  // Clear chat
  // -----------------------------------------------------------------------
  void _confirmClearChat() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Chat'),
        content: const Text(
          'Delete all messages in this conversation? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await widget.store.clear(_peerId);
              if (mounted) {
                setState(() {
                  _allMessages.clear();
                  _messages.clear();
                  _displayCount = _pageSize;
                  _totalInDb = 0;
                  _hasMoreOlder = false;
                });
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final h = dt.hour == 0 ? 12 : (dt.hour > 12 ? dt.hour - 12 : dt.hour);
    final m = dt.minute.toString().padLeft(2, '0');
    final period = dt.hour >= 12 ? 'PM' : 'AM';
    return '$h:$m $period';
  }

  String _fmtDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    if (msgDay == today) return 'Today';
    if (msgDay == today.subtract(const Duration(days: 1))) return 'Yesterday';
    const months = [
      '',
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }

  bool _needsDateSeparator(int index) {
    if (index == 0) return true;
    final prev = DateTime.fromMillisecondsSinceEpoch(
      _messages[index - 1].timestamp,
    );
    final curr = DateTime.fromMillisecondsSinceEpoch(
      _messages[index].timestamp,
    );
    return prev.year != curr.year ||
        prev.month != curr.month ||
        prev.day != curr.day;
  }

  Widget _buildDateSeparator(BuildContext context, DateTime dt) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              _fmtDate(dt),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: cs.outline,
              ),
            ),
          ),
          Expanded(
            child: Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
        ],
      ),
    );
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }

  static String _fmtSpeed(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    final kb = bytesPerSec / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB/s';
    return '${(mb / 1024).toStringAsFixed(1)} GB/s';
  }

  bool _isImage(String name) {
    final l = name.toLowerCase();
    return l.endsWith('.png') ||
        l.endsWith('.jpg') ||
        l.endsWith('.jpeg') ||
        l.endsWith('.gif') ||
        l.endsWith('.webp') ||
        l.endsWith('.bmp');
  }

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  static TextStyle _messageBodyStyle(Color color) =>
      TextStyle(color: color, fontSize: 15, height: 1.35);

  /// Preserves line breaks and spacing; selection toolbar includes Copy.
  Widget _buildSelectableMessageBody(String text, Color color) {
    return SelectableText(text, style: _messageBodyStyle(color));
  }

  static String _fileTypeLabel(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return 'File';
    final ext = name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'svg' => 'Image',
      'mp4' || 'mkv' || 'avi' || 'mov' || 'wmv' || 'flv' => 'Video',
      'mp3' || 'wav' || 'flac' || 'aac' || 'ogg' || 'wma' => 'Audio',
      'pdf' => 'PDF Document',
      'doc' || 'docx' => 'Word Document',
      'xls' || 'xlsx' => 'Spreadsheet',
      'ppt' || 'pptx' => 'Presentation',
      'zip' || 'rar' || '7z' || 'tar' || 'gz' => 'Archive',
      'txt' || 'log' || 'csv' => 'Text File',
      'apk' => 'Android Package',
      'exe' || 'msi' => 'Executable',
      'dart' ||
      'py' ||
      'js' ||
      'ts' ||
      'java' ||
      'cpp' ||
      'c' ||
      'h' => 'Source Code',
      'json' || 'xml' || 'yaml' || 'yml' => 'Data File',
      _ => '${ext.toUpperCase()} File',
    };
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: widget.peer.avatarColor,
              child: Text(
                widget.peer.name.isNotEmpty
                    ? widget.peer.name[0].toUpperCase()
                    : '?',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.peer.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _connected ? Colors.green : cs.error,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _connected ? 'Connected' : 'Disconnected',
                      style: TextStyle(
                        color: _connected ? Colors.green : cs.error,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear') _confirmClearChat();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  leading: Icon(Icons.delete_sweep),
                  title: Text('Clear Chat'),
                  dense: true,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _messages.isEmpty
                  ? Center(
                      child: Text(
                        'No messages yet',
                        style: TextStyle(color: cs.outline),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      cacheExtent: 400,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      itemCount: _messages.length,
                      itemBuilder: (ctx, i) {
                        final widgets = <Widget>[];
                        if (_needsDateSeparator(i)) {
                          widgets.add(
                            _buildDateSeparator(
                              ctx,
                              DateTime.fromMillisecondsSinceEpoch(
                                _messages[i].timestamp,
                              ),
                            ),
                          );
                        }
                        widgets.add(_buildBubble(ctx, _messages[i]));
                        return RepaintBoundary(
                          key: ValueKey<String>(_messages[i].id),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: widgets,
                          ),
                        );
                      },
                    ),
            ),
            _buildComposerStrip(context),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Composer + staged strip (desktop: file drop only on this strip, not the message list)
  // -----------------------------------------------------------------------
  Widget _buildComposerStrip(BuildContext context) {
    final bottom = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_staged.isNotEmpty) _buildStagedPreview(context),
        _buildComposer(context),
      ],
    );
    if (!_isDesktop) return bottom;
    return DropTarget(
      enable: ModalRoute.of(context)?.isCurrent ?? true,
      onDragDone: _onDropDone,
      child: bottom,
    );
  }

  // -----------------------------------------------------------------------
  // Staged files preview strip
  // -----------------------------------------------------------------------
  Widget _buildStagedPreview(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                '${_staged.length} file${_staged.length > 1 ? 's' : ''} ready to send',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() {
                  _staged.clear();
                  _stagedClipboardHashes.clear();
                }),
                child: Text(
                  'Clear all',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.error,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 72,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _staged.length,
              itemBuilder: (ctx, i) {
                final df = _staged[i];
                final isFolder = df.kind == StagedSourceKind.folderToZip;
                final previewPath = df.localPathForPreview;
                final isImg =
                    previewPath != null &&
                    _isImage(df.displayName) &&
                    !isFolder;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: cs.surfaceContainerHighest,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: _StagedThumbTile(
                          path: previewPath,
                          name: df.displayName,
                          isImage: isImg,
                          isFolder: isFolder,
                          knownSizeBytes: df.knownSizeBytes,
                          cs: cs,
                          imageWrapper: (image) => _wrapImageWithContextMenu(
                            path: previewPath!,
                            fileName: df.displayName,
                            image: image,
                          ),
                        ),
                      ),
                      Positioned(
                        top: -4,
                        right: -4,
                        child: Material(
                          elevation: 4,
                          shadowColor: Colors.black54,
                          shape: const CircleBorder(),
                          color: cs.surface,
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => setState(() {
                              final r = _staged.removeAt(i);
                              final h = r.clipboardPasteHash;
                              if (h != null && h.isNotEmpty) {
                                _stagedClipboardHashes.remove(h);
                              }
                            }),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                size: 18,
                                color: cs.onSurface,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Bubbles — reads transfer state from TransferManager
  // -----------------------------------------------------------------------
  String _deliveryStatusLabel(MessageDelivery d) {
    switch (d) {
      case MessageDelivery.delivered:
        return 'Delivered';
      case MessageDelivery.awaitingConfirm:
        return 'Confirming';
      case MessageDelivery.pending:
        return 'Sent';
      case MessageDelivery.undelivered:
        return 'Undelivered';
    }
  }

  void _showCopyFeedback(String message) {
    if (!mounted) return;
    final now = DateTime.now();
    if (_lastSnackMessage == message &&
        _lastSnackAt != null &&
        now.difference(_lastSnackAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastSnackMessage = message;
    _lastSnackAt = now;
    final ms = ScaffoldMessenger.of(context);
    ms.clearSnackBars();
    ms.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 1800),
        behavior: SnackBarBehavior.floating,
        margin: appSnackBarMargin(context),
        dismissDirection: DismissDirection.up,
      ),
    );
  }

  void _copyMessage(ChatMessage m) {
    String text;
    if (m.attachmentPath != null && _isImage(m.attachmentName ?? '')) {
      text = m.attachmentPath!;
    } else if (m.attachmentName != null) {
      text = m.attachmentPath ?? m.attachmentName!;
    } else {
      text = m.text;
    }
    Clipboard.setData(ClipboardData(text: text));
    _showCopyFeedback('Copied to clipboard');
  }

  void _showCopyMenu(BuildContext context, Offset position, ChatMessage m) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: const [PopupMenuItem(value: 'copy', child: Text('Copy'))],
    ).then((value) {
      if (value == 'copy') _copyMessage(m);
    });
  }

  static const _iMessageBlue = Color(0xFF007AFF);
  static const _iMessageGray = Color(0xFFE5E5EA);
  static const _iMessageDarkGray = Color(0xFF3A3A3C);

  static const _failedRed = Color(0xFFFF3B30);
  static const _cancelledAmber = Color(0xFFFF9500);

  Widget _buildBubble(BuildContext context, ChatMessage m) {
    final cs = Theme.of(context).colorScheme;
    final mine = m.isMine;
    final t = _tm.transfers[m.id];
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bool isFailed = t != null && t.error != null && !t.cancelled;
    final bool isCancelled = t != null && t.cancelled;
    final bool isPaused =
        t != null && t.isPaused && t.error == null && !t.cancelled;
    final bool dismissedAborted =
        m.transferDismissed && m.attachmentName != null && t == null;

    Color bubbleColor;
    if (dismissedAborted) {
      bubbleColor = isDark
          ? const Color(0xFF4A4A4A).withValues(alpha: 0.85)
          : const Color(0xFFD0D0D0);
    } else if (isFailed) {
      bubbleColor = _failedRed.withValues(alpha: 0.15);
    } else if (isCancelled) {
      bubbleColor = _cancelledAmber.withValues(alpha: 0.12);
    } else {
      bubbleColor = mine
          ? _iMessageBlue
          : (isDark ? _iMessageDarkGray : _iMessageGray);
    }

    final textColor = (isFailed || isCancelled)
        ? (isDark ? Colors.white : Colors.black87)
        : dismissedAborted
        ? (isDark ? Colors.white54 : Colors.black45)
        : (mine ? Colors.white : (isDark ? Colors.white : Colors.black));
    final subtleColor = (isFailed || isCancelled)
        ? (isDark ? Colors.white60 : Colors.black54)
        : dismissedAborted
        ? (isDark ? Colors.white38 : Colors.black38)
        : (mine
              ? Colors.white.withValues(alpha: 0.6)
              : (isDark ? Colors.white60 : Colors.black54));

    final bubble = Container(
      constraints: const BoxConstraints(maxWidth: 520),
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: bubbleColor,
        border: dismissedAborted
            ? Border.all(
                color: isDark ? Colors.white24 : Colors.black26,
                width: 1,
              )
            : (isFailed || isCancelled)
            ? Border.all(
                color: isFailed ? _failedRed : _cancelledAmber,
                width: 1.2,
              )
            : null,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(18),
          topRight: const Radius.circular(18),
          bottomLeft: Radius.circular(mine ? 18 : 4),
          bottomRight: Radius.circular(mine ? 4 : 18),
        ),
      ),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          if (m.attachmentName != null)
            _buildAttachment(context, m, mine, dismissedAborted)
          else
            _buildSelectableMessageBody(m.text, textColor),

          if (mine && m.attachmentName == null && m.delivery != null) ...[
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _deliveryStatusLabel(m.delivery!),
                  style: TextStyle(
                    fontSize: 11,
                    color: subtleColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (m.delivery == MessageDelivery.undelivered ||
                    m.delivery == MessageDelivery.awaitingConfirm) ...[
                  const SizedBox(width: 10),
                  InkWell(
                    onTap: () => unawaited(_resendTextMessage(m)),
                    child: Text(
                      'Resend',
                      style: TextStyle(
                        fontSize: 11,
                        color: mine ? Colors.white : cs.primary,
                        fontWeight: FontWeight.w700,
                        decoration: TextDecoration.underline,
                        decorationColor: mine ? Colors.white70 : cs.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],

          if (t != null) ...[
            const SizedBox(height: 8),
            if (isFailed || isCancelled) ...[
              Row(
                children: [
                  Icon(
                    isFailed ? Icons.error_outline : Icons.cancel_outlined,
                    size: 16,
                    color: isFailed ? _failedRed : _cancelledAmber,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      isFailed
                          ? 'Not delivered — transfer failed'
                          : 'Cancelled',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: isFailed ? _failedRed : _cancelledAmber,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _actionButton(
                label: 'Dismiss',
                icon: Icons.close,
                color: cs.outline,
                onTap: () => _tm.dismiss(m.id),
              ),
            ] else if (isPaused) ...[
              LinearProgressIndicator(
                value: t.progress.clamp(0, 1).toDouble(),
                minHeight: 5,
                borderRadius: BorderRadius.circular(99),
                backgroundColor: mine ? Colors.white24 : cs.outlineVariant,
                color: mine ? Colors.white70 : cs.outline,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.hourglass_empty, size: 16, color: cs.outline),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      t.isSending
                          ? 'Reconnecting\u2026'
                          : 'Waiting for sender\u2026',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: subtleColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _actionButton(
                label: 'Cancel',
                icon: Icons.stop_circle_outlined,
                color: _failedRed,
                onTap: () => _cancelTransfer(m.id),
              ),
            ] else if (t.isSending &&
                t.outgoingPhase == OutgoingTransferPhase.preparing) ...[
              LinearProgressIndicator(
                value: t.totalBytes > 0
                    ? t.progress.clamp(0, 1).toDouble()
                    : null,
                minHeight: 5,
                borderRadius: BorderRadius.circular(99),
                backgroundColor: mine ? Colors.white24 : cs.outlineVariant,
                color: mine ? Colors.white : _iMessageBlue,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t.totalBytes > 0
                          ? 'Preparing\u2026 ${(t.progress * 100).toStringAsFixed(0)}%'
                                ' \u2022 ${_fmtBytes(t.transferredBytes)}/${_fmtBytes(t.totalBytes)}'
                          : 'Preparing\u2026',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: subtleColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _actionButton(
                    label: 'Cancel',
                    icon: Icons.stop_circle_outlined,
                    color: _failedRed,
                    onTap: () => _cancelTransfer(m.id),
                  ),
                ],
              ),
            ] else ...[
              LinearProgressIndicator(
                value: t.progress.clamp(0, 1).toDouble(),
                minHeight: 5,
                borderRadius: BorderRadius.circular(99),
                backgroundColor: mine ? Colors.white24 : cs.outlineVariant,
                color: mine ? Colors.white : _iMessageBlue,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${t.isSending ? "Sending\u2026 " : "Receiving\u2026 "}'
                      '${(t.progress * 100).toStringAsFixed(0)}%'
                      ' \u2022 ${_fmtBytes(t.transferredBytes)}/${_fmtBytes(t.totalBytes)}'
                      ' \u2022 ${_fmtSpeed(t.currentSpeed)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: subtleColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _actionButton(
                    label: 'Cancel',
                    icon: Icons.stop_circle_outlined,
                    color: _failedRed,
                    onTap: () => _cancelTransfer(m.id),
                  ),
                ],
              ),
            ],
          ],
          if (mine &&
              m.attachmentName != null &&
              t == null &&
              m.attachmentPath != null &&
              !m.transferDismissed &&
              !dismissedAborted) ...[
            const SizedBox(height: 6),
            Text(
              'Delivered',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: subtleColor,
              ),
            ),
          ],

          const SizedBox(height: 4),
          Text(
            _fmtTime(m.timestamp),
            style: TextStyle(fontSize: 11, color: subtleColor),
          ),
        ],
      ),
    );

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: m.attachmentName != null
          ? GestureDetector(
              onLongPress: () => _copyMessage(m),
              onSecondaryTapUp: (details) =>
                  _showCopyMenu(context, details.globalPosition, m),
              child: bubble,
            )
          : bubble,
    );
  }

  Future<void> _showAttachmentImageMenu(
    BuildContext context,
    Offset globalPosition, {
    required String path,
    required String fileName,
  }) async {
    final overlayState = Overlay.maybeOf(context);
    final overlayBox = overlayState?.context.findRenderObject() as RenderBox?;
    if (overlayBox == null) return;

    final topLeft = overlayBox.globalToLocal(globalPosition);
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(topLeft.dx, topLeft.dy, 0, 0),
        Offset.zero & overlayBox.size,
      ),
      items: const [
        PopupMenuItem(value: 'path', child: Text('Copy file path')),
        PopupMenuItem(value: 'image', child: Text('Copy image to clipboard')),
      ],
    );
    if (!context.mounted) return;
    if (selected == 'path') {
      await Clipboard.setData(ClipboardData(text: path));
      if (!context.mounted) return;
      _showCopyFeedback('File path copied');
    } else if (selected == 'image') {
      await _copyImageBytesToClipboard(path, fileName);
    }
  }

  Future<void> _copyImageBytesToClipboard(
    String path,
    String displayFileName,
  ) async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await _appControlChannel.invokeMethod<void>('copyImageToClipboard', {
          'path': path,
        });
        if (!context.mounted) return;
        _showCopyFeedback('Image copied to clipboard');
      } catch (e) {
        if (!context.mounted) return;
        _showCopyFeedback('Could not copy image: $e');
      }
      return;
    }
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      if (!context.mounted) return;
      _showCopyFeedback('Image clipboard is not available here');
      return;
    }
    try {
      final bytes = await File(path).readAsBytes();
      if (!context.mounted) return;
      final item = DataWriterItem(suggestedName: p.basename(displayFileName));
      final ext = p.extension(displayFileName).toLowerCase();
      if (ext == '.png') {
        item.add(Formats.png(bytes));
      } else if (ext == '.jpg' || ext == '.jpeg') {
        item.add(Formats.jpeg(bytes));
      } else if (ext == '.gif') {
        item.add(Formats.gif(bytes));
      } else if (ext == '.webp') {
        item.add(Formats.webp(bytes));
      } else if (ext == '.bmp') {
        item.add(Formats.bmp(bytes));
      } else {
        item.add(Formats.png(bytes));
      }
      await clipboard.write([item]);
      if (!context.mounted) return;
      _showCopyFeedback('Image copied to clipboard');
    } catch (e) {
      if (!context.mounted) return;
      _showCopyFeedback('Could not copy image: $e');
    }
  }

  Widget _wrapImageWithContextMenu({
    required String path,
    required String fileName,
    required Widget image,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_openAttachmentPath(path)),
      onLongPressStart: (d) => unawaited(
        _showAttachmentImageMenu(
          context,
          d.globalPosition,
          path: path,
          fileName: fileName,
        ),
      ),
      onSecondaryTapDown: (d) => unawaited(
        _showAttachmentImageMenu(
          context,
          d.globalPosition,
          path: path,
          fileName: fileName,
        ),
      ),
      child: image,
    );
  }

  /// Thumbnail in bubble: [cacheWidth] only preserves aspect ratio; [BoxFit.contain] avoids stretch.
  /// [messageId] + [path] in [ValueKey] prevents ListView recycle from swapping Image state (Android).
  Widget _bubbleAttachmentImage(String messageId, String path) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final decodeW = (_bubbleImageW * dpr).round();
    final skipDecodeResize = !kIsWeb && Platform.isAndroid;
    final subtle = Theme.of(context).colorScheme.outline;
    final bg = Theme.of(context).brightness == Brightness.dark
        ? Colors.black.withValues(alpha: 0.22)
        : Colors.black.withValues(alpha: 0.06);
    return SizedBox(
      width: _bubbleImageW,
      height: _bubbleImageH,
      child: ColoredBox(
        color: bg,
        child: Image.file(
          File(path),
          key: ValueKey<String>('bubble-img-$messageId-$path'),
          width: _bubbleImageW,
          height: _bubbleImageH,
          fit: BoxFit.contain,
          alignment: Alignment.center,
          filterQuality: FilterQuality.low,
          gaplessPlayback: true,
          isAntiAlias: false,
          cacheWidth: skipDecodeResize ? null : decodeW,
          errorBuilder: (_, _, _) => SizedBox(
            width: _bubbleImageW,
            height: _bubbleImageH,
            child: Center(
              child: Icon(Icons.broken_image_outlined, size: 40, color: subtle),
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionButton({
    required String label,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAttachment(
    BuildContext context,
    ChatMessage m,
    bool mine,
    bool strikeAborted,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasPath = m.attachmentPath != null;
    final isImg = hasPath && _isImage(m.attachmentName!);
    final isTransferring = _tm.transfers.containsKey(m.id);
    final fgColor = strikeAborted
        ? (isDark ? Colors.orangeAccent.shade100 : Colors.deepOrange.shade800)
        : (mine ? Colors.white : (isDark ? Colors.white : Colors.black));
    final subtleColor = mine
        ? Colors.white.withValues(alpha: 0.7)
        : (isDark ? Colors.white60 : Colors.black54);

    final typeLabel = _fileTypeLabel(m.attachmentName!);
    final sizeLabel = m.attachmentSize != null
        ? _fmtBytes(m.attachmentSize!)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isImg && !strikeAborted)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _wrapImageWithContextMenu(
                path: m.attachmentPath!,
                fileName: m.attachmentName!,
                image: _bubbleAttachmentImage(m.id, m.attachmentPath!),
              ),
            ),
          ),
        GestureDetector(
          onTap: hasPath && !strikeAborted
              ? () => unawaited(_openAttachmentPath(m.attachmentPath!))
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isImg ? Icons.image : Icons.insert_drive_file,
                size: 18,
                color: fgColor,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  m.attachmentName!,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fgColor,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    decoration: strikeAborted
                        ? TextDecoration.lineThrough
                        : (hasPath
                              ? TextDecoration.underline
                              : TextDecoration.none),
                    decorationThickness: strikeAborted ? 2.8 : 1,
                    decorationColor: strikeAborted ? fgColor : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (!isTransferring && (sizeLabel != null || typeLabel.isNotEmpty))
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              sizeLabel != null ? '$typeLabel \u2022 $sizeLabel' : typeLabel,
              style: TextStyle(
                fontSize: 11,
                color: subtleColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        if (hasPath && !isTransferring && _isDesktop)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _openFolder(m.attachmentPath!),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open, size: 14, color: subtleColor),
                    const SizedBox(width: 4),
                    Text(
                      'View In Explorer',
                      style: TextStyle(
                        fontSize: 11,
                        color: subtleColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        if (hasPath && !isTransferring && !kIsWeb && Platform.isAndroid)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _locateFileAndroid(m.attachmentPath!),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.file_open_outlined,
                      size: 14,
                      color: subtleColor,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Locate File',
                      style: TextStyle(
                        fontSize: 11,
                        color: subtleColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// Right-click / long-press: default text operations + paste image (desktop + Android).
  Widget _composerContextMenu(BuildContext context, EditableTextState state) {
    final cs = Theme.of(context).colorScheme;
    final isAndroid = !kIsWeb && Platform.isAndroid;
    final toolbar = AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: <ContextMenuButtonItem>[
        ...state.contextMenuButtonItems,
        if (_isDesktop || isAndroid)
          ContextMenuButtonItem(
            label: isAndroid ? 'Paste image' : 'Paste image from clipboard',
            onPressed: () {
              state.hideToolbar();
              unawaited(_pasteClipboardImageToStaging());
            },
          ),
      ],
    );
    if (isAndroid) {
      return Material(
        elevation: 4,
        surfaceTintColor: cs.surfaceTint,
        shadowColor: Colors.black.withValues(alpha: 0.28),
        borderRadius: BorderRadius.circular(14),
        color: cs.surfaceContainerHigh,
        clipBehavior: Clip.antiAlias,
        child: toolbar,
      );
    }
    return toolbar;
  }

  // -----------------------------------------------------------------------
  // Composer
  // -----------------------------------------------------------------------
  Widget _buildComposer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hint = _staged.isNotEmpty
        ? 'Add a message (optional)...'
        : (_isDesktop
              ? 'Message — Enter send · Shift+Enter new line · Ctrl+Shift+V paste image'
              : (!kIsWeb && Platform.isAndroid
                    ? 'Message — long-press field for paste text / paste image'
                    : 'Message'));

    // Rebuild only the composer row on typing — not the whole chat (avoids jank).
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: ListenableBuilder(
        listenable: _input,
        builder: (context, _) {
          final textReady = normalizeOutgoingMessageText(
            _input.text,
          ).isNotEmpty;
          final canSend = textReady || (_connected && _staged.isNotEmpty);
          return Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton.filled(
                onPressed: _nativePickerOpen ? null : _pickFiles,
                tooltip: 'Attach Files',
                icon: const Icon(Icons.attach_file),
              ),
              if (_isDesktop) ...[
                const SizedBox(width: 4),
                IconButton.filled(
                  onPressed: _nativePickerOpen ? null : _pickFolder,
                  tooltip: 'Attach Folder',
                  style: IconButton.styleFrom(
                    backgroundColor: cs.secondaryContainer,
                    foregroundColor: cs.onSecondaryContainer,
                  ),
                  icon: const Icon(Icons.folder),
                ),
              ],
              if (!kIsWeb && Platform.isAndroid) ...[
                const SizedBox(width: 4),
                IconButton.filled(
                  onPressed: _nativePickerOpen ? null : _pickGallery,
                  tooltip: 'Gallery',
                  style: IconButton.styleFrom(
                    backgroundColor: cs.secondaryContainer,
                    foregroundColor: cs.onSecondaryContainer,
                  ),
                  icon: const Icon(Icons.photo_library),
                ),
              ],
              if (!kIsWeb && !Platform.isAndroid) ...[
                const SizedBox(width: 4),
                IconButton.filled(
                  onPressed: _nativePickerOpen
                      ? null
                      : () => unawaited(_pasteClipboardImageToStaging()),
                  tooltip: _isDesktop
                      ? 'Paste image from clipboard (Ctrl+Shift+V or Cmd+Shift+V)'
                      : 'Paste image from clipboard',
                  style: IconButton.styleFrom(
                    backgroundColor: cs.secondaryContainer,
                    foregroundColor: cs.onSecondaryContainer,
                  ),
                  icon: const Icon(Icons.content_paste_go),
                ),
              ],
              const SizedBox(width: 8),
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minHeight: 48,
                    maxHeight: 168,
                  ),
                  child: Material(
                    color: cs.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(22),
                    clipBehavior: Clip.antiAlias,
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      minLines: 1,
                      maxLines: null,
                      contextMenuBuilder: kIsWeb ? null : _composerContextMenu,
                      textAlignVertical: TextAlignVertical.top,
                      scrollPadding: const EdgeInsets.only(
                        bottom: 120,
                        top: 16,
                      ),
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge?.copyWith(height: 1.35),
                      scrollPhysics: const ClampingScrollPhysics(),
                      decoration: InputDecoration(
                        hintText: hint,
                        hintStyle: TextStyle(
                          color: cs.onSurfaceVariant.withValues(alpha: 0.65),
                          fontSize: 13,
                        ),
                        border: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: const EdgeInsets.fromLTRB(
                          16,
                          12,
                          16,
                          12,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: canSend ? () => unawaited(_sendAll()) : null,
                icon: const Icon(Icons.send),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Staged attachment thumbnail: avoids decoding huge images on the UI thread (Android jank).
class _StagedThumbTile extends StatefulWidget {
  final String? path;
  final String name;
  final bool isImage;
  final bool isFolder;
  final int? knownSizeBytes;
  final ColorScheme cs;
  final Widget Function(Widget image) imageWrapper;

  const _StagedThumbTile({
    this.path,
    required this.name,
    required this.isImage,
    this.isFolder = false,
    this.knownSizeBytes,
    required this.cs,
    required this.imageWrapper,
  });

  @override
  State<_StagedThumbTile> createState() => _StagedThumbTileState();
}

class _StagedThumbTileState extends State<_StagedThumbTile> {
  Future<int>? _sizeFuture;

  static const _maxPreviewBytes = 6 * 1024 * 1024;

  @override
  void initState() {
    super.initState();
    _refreshSizeFuture();
  }

  @override
  void didUpdateWidget(_StagedThumbTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _refreshSizeFuture();
    }
  }

  void _refreshSizeFuture() {
    final p = widget.path;
    _sizeFuture = p != null && p.isNotEmpty ? File(p).length() : null;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isFolder) {
      return _folderIconColumn();
    }
    final p = widget.path;
    if (p == null || p.isEmpty) {
      return _fileIconColumn();
    }
    if (!widget.isImage) {
      return _fileIconColumn();
    }
    final kb = widget.knownSizeBytes;
    if (kb != null) {
      if (kb > _maxPreviewBytes) {
        return _fileIconColumn();
      }
      final dpr = MediaQuery.devicePixelRatioOf(context);
      final cw = (64 * dpr).round();
      final skipDecodeResize = !kIsWeb && Platform.isAndroid;
      return widget.imageWrapper(
        Image.file(
          File(p),
          key: ValueKey<String>('staged-$p'),
          fit: BoxFit.contain,
          width: 64,
          height: 64,
          alignment: Alignment.center,
          cacheWidth: skipDecodeResize ? null : cw,
          filterQuality: FilterQuality.low,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) =>
              Icon(Icons.broken_image, size: 24, color: widget.cs.outline),
        ),
      );
    }
    final fut = _sizeFuture;
    if (fut == null) {
      return _fileIconColumn();
    }
    return FutureBuilder<int>(
      future: fut,
      builder: (context, snap) {
        if (snap.hasError) {
          return _fileIconColumn();
        }
        if (snap.connectionState != ConnectionState.done) {
          return Center(
            child: Icon(
              Icons.image_outlined,
              size: 28,
              color: widget.cs.outline,
            ),
          );
        }
        final len = snap.data ?? 0;
        if (len > _maxPreviewBytes) {
          return _fileIconColumn();
        }
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final cw = (64 * dpr).round();
        final skipDecodeResize = !kIsWeb && Platform.isAndroid;
        return widget.imageWrapper(
          Image.file(
            File(p),
            key: ValueKey<String>('staged-$p'),
            fit: BoxFit.contain,
            width: 64,
            height: 64,
            alignment: Alignment.center,
            cacheWidth: skipDecodeResize ? null : cw,
            filterQuality: FilterQuality.low,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) =>
                Icon(Icons.broken_image, size: 24, color: widget.cs.outline),
          ),
        );
      },
    );
  }

  Widget _folderIconColumn() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.folder_zip_outlined,
          size: 24,
          color: widget.cs.onSurfaceVariant,
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            widget.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 8, color: widget.cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  Widget _fileIconColumn() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.insert_drive_file,
          size: 24,
          color: widget.cs.onSurfaceVariant,
        ),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            widget.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 8, color: widget.cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:uuid/uuid.dart';

import 'connection_service.dart';
import 'device.dart';
import 'message_model.dart';
import 'message_store.dart';
import 'transfer_manager.dart';

class ChatScreen extends StatefulWidget {
  final DeviceInfo me;
  final PeerDevice peer;
  final ConnectionService connections;
  final MessageStore store;

  const ChatScreen({
    super.key,
    required this.me,
    required this.peer,
    required this.connections,
    required this.store,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const _uuid = Uuid();
  final List<ChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();

  void Function(String, Map<String, dynamic>)? _prevOnMessage;
  void Function(String)? _prevOnDisconnected;
  bool _connected = false;
  bool _loading = true;

  final List<_StagedFile> _staged = [];

  StreamSubscription<void>? _transferSub;
  StreamSubscription<FileMessageEvent>? _fileMsgSub;
  Timer? _transferThrottle;

  String get _peerId => widget.peer.userId;
  TransferManager get _tm => TransferManager.instance;

  @override
  void initState() {
    super.initState();
    _connected = widget.connections.isConnected(_peerId);

    _prevOnMessage = widget.connections.onMessage;
    widget.connections.onMessage = (peerId, json) {
      _prevOnMessage?.call(peerId, json);
      if (peerId != _peerId) return;
      _handleJson(json);
    };

    _prevOnDisconnected = widget.connections.onDisconnected;
    widget.connections.onDisconnected = (peerId) {
      _prevOnDisconnected?.call(peerId);
      if (peerId == _peerId && mounted) {
        setState(() => _connected = false);
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
      if (_messages.any((m) => m.id == event.message.id)) {
        // Update existing message (e.g. attachmentPath set on completion)
        final idx =
            _messages.indexWhere((m) => m.id == event.message.id);
        if (idx >= 0) {
          setState(() => _messages[idx] = event.message);
        }
      } else {
        setState(() => _messages.add(event.message));
      }
      _scrollToBottom();
    });

    if (!_connected) _connect();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final stored = await widget.store.load(_peerId);
    if (!mounted) return;
    final existingIds = _messages.map((m) => m.id).toSet();
    setState(() {
      for (final m in stored) {
        if (!existingIds.contains(m.id)) _messages.add(m);
      }
      _messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _loading = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _connect() async {
    final socket = await widget.connections.connectTo(widget.peer);
    if (socket != null && mounted) {
      setState(() => _connected = true);
    }
  }

  @override
  void dispose() {
    widget.connections.onMessage = _prevOnMessage;
    widget.connections.onDisconnected = _prevOnDisconnected;
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
    if (_messages.any((m) => m.id == msg.id)) return;
    setState(() => _messages.add(msg));
    _scrollToBottom();
  }

  // -----------------------------------------------------------------------
  // Staging — pick files / images into preview, send all on press
  // -----------------------------------------------------------------------
  void _stageFiles(List<_StagedFile> files) {
    if (files.isEmpty) return;
    setState(() => _staged.addAll(files));
  }

  Future<void> _pickFiles() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: false,
    );
    if (picked == null) return;
    _stageFiles(picked.files
        .where((f) => f.path != null)
        .map((f) => _StagedFile(f.path!, f.name))
        .toList());
  }

  Future<void> _pickFolder() async {
    final dirPath = await FilePicker.platform.getDirectoryPath();
    if (dirPath == null) return;

    final folderName = dirPath.split(Platform.pathSeparator).last;
    final zipPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}$folderName.zip';

    try {
      final zipFile = File(zipPath);
      if (await zipFile.exists()) await zipFile.delete();

      final parentDir = Directory(dirPath).parent.path;
      final result = await Process.run(
        'tar',
        ['-a', '-cf', zipPath, '-C', parentDir, folderName],
      );
      if (result.exitCode != 0) {
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..clearSnackBars()
            ..showSnackBar(SnackBar(
              content: Text('Failed to compress folder: ${result.stderr}'),
              behavior: SnackBarBehavior.floating,
            ));
        }
        return;
      }
      _stageFiles([_StagedFile(zipPath, '$folderName.zip')]);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(
            content: Text('Failed to compress folder: $e'),
            behavior: SnackBarBehavior.floating,
          ));
      }
    }
  }

  Future<void> _pickGallery() async {
    final picker = ImagePicker();
    final images = await picker.pickMultiImage(limit: 20);
    if (images.isEmpty) return;
    _stageFiles(images.map((x) => _StagedFile(x.path, x.name)).toList());
  }

  void _onDropDone(DropDoneDetails details) {
    _stageFiles(
        details.files.map((x) => _StagedFile(x.path, x.name)).toList());
  }

  // -----------------------------------------------------------------------
  // Send — text + all staged files via TransferManager
  // -----------------------------------------------------------------------
  void _sendAll() {
    final text = _input.text.trim();
    final hasText = text.isNotEmpty;
    final hasFiles = _staged.isNotEmpty;

    if (!hasText && !hasFiles) return;
    if (!_connected) return;

    if (hasText) {
      final msg = ChatMessage(
        id: _uuid.v4(),
        senderId: widget.me.userId,
        text: text,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isMine: true,
      );
      widget.connections.sendJson(_peerId, msg.toJson());
      setState(() => _messages.add(msg));
      widget.store.add(_peerId, msg);
      _input.clear();
    }

    if (hasFiles) {
      final batch = List<_StagedFile>.from(_staged);
      setState(() => _staged.clear());
      for (final sf in batch) {
        unawaited(_sendFile(sf.path, sf.name));
      }
    }

    _focus.requestFocus();
    _scrollToBottom();
  }

  Future<void> _sendFile(String filePath, String fileName) async {
    final fileId = _uuid.v4();
    final fileSize = await File(filePath).length();

    await _tm.sendFile(
      peerId: _peerId,
      peerIp: widget.peer.ip,
      fileId: fileId,
      fileName: fileName,
      filePath: filePath,
      fileSize: fileSize,
    );
  }

  void _cancelTransfer(String fileId) {
    _tm.cancel(fileId);
  }

  void _retryTransfer(String fileId) {
    _tm.retry(fileId);
  }

  void _openFolder(String filePath) {
    if (Platform.isWindows) {
      Process.run('explorer.exe', ['/select,', filePath]);
    } else {
      final dir = File(filePath).parent.path;
      OpenFilex.open(dir);
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
        content:
            const Text('Delete all messages in this conversation? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await widget.store.clear(_peerId);
              if (mounted) setState(() => _messages.clear());
            },
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error),
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
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    });
  }

  String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _fmtDate(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final msgDay = DateTime(dt.year, dt.month, dt.day);
    if (msgDay == today) return 'Today';
    if (msgDay == today.subtract(const Duration(days: 1))) return 'Yesterday';
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[dt.month]} ${dt.day}, ${dt.year}';
  }

  bool _needsDateSeparator(int index) {
    if (index == 0) return true;
    final prev = DateTime.fromMillisecondsSinceEpoch(_messages[index - 1].timestamp);
    final curr = DateTime.fromMillisecondsSinceEpoch(_messages[index].timestamp);
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
          Expanded(child: Divider(color: cs.outlineVariant.withValues(alpha: 0.4))),
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
          Expanded(child: Divider(color: cs.outlineVariant.withValues(alpha: 0.4))),
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

  static final _linkRe = RegExp(
    r'(https?://[^\s]+)|([\w.+-]+@[\w-]+\.\w[\w.]*)',
    caseSensitive: false,
  );

  void _openUrl(String raw) async {
    final uri = raw.contains('@') && !raw.startsWith('http')
        ? Uri.parse('mailto:$raw')
        : Uri.parse(raw);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _buildRichText(String text, Color color, bool mine) {
    final cs = Theme.of(context).colorScheme;
    final matches = _linkRe.allMatches(text).toList();
    if (matches.isEmpty) {
      return Text(text,
          style: TextStyle(color: color, fontSize: 15, height: 1.3));
    }

    final spans = <InlineSpan>[];
    int last = 0;
    for (final m in matches) {
      if (m.start > last) {
        spans.add(TextSpan(
            text: text.substring(last, m.start),
            style: TextStyle(color: color, fontSize: 15, height: 1.3)));
      }
      final link = m.group(0)!;
      final linkColor =
          mine ? cs.onPrimary.withValues(alpha: 0.85) : cs.primary;
      spans.add(TextSpan(
        text: link,
        style: TextStyle(
          color: linkColor,
          fontSize: 15,
          height: 1.3,
          decoration: TextDecoration.underline,
          decorationColor: linkColor,
          fontWeight: FontWeight.w600,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () {
            if (!kIsWeb && Platform.isAndroid) {
              _showLinkMenu(link);
            } else {
              _openUrl(link);
            }
          },
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(
          text: text.substring(last),
          style: TextStyle(color: color, fontSize: 15, height: 1.3)));
    }
    return Text.rich(TextSpan(children: spans));
  }

  void _showLinkMenu(String link) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_browser),
              title: Text(link.contains('@') ? 'Send Email' : 'Open in Browser'),
              onTap: () {
                Navigator.pop(ctx);
                _openUrl(link);
              },
            ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: link));
                ScaffoldMessenger.of(context)
                  ..clearSnackBars()
                  ..showSnackBar(const SnackBar(
                    content: Text('Copied to clipboard'),
                    duration: Duration(seconds: 1),
                    behavior: SnackBarBehavior.floating,
                  ));
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _fileTypeLabel(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return 'File';
    final ext = name.substring(dot + 1).toLowerCase();
    return switch (ext) {
      'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'svg' =>
        'Image',
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
      'h' =>
        'Source Code',
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
                    fontSize: 16),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.peer.name,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
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
                        color: _connected
                            ? Colors.green
                            : cs.error,
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
        child: DropTarget(
          enable: _isDesktop,
          onDragDone: _onDropDone,
          child: Column(
            children: [
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _messages.isEmpty
                        ? Center(
                            child: Text('No messages yet',
                                style: TextStyle(color: cs.outline)))
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8),
                            itemCount: _messages.length,
                            itemBuilder: (ctx, i) {
                              final widgets = <Widget>[];
                              if (_needsDateSeparator(i)) {
                                widgets.add(_buildDateSeparator(ctx,
                                    DateTime.fromMillisecondsSinceEpoch(
                                        _messages[i].timestamp)));
                              }
                              widgets.add(_buildBubble(ctx, _messages[i]));
                              return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: widgets);
                            },
                          ),
              ),
              if (_staged.isNotEmpty) _buildStagedPreview(context),
              _buildComposer(context),
            ],
          ),
        ),
      ),
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
                onTap: () => setState(() => _staged.clear()),
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
                final sf = _staged[i];
                final isImg = _isImage(sf.name);
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
                        child: isImg
                            ? Image.file(File(sf.path),
                                fit: BoxFit.cover,
                                width: 64,
                                height: 64,
                                errorBuilder: (_, e, s) => Icon(
                                    Icons.broken_image,
                                    size: 24,
                                    color: cs.outline))
                            : Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.insert_drive_file,
                                      size: 24, color: cs.onSurfaceVariant),
                                  const SizedBox(height: 2),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    child: Text(
                                      sf.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          fontSize: 8,
                                          color: cs.onSurfaceVariant),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      Positioned(
                        top: -6,
                        right: -6,
                        child: GestureDetector(
                          onTap: () => setState(() => _staged.removeAt(i)),
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: cs.error,
                            ),
                            child:
                                Icon(Icons.close, size: 12, color: cs.onError),
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
  void _copyMessage(ChatMessage m) {
    final text = m.attachmentName != null ? m.attachmentName! : m.text;
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(const SnackBar(
          content: Text('Copied to clipboard'),
          duration: Duration(seconds: 1),
          behavior: SnackBarBehavior.floating,
        ));
    }
  }

  void _showCopyMenu(BuildContext context, Offset position, ChatMessage m) {
    showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
          position.dx, position.dy, position.dx, position.dy),
      items: const [
        PopupMenuItem(value: 'copy', child: Text('Copy')),
      ],
    ).then((value) {
      if (value == 'copy') _copyMessage(m);
    });
  }

  Widget _buildBubble(BuildContext context, ChatMessage m) {
    final cs = Theme.of(context).colorScheme;
    final mine = m.isMine;
    final t = _tm.transfers[m.id];

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: () => _copyMessage(m),
        onSecondaryTapUp: (details) =>
            _showCopyMenu(context, details.globalPosition, m),
        child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine
              ? cs.primary
              : cs.surfaceContainerHighest.withValues(alpha: 0.8),
          border: mine
              ? null
              : Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.3), width: 0.5),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (m.attachmentName != null)
              _buildAttachment(context, m, mine)
            else
              _buildRichText(
                  m.text, mine ? cs.onPrimary : cs.onSurface, mine),

            if (t != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: t.progress.clamp(0, 1).toDouble(),
                minHeight: 4,
                borderRadius: BorderRadius.circular(99),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t.error != null
                          ? 'Failed'
                          : '${(t.progress * 100).toStringAsFixed(0)}%'
                              ' \u2022 ${_fmtBytes(t.transferredBytes)}/${_fmtBytes(t.totalBytes)}'
                              ' \u2022 ${_fmtSpeed(t.currentSpeed)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: mine ? cs.onPrimary : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (t.error != null && t.isSending)
                    _bubbleButton('Retry', () => _retryTransfer(m.id)),
                  _bubbleButton('Cancel', () => _cancelTransfer(m.id)),
                ],
              ),
            ],

            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _fmtTime(m.timestamp),
                style: TextStyle(
                  fontSize: 11,
                  color: (mine ? cs.onPrimary : cs.onSurfaceVariant)
                      .withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _bubbleButton(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(label,
              style:
                  const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _buildAttachment(BuildContext context, ChatMessage m, bool mine) {
    final cs = Theme.of(context).colorScheme;
    final hasPath = m.attachmentPath != null;
    final isImg = hasPath && _isImage(m.attachmentName!);
    final isTransferring = _tm.transfers.containsKey(m.id);
    final fgColor = mine ? cs.onPrimary : cs.onSurface;
    final subtleColor =
        (mine ? cs.onPrimary : cs.onSurfaceVariant).withValues(alpha: 0.7);

    final typeLabel = _fileTypeLabel(m.attachmentName!);
    final sizeLabel =
        m.attachmentSize != null ? _fmtBytes(m.attachmentSize!) : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isImg)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: GestureDetector(
              onTap: () => OpenFilex.open(m.attachmentPath!),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(m.attachmentPath!),
                  width: 220,
                  height: 160,
                  fit: BoxFit.cover,
                  errorBuilder: (_, e, s) =>
                      const Icon(Icons.broken_image, size: 48),
                ),
              ),
            ),
          ),
        GestureDetector(
          onTap: hasPath ? () => OpenFilex.open(m.attachmentPath!) : null,
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
                    decoration: hasPath
                        ? TextDecoration.underline
                        : TextDecoration.none,
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
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
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Composer
  // -----------------------------------------------------------------------
  Widget _buildComposer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final canSend =
        _connected && (_input.text.trim().isNotEmpty || _staged.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
          IconButton.filled(
            onPressed: _pickFiles,
            tooltip: 'Attach Files',
            icon: const Icon(Icons.attach_file),
          ),
          if (_isDesktop) ...[
            const SizedBox(width: 4),
            IconButton.filled(
              onPressed: _pickFolder,
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
              onPressed: _pickGallery,
              tooltip: 'Gallery',
              style: IconButton.styleFrom(
                backgroundColor: cs.secondaryContainer,
                foregroundColor: cs.onSecondaryContainer,
              ),
              icon: const Icon(Icons.photo_library),
            ),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendAll(),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: _staged.isNotEmpty
                    ? 'Add a message (optional)...'
                    : 'Message',
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: canSend ? _sendAll : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _StagedFile {
  final String path;
  final String name;
  const _StagedFile(this.path, this.name);
}

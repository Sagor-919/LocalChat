path = r"k:\GitRepos\LocalChat\lib\transfer_manager.dart"
with open(path, encoding="utf-8") as f:
    s = f.read()

old_cancel = """  void cancel(String fileId) {
    final t = transfers[fileId];
    if (t == null) return;
    if (t.isSending) {
      t.sender?.cancel();
    } else {
      _receiver?.cancelReceive(fileId);
    }
    t.error = 'Cancelled';
    t.cancelled = true;
    t.isPaused = false;
    _notify();
  }"""

new_cancel = """  void cancel(String fileId) {
    final t = transfers[fileId];
    if (t == null) return;
    t.cancelRequested = true;
    try {
      t.prepProcess?.kill(ProcessSignal.sigkill);
    } catch (_) {}
    t.prepProcess = null;
    if (t.isSending) {
      t.sender?.cancel();
    } else {
      _receiver?.cancelReceive(fileId);
    }
    t.error = 'Cancelled';
    t.cancelled = true;
    t.isPaused = false;
    _notify();
  }"""

s = s.replace(old_cancel, new_cancel, 1)

old_pause = """  void pauseOutgoing(String fileId) {
    final t = transfers[fileId];
    if (t == null || !t.isSending || t.error != null) return;"""

new_pause = """  void pauseOutgoing(String fileId) {
    final t = transfers[fileId];
    if (t == null ||
        !t.isSending ||
        t.error != null ||
        t.outgoingPhase == OutgoingTransferPhase.preparing) {
      return;
    }"""

s = s.replace(old_pause, new_pause, 1)

old_remote = """  void handleRemotePauseOutgoing(String fileId) {
    final t = transfers[fileId];
    if (t == null || !t.isSending) return;"""

new_remote = """  void handleRemotePauseOutgoing(String fileId) {
    final t = transfers[fileId];
    if (t == null ||
        !t.isSending ||
        t.outgoingPhase == OutgoingTransferPhase.preparing) {
      return;
    }"""

s = s.replace(old_remote, new_remote, 1)

old_dismiss = """  void dismiss(String fileId) {
    final t = transfers.remove(fileId);
    _notify();
    if (t == null) return;
    unawaited(_persistDismissedTransfer(t.peerId, fileId));
  }"""

new_dismiss = """  void dismiss(String fileId) {
    final t = transfers.remove(fileId);
    _notify();
    if (t == null) return;
    if (t.isSending) {
      _cleanupOutgoingTemps(t);
    }
    unawaited(_persistDismissedTransfer(t.peerId, fileId));
  }"""

s = s.replace(old_dismiss, new_dismiss, 1)

old_run = """      t.isPaused = false;
      transfers.remove(t.fileId);
      _notify();
    } catch (e) {
      if (e is TransferPausedException) {"""

new_run = """      t.isPaused = false;
      _cleanupOutgoingTemps(t);
      transfers.remove(t.fileId);
      _notify();
    } catch (e) {
      if (e is TransferPausedException) {"""

s = s.replace(old_run, new_run, 1)

with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(s)
print('ok3')

// In _refreshPeerList() - Add incremental updates instead of full rebuild

Future<void> _refreshPeerListIncremental() async {
  final gen = ++_peerRefreshGeneration;
  final networkDown = _connectivityOffline;
  
  // Get fresh discovery snapshot
  final discoveryPeers = widget.discovery.peers;
  final onlineIds = networkDown ? <String>{} : discoveryPeers.map((p) => p.userId).toSet();

  // Load stored peer info only once
  final storedInfos = await widget.store.loadAllPeerInfos();
  if (!mounted || gen != _peerRefreshGeneration) return;

  final conversationPeerIds = await widget.store.listPeerIdsWithConversation();
  if (!mounted || gen != _peerRefreshGeneration) return;

  // Build new list with deduplication
  final newList = <_PeerEntry>[];
  final seenIds = <String>{};

  // Online peers (highest priority)
  if (!networkDown) {
    for (final p in discoveryPeers) {
      if (seenIds.add(p.userId)) {
        newList.add(_PeerEntry(
          userId: p.userId,
          name: p.name,
          ip: p.ip,
          port: p.port,
          online: true,
          peer: p,
        ));
      }
    }
  }

  // Offline peers (with conversation history)
  final offlineIds = conversationPeerIds.where((id) => !onlineIds.contains(id)).toSet();
  for (final id in offlineIds) {
    if (seenIds.add(id)) {
      final info = storedInfos[id];
      newList.add(_PeerEntry(
        userId: id,
        name: info?['name'] as String? ?? 'Unknown',
        ip: info?['ip'] as String? ?? '',
        port: (info?['port'] as num?)?.toInt() ?? 4041,
        online: false,
      ));
    }
  }

  if (!mounted || gen != _peerRefreshGeneration) return;
  
  // Only update if actual changes detected
  if (!_listsAreEqual(_peerList, newList)) {
    setState(() => _peerList = newList);
    await _hydratePreviewsFromStore(newList, gen);
  }
}

bool _listsAreEqual(List<_PeerEntry> a, List<_PeerEntry> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i].userId != b[i].userId || 
        a[i].online != b[i].online) return false;
  }
  return true;
}
import 'dart:async';

import 'package:flutter/material.dart';

import '../global/pairing_service.dart';

class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key, required this.service});

  final PairingService service;

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _codeController = TextEditingController();
  PairingSession? _session;
  String? _visibleCode;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  bool _relaysReachable() {
    final nostr = widget.service.nostr;
    return nostr.connectedRelayCount.value > 0 || nostr.connecting.value;
  }

  Future<void> _startInitiator() async {
    if (!_relaysReachable()) {
      setState(
        () => _error =
            'No relays connected. Check internet, then enable Global Discovery again.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _session = null;
      _visibleCode = PairingService.generatePairingCode();
    });
    try {
      final session = await widget.service.startAsInitiator(code: _visibleCode);
      if (!mounted) return;
      setState(() => _session = session);
    } on TimeoutException {
      if (mounted) setState(() => _error = 'Pairing timed out. Try again.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Pairing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _joinResponder() async {
    final code = _codeController.text.trim();
    if (!_relaysReachable()) {
      setState(
        () => _error =
            'No relays connected. Check internet, then enable Global Discovery again.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _session = null;
      _visibleCode = PairingService.formatPairingCode(code);
    });
    try {
      final session = await widget.service.joinAsResponder(code);
      if (!mounted) return;
      setState(() => _session = session);
    } on TimeoutException {
      if (mounted) setState(() => _error = 'Pairing timed out. Try again.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Pairing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmMatch() async {
    final session = _session;
    if (session == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.service.confirm(session);
      if (mounted) Navigator.of(context).pop(session.peer);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save peer: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reject() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Pair Device'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Show code'),
              Tab(text: 'Enter code'),
            ],
          ),
        ),
        body: TabBarView(children: [_buildShowCode(cs), _buildEnterCode(cs)]),
      ),
    );
  }

  Widget _buildShowCode(ColorScheme cs) {
    return _pairingBody(
      children: [
        _buildRelayHealth(cs),
        if (_visibleCode != null)
          SelectableText(
            _visibleCode!,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
          )
        else
          FilledButton.icon(
            onPressed: _busy ? null : _startInitiator,
            icon: const Icon(Icons.qr_code_2),
            label: const Text('Generate Code'),
          ),
        const SizedBox(height: 18),
        if (_busy && _session == null)
          _waitingText(cs, 'Waiting for the other device to enter this code.'),
        if (_session != null) _buildSasCard(cs),
        if (_error != null) _errorText(cs),
      ],
    );
  }

  Widget _buildEnterCode(ColorScheme cs) {
    return _pairingBody(
      children: [
        _buildRelayHealth(cs),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Pairing code',
            hintText: '123-456-789',
            prefixIcon: Icon(Icons.pin_outlined),
          ),
          onChanged: (value) {
            final normalized = PairingService.normalizePairingCode(value);
            if (normalized.length > 9) {
              _codeController.text = normalized.substring(0, 9);
              _codeController.selection = TextSelection.fromPosition(
                TextPosition(offset: _codeController.text.length),
              );
            }
          },
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _joinResponder,
          icon: const Icon(Icons.login),
          label: const Text('Join'),
        ),
        const SizedBox(height: 18),
        if (_busy && _session == null)
          _waitingText(cs, 'Looking for the device that generated this code.'),
        if (_session != null) _buildSasCard(cs),
        if (_error != null) _errorText(cs),
      ],
    );
  }

  Widget _pairingBody({required List<Widget> children}) {
    return ListView(padding: const EdgeInsets.all(20), children: children);
  }

  Widget _buildRelayHealth(ColorScheme cs) {
    final nostr = widget.service.nostr;
    return ValueListenableBuilder<int>(
      valueListenable: nostr.connectedRelayCount,
      builder: (_, count, _) {
        return ValueListenableBuilder<int>(
          valueListenable: nostr.targetRelayCount,
          builder: (_, total, _) {
            return ValueListenableBuilder<bool>(
              valueListenable: nostr.connecting,
              builder: (_, connecting, _) {
                final healthy = count > 0;
                final waiting = !healthy && (connecting || total == 0);
                final Color color;
                final IconData icon;
                final String text;
                if (healthy) {
                  color = cs.primary;
                  icon = Icons.cloud_done_outlined;
                  text = total > 0
                      ? '$count of $total relays online'
                      : '$count relays online';
                } else if (waiting) {
                  color = cs.outline;
                  icon = Icons.cloud_sync_outlined;
                  text = 'Connecting to relays…';
                } else {
                  color = cs.error;
                  icon = Icons.cloud_off_outlined;
                  text = 'No relays reachable. Pairing will fail.';
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Icon(icon, size: 18, color: color),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          text,
                          style: TextStyle(
                            color: color,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _waitingText(ColorScheme cs, String text) {
    return Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2, color: cs.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: cs.outline, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildSasCard(ColorScheme cs) {
    final session = _session!;
    final sasMismatch =
        session.remoteSas != null && session.remoteSas != session.sas;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              session.peer.name,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            Text(
              session.sas,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 36, letterSpacing: 2),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _reject,
                    child: const Text('Different'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _busy || sasMismatch ? null : _confirmMatch,
                    child: const Text('Match'),
                  ),
                ),
              ],
            ),
            if (sasMismatch) ...[
              const SizedBox(height: 10),
              Text(
                'Verification mismatch. Do not pair this device.',
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.error, fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _errorText(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Text(_error!, style: TextStyle(color: cs.error)),
    );
  }
}

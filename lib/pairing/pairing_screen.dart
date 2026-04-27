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

  Future<void> _startInitiator() async {
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
        if (_busy && _session == null) const LinearProgressIndicator(),
        if (_session != null) _buildSasCard(cs),
        if (_error != null) _errorText(cs),
      ],
    );
  }

  Widget _buildEnterCode(ColorScheme cs) {
    return _pairingBody(
      children: [
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
        if (_busy && _session == null) const LinearProgressIndicator(),
        if (_session != null) _buildSasCard(cs),
        if (_error != null) _errorText(cs),
      ],
    );
  }

  Widget _pairingBody({required List<Widget> children}) {
    return ListView(padding: const EdgeInsets.all(20), children: children);
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

// lib/main.dart — Resilient App Lab
// Teaching example: connectivity check, timeout, retry with backoff, friendly feedback.
// No Provider/Bloc/Riverpod, no dio, no extra screens.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// Server address: emulator reaches host via 10.0.2.2.
// Real phone: flutter run --dart-define=SERVER_URL=http://<PC-LAN-IP>:8080
const serverUrl = String.fromEnvironment(
  'SERVER_URL',
  defaultValue: 'http://10.0.2.2:8080',
);

// ── Tuning constants ────────────────────────────────────────────────────────
const requestTimeout  = Duration(seconds: 5);
const slowThreshold   = Duration(seconds: 3); // "Still working..." timer
const maxAttempts     = 3;
const modeSetTimeout  = Duration(seconds: 3); // POST /mode has no retry

// ── Failure taxonomy ────────────────────────────────────────────────────────
enum FailureKind { offline, timeout, noServer, serverError, rejected, unauthorized }

String describe(FailureKind kind) {
  switch (kind) {
    case FailureKind.offline:
      return "You're offline. Turn off airplane mode and try again.";
    case FailureKind.timeout:
      return 'The server is taking too long.';
    case FailureKind.noServer:
      return "Can't reach the server.";
    case FailureKind.serverError:
      return 'The server had a problem. Try again later.';
    case FailureKind.rejected:
      return 'The request was rejected.';
    case FailureKind.unauthorized:
      return 'Please log in again.';
  }
}

// ── Mode metadata ────────────────────────────────────────────────────────────
const serverModes = ['normal', 'slow', 'flaky', 'hangs'];

void main() => runApp(const ResilientApp());

class ResilientApp extends StatelessWidget {
  const ResilientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Resilient App Lab',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const HomePage(),
    );
  }
}

// ── Home page state ──────────────────────────────────────────────────────────
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // ── server mode selection
  String _selectedMode = 'normal';

  // ── load state
  bool          _loading        = false;
  bool          _cancelled      = false;
  String        _status         = '';   // status line under the spinner
  FailureKind?  _lastFailure;           // null = no error
  Map<String, dynamic>? _data;          // last successful payload

  // "earlier data" note shown when a refresh fails but we still have old data
  bool _showingEarlierData = false;

  // Retry-when-online: set when load is stopped because we're offline
  bool _retryWhenOnline = false;

  // ── timers / subscriptions / active client
  Timer?                      _slowTimer;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  http.Client?                _activeClient;

  // ── cleanup ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _fetchCurrentMode();   // best-effort — sync dropdown at startup
    _listenConnectivity(); // watch for network changes
  }

  @override
  void dispose() {
    _cancelled = true;
    _activeClient?.close();
    _slowTimer?.cancel();
    _connectivitySub?.cancel();
    super.dispose();
  }

  // ── Connectivity listener ───────────────────────────────────────────────
  void _listenConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final online = results.any((r) => r != ConnectivityResult.none);
      if (online && _retryWhenOnline && !_loading) {
        // Network came back — auto-retry (spec §4.1)
        _retryWhenOnline = false;
        _load();
      }
    });
  }

  /// Returns true if we are definitely offline right now.
  Future<bool> _isOffline() async {
    final results = await Connectivity().checkConnectivity();
    return results.every((r) => r == ConnectivityResult.none);
  }

  // ── Sync dropdown with server on startup (best-effort) ──────────────────
  Future<void> _fetchCurrentMode() async {
    try {
      final client = http.Client();
      try {
        final res = await client
            .get(Uri.parse('$serverUrl/mode'))
            .timeout(modeSetTimeout);
        if (res.statusCode == 200) {
          final body = jsonDecode(res.body) as Map<String, dynamic>;
          final mode = body['mode'] as String?;
          if (mode != null && serverModes.contains(mode) && mounted) {
            setState(() => _selectedMode = mode);
          }
        }
      } finally {
        client.close();
      }
    } catch (_) {
      // Best-effort: ignore failures silently
    }
  }

  // ── Mode selection: POST /mode?set=... (once, no retry) ─────────────────
  Future<void> _setMode(String mode) async {
    setState(() => _selectedMode = mode);
    final client = http.Client();
    try {
      await client
          .post(Uri.parse('$serverUrl/mode?set=$mode'))
          .timeout(modeSetTimeout);
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't reach the server to change mode.")),
        );
      }
    } finally {
      client.close();
    }
  }

  // ── Core load flow (spec §4.2) ───────────────────────────────────────────
  Future<void> _load() async {
    if (_loading) return; // ignore duplicate taps

    setState(() {
      _loading        = true;
      _cancelled      = false;
      _lastFailure    = null;
      _status         = 'Loading...';
      _showingEarlierData = false;
    });

    // "Still working..." after 3 s without a result
    _slowTimer = Timer(slowThreshold, () {
      if (_loading && mounted) setState(() => _status = 'Still working...');
    });

    FailureKind? lastError;

    // ── Retry loop ─────────────────────────────────────────────────────────
    // Only safe, idempotent GET is retried (a POST that creates data would not be — see spec).
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      // 1. Connectivity check
      if (await _isOffline()) {
        _retryWhenOnline = true;
        lastError = FailureKind.offline;
        break; // stop — listener will auto-retry when online
      }

      if (_cancelled) break;

      // 2. Issue request with 5 s timeout; create a fresh client each attempt
      //    so closing it really aborts the socket (spec §4.2 requirement).
      _activeClient = http.Client();
      int? statusCode;
      bool shouldRetry = false;
      try {
        final res = await _activeClient!
            .get(Uri.parse('$serverUrl/data'))
            .timeout(requestTimeout);
        statusCode = res.statusCode;

        if (statusCode == 200) {
          // Success
          final body = jsonDecode(res.body) as Map<String, dynamic>;
          if (mounted && !_cancelled) {
            setState(() {
              _data            = body;
              _loading         = false;
              _status          = '';
              _lastFailure     = null;
              _showingEarlierData = false;
            });
          }
          _cleanupAfterLoad();
          return; // done
        }

        // ── Classify HTTP error
        if (statusCode == 429) {
          // Rate-limited: honour Retry-After header if present
          lastError   = FailureKind.serverError;
          shouldRetry = true;
        } else if (statusCode == 401) {
          lastError   = FailureKind.unauthorized;
          shouldRetry = false; // non-retryable
        } else if (statusCode >= 500 && statusCode <= 599) {
          // 500/502/503/504 → retryable; other 5xx → not retryable
          final retryable5xx = {500, 502, 503, 504};
          lastError   = FailureKind.serverError;
          shouldRetry = retryable5xx.contains(statusCode);
        } else if (statusCode >= 400) {
          lastError   = FailureKind.rejected;
          shouldRetry = false; // 4xx generally not retryable
        } else {
          lastError   = FailureKind.serverError;
          shouldRetry = true;
        }
      } on TimeoutException {
        lastError   = FailureKind.timeout;
        shouldRetry = true;
      } on SocketException {
        lastError   = FailureKind.noServer;
        shouldRetry = true;
      } on http.ClientException {
        lastError   = FailureKind.noServer;
        shouldRetry = true;
      } catch (_) {
        lastError   = FailureKind.serverError;
        shouldRetry = true;
      } finally {
        _activeClient?.close();
        _activeClient = null; // always close to free the socket
      }

      if (_cancelled) break;
      if (!shouldRetry) break; // non-retryable error — stop immediately

      // 3. Backoff between attempts (not after the last attempt)
      if (attempt < maxAttempts) {
        // Backoff: 1 s, 2 s  (2^(attempt-1) seconds: attempt 1 → 1 s, attempt 2 → 2 s)
        final waitSeconds = 1 << (attempt - 1); // bit-shift = 2^(attempt-1)
        final nextAttempt = attempt + 1;
        for (int t = waitSeconds; t > 0; t--) {
          if (_cancelled) break;
          if (mounted) {
            setState(() {
              _status = 'Retrying in ${t}s (attempt $nextAttempt of $maxAttempts)...';
            });
          }
          await Future.delayed(const Duration(seconds: 1));
        }
      }
    } // end retry loop

    // ── Loop ended: show error (unless cancelled)
    if (!_cancelled && mounted) {
      final hasOldData = _data != null;
      setState(() {
        _loading            = false;
        _status             = '';
        _lastFailure        = lastError;
        _showingEarlierData = hasOldData;
      });
    } else if (_cancelled && mounted) {
      setState(() {
        _loading     = false;
        _status      = 'Cancelled.';
        _lastFailure = null;
      });
    }
    _cleanupAfterLoad();
  }

  void _cleanupAfterLoad() {
    _slowTimer?.cancel();
    _slowTimer = null;
  }

  // ── Cancel ───────────────────────────────────────────────────────────────
  void _cancel() {
    _cancelled = true;
    _activeClient?.close();
    _activeClient = null;
    _cleanupAfterLoad();
    if (mounted) {
      setState(() {
        _loading = false;
        _status = 'Cancelled.';
        _lastFailure = null;
      });
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Resilient App Lab'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ModeSelector(
              selected: _selectedMode,
              onChanged: _loading ? null : _setMode, // lock while loading
            ),
            const SizedBox(height: 16),
            _LoadButton(
              loading: _loading,
              onLoad: _load,
              onCancel: _cancel,
            ),
            if (_status.isNotEmpty) ...[
              const SizedBox(height: 12),
              _StatusLine(status: _status, loading: _loading),
            ],
            const SizedBox(height: 16),
            Expanded(child: _Body(
              loading:            _loading,
              failure:            _lastFailure,
              data:               _data,
              showingEarlierData: _showingEarlierData,
              onRetry:            _load,
            )),
          ],
        ),
      ),
    );
  }
}

// ── Sub-widgets ───────────────────────────────────────────────────────────────

class _ModeSelector extends StatelessWidget {
  final String selected;
  final void Function(String)? onChanged;

  const _ModeSelector({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Text('Server mode:', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(width: 12),
        DropdownButton<String>(
          value: selected,
          onChanged: onChanged == null ? null : (v) => onChanged!(v!),
          items: serverModes
              .map((m) => DropdownMenuItem(
                    value: m,
                    child: Text(m[0].toUpperCase() + m.substring(1)),
                  ))
              .toList(),
        ),
      ],
    );
  }
}

class _LoadButton extends StatelessWidget {
  final bool loading;
  final VoidCallback onLoad;
  final VoidCallback onCancel;

  const _LoadButton({
    required this.loading,
    required this.onLoad,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ElevatedButton(
          onPressed: loading ? null : onLoad,
          child: const Text('Load'),
        ),
        if (loading) ...[
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: onCancel,
            child: const Text('Cancel'),
          ),
        ],
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  final String status;
  final bool loading;

  const _StatusLine({required this.status, required this.loading});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (loading)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        if (loading) const SizedBox(width: 8),
        Expanded(
          child: Text(
            status,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.secondary,
            ),
          ),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  final bool loading;
  final FailureKind? failure;
  final Map<String, dynamic>? data;
  final bool showingEarlierData;
  final VoidCallback onRetry;

  const _Body({
    required this.loading,
    required this.failure,
    required this.data,
    required this.showingEarlierData,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        // "Earlier data" notice (spec §4.3)
        if (showingEarlierData && data != null)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: Colors.amber.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              "Showing earlier data (couldn't refresh)",
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ),

        // Successful data display
        if (data != null) ...[
          Text(
            'Served at: ${data!['servedAt'] ?? '—'}',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ...(data!['items'] as List).map(
            (item) => ListTile(
              leading: const Icon(Icons.check_circle_outline),
              title: Text(item.toString()),
              dense: true,
            ),
          ),
          const Divider(),
        ],

        // Error display (spec §4.2 — friendly messages, never raw exceptions)
        if (failure != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.red),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  describe(failure!),
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: loading ? null : onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
          ),
        ],
      ],
    );
  }
}

// Development entrypoint for the D1-02 / D1-04 L4 lifecycle run:
//   flutter build ios --simulator --debug -t lib/dev/engine_lifecycle_probe_main.dart
//   node tooling/ios/engine-smoke/d1-02-lifecycle-check.mjs --simulator <udid> \
//     --app app/build/ios/iphonesimulator/Runner.app --report reports/wave2/t8-t9-l4.json
//
// It drives the real `dsh/runtime` channel (same bridge as the app) through one
// in-process start → stop → start → restart and reports each step with a
// `[probe]` line (collected with `xcrun simctl spawn … log stream`).
import 'dart:async';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../runtime/runtime_bridge.dart';

void main() => runApp(const MaterialApp(home: _LifecycleProbe()));

class _LifecycleProbe extends StatefulWidget {
  const _LifecycleProbe();

  @override
  State<_LifecycleProbe> createState() => _LifecycleProbeState();
}

class _LifecycleProbeState extends State<_LifecycleProbe> {
  final _bridge = RuntimeBridge();
  final _lines = <String>[];
  final _eventSeqs = <int>[];
  int _logBatches = 0;
  StreamSubscription<RuntimeEvent>? _sub;

  void _log(String line) {
    debugPrint('[probe] $line');
    if (mounted) setState(() => _lines.add(line));
  }

  @override
  void initState() {
    super.initState();
    _sub = _bridge.events.listen((event) {
      switch (event) {
        case RuntimeLogsEvent(:final entries):
          _logBatches++;
          for (final entry in entries) {
            _eventSeqs.add(entry.seq);
            debugPrint('[dsh] ${entry.line}');
          }
        case RuntimeStatusEvent(:final status):
          _log('phase ${status.phase.name}${status.error != null ? ' error=${status.error}' : ''}');
        case RuntimeProgressEvent(:final fraction):
          debugPrint('[dsh] progress ${(fraction * 100).floor()}%');
        case RuntimeNoticeEvent(:final text):
          _log('notice: $text');
      }
    });
    unawaited(_run());
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  Future<void> _run() async {
    final sw = Stopwatch()..start();
    try {
      await _lifecycle(sw);
    } catch (e, st) {
      _log('PROBE FAILED: $e');
      debugPrint('$st');
      for (final line in await _bridge.logs(lines: 60)) {
        debugPrint('[dsh-tail] $line');
      }
    } finally {
      await _sub?.cancel();
    }
  }

  Future<void> _lifecycle(Stopwatch sw) async {
    _log('pid=$pid first');
    var status = await _bridge.status();
    _log('status phase=${status.phase.name} installed=${status.installedVersion} bundled=${status.bundledVersion}');
    if (status.installedVersion != status.bundledVersion) {
      sw.reset();
      await _bridge.install();
      _log('installed in ${sw.elapsed.inMilliseconds}ms');
    }

    // D1-04-AC1: subscribe first, then snapshot (the pre-start snapshot may be
    // empty); the post-start one below must carry seq/stream/line entries.
    final before = await _bridge.logSnapshot();
    _log('presnapshot entries=${before.entries.length} throughSeq=${before.throughSeq}');

    // D1-02-AC1: start → running with a usable baseUrl.
    sw.reset();
    await _bridge.start();
    status = await _waitFor(RuntimePhase.running);
    _log('start ms=${sw.elapsed.inMilliseconds} baseUrl=${status.baseUrl} token=${status.token != null}');

    // D1-02-AC4 (native): a second start while running is a no-op, not a crash.
    sw.reset();
    await _bridge.start();
    final again = await _bridge.status();
    _log('start-while-running ms=${sw.elapsed.inMilliseconds} phase=${again.phase.name}');

    // D1-02-AC1: stop → installed.
    sw.reset();
    await _bridge.stop();
    status = await _waitFor(RuntimePhase.installed);
    _log('stop ms=${sw.elapsed.inMilliseconds} phase=${status.phase.name}');
    _log('failureLog after clean stop lines=${(await _bridge.failureLog()).length}');

    // D1-02-AC2: start again in the same process; a client can list sessions.
    sw.reset();
    await _bridge.start();
    status = await _waitFor(RuntimePhase.running);
    _log('start-after-stop ms=${sw.elapsed.inMilliseconds} baseUrl=${status.baseUrl}');
    final client = await DshClient.connect(baseUri: Uri.parse(status.baseUrl!), token: status.token!);
    final sessions = await client.listSessions();
    _log('client sessions=${sessions.length}');
    await client.close();

    // D1-02-AC2: restart = stop then start, still the same process.
    sw.reset();
    await _bridge.stop();
    await _waitFor(RuntimePhase.installed);
    await _bridge.start();
    status = await _waitFor(RuntimePhase.running);
    _log('restart ms=${sw.elapsed.inMilliseconds} pid=$pid');

    // D1-04-AC1: after four starts the native buffer has accumulated lines;
    // the snapshot/cutpoint and the ring cap are read with the engine running.
    final snap = await _bridge.logSnapshot();
    final entries = snap.entries;
    final labelled = entries.where((e) => e.line.isNotEmpty || e.stream.isNotEmpty).length;
    _log('snapshot entries=${entries.length} labelled=$labelled throughSeq=${snap.throughSeq}');
    final ring = await _bridge.logs(lines: 5000);
    _log('ring lines=${ring.length}');
    _log(
      'events batches=$_logBatches seqs=${_eventSeqs.length} '
      'monotonic=${_monotonic(_eventSeqs)} duplicates=${_eventSeqs.length - _eventSeqs.toSet().length}',
    );

    // D1-04-AC2: a rejected start reports a stable code and readable reason,
    // the log stays readable, and the engine can still be started afterwards.
    await _bridge.stop();
    await _waitFor(RuntimePhase.installed);
    try {
      await _bridge.start(env: {'NODE_OPTIONS': '--max-old-space-size=64'});
      _log('start-failure unexpected-success');
    } on PlatformException catch (e) {
      _log('start-failure code=${e.code} message=${e.message}');
    }
    try {
      await _bridge.start(mode: EngineMode.safe);
      _log('start-failure-mode unexpected-success');
    } on PlatformException catch (e) {
      _log('start-failure-mode code=${e.code} message=${e.message}');
    }
    final failureSnap = await _bridge.logSnapshot();
    _log('failureLog lines=${(await _bridge.failureLog()).length} snapshot=${failureSnap.entries.length}');
    sw.reset();
    await _bridge.start();
    status = await _waitFor(RuntimePhase.running);
    _log('start-after-failure ms=${sw.elapsed.inMilliseconds}');

    // Leave the engine stopped so a rerun starts from the same place.
    await _bridge.stop();
    await _waitFor(RuntimePhase.installed);
    _log('pid=$pid last');
    _log('LIFECYCLE PROBE OK');
  }

  bool _monotonic(List<int> seqs) {
    for (var i = 1; i < seqs.length; i++) {
      if (seqs[i] <= seqs[i - 1]) return false;
    }
    return true;
  }

  Future<RuntimeStatus> _waitFor(RuntimePhase phase, {Duration limit = const Duration(seconds: 120)}) async {
    final wait = Stopwatch()..start();
    while (true) {
      final status = await _bridge.status();
      if (status.phase == phase) return status;
      if (status.phase == RuntimePhase.error) throw StateError('runtime error: ${status.error}');
      if (wait.elapsed > limit) throw TimeoutException('waiting for ${phase.name}');
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [for (final l in _lines) Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))],
      ),
    ),
  );
}

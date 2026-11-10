// Fake SSH host whose tunnel is a real loopback socket to an in-process
// `dsh web` imitation (packages/dsh_client/test/support/fake_dsh.dart).
//
// The transport records the exact scripts and channels the production
// SshHostLink asks for, but every byte after authentication travels through
// [LocalForwarder] → this fake SSH channel → FakeDsh. That makes session
// lists, prompt acknowledgements and streamed follow frames exercise the real
// DshClient instead of a mock, while no real SSH host or external network is
// used.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_app/remote/link_status.dart';
import 'package:dsh_app/remote/ssh/remote_shell.dart';
import 'package:dsh_app/remote/ssh/ssh_host_config.dart';
import 'package:dsh_app/remote/ssh/ssh_transport.dart';

/// The key this fake server presents until [BridgeSshServer.hostKey] changes.
const bridgeHostKey = PresentedHostKey(
  'ssh-ed25519',
  'SHA256:bridgekeybridgekeybridgekeybridgekeybridge0000',
);

/// What the remote machine answers; its endpoint is the fake host that
/// actually listens on loopback.
class BridgeRemote {
  BridgeRemote({required this.port, required this.token});

  int port;
  final String token;

  /// Incremented each time the bootstrap start script runs on this machine.
  int launches = 0;
  int? pid;

  /// Make the next start script report a process that exited.
  bool crashOnStart = false;
  final List<String> scripts = [];

  RemoteExecResult run(String script) {
    scripts.add(script);
    if (script.contains('DSHAPP started')) {
      launches++;
      pid = 4000 + launches;
      if (crashOnStart) {
        return const RemoteExecResult(
          1,
          'DSHAPP home /home/me\nDSHAPP started 4001\nDSHAPP exited\nDSHAPP log Error: listen EADDRINUSE\n',
          '',
        );
      }
      return RemoteExecResult(
        0,
        'DSHAPP home /home/me\nDSHAPP dsh /usr/local/bin/dsh\nDSHAPP started $pid\n'
            'DSHAPP url dsh web: http://127.0.0.1:$port/?token=$token\n',
        '',
      );
    }
    if (script.contains('DSHAPP alive')) {
      final alive = pid;
      return RemoteExecResult(
        0,
        alive == null
            ? 'DSHAPP home /home/me\n'
            : 'DSHAPP home /home/me\nDSHAPP alive $alive\nDSHAPP samecmd\n'
                  'DSHAPP url dsh web: http://127.0.0.1:$port/?token=$token\n',
        '',
      );
    }
    return const RemoteExecResult(0, '', '');
  }
}

/// A tunnel channel backed by one loopback TCP socket.
class BridgeChannel implements TunnelChannel {
  BridgeChannel(this._socket);

  final Socket _socket;

  @override
  Stream<Uint8List> get stream => _socket;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  void destroy() => _socket.destroy();
}

/// One authenticated SSH connection over a recorded fake; tunnels are real
/// loopback sockets to [BridgeSshServer.forwardPort].
class BridgeTransport implements SshTransport {
  BridgeTransport(this.server);

  final BridgeSshServer server;
  final _done = Completer<void>();
  final List<(String, int)> tunnels = [];
  final List<String> scripts = [];
  bool _closed = false;

  /// Simulates the network dropping the connection.
  void drop() {
    if (_done.isCompleted) return;
    _closed = true;
    _done.complete();
  }

  @override
  Future<RemoteExecResult> run(String script, {Duration timeout = const Duration(seconds: 30)}) async {
    if (_closed) throw const HostLinkError(HostLinkErrorKind.unreachable, 'closed', retryable: true);
    scripts.add(script);
    return server.remote.run(script);
  }

  @override
  Future<TunnelChannel> openTunnel(String host, int port) async {
    tunnels.add((host, port));
    if (_closed) throw const HostLinkError(HostLinkErrorKind.unreachable, 'closed', retryable: true);
    final forwardPort = server.forwardPort;
    if (forwardPort == null) throw const TunnelRefused('no fake dsh running');
    return BridgeChannel(await Socket.connect(InternetAddress.loopbackIPv4, forwardPort));
  }

  @override
  Future<void> ping({Duration timeout = const Duration(seconds: 10)}) async {
    if (_closed) throw TimeoutException('ping');
  }

  @override
  Future<void> get done => _done.future;

  @override
  bool get isClosed => _closed;

  @override
  void close() => drop();
}

/// Builds transports against a [BridgeRemote], presenting [hostKey]; can be
/// told to fail the next connects.
class BridgeSshServer {
  BridgeSshServer({required this.forwardPort, required String token, PresentedHostKey? hostKey})
    : remote = BridgeRemote(port: forwardPort ?? 0, token: token),
      hostKey = hostKey ?? bridgeHostKey;

  /// Loopback port of the FakeDsh this fake SSH server forwards to. Null
  /// simulates a dsh web that stopped listening.
  final int? forwardPort;
  final BridgeRemote remote;
  PresentedHostKey hostKey;

  final List<BridgeTransport> transports = [];
  final List<SshConnectParams> connects = [];

  /// Errors thrown by the next connect attempts, in order.
  final List<HostLinkError> failNext = [];

  BridgeTransport get last => transports.last;

  Future<SshTransport> connect(SshConnectParams params, HostKeyCheck verify) async {
    connects.add(params);
    if (failNext.isNotEmpty) throw failNext.removeAt(0);
    final ok = await verify(hostKey);
    if (!ok) throw const HostLinkError(HostLinkErrorKind.hostKeyRejected, 'rejected');
    final transport = BridgeTransport(this);
    transports.add(transport);
    return transport;
  }
}

/// A pinned sample host pointing at [BridgeSshServer].
SshHostConfig bridgeSshConfig({String id = 'ssh-bridge', String? fingerprint}) =>
    SshHostConfig(
      id: id,
      name: '电脑',
      host: '192.168.1.20',
      user: 'me',
      hostKeyType: fingerprint == null ? null : 'ssh-ed25519',
      hostKeyFingerprint: fingerprint,
    );

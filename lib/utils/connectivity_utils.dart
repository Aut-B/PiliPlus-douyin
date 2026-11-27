import 'dart:async';
import 'dart:io' show Platform;

import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/pages/douyin/diag_probe.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:nm/nm.dart';

abstract final class ConnectivityUtils {
  // One app-lifetime watcher; there is no owner to cancel it explicitly.
  // ignore: cancel_subscriptions
  static StreamSubscription<List<ConnectivityResult>>? _recoverySub;
  static final StreamController<void> _recovered =
      StreamController<void>.broadcast();
  static Timer? _recoveryDebounce;
  static bool _seeded = false;
  static bool _offline = false;
  static int _pendingRecoveries = 0;

  /// Fires after the connectivity stack comes back from a fully-offline
  /// state and the HTTP pool has been rebuilt. Pages can listen to this and
  /// call their own `onReload`; missing the event is safe because the next
  /// request already uses the fresh pool.
  static Stream<void> get onNetworkRecovered => _recovered.stream;

  /// Whether the last observed connectivity state had no usable transport.
  static bool get isOffline => _offline;

  /// Starts watching offline -> online transitions. Idempotent; the HTTP
  /// layer calls this once when its Dio instance is created.
  static void watchRecovery() {
    if (_recoverySub != null) return;
    final connectivity = Connectivity();
    connectivity.checkConnectivity().then(_seed, onError: (Object _) {});
    _recoverySub = connectivity.onConnectivityChanged.listen(
      _onConnectivityChanged,
      onError: (Object _) {},
    );
  }

  static void _seed(List<ConnectivityResult> result) {
    if (_seeded) return;
    _seeded = true;
    _offline = _isNone(result);
  }

  static void _onConnectivityChanged(List<ConnectivityResult> result) {
    final offline = _isNone(result);
    if (!_seeded) {
      _seeded = true;
      _offline = offline;
      return;
    }
    final wasOffline = _offline;
    _offline = offline;
    if (offline) {
      // Flapped back down before the debounce fired: do not rebuild or emit
      // a reload for a recovery that no longer exists.
      _recoveryDebounce?.cancel();
      _recoveryDebounce = null;
      _pendingRecoveries = 0;
      return;
    }
    if (!wasOffline) return;

    // Wi-Fi -> VPN -> Wi-Fi can emit several transitions in a row; coalesce
    // them into one pool rebuild instead of force-closing a fresh pool.
    _pendingRecoveries++;
    _recoveryDebounce?.cancel();
    _recoveryDebounce = Timer(
      const Duration(milliseconds: 300),
      _applyRecovery,
    );
  }

  static void _applyRecovery() {
    _recoveryDebounce = null;
    final transitions = _pendingRecoveries;
    _pendingRecoveries = 0;
    if (transitions == 0) return;

    NetResetOutcome? outcome;
    try {
      outcome = Request.resetConnectionPool(reason: 'connectivity');
    } catch (_) {
      // Never let pool maintenance break the connectivity stream.
    }
    DiagProbe.log('net-connectivity', <String, Object?>{
      'event': 'recovered',
      'transitions': transitions,
      'rebuilt': outcome?.rebuilt,
      'generation': outcome?.generation,
      'transport': outcome?.transport,
      'rebuildMs': outcome?.rebuildMs,
      'platform': Platform.operatingSystem,
    });
    if (!_recovered.isClosed) _recovered.add(null);
  }

  static bool _isNone(List<ConnectivityResult> result) =>
      result.isEmpty ||
      result.every((item) => item == ConnectivityResult.none);

  static Future<bool> get isWiFi async {
    try {
      if (Platform.isLinux) {
        final client = NetworkManagerClient();
        try {
          await client.connect();
          return switch (client.metered) {
            NetworkManagerMetered.yes ||
            NetworkManagerMetered.guessYes => false,
            _ => true,
          };
        } finally {
          await client.close();
        }
      }
      return PlatformUtils.isMobile &&
          (await Connectivity().checkConnectivity()).contains(
            ConnectivityResult.wifi,
          );
    } catch (_) {
      return true;
    }
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/pages/douyin/diag_probe.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/global_data.dart';
import 'package:PiliPlus/utils/login_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:brotli/brotli.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_http2_adapter/dio_http2_adapter.dart';
import 'package:flutter/foundation.dart' show kDebugMode, listEquals;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

const String _kDiagStartMs = '_diag_start_ms';
const String _kDiagSinceResume = '_diag_since_resume';
const String _kDiagFirstAfterResume = '_diag_first_after_resume';
const String _kDiagFirstAfterLongIdle = '_diag_first_after_long_idle';
const String _kNetRetryTag = 'net-retry';
const String _kNetRecoveredTag = 'net-recovered';

/// scheme://host/path only: never persist query values (access_key etc).
String _safeUri(Uri uri) {
  final path = uri.path.isEmpty ? '/' : uri.path;
  return '${uri.scheme}://${uri.host}$path';
}

/// HTTP/2 forbids connection-specific headers, while an explicit keep-alive
/// keeps the h11 pool warm. Keep the base / in-flight request headers aligned
/// with whichever transport the retry is about to use.
void _syncConnectionHeader(Map<String, dynamic> headers, bool http2) {
  String? key;
  for (final name in headers.keys) {
    if (name.toLowerCase() == 'connection') {
      key = name;
      break;
    }
  }
  if (http2) {
    if (key != null) headers.remove(key);
  } else if (key == null) {
    headers['connection'] = 'keep-alive';
  }
}

/// 只读诊断拦截器：请求失败时写一条 `net-fail`，绝不改变重试/超时/鉴权行为。
///
/// 位置必须排在 `RetryInterceptor` 之前：Dio 的 onError 是逆序执行，
/// 这样只有重试彻底放弃后的最终失败才会被记录，重试成功不产生噪音。
class _NetFailDiagInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    // Recorded even when diagnostics are off: the pool owner uses it to tell
    // a concurrent sibling from a retry that already started on a new pool.
    options.extra[kNetAttemptStartExtra] =
        DateTime.now().millisecondsSinceEpoch;
    try {
      if (kDiagEnabled) {
        final (msSinceResume, firstAfterResume, firstAfterLongIdle) =
            DiagProbe.takeRequestTiming();
        options.extra
          ..[_kDiagStartMs] = DateTime.now().millisecondsSinceEpoch
          ..[_kDiagSinceResume] = msSinceResume
          ..[_kDiagFirstAfterResume] = firstAfterResume
          ..[_kDiagFirstAfterLongIdle] = firstAfterLongIdle;
      }
    } catch (_) {
      // 诊断永远不能反过来影响请求本身。
    }
    handler.next(options);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    try {
      _record(err);
    } catch (_) {
      // 诊断永远不能反过来影响请求失败的处理。
    }
    handler.next(err);
  }

  void _record(DioException err) {
    final options = err.requestOptions;
    final startMs = options.extra[_kDiagStartMs];
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final uri = options.uri;
    DiagProbe.log('net-fail', <String, Object?>{
      'host': uri.host,
      // 只记 path，不记任何 query/value，避免 access_key、SESSDATA 等落盘。
      'path': uri.path.isEmpty ? options.path.split('?').first : uri.path,
      'method': options.method,
      'statusCode': err.response?.statusCode,
      'errorType': _errorType(err),
      'dioType': err.type.name,
      'errorMsg': _safeErrorMsg(err),
      'elapsedMs': startMs is int ? nowMs - startMs : null,
      'msSinceResume': options.extra[_kDiagSinceResume],
      'firstAfterResume': options.extra[_kDiagFirstAfterResume] == true,
      'firstAfterLongIdle': options.extra[_kDiagFirstAfterLongIdle] == true,
      'hasToken': _hasToken(options),
      'hasCookie': _hasHeader(options.headers, 'cookie'),
      'rebuilt': options.extra[kNetRebuiltExtra] == true,
      'transport': options.extra[kNetTransportExtra] ?? Request.transportPath,
      'generation':
          options.extra[kNetGenerationExtra] ?? Request.poolGeneration,
      'switched': options.extra[kNetSwitchedExtra] == true,
      'escalated': options.extra[kNetEscalatedExtra] == true,
    });
  }

  static String _errorType(DioException err) {
    if (err.response != null) return 'http';
    return switch (err.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.transformTimeout => 'timeout',
      DioExceptionType.badCertificate => 'tls',
      DioExceptionType.badResponse => 'http',
      DioExceptionType.connectionError ||
      DioExceptionType.unknown => _classifyIoError(err.error) ?? 'connection',
      DioExceptionType.cancel => 'connection',
    };
  }

  static String? _classifyIoError(Object? error) {
    if (error is HandshakeException || error is TlsException) return 'tls';
    if (error is SocketException) {
      final msg = error.message.toLowerCase();
      if (msg.contains('failed host lookup') ||
          msg.contains('nodename nor servname') ||
          msg.contains('no address associated with hostname') ||
          msg.contains('name or service not known') ||
          msg.contains('temporary failure in name resolution')) {
        return 'dns';
      }
      if (msg.contains('timed out') || msg.contains('timeout')) {
        return 'timeout';
      }
      if (msg.contains('connection closed') ||
          msg.contains('connection reset') ||
          msg.contains('broken pipe') ||
          msg.contains('socket has been closed') ||
          msg.contains('connection abort')) {
        return 'socket';
      }
      return 'connection';
    }
    return null;
  }

  static String _safeErrorMsg(DioException err) {
    final raw = (err.error?.toString() ?? err.message ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .replaceAllMapped(
          RegExp(
            r'(access_key|sessdata|bili_jct|buvid3|buvid4|token|cookie|authorization)\s*[=:]\s*[^&\s;]+',
            caseSensitive: false,
          ),
          (match) => '${match[1]}=***',
        );
    return raw.length <= 300 ? raw : raw.substring(0, 300);
  }

  static bool _hasToken(RequestOptions options) {
    if (_hasHeader(options.headers, 'authorization')) return true;
    final cookie = _headerValue(options.headers, 'cookie');
    if (cookie != null && cookie.contains('SESSDATA=')) return true;
    if (options.queryParameters['access_key'] != null) return true;
    final data = options.data;
    return data is Map && data['access_key'] != null;
  }

  static String? _headerValue(Map<String, dynamic> headers, String name) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == name) {
        final value = entry.value;
        return value?.toString();
      }
    }
    return null;
  }

  static bool _hasHeader(Map<String, dynamic> headers, String name) {
    final value = _headerValue(headers, name);
    return value != null && value.isNotEmpty;
  }
}

class Request {
  static final gzip = ZLibDecoder(gzip: true);
  static const brotli = BrotliDecoder();

  static final Request _instance = Request._internal();
  static late AccountManager accountManager;
  static final _enableHttp2 = Pref.enableHttp2;
  static late final Dio dio;
  static Dio? _http11Dio;
  static Dio get http11Dio {
    if (!_transportH2) return _http11Dio ?? dio;
    return _http11Dio ??= _cloneHttp11Dio();
  }
  factory Request() => _instance;

  /// Transport currently used by [dio]. Reported in `net-rebuild` / `net-fail`.
  static String get transportPath => _transportH2 ? 'h2' : 'h11';

  /// Bumped every time the connection pool is replaced. A retry log carrying a
  /// newer generation proves it did not run on the old dead sockets.
  static int get poolGeneration => _poolGeneration;

  static bool _transportH2 = _enableHttp2;
  static int _poolGeneration = 0;
  static int _lastResetAtMs = 0;
  static int _lastConnectionFailAtMs = 0;
  static int _connectionFailStreak = 0;

  /// Parallel requests failing on the same dead pool must share one rebuild.
  static const int _kResetDebounceMs = 500;

  /// Two failures farther apart than this are separate episodes.
  static const int _kConsecutiveFailWindowMs = 15000;

  /// 设置cookie
  static void setCookie() {
    accountManager = AccountManager();
    dio.interceptors.add(accountManager);
    Accounts.refresh();
    LoginUtils.setWebCookie();

    if (Accounts.main.isLogin) {
      final coin = Pref.userInfoCache?.money;
      if (coin == null) {
        setCoin();
      } else {
        GlobalData().coins = coin;
      }
    }
  }

  static Future<void> setCoin() async {
    final res = await UserHttp.getCoin();
    if (res case Success(:final response)) {
      GlobalData().coins = response;
    }
  }

  static Future<void> buvidActive(Account account) async {
    // 这样线程不安全, 但仍按预期进行
    if (account.activated) return;
    account.activated = true;
    try {
      // final html = await Request().get(Api.dynamicSpmPrefix,
      //     options: Options(extra: {'account': account}));
      // final String spmPrefix = _spmPrefixExp.firstMatch(html.data)!.group(1)!;
      final String randPngEnd = base64.encode([
        ...Iterable<int>.generate(32, (_) => Utils.random.nextInt(256)),
        0,
        0,
        0,
        0,
        73,
        69,
        78,
        68,
        ...Iterable<int>.generate(4, (_) => Utils.random.nextInt(256)),
      ]);

      final jsonData = json.encode({
        '3064': 1,
        '39c8': '333.1387.fp.risk',
        '3c43': {
          'adca': 'Linux',
          'bfe9': randPngEnd.substring(randPngEnd.length - 50),
        },
      });

      await Request().post(
        Api.activateBuvidApi,
        data: {'payload': jsonData},
        options: Options(
          extra: {'account': account},
          contentType: Headers.jsonContentType,
        ),
      );
    } catch (_) {}
  }

  static Dio _cloneHttp11Dio() {
    final current = dio.httpClientAdapter;
    final h11Adapter = current is Http2Adapter
        ? current.fallbackAdapter
        : current as IOHttpClientAdapter;
    final h11 = dio.clone(httpClientAdapter: h11Adapter);
    final interceptors = h11.interceptors;
    for (var i = 0; i < interceptors.length; i++) {
      final elem = interceptors[i];
      if (elem is RetryInterceptor) {
        interceptors[i] = elem.copyWith(client: h11);
        break;
      }
    }
    return h11;
  }

  static Timer? _networkChangeDebounce;

  static void _onConnectivityChanged(List<ConnectivityResult> result) {
    if (listEquals(result, const [ConnectivityResult.none])) {
      return;
    }
    _networkChangeDebounce?.cancel();
    _networkChangeDebounce = Timer(
      const Duration(milliseconds: 500),
      _resetAdaptersForNetworkChange,
    );
  }

  static void _watchConnectivity() {
    Connectivity().onConnectivityChanged.skip(1).listen(_onConnectivityChanged);
  }

  static (IOHttpClientAdapter, ConnectionManager?) _createPool({
    required bool http2,
  }) {
    final bool enableSystemProxy;
    late final String systemProxyHost;
    late final int? systemProxyPort;
    if (Pref.enableSystemProxy) {
      systemProxyHost = Pref.systemProxyHost;
      systemProxyPort = int.tryParse(Pref.systemProxyPort);
      enableSystemProxy = systemProxyPort != null && systemProxyHost.isNotEmpty;
    } else {
      enableSystemProxy = false;
    }

    final http11Adapter = IOHttpClientAdapter(
      createHttpClient: enableSystemProxy
          ? () => HttpClient()
              ..idleTimeout = const Duration(seconds: 15)
              ..autoUncompress = false
              ..findProxy = ((_) => 'PROXY $systemProxyHost:$systemProxyPort')
              ..badCertificateCallback = (cert, host, port) => true
          : () => HttpClient()
              ..idleTimeout = const Duration(seconds: 15)
              ..autoUncompress = false, // Http2Adapter没有自动解压, 统一行为
    );

    final connectionManager = http2
        ? ConnectionManager(
            idleTimeout: const Duration(seconds: 15),
            onClientCreate: enableSystemProxy
                ? (_, config) => config
                    ..proxy = Uri(
                      scheme: 'http',
                      host: systemProxyHost,
                      port: systemProxyPort,
                    )
                    ..onBadCertificate = (_) => true
                : Pref.badCertificateCallback
                ? (_, config) => config.onBadCertificate = (_) => true
                : null,
          )
        : null;
    return (http11Adapter, connectionManager);
  }

  @pragma('vm:notify-debugger-on-exception')
  static void _resetAdaptersForNetworkChange() {
    resetConnectionPool(reason: 'connectivity');
  }

  /// Force-close the current connection pool / http client and swap in a
  /// freshly built one. This drops any stale dns cache or half-dead socket
  /// pool left behind after a long background idle, and is called both on
  /// connectivity changes and on a dns-class retry.
  @pragma('vm:notify-debugger-on-exception')
  static void rebuildConnectionPool({String reason = 'manual'}) {
    resetConnectionPool(reason: reason);
  }

  /// Called by [RetryInterceptor] before it schedules a retry.
  static NetResetOutcome handleConnectionReset(
    DioException err,
    String reason,
    int attempt,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final sinceLast = _lastResetAtMs == 0 ? null : now - _lastResetAtMs;
    final attemptStart = err.requestOptions.extra[kNetAttemptStartExtra];
    // A request that left for the wire before the latest rebuild is a
    // concurrent sibling of the failure that triggered it: share that one
    // rebuild instead of rebuilding again for every parallel call on the page.
    final sibling = _lastResetAtMs > 0 &&
        (attemptStart is int
            ? attemptStart < _lastResetAtMs
            : sinceLast != null && sinceLast < _kResetDebounceMs);
    if (sibling) {
      final outcome = NetResetOutcome(
        rebuilt: false,
        debounced: true,
        transport: transportPath,
        generation: _poolGeneration,
        consecutive: _connectionFailStreak,
      );
      // This retry still runs on the pool as it is now, not on the snapshot
      // the request was created with.
      _syncConnectionHeader(
        err.requestOptions.headers,
        outcome.transport == 'h2',
      );
      _logRebuild(
        reason,
        outcome,
        err,
        attempt: attempt,
        sinceLast: sinceLast,
      );
      return outcome;
    }

    var streak = _connectionFailStreak;
    var observedStreak = streak;
    var escalated = false;
    if (reason == 'connection') {
      if (_lastConnectionFailAtMs == 0 ||
          now - _lastConnectionFailAtMs > _kConsecutiveFailWindowMs) {
        streak = 1;
      } else {
        streak += 1;
      }
      _lastConnectionFailAtMs = now;
      observedStreak = streak;
      // The retry on the freshly rebuilt pool also failed: stop hammering the
      // same transport path and switch to the other one (h11 <-> h2).
      if (streak >= 2) {
        escalated = true;
      }
      // Persist the streak even on the first failure. Otherwise every call
      // starts from 0, reaches at most 1, and escalation never happens.
      _connectionFailStreak = escalated ? 0 : streak;
    } else {
      _connectionFailStreak = 0;
      streak = 0;
      observedStreak = 0;
    }

    // Respect the user's HTTP/2 setting: only a user who enabled h2 gets the
    // h11 <-> h2 fallback. With h2 off, a second failure still rebuilds a
    // fresh h11 pool instead of silently switching transports.
    final switchTransport = escalated && _enableHttp2;
    final targetH2 = switchTransport ? !_transportH2 : _transportH2;
    _lastResetAtMs = now;
    final outcome = _rebuildNow(
      targetH2: targetH2,
      reason: reason,
      err: err,
      attempt: attempt,
      consecutive: observedStreak,
      switched: targetH2 != _transportH2,
      escalated: escalated,
      sinceLast: sinceLast,
    );
    _syncConnectionHeader(
      err.requestOptions.headers,
      outcome.transport == 'h2',
    );
    return outcome;
  }

  /// Force a rebuild outside a retry (network change / resume warmup).
  static NetResetOutcome resetConnectionPool({
    required String reason,
    DioException? err,
  }) {
    _lastResetAtMs = DateTime.now().millisecondsSinceEpoch;
    _connectionFailStreak = 0;
    return _rebuildNow(targetH2: _transportH2, reason: reason, err: err);
  }

  static NetResetOutcome _rebuildNow({
    required bool targetH2,
    required String reason,
    DioException? err,
    int? attempt,
    int consecutive = 0,
    bool switched = false,
    bool escalated = false,
    int? sinceLast,
  }) {
    final previousTransport = transportPath;
    final watch = Stopwatch()..start();
    var ok = false;
    Object? failure;
    try {
      _applyPool(_createPool(http2: targetH2), http2: targetH2);
      ok = true;
    } catch (e) {
      failure = e;
    }
    watch.stop();
    if (ok) _poolGeneration++;

    final outcome = NetResetOutcome(
      rebuilt: ok,
      debounced: false,
      transport: transportPath,
      generation: _poolGeneration,
      rebuildMs: watch.elapsedMilliseconds,
      consecutive: consecutive,
      switched: switched,
      escalated: escalated,
      freshClient: ok,
    );
    _logRebuild(
      reason,
      outcome,
      err,
      previousTransport: previousTransport,
      attempt: attempt,
      sinceLast: sinceLast,
    );
    if (failure != null) {
      DiagProbe.log('net-rebuild-error', <String, Object?>{
        'reason': reason,
        'error': failure.toString(),
      });
    }
    return outcome;
  }

  static void _logRebuild(
    String reason,
    NetResetOutcome outcome,
    DioException? err, {
    String? previousTransport,
    int? attempt,
    int? sinceLast,
  }) {
    final uri = err?.requestOptions.uri;
    DiagProbe.log('net-rebuild', <String, Object?>{
      'reason': reason,
      'uri': uri == null ? null : _safeUri(uri),
      'host': uri?.host,
      'method': err?.requestOptions.method,
      'attempt': attempt,
      'debounced': outcome.debounced,
      'rebuilt': outcome.rebuilt,
      'switched': outcome.switched,
      'escalated': outcome.escalated,
      'freshClient': outcome.freshClient,
      'previousTransport': previousTransport,
      'transport': outcome.transport,
      'switchBlocked': outcome.escalated && !outcome.switched && !_enableHttp2
          ? 'http2_disabled'
          : null,
      'generation': outcome.generation,
      'rebuildMs': outcome.rebuildMs,
      'consecutive': outcome.consecutive,
      'sinceLastResetMs': sinceLast,
      'dioType': err?.type.name,
    });
  }

  static void _applyPool(
    (IOHttpClientAdapter, ConnectionManager?) pool, {
    required bool http2,
  }) {
    final (newH11, newConnectionManager) = pool;
    final oldAdapter = dio.httpClientAdapter;
    final oldH11 = _http11Dio?.httpClientAdapter;
    final oldFallback =
        oldAdapter is Http2Adapter ? oldAdapter.fallbackAdapter : null;

    final newAdapter = http2
        ? Http2Adapter(newConnectionManager!, fallbackAdapter: newH11)
        : newH11;
    // Swap first so a retry that starts now cannot land on the dead pool.
    dio.httpClientAdapter = newAdapter;
    _http11Dio?.httpClientAdapter = newH11;
    _transportH2 = http2;
    _syncPoolConnectionHeader(http2);

    // Drop the old clients after the swap. force:true closes idle and
    // in-flight sockets, clearing the stale keep-alive pool with them.
    final oldAdapters = <HttpClientAdapter>{
      oldAdapter,
      if (oldFallback != null) oldFallback,
      if (oldH11 != null) oldH11,
    };
    for (final adapter in oldAdapters) {
      if (identical(adapter, newAdapter) || identical(adapter, newH11)) {
        continue;
      }
      try {
        adapter.close(force: true);
      } catch (_) {}
    }
  }

  /*
   * config it and create
   */
  Request._internal() {
    //BaseOptions、Options、RequestOptions 都可以配置参数，优先级别依次递增，且可以根据优先级别覆盖参数
    BaseOptions options = BaseOptions(
      //请求基地址,可以包含子路径
      baseUrl: HttpString.apiBaseUrl,
      //连接服务器超时时间，单位是毫秒.
      connectTimeout: const Duration(milliseconds: 10000),
      //响应流上前后两次接受到数据的间隔，单位为毫秒。
      receiveTimeout: const Duration(milliseconds: 10000),
      //Http请求头.
      headers: {
        'user-agent': 'Dart/3.6 (dart:io)', // Http2Adapter不会自动添加标头
        if (!_enableHttp2) 'connection': 'keep-alive',
        'accept-encoding': 'br,gzip',
      },
      responseDecoder: _responseDecoder, // Http2Adapter没有自动解压
      persistentConnection: true,
    );

    final (h11, connectionManager) = _createPool(http2: _enableHttp2);

    dio = Dio(options)
      ..httpClientAdapter = _enableHttp2
          ? Http2Adapter(connectionManager, fallbackAdapter: h11)
          : h11;
    _syncPoolConnectionHeader(_enableHttp2);

    // 只读诊断，先于重试拦截器入链：onError 逆序，最终失败才会被记录。
    dio.interceptors.add(_NetFailDiagInterceptor());

    // 先于其他Interceptor
    if (Pref.retryCount != 0) {
      dio.interceptors.add(
        RetryInterceptor(
          dio,
          Pref.retryCount,
          Pref.retryDelay,
          onNetReset: handleConnectionReset,
          log: (tag, fields) => DiagProbe.log(tag, fields),
          retryTag: _kNetRetryTag,
          recoveredTag: _kNetRecoveredTag,
        ),
      );
    }

    // 日志拦截器 输出请求、响应内容
    if (kDebugMode) {
      dio.interceptors.add(
        LogInterceptor(
          request: false,
          requestHeader: false,
          responseHeader: false,
        ),
      );
    }

    dio
      ..transformer = BackgroundTransformer()
      ..options.validateStatus = (int? status) {
        return status != null && status >= 200 && status < 300;
      };

    if (Platform.isIOS) _watchConnectivity();
    _watchLifecycle();
  }

  /*
   * get请求
   */
  Future<Response> get<T>(
    String url, {
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      return await dio.get<T>(
        url,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        }, // 将自定义 Map 数据赋值给 Response 的 data 属性
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  /*
   * post请求
   */
  Future<Response> post<T>(
    String url, {
    Object? data,
    Map<String, dynamic>? queryParameters,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    // if (kDebugMode) debugPrint('post-data: $data');
    try {
      return await dio.post<T>(
        url,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      AccountManager.toast(e);
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        }, // 将自定义 Map 数据赋值给 Response 的 data 属性
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  Future<Response> request<T>(
    String url, {
    Map<String, dynamic>? queryParameters,
    Object? data,
    Options? options,
    CancelToken? cancelToken,
  }) async {
    try {
      return await dio.request<T>(
        url,
        data: data,
        queryParameters: queryParameters,
        options: options,
        cancelToken: cancelToken,
      );
    } on DioException catch (e) {
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        }, // 将自定义 Map 数据赋值给 Response 的 data 属性
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  /*
   * 下载文件
   */
  Future<Response> downloadFile(
    String urlPath,
    String savePath, {
    CancelToken? cancelToken,
  }) async {
    try {
      return await dio.download(
        urlPath,
        savePath,
        cancelToken: cancelToken,
        // onReceiveProgress: (int count, int total) {
        // 进度
        // if (kDebugMode) debugPrint("$count $total");
        // },
      );
      // if (kDebugMode) debugPrint('downloadFile success: ${response.data}');
    } on DioException catch (e) {
      // if (kDebugMode) debugPrint('downloadFile error: $e');
      return Response(
        data: {
          'message': await AccountManager.dioError(e),
        },
        statusCode: e.response?.statusCode ?? -1,
        requestOptions: e.requestOptions,
      );
    }
  }

  static List<int> responseBytesDecoder(
    List<int> responseBytes,
    Map<String, List<String>> headers,
  ) => switch (headers['content-encoding']?.firstOrNull) {
    'gzip' => gzip.convert(responseBytes),
    'br' => brotli.convert(responseBytes),
    _ => responseBytes,
  };

  static String _responseDecoder(
    List<int> responseBytes,
    RequestOptions options,
    ResponseBody responseBody,
  ) => utf8.decode(
    responseBytesDecoder(responseBytes, responseBody.headers),
    allowMalformed: true,
  );

  /// Background longer than this counts as a "long idle" whose resume may
  /// leave the dns / connection stack stale. Kept in sync with
  /// `mobile_observer.dart` so the diag signal and the warmup agree.
  static const int _kLongBackgroundMs = 5 * 60 * 1000;

  static bool _lifecycleObserved = false;

  static void _watchLifecycle() {
    if (_lifecycleObserved) return;
    _lifecycleObserved = true;
    WidgetsBinding.instance.addObserver(_LifecycleObserver());
  }

  /// Lightweight probe fired once after the app returns from a long
  /// background idle, before the first real request. It warms up the
  /// connection stack and, if the probe still fails with a connection/dns
  /// error, rebuilds the pool once so the subsequent real requests do not
  /// all start with dns failures. Fire-and-forget; never blocks callers.
  static Future<void> warmUpAfterResume(int idleMs) async {
    final url = '${HttpString.apiBaseUrl}/x/web-interface/nav';
    // Throwaway Dio with NO interceptors so the probe:
    //   - does not consume the first-after-resume flag of takeRequestTiming()
    //   - does not get logged as net-fail noise by _NetFailDiagInterceptor
    //   - does not trigger RetryInterceptor (the probe IS the recovery)
    // Share the current adapter of dio so it probes the real pool state; do NOT
    // close() the probe, that would close the shared adapter and kill the pool of dio.
    final probe = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 4),
        sendTimeout: const Duration(seconds: 4),
        receiveTimeout: const Duration(seconds: 4),
      ),
    )..httpClientAdapter = dio.httpClientAdapter;
    try {
      await probe.get<void>(url).timeout(const Duration(seconds: 5));
      DiagProbe.log('net-warmup', <String, Object?>{'idleMs': idleMs, 'ok': true});
    } on DioException catch (e) {
      if (isRetryableNetError(e)) {
        DiagProbe.log('net-warmup-rebuild', <String, Object?>{
          'idleMs': idleMs,
          'dns': isDnsError(e),
          'dioType': e.type.name,
        });
        rebuildConnectionPool(reason: 'resume-warmup');
      }
    } catch (_) {
      // timeout / cancel / anything non-retryable: ignore, let real requests retry.
    }
  }

  static void _syncPoolConnectionHeader(bool http2) {
    _syncConnectionHeader(dio.options.headers, http2);
    final h11 = _http11Dio;
    if (h11 != null && !identical(h11.options.headers, dio.options.headers)) {
      _syncConnectionHeader(h11.options.headers, http2);
    }
  }
}

class _LifecycleObserver with WidgetsBindingObserver {
  int? _backgroundAtMs;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (state == AppLifecycleState.resumed) {
      final idleMs = _backgroundAtMs == null ? null : nowMs - _backgroundAtMs!;
      _backgroundAtMs = null;
      if (idleMs != null && idleMs >= Request._kLongBackgroundMs) {
        unawaited(Request.warmUpAfterResume(idleMs));
      }
    } else {
      _backgroundAtMs ??= nowMs;
    }
  }
}

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:http2/http2.dart';

/// Hook invoked before a retry that may land on a dead socket pool, so the
/// owner can close the stale client and swap in a fresh one **before** the
/// next attempt leaves for the wire.
///
/// The hook runs synchronously. Returning the outcome lets the retry log prove
/// whether the rebuild actually happened and which transport it runs on.
typedef NetResetHook = NetResetOutcome? Function(
  DioException err,
  String reason,
  int attempt,
);

/// Extra keys written into [RequestOptions.extra] so the terminal `net-fail`
/// diagnostic can report what the retry path did.
const String kNetRebuiltExtra = '_net_rebuilt';
const String kNetRebuildMsExtra = '_net_rebuild_ms';
const String kNetTransportExtra = '_net_transport';
const String kNetGenerationExtra = '_net_generation';
const String kNetSwitchedExtra = '_net_switched';
const String kNetEscalatedExtra = '_net_escalated';

/// When the current attempt actually hit the network. Used by the pool owner
/// to tell a concurrent sibling (started before the rebuild, so it must be
/// debounced) apart from a retry that started on the fresh pool (which is
/// allowed to escalate the transport).
const String kNetAttemptStartExtra = '_net_attempt_start_ms';

/// Retry counter written by [RetryInterceptor]. `> 0` means this request has
/// already been replayed at least once (and therefore already rebuilt the
/// pool), so the toast-level auto recovery must not replay it a second time.
const String kNetRetryCountExtra = '_rt';

/// What the owner did (or skipped) when asked to rebuild the transport pool.
class NetResetOutcome {
  const NetResetOutcome({
    required this.rebuilt,
    required this.debounced,
    required this.transport,
    required this.generation,
    this.rebuildMs,
    this.consecutive = 0,
    this.switched = false,
    this.escalated = false,
    this.freshClient = false,
  });

  final bool rebuilt;
  final bool debounced;
  final String transport;
  final int generation;
  final int? rebuildMs;
  final int consecutive;
  final bool switched;
  final bool escalated;
  final bool freshClient;
}

/// Whether [err] is a connection-level failure worth retrying. Reused by
/// `init.dart` for the post-resume warmup decision so both paths share one
/// definition of "retryable network error".
bool isRetryableNetError(DioException err) {
  if (err.requestOptions.responseType == ResponseType.stream) return false;
  if (err.response != null) return false;
  return switch (err.type) {
    DioExceptionType.connectionError ||
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.unknown =>
      // A dead keep-alive socket is only safe to replay for idempotent
      // methods; otherwise the request may already have reached the server
      // and retrying could double-submit.
      err.error is! TransportConnectionException || isStaleSocketError(err),
    _ => false,
  };
}

/// Whether [err] is a terminated keep-alive socket on an idempotent request.
///
/// `dio_http2_adapter` surfaces a forcefully closed h2 connection as
/// [TransportConnectionException] (dio wraps it as `unknown` with no response).
/// Replaying GET/HEAD/OPTIONS cannot double-submit a side effect, so such a
/// failure must be retried on a rebuilt pool like any other connection error.
bool isStaleSocketError(DioException err) {
  if (err.response != null) return false;
  if (err.requestOptions.responseType == ResponseType.stream) return false;
  if (err.error is! TransportConnectionException) return false;
  return switch (err.requestOptions.method.toUpperCase()) {
    'GET' || 'HEAD' || 'OPTIONS' => true,
    _ => false,
  };
}

/// Whether [err] is a dns-resolution failure (Failed host lookup and friends).
bool isDnsError(DioException err) {
  final e = err.error;
  if (e is SocketException) {
    final msg = e.message.toLowerCase();
    return msg.contains('failed host lookup') ||
        msg.contains('nodename nor servname') ||
        msg.contains('no address associated with hostname') ||
        msg.contains('name or service not known') ||
        msg.contains('temporary failure in name resolution');
  }
  return false;
}

/// Exponential backoff (ms) for retry [attempt] (1-based), e.g. base 500 ->
/// 500 / 1000 / 2000 ms.
int retryDelayMs(int attempt, int baseDelay) => baseDelay * (1 << (attempt - 1));

/// Bounded backoff retries for connection-level failures.
///
/// Diagnostics (read-only): every retry attempt logs `net-retry`; a request
/// that succeeds after at least one retry logs `net-recovered`. The final
/// terminal failure is left to `_NetFailDiagInterceptor` (registered before
/// this interceptor; dio runs onError in reverse, so only the terminal
/// failure reaches it) which already emits `net-fail`.
class RetryInterceptor extends Interceptor {
  final Dio _client;
  final int _count;
  final int _delay;

  final NetResetHook? onNetReset;
  final void Function(String tag, Map<String, Object?> fields)? log;
  final String retryTag;
  final String recoveredTag;

  RetryInterceptor(
    this._client,
    this._count,
    this._delay, {
    this.onNetReset,
    this.log,
    this.retryTag = 'net-retry',
    this.recoveredTag = 'net-recovered',
  });

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    if (options.responseType == ResponseType.stream) {
      return handler.next(err);
    }
    if (err.response != null) {
      if (options.followRedirects && options.maxRedirects > 0) {
        final status = err.response!.statusCode;
        if (status != null && 300 <= status && status < 400) {
          var redirectUrl = err.response!.headers.value('location');
          if (redirectUrl != null) {
            var uri = Uri.parse(redirectUrl);
            if (!uri.hasScheme) {
              uri = options.uri.resolveUri(uri);
              redirectUrl = uri.toString();
            }
            (options..path = redirectUrl).maxRedirects--;
            if (status == 303) {
              options
                ..data = null
                ..method = 'GET';
            }
            _client
                .fetch(options)
                .then(
                  (i) => handler.resolve(
                    i
                      ..redirects.add(
                        RedirectRecord(status, options.method, uri),
                      )
                      ..isRedirect = true,
                  ),
                )
                .onError<DioException>((error, _) => handler.next(error));
            return;
          }
        }
      }
      return handler.next(err);
    }

    if (!isRetryableNetError(err)) {
      return handler.next(err);
    }

    final attempt = ((options.extra[kNetRetryCountExtra] as int?) ?? 0) + 1;
    if (attempt > _count) {
      return handler.next(err);
    }
    options.extra[kNetRetryCountExtra] = attempt;

    final dns = isDnsError(err);
    NetResetOutcome? reset;
    final reason = _resetReason(err);
    if (reason != null) {
      try {
        // Rebuild BEFORE scheduling the retry: the next attempt must never
        // reuse the socket pool / dns cache that just failed.
        reset = onNetReset?.call(err, reason, attempt);
      } catch (_) {
        // diagnostics / pool rebuild must never break request handling
      }
    }
    if (reset != null) {
      options.extra
        ..[kNetRebuiltExtra] = reset.rebuilt
        ..[kNetRebuildMsExtra] = reset.rebuildMs
        ..[kNetTransportExtra] = reset.transport
        ..[kNetGenerationExtra] = reset.generation
        ..[kNetSwitchedExtra] = reset.switched
        ..[kNetEscalatedExtra] = reset.escalated;
    }
    _log(retryTag, err, attempt, dns, reset);

    final waitMs = retryDelayMs(attempt, _delay);
    Timer(Duration(milliseconds: waitMs), () {
      // Mark the moment this attempt leaves for the wire: a failure from this
      // attempt started after the rebuild, so it may escalate the transport.
      options.extra[kNetAttemptStartExtra] =
          DateTime.now().millisecondsSinceEpoch;
      _client.fetch(options).then<void>(
        (response) {
          _log(recoveredTag, err, attempt, dns, reset);
          handler.resolve(response);
        },
        onError: (Object error, StackTrace _) {
          if (error is DioException) {
            handler.reject(error);
          } else {
            handler.reject(
              DioException(requestOptions: options, error: error),
            );
          }
        },
      );
    });
  }

  /// Whether this failure should trigger a pool rebuild before retrying.
  ///
  /// DNS failures always do. A generic connection failure only does so for
  /// idempotent requests: replaying GET/HEAD/OPTIONS cannot double-submit a
  /// side effect, while a POST may already have reached the server.
  String? _resetReason(DioException err) {
    if (err.response != null) return null;
    if (isDnsError(err)) return 'dns';
    final method = err.requestOptions.method.toUpperCase();
    if (method != 'GET' && method != 'HEAD' && method != 'OPTIONS') {
      return null;
    }
    // Stale h2 sockets arrive as `unknown` / `sendTimeout` rather than
    // `connectionError`, but they are exactly the dead-pool case.
    if (isStaleSocketError(err)) return 'connection';
    // `sendTimeout` on a keep-alive socket is the h2 adapter's way of saying
    // the request never got a response from a dead connection; for an
    // idempotent method a replay on a fresh pool is safe.
    if (err.type == DioExceptionType.connectionError ||
        err.type == DioExceptionType.connectionTimeout ||
        err.type == DioExceptionType.sendTimeout) {
      return 'connection';
    }
    // dio wraps some socket-level failures as `unknown`; only treat it as a
    // connection failure when the underlying error really is a socket one.
    if (err.type == DioExceptionType.unknown &&
        err.error is SocketException) {
      return 'connection';
    }
    return null;
  }

  void _log(
    String tag,
    DioException err,
    int attempt,
    bool dns,
    NetResetOutcome? reset,
  ) {
    try {
      log?.call(tag, <String, Object?>{
        'host': err.requestOptions.uri.host,
        'method': err.requestOptions.method,
        'attempt': attempt,
        'max': _count,
        'dns': dns,
        'dioType': err.type.name,
        'errorMsg': _short(err),
        'rebuild': reset?.rebuilt,
        'debounced': reset?.debounced,
        'rebuildMs': reset?.rebuildMs,
        'transport': reset?.transport,
        'generation': reset?.generation,
        'switched': reset?.switched,
        'escalated': reset?.escalated,
        'freshClient': reset?.freshClient,
      });
    } catch (_) {}
  }

  static String _short(DioException err) {
    final raw = err.error?.toString() ?? err.message ?? '';
    return raw.length <= 200 ? raw : raw.substring(0, 200);
  }

  RetryInterceptor copyWith({Dio? client, int? count, int? delay}) =>
      RetryInterceptor(
        client ?? _client,
        count ?? _count,
        delay ?? _delay,
        onNetReset: onNetReset,
        log: log,
        retryTag: retryTag,
        recoveredTag: recoveredTag,
      );
}

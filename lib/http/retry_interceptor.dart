import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:http2/http2.dart';

/// Hook invoked before a dns-class retry so the owner can close the stale
/// connection pool / rebuild the http client and clear the dead dns cache
/// left behind after a long background idle.
typedef DnsResetHook = void Function(DioException err);

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
      // TransportConnectionException: request may already have been received
      // by the server, so retrying could double-submit.
      err.error is! TransportConnectionException,
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

  final DnsResetHook? onDnsReset;
  final void Function(String tag, Map<String, Object?> fields)? log;
  final String retryTag;
  final String recoveredTag;

  RetryInterceptor(
    this._client,
    this._count,
    this._delay, {
    this.onDnsReset,
    this.log,
    this.retryTag = 'net-retry',
    this.recoveredTag = 'net-recovered',
  });

  static const String _rtKey = '_rt';

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

    final attempt = ((options.extra[_rtKey] as int?) ?? 0) + 1;
    if (attempt > _count) {
      return handler.next(err);
    }
    options.extra[_rtKey] = attempt;

    final dns = isDnsError(err);
    _log(retryTag, err, attempt, dns);

    if (dns) {
      try {
        onDnsReset?.call(err);
      } catch (_) {
        // diagnostics / pool rebuild must never break request handling
      }
    }

    final waitMs = retryDelayMs(attempt, _delay);
    Timer(Duration(milliseconds: waitMs), () {
      _client.fetch(options).then<void>(
        (response) {
          _log(recoveredTag, err, attempt, dns);
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

  void _log(String tag, DioException err, int attempt, bool dns) {
    try {
      log?.call(tag, <String, Object?>{
        'host': err.requestOptions.uri.host,
        'method': err.requestOptions.method,
        'attempt': attempt,
        'max': _count,
        'dns': dns,
        'dioType': err.type.name,
        'errorMsg': _short(err),
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
        onDnsReset: onDnsReset,
        log: log,
        retryTag: retryTag,
        recoveredTag: recoveredTag,
      );
}

// edit from package:dio_cookie_manager
import 'dart:io';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/retry_interceptor.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/pages/douyin/diag_probe.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/api_type.dart';
import 'package:PiliPlus/utils/app_sign.dart';
import 'package:PiliPlus/utils/extension/string_ext.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

final _setCookieReg = RegExp('(?<=)(,)(?=[^;]+?=)');

/// 用户可见的失败类别：
/// - [network] 真·网络断（没拿到任何响应），可以原地重试；
/// - [risk] 签名 / 风控拒绝（-352、403、412），重试前需要换 key，交给 wbi；
/// - [expired] 取流 CDN 地址过期（媒体流 403/404/410），要重新取 playurl；
/// - [other] 普通业务错误，保持原来的提示；
/// - [silent] 主动取消，不打扰用户。
enum _ErrKind { network, risk, expired, other, silent }

class AccountManager extends Interceptor {
  AccountManager();

  static String blockServer = Pref.blockServer;

  /// 同一页面多个请求会同时失败，8 秒内同类只提示一次。
  static const int _toastDedupeMs = 8000;
  static int _lastToastAtMs = 0;
  static _ErrKind? _lastToastKind;

  static String getCookies(List<Cookie> cookies) {
    // Sort cookies by path (longer path first).
    cookies.sort((a, b) {
      if (a.path == null && b.path == null) {
        return 0;
      } else if (a.path == null) {
        return -1;
      } else if (b.path == null) {
        return 1;
      } else {
        return b.path!.length.compareTo(a.path!.length);
      }
    });
    return cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');
  }

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final path = options.path;

    final account = _bindRequestAccount(options);

    if (account is NoAccount || _skipCookie(path)) return handler.next(options);

    if (!account.isLogin && path == Api.heartBeat) {
      return handler.reject(
        DioException.requestCancelled(requestOptions: options, reason: null),
        false,
      );
    }

    final isApp = path.startsWith(HttpString.appBaseUrl);

    if (isApp && options.responseType == ResponseType.bytes) {
      options.headers.addAll(account.grpcHeaders);
      return handler.next(options);
    }

    options.headers
      ..addAll(account.headers)
      ..['referer'] ??= HttpString.baseUrl;

    // app端不需要管理cookie
    if (isApp) {
      // if (kDebugMode) debugPrint('is app: ${options.path}');
      final dataPtr = (options.method == 'POST' && options.data is Map
          ? (options.data as Map).cast<String, dynamic>()
          : options.queryParameters);
      if (dataPtr.isNotEmpty) {
        if (!account.accessKey.isNullOrEmpty) {
          dataPtr['access_key'] = account.accessKey!;
        }
        AppSign.appSign(dataPtr..remove('sign'));
        // if (kDebugMode) debugPrint(dataPtr.toString());
      }
      return handler.next(options);
    } else {
      account.cookieJar
          .loadForRequest(options.uri)
          .then((cookies) {
            final previousCookies =
                options.headers[HttpHeaders.cookieHeader] as String?;
            final newCookies = getCookies([
              ...?previousCookies
                  ?.split(';')
                  .where((e) => e.isNotEmpty)
                  .map(Cookie.fromSetCookieValue),
              ...cookies,
            ]);
            options.headers[HttpHeaders.cookieHeader] = newCookies.isNotEmpty
                ? newCookies
                : '';
            handler.next(options);
          })
          .catchError((Object e, StackTrace s) {
            final err = DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            );
            handler.reject(err, true);
          });
    }
  }

  @override
  void onResponse(Response response, ResponseInterceptorHandler handler) {
    if (_boundRequestAccount(response.requestOptions) case final account?) {
      final future = _saveCookies(
        account,
        response,
      ).whenComplete(() => handler.next(response));
      assert(() {
        future.catchError(
          (Object e, StackTrace s) {
            throw DioException(
              requestOptions: response.requestOptions,
              error: e,
              stackTrace: s,
            );
          },
        );
        return true;
      }());
    } else {
      return handler.next(response);
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final options = err.requestOptions;
    if (options.responseType == ResponseType.stream) {
      return handler.next(err);
    }

    if (options.method != 'POST') toast(err);

    if (err.response case final res?) {
      if (_boundRequestAccount(options) case final account?) {
        _saveCookies(account, res).then(
          (_) => handler.next(err),
          onError: (Object e, StackTrace s) => handler.next(
            DioException(
              requestOptions: options,
              error: e,
              stackTrace: s,
            ),
          ),
        );
        return;
      }
    }
    return handler.next(err);
  }

  static void toast(DioException err) {
    const skipShow = [
      'heartbeat',
      'history/report',
      'roomEntryAction',
      'seg.so',
      'online/total',
      'github',
      'hdslb.com',
      'biliimg.com',
      'site/getCoin',
    ];
    String url = err.requestOptions.uri.toString();
    if (kDebugMode) debugPrint('🌹🌹ApiInterceptor: $url\n$err');
    if (skipShow.any(url.contains) ||
        (url.contains('skipSegments') && err.requestOptions.method == 'GET')) {
      return;
    }

    final kind = _classify(err);
    if (kind == _ErrKind.silent) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      // 只有「一个字节都没收到」的失败才补原始 error 文本；HTTP 4xx/5xx
      // 的 net-fail 已由 init.dart 的传输层记录，不再重复一条。
      if (err.response == null) _logNetFail(err, kind);
      DiagProbe.log('net-toast', <String, Object?>{
        'kind': kind.name,
        'host': err.requestOptions.uri.host,
        'path': err.requestOptions.uri.path,
        'method': err.requestOptions.method,
        'dioType': err.type.name,
        'statusCode': err.response?.statusCode,
        'code': _apiCode(err),
      });
    } catch (_) {
      // 诊断永远不能影响提示本身。
    }
    if (kind == _lastToastKind && now - _lastToastAtMs < _toastDedupeMs) {
      return;
    }
    _lastToastKind = kind;
    _lastToastAtMs = now;

    switch (kind) {
      case _ErrKind.network:
        _showNetworkDown(err);
      case _ErrKind.risk:
        final code = _apiCode(err) ?? err.response?.statusCode;
        SmartDialog.showToast(
          code == null
              ? '签名或风控校验失败，请稍后重试'
              : '签名或风控校验失败（$code），请稍后重试',
        );
      case _ErrKind.expired:
        SmartDialog.showToast('视频取流地址已过期，正在重新获取');
      case _ErrKind.other:
        // 不再把整条请求 url 拼进提示：又长又没有可读价值。
        dioError(err).then(SmartDialog.showToast);
      case _ErrKind.silent:
        break;
    }
  }

  /// 补一条用户提示层的 `net-fail`：带原始 `DioException.error` 文本和
  /// 不含 query 的完整 uri。传输层的 `net-fail`（init.dart）已有
  /// host/path/errorMsg 以及 rebuilt / transport，但拿不到 error 原文，
  /// 这里用 `stage: toast` 与它区分。
  static void _logNetFail(DioException err, _ErrKind kind) {
    final options = err.requestOptions;
    final uri = options.uri;
    DiagProbe.log('net-fail', <String, Object?>{
      'stage': 'toast',
      'kind': kind.name,
      'uri': _safeUri(uri),
      'host': uri.host,
      'path': uri.path.isEmpty ? options.path.split('?').first : uri.path,
      'method': options.method,
      'statusCode': err.response?.statusCode,
      'dioType': err.type.name,
      'errorMsg': _safeErrText(err.message),
      'rawError': _safeRawError(err),
      'rebuilt': options.extra[kNetRebuiltExtra] == true,
      'transport': options.extra[kNetTransportExtra] ?? Request.transportPath,
      'generation':
          options.extra[kNetGenerationExtra] ?? Request.poolGeneration,
    });
  }

  /// 只保留 scheme://host/path：query 里有 access_key、SESSDATA 等。
  static String _safeUri(Uri uri) =>
      '${uri.scheme}://${uri.host}${uri.path.isEmpty ? '/' : uri.path}';

  static String? _safeRawError(DioException err) {
    final raw = err.error?.toString();
    if (raw == null || raw.isEmpty) return null;
    final uri = err.requestOptions.uri;
    return _safeErrText(raw.replaceAll(uri.toString(), _safeUri(uri)));
  }

  static String? _safeErrText(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    var text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    final q = text.indexOf('?');
    if (q >= 0) text = text.substring(0, q);
    return text.length > 300 ? '${text.substring(0, 300)}…' : text;
  }

  /// 真·网络断：给用户一个能重发这次请求的按钮。
  static void _showNetworkDown(DioException err) {
    SmartDialog.show(
      animationType: SmartAnimationType.centerFade_otherSlide,
      builder: (context) => AlertDialog(
        title: const Text('网络连接中断'),
        content: const Text('没有收到服务器响应，请检查网络设置后重试。'),
        actions: [
          const TextButton(
            onPressed: SmartDialog.dismiss,
            child: Text('取消'),
          ),
          TextButton(
            onPressed: () {
              SmartDialog.dismiss();
              _retryRequest(err.requestOptions);
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  static Future<void> _retryRequest(RequestOptions options) async {
    // 用户主动重试：清掉上一次自动重试的计数，让这次从新的尝试开始。
    options.extra.remove('_rt');
    try {
      await Request.dio.fetch(options);
      SmartDialog.showToast('网络已恢复');
    } on DioException catch (e) {
      // 这次失败是用户主动触发的，不受上一条提示的去重窗口影响。
      _lastToastKind = null;
      toast(e);
    } catch (_) {
      // 取消失败等非 Dio 异常：不额外打扰。
    }
  }

  static _ErrKind _classify(DioException err) {
    if (err.type == DioExceptionType.cancel) return _ErrKind.silent;
    final res = err.response;
    if (res == null) {
      return _isNetworkDown(err) ? _ErrKind.network : _ErrKind.other;
    }
    final status = res.statusCode;
    if (_isExpiredStream(err, status)) return _ErrKind.expired;
    final code = _apiCode(err);
    if (status == 412 ||
        status == 403 ||
        code == -352 ||
        code == -403 ||
        code == -412 ||
        code == 403 ||
        code == 412) {
      return _ErrKind.risk;
    }
    return _ErrKind.other;
  }

  /// 没拿到响应、且属于连接级失败。复用 RetryInterceptor 的判定，
  /// 保证「该重试」和「提示可重试」是同一套标准。
  static bool _isNetworkDown(DioException err) {
    if (err.response != null) return false;
    if (isRetryableNetError(err)) return true;
    // 响应超时同样是一个字节都没收到，不是签名/风控问题。
    return err.type == DioExceptionType.receiveTimeout;
  }

  /// 取流 CDN 地址过期：403/404/410，且请求的是媒体流或 CDN 域名。
  /// 普通 API 的 403 属于风控，重取地址没有意义，故意排除。
  static bool _isExpiredStream(DioException err, int? status) {
    if (status != 403 && status != 404 && status != 410) return false;
    final options = err.requestOptions;
    if (options.responseType == ResponseType.stream) return true;
    final host = options.uri.host;
    return host.contains('bilivideo') ||
        host.contains('akamai') ||
        host.contains('mcdn') ||
        host.contains('szbdyd');
  }

  static int? _apiCode(DioException err) {
    final data = err.response?.data;
    if (data is Map) {
      final code = data['code'];
      if (code is num) return code.toInt();
      if (code is String) return int.tryParse(code);
    }
    return null;
  }

  static Future<void> _saveCookies(Account account, Response response) async {
    final setCookies = response.headers[HttpHeaders.setCookieHeader];
    if (setCookies == null || setCookies.isEmpty) {
      return;
    }
    final List<Cookie> cookies = setCookies
        .map((str) => str.split(_setCookieReg))
        .expand((cookie) => cookie)
        .where((cookie) => cookie.isNotEmpty)
        .map(Cookie.fromSetCookieValue)
        .toList();
    final statusCode = response.statusCode ?? 0;
    final locations = response.headers[HttpHeaders.locationHeader] ?? const [];
    final isRedirectRequest = statusCode >= 300 && statusCode < 400;
    final originalUri = response.requestOptions.uri;
    final realUri = originalUri.resolveUri(response.realUri);
    await account.cookieJar.saveFromResponse(realUri, cookies);
    if (isRedirectRequest && locations.isNotEmpty) {
      final originalUri = response.realUri;
      await Future.wait(
        locations.map(
          (location) => account.cookieJar.saveFromResponse(
            // Resolves the location based on the current Uri.
            originalUri.resolve(location),
            cookies,
          ),
        ),
      );
    }
    await account.onChange();
  }

  static bool _skipCookie(String path) {
    return path.startsWith(blockServer) ||
        path.contains('hdslb.com') ||
        path.contains('biliimg.com');
  }

  static Account _findAccount(String path) => ApiType.loginApi.contains(path)
      ? AnonymousAccount()
      : Accounts.get(
          AccountType.values.firstWhere(
            (i) => ApiType.apiTypeSet[i]?.contains(path) == true,
            orElse: () => AccountType.main,
          ),
        );

  static Account _bindRequestAccount(RequestOptions options) {
    assert(options.extra['account'] is Account?);
    return options.extra['account'] ??= _findAccount(options.path);
  }

  static Account? _boundRequestAccount(RequestOptions options) {
    final path = options.path;
    final account = options.extra['account'] as Account;
    if (account is NoAccount ||
        path.startsWith(HttpString.appBaseUrl) ||
        _skipCookie(path)) {
      return null;
    }
    return account;
  }

  static Future<String> dioError(DioException error) async {
    switch (_classify(error)) {
      case _ErrKind.network:
        return '网络连接中断，请检查网络设置后重试';
      case _ErrKind.risk:
        return '签名或风控校验失败，请稍后重试';
      case _ErrKind.expired:
        return '视频取流地址已过期，正在重新获取';
      case _ErrKind.silent:
        return '请求已取消';
      case _ErrKind.other:
        break;
    }
    switch (error.type) {
      case .badCertificate:
        return '证书有误！';
      case .badResponse:
        return '服务器异常，请稍后重试！';
      case .cancel:
        return '请求已被取消，请重新请求';
      case .connectionError:
        return '连接错误，请检查网络设置';
      case .connectionTimeout:
        return '网络连接超时，请检查网络设置';
      case .receiveTimeout:
        return '响应超时，请稍后重试！';
      case .sendTimeout:
        return '发送请求超时，请检查网络设置';
      case .transformTimeout:
        return '转换响应数据超时！';
      case .unknown:
        String desc;
        try {
          desc = PlatformUtils.isMobile
              ? (await Connectivity().checkConnectivity()).first.desc
              : '';
        } catch (_) {
          desc = '';
        }
        return '$desc网络异常 ${error.error}';
    }
  }
}

extension _ConnectivityResultExt on ConnectivityResult {
  String get desc => const ['蓝牙', 'Wi-Fi', '局域', '流量', '无', '代理', '其他'][index];
}

// Wbi签名 用于生成 REST API 请求中的 w_rid 和 wts 字段
// https://github.com/SocialSisterYi/bilibili-API-collect/blob/master/docs/misc/sign/wbi.md
// import md5 from 'md5'
// import axios from 'axios'
import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/pages/douyin/diag_probe.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:hive_ce/hive.dart';

abstract final class WbiSign {
  static Box get _localCache => GStorage.localCache;
  static final RegExp _chrFilter = RegExp(r"[!\'\(\)\*]");
  static const _mixinKeyEncTab = <int>[
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];

  static Future<String>? _future;

  // invalidateKeys 会递增代际号；在途请求完成时若代际已变，只把 key 返回给
  // 调用方、不写缓存，避免旧请求把强制刷新后的新 key 覆盖回去。
  static int _generation = 0;

  // B 站会轮换 wbi 密钥，按自然日缓存会把过期 key 一直用到跨天。
  // 25 分钟刷新一次：不会频繁打 userInfo，也不会长期用过期 key 签名。
  static const Duration _keyTtl = Duration(minutes: 25);

  // 并发多个 -352 时不要各自打一次 userInfo：取键请求起飞 5 秒内再要求强制
  // 刷新，直接复用这次在途请求（它拿到的必然是轮换后的新 key）。
  static const Duration _invalidateReuse = Duration(seconds: 5);
  static int _lastFetchAtMs = 0;

  // 对 imgKey 和 subKey 进行字符顺序打乱编码
  static String getMixinKey(String orig) {
    return String.fromCharCodes(_mixinKeyEncTab.map(orig.codeUnitAt));
  }

  // 为请求参数进行 wbi 签名
  static void encWbi(Map<String, Object> params, String mixinKey) {
    params['wts'] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 按照 key 重排参数
    final List<String> keys = params.keys.toList()..sort();
    final queryStr = keys
        .map(
          (i) =>
              '${Uri.encodeComponent(i)}=${Uri.encodeComponent(params[i].toString().replaceAll(_chrFilter, ''))}',
        )
        .join('&');
    params['w_rid'] = md5
        .convert(utf8.encode(queryStr + mixinKey))
        .toString(); // 计算 w_rid
  }

  static Future<String> _getWbiKeys(int generation, int startedAtMs) async {
    try {
      final resp = await Request().get(Api.userInfo);
      final data = resp.data;
      final userData = data is Map ? data['data'] : null;
      final wbiUrls = userData is Map ? userData['wbi_img'] : null;
      final imgUrl = wbiUrls is Map ? wbiUrls['img_url'] : null;
      final subUrl = wbiUrls is Map ? wbiUrls['sub_url'] : null;
      if (imgUrl is! String || subUrl is! String) {
        throw const FormatException('wbi: wbi_img missing');
      }
      final mixinKey = getMixinKey(
        Utils.getFileName(imgUrl, fileExt: false) +
            Utils.getFileName(subUrl, fileExt: false),
      );
      if (mixinKey.isEmpty) {
        throw const FormatException('wbi: empty mixin key');
      }
      // 只有取到有效 key 才写缓存。旧实现先写时间戳再取 key，取键失败后
      // 缓存里会留下过期/空 key，签名会一直失败到跨天或重启。
      final stale = generation != _generation;
      if (!stale) {
        await _localCache.put(LocalCacheKey.mixinKey, mixinKey);
        await _localCache.put(LocalCacheKey.timeStamp, startedAtMs);
      }
      DiagProbe.log('wbi-keys', <String, Object?>{
        'ok': true,
        'source': 'fetch',
        'keyLen': mixinKey.length,
        'stale': stale,
        'ms': DateTime.now().millisecondsSinceEpoch - startedAtMs,
      });
      return mixinKey;
    } catch (e) {
      DiagProbe.log('wbi-keys', <String, Object?>{
        'ok': false,
        'source': 'fetch',
        'error': e.toString(),
      });
      // 失败必须把缓存清空：空 key 一旦留在 mixinKey/timeStamp 里，
      // 后续请求会继续用坏 key 签名。代际已变则说明有更新的请求在跑，
      // 不要清掉它可能刚写入的结果。
      if (generation == _generation) {
        try {
          await _localCache.delete(LocalCacheKey.mixinKey);
          await _localCache.put(LocalCacheKey.timeStamp, 0);
        } catch (e) {
          DiagProbe.log('wbi-keys', <String, Object?>{
            'ok': false,
            'source': 'cache-clear',
            'error': e.toString(),
          });
        }
      }
      rethrow;
    }
  }

  static Future<String> _startFetch(
    int startedAtMs, {
    bool clearTimestamp = false,
  }) {
    final generation = _generation;
    _lastFetchAtMs = startedAtMs;
    // 注意：这里到 _future 赋值之间不能有 await，否则并发调用会看到
    // _future == null 又各自发起一次取键。
    final future = clearTimestamp
        ? _resetAndFetch(generation, startedAtMs)
        : _getWbiKeys(generation, startedAtMs);
    _future = future;
    // 无论成功失败都要释放 _future；失败后若继续留着它，后续签名会反复
    // 复用同一个已拒绝的 Future，直到重启或跨天才恢复。
    unawaited(
      future.then<void>(
        (_) => _releaseFuture(future, null),
        onError: (Object e, StackTrace _) => _releaseFuture(future, e),
      ),
    );
    return future;
  }

  /// 先把缓存时间戳清零（旧 key 立即失效），再重新取键。
  static Future<String> _resetAndFetch(int generation, int startedAtMs) async {
    try {
      // 时间戳清零即可让旧 key 失效，不必把空串写回 mixinKey。
      await _localCache.put(LocalCacheKey.timeStamp, 0);
    } catch (e) {
      DiagProbe.log('wbi-keys', <String, Object?>{
        'ok': false,
        'source': 'cache-clear',
        'error': e.toString(),
      });
    }
    return _getWbiKeys(generation, startedAtMs);
  }

  static void _releaseFuture(Future<String> future, Object? error) {
    if (!identical(_future, future)) return;
    _future = null;
    DiagProbe.log('wbi-keys', <String, Object?>{
      'ok': error == null,
      'source': 'release',
      if (error != null) 'error': error.toString(),
    });
  }

  static FutureOr<String> getWbiKeys() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final rawTs = _localCache.get(LocalCacheKey.timeStamp, defaultValue: 0);
    final cachedAt = rawTs is int ? rawTs : 0;
    final rawKey = _localCache.get(LocalCacheKey.mixinKey);
    final cachedKey = rawKey is String && rawKey.isNotEmpty ? rawKey : null;
    final ageMs = cachedAt > 0 ? nowMs - cachedAt : null;
    if (cachedKey != null &&
        ageMs != null &&
        ageMs >= 0 &&
        ageMs < _keyTtl.inMilliseconds) {
      return cachedKey;
    }

    final inflight = _future;
    if (inflight != null) return inflight;

    final String reason;
    if (cachedKey == null) {
      reason = 'missing-key';
    } else if (ageMs == null) {
      reason = 'no-timestamp';
    } else if (ageMs < 0) {
      reason = 'clock-skew';
    } else {
      reason = 'expired';
    }
    DiagProbe.log('wbi-keys', <String, Object?>{
      'ok': true,
      'source': 'refresh',
      'reason': reason,
      'ageMs': ageMs,
    });
    return _startFetch(nowMs);
  }

  /// 强制丢弃当前 key 并立刻重新取一次。
  /// 上层在签名接口返回 -352 / -403 / 风控 412 时调用一次，再重签重试。
  static Future<String> invalidateKeys() async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final inflight = _future;
    if (inflight != null &&
        nowMs - _lastFetchAtMs < _invalidateReuse.inMilliseconds) {
      DiagProbe.log('wbi-keys', <String, Object?>{
        'ok': true,
        'source': 'invalidate',
        'reuse': true,
        'ageMs': nowMs - _lastFetchAtMs,
      });
      return inflight;
    }
    _generation++;
    DiagProbe.log('wbi-keys', <String, Object?>{
      'ok': true,
      'source': 'invalidate',
      'reuse': false,
    });
    return _startFetch(nowMs, clearTimestamp: true);
  }

  static Future<Map<String, Object>> makSign(
    Map<String, Object> params,
  ) async {
    // params 为需要加密的请求参数
    String? mixinKey;
    try {
      mixinKey = await getWbiKeys();
    } catch (_) {
      mixinKey = null;
    }
    if (mixinKey == null || mixinKey.isEmpty) {
      // 取键失败不在这里连环重取（否则断网时会双倍打 userInfo）；
      // _future 已在失败时释放，下次调用会重新取键。
      // 退回未签名参数，绝不用空 key 生成必然被服务端拒绝的假 w_rid。
      DiagProbe.log('wbi-keys', <String, Object?>{
        'ok': false,
        'source': 'skip-sign',
      });
      return params;
    }
    encWbi(params, mixinKey);
    return params;
  }

  static bool _isSignRejected(Response<dynamic> resp) {
    // Request().get 会把 DioException 吞成 Response，风控 412/403 只剩
    // statusCode 可判（data 里只有 message，没有 code），必须一起看。
    // 连接错误是 statusCode -1 + code -1，不能当成签名被拒。
    final status = resp.statusCode;
    if (status == 412 || status == 403) return true;
    final data = resp.data;
    final code = data is Map ? data['code'] : null;
    return code == -352 || code == -403;
  }

  static Future<bool> _refreshKeys() async {
    try {
      await invalidateKeys();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 用已签名参数发请求；返回 -352/-403 或 HTTP 412（风控）时强制换 key
  /// 重签一次再发一次，只重试一次，避免风控下反复打取键接口。
  static Future<Response<dynamic>> sendSigned(
    Map<String, Object> signedParams,
    Future<Response<dynamic>> Function(Map<String, Object> signed) send,
  ) async {
    final resp = await send(signedParams);
    if (!_isSignRejected(resp)) return resp;
    // 换 key 失败就原样交回被拒的响应，不掩盖真实错误。
    if (!await _refreshKeys()) return resp;
    // 重签前必须剔除上一次的 w_rid/wts：encWbi 会把 w_rid 一起排序进
    // 待签串，而服务端校验时会剔除 w_rid，第二次签名必然不匹配。
    final base = Map<String, Object>.from(signedParams)
      ..remove('w_rid')
      ..remove('wts');
    final resigned = await makSign(base);
    // 重取 key 也没成功时不发一次注定被拒的未签名请求，直接交回原响应。
    if (!resigned.containsKey('w_rid')) return resp;
    return send(resigned);
  }
}

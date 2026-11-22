import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:PiliPlus/pages/douyin/diag_probe.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 根因扫描器（Dart 侧）。
///
/// 用户多次报「播放页整页点不动、返回不了、起播很慢」，而每次读代码改完
/// 装上都没变化。说明靠读代码猜根因是不可靠的。这里把能测的全测一遍，
/// 一次写成 `Documents/rootscan.json`，避免一轮只验证一个猜测。
///
/// 采集分两部分：
///   * 原生（PiliRootScan）：视图层级、命中测试、帧率、主线程阻塞
///   * Dart（这里）：播放器状态、texture、通道可用性、路由栈、事件响应
///
/// 永不抛异常：任何一项失败就记 `error`，其它项照常采。
abstract final class PiliRootScan {
  static const MethodChannel _channel = MethodChannel('piliplus/rootscan');

  /// 扫描结果文件名。用户从「文件」App 里能直接找到。
  static const String fileName = 'rootscan.json';

  /// 最近一次扫描结果，界面直接读它展示。
  static Map<String, Object?>? _lastReport;
  static Map<String, Object?>? get lastReport => _lastReport;

  /// 跑一次完整扫描并落盘，返回文件路径（失败返回 null）。
  ///
  /// [seconds] 是帧率采样时长。默认 3 秒，足够看出掉帧与主线程阻塞。
  static Future<String?> run({double seconds = 3.0}) async {
    final report = <String, Object?>{};
    report['schema'] = 1;
    report['at'] = DateTime.now().toIso8601String();
    // 用户装了哪一版、画面到底走没走硬件解码：版本号与 mpv 解码指标必须
    // 和扫描结果落在同一份 JSON 里，否则拿到日志也无法确认现象对应哪一版。
    // appInfo 读原生 mainBundle（通道缺失时回落到 package_info_plus）。
    report['app'] = await DiagProbe.appInfo();

    // 一、原生层
    try {
      final points = <Map<String, Object?>>[
        // 返回按钮大致位置：左上角
        {'label': 'back_button', 'x': 24.0, 'y': 60.0},
        // 屏幕正中（视频区）
        {'label': 'center', 'x': _screenW / 2, 'y': _screenH / 2},
        // 底部控件条
        {'label': 'bottom_bar', 'x': _screenW / 2, 'y': _screenH - 60},
      ];
      final native = await _channel
          .invokeMapMethod<String, Object?>('scan', {
            'seconds': seconds,
            'points': points,
          })
          .timeout(Duration(seconds: (seconds + 8).toInt()));
      report['native'] = native;
    } catch (error) {
      report['native'] = {'error': '$error'};
    }

    // 二、解码指标：放在 3 秒原生采样之后读，播放器此时通常已起播，
    // 才拿得到真实的 hwdec / 分辨率 / 丢帧数。
    report['mpv'] = DiagProbe.snapshot();

    // 三、Dart 层
    report['dart'] = await _dartSnapshot();

    report['verdict'] = _verdict(report);
    _lastReport = report;

    // 四、落盘：多个位置都写一份，哪个能拿到用哪个
    //
    // 在 LiveContainer + SideStore 里跑时，App 的 Documents 既不出现在系统
    // 「文件」App 里，容器路径也随 LC 的目录结构走，用户很难自己翻到。
    // 所以这里同时写到两处，并把路径回传给调用方，由界面直接显示给用户看。
    final paths = <String>[];
    final json = const JsonEncoder.withIndent('  ').convert(report);

    for (final dir in await _candidateDirs()) {
      try {
        final file = File('${dir.path}/$fileName');
        await file.writeAsString(json, flush: true);
        paths.add(file.path);
      } catch (_) {}
    }

    report['writtenTo'] = paths;
    return paths.isEmpty ? null : paths.first;
  }

  /// 依次尝试的落盘目录。
  ///
  /// - Documents：常规安装在这里，Filza 能进
  /// - 应用支持目录：LC 里通常也可写，而且和沙盒同源
  /// - 临时目录：最后兜底，至少文件存在
  static Future<List<Directory>> _candidateDirs() async {
    final out = <Directory>[];
    try {
      out.add(await getApplicationDocumentsDirectory());
    } catch (_) {}
    try {
      out.add(await getApplicationSupportDirectory());
    } catch (_) {}
    try {
      out.add(Directory.systemTemp);
    } catch (_) {}
    return out;
  }

  /// 读取上一次扫描的结果，给界面直接展示用。
  ///
  /// 用户在 LC 里拿不到文件时，可以在这里复制全文，或者截屏发出来。
  static Future<String?> readLast() async {
    for (final dir in await _candidateDirs()) {
      try {
        final file = File('${dir.path}/$fileName');
        if (await file.exists()) return await file.readAsString();
      } catch (_) {}
    }
    return null;
  }

  static double get _screenW {
    try {
      return PlatformDispatcher.instance.views.first.physicalSize.width /
          PlatformDispatcher.instance.views.first.devicePixelRatio;
    } catch (_) {
      return 375;
    }
  }

  static double get _screenH {
    try {
      return PlatformDispatcher.instance.views.first.physicalSize.height /
          PlatformDispatcher.instance.views.first.devicePixelRatio;
    } catch (_) {
      return 667;
    }
  }

  /// Dart 侧能测到的东西：播放器单例状态、通道、路由栈。
  ///
  /// 重点看 `player`：如果 `hasInstance` 是 true 但 `textureId` 为 null，
  /// 说明播放器实例在、画面没挂上——这就是「有声音没画面」的机制。
  static Future<Map<String, Object?>> _dartSnapshot() async {
    final out = <String, Object?>{};

    // 播放器单例
    try {
      final player = PlPlayerController.instance;
      if (player == null) {
        out['player'] = {'hasInstance': false};
      } else {
        final videoController = player.videoController;
        out['player'] = {
          'hasInstance': true,
          'hasVideoController': videoController != null,
          'textureId': videoController?.id.value,
          'positionMs': player.positionInMilliseconds,
          'durationMs': player.durationInMilliseconds,
          'isPlaying': player.playerStatus.isPlaying,
          'isBuffering': player.isBuffering.value,
          'dataStatus': player.dataStatus.value.name,
        };
      }
    } catch (error) {
      out['player'] = {'error': '$error'};
    }

    // 原生通道是否真的存在——缺失会表现为「点了没反应」
    out['channels'] = {
      'shortvideo_web': await _probeShortVideoWeb(),
      'rootscan': true,
    };

    return out;
  }

  /// 探 `piliplus/shortvideo_web` 在不在。
  ///
  /// `deviceMemory` 是它上面一个只读、无副作用的方法。能调用成功说明通道
  /// 已注册；`MissingPluginException` 说明这个原生实现根本没编进包里——
  /// 那 Dart 侧所有网页登录 / 直链解析 / 下载都会静默失败。
  static Future<bool> _probeShortVideoWeb() async {
    try {
      await const MethodChannel(
        'piliplus/shortvideo_web',
      ).invokeMethod<int>('deviceMemory').timeout(const Duration(seconds: 1));
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      // 通道存在但这次调用出了别的问题，也算通道在
      return true;
    }
  }

  /// 把关键信号压成几句人话，省得每次都翻 JSON。
  static List<String> _verdict(Map<String, Object?> report) {
    final issues = <String>[];

    final native = report['native'];
    if (native is Map) {
      final thread = native['mainThread'];
      if (thread is Map && thread['blocked'] == true) {
        issues.add(
          '主线程被阻塞 ${thread['dispatchDelayMs']}ms —— '
          '这个状态下点任何按钮都不会有反应',
        );
      }
      final frames = native['frames'];
      if (frames is Map && frames['verdict'] == 'janky') {
        issues.add(
          '实测掉帧：均值 ${frames['meanMs']}ms/帧，'
          '最差 ${frames['worstMs']}ms',
        );
      }
      final hits = native['hitTests'];
      if (hits is List) {
        for (final hit in hits) {
          if (hit is! Map) continue;
          final top = '${hit['topmost']}';
          if (hit['label'] == 'back_button' && !top.contains('Flutter')) {
            issues.add('返回按钮位置命中的是 $top，不是 Flutter 视图');
          }
        }
      }
    }

    final dart = report['dart'];
    if (dart is Map) {
      final player = dart['player'];
      if (player is Map) {
        if (player['hasVideoController'] == false) {
          issues.add('播放器没有 videoController —— 画面出不来');
        }
        final texture = player['textureId'];
        if (texture == null) {
          issues.add('textureId 为空 —— 视频轨没有挂上渲染');
        }
      }
    }

    if (issues.isEmpty) {
      issues.add('本次扫描未发现明显异常，需要结合完整 JSON 判断');
    }
    return issues;
  }
}
// TESTMARK

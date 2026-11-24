import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// Picture-in-Picture on iOS, implemented in `ios/Runner/PipPlugin.swift`.
abstract final class IOSPipHelper {
  static const _channel = MethodChannel('com.example.piliplus/pip');

  static bool isAvailable = false;

  /// Whether the PiP window is shown or about to be shown.
  static bool isActive = false;

  static bool _autoEnter = false;

  /// 自动画中画真正进入时回调，只用于 Dart 侧写诊断日志。
  static void Function()? onAutoEnter;

  /// Whether the native side needs playback state updates.
  static bool get needsUpdate => isActive || _autoEnter;

  static Future<void> init() async {
    _channel.setMethodCallHandler(_onMethodCall);
    try {
      isAvailable = await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('IOSPipHelper init: $e');
    }
  }

  static Future<void> _onMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onStateChanged':
        final args = call.arguments as Map;
        final wasActive = isActive;
        isActive = args['active'] as bool;
        if (!wasActive && isActive && _autoEnter) {
          onAutoEnter?.call();
        }
        final isResumed =
            WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
        if (args['error'] != null && isResumed) {
          SmartDialog.showToast('画中画启动失败');
        }
        // Closing the PiP window in background stops playback, as on Android.
        if (args['closed'] == true && !isResumed) {
          if (PlPlayerController.instance case final ctr?
              when !ctr.continuePlayInBackground.value) {
            PlPlayerController.pauseIfExists();
          }
        }
      case 'setPlaying':
        unawaited(_setPlaying(call.arguments as bool));
      case 'skip':
        final args = call.arguments;
        int deltaMs = 0;
        int? targetMs;
        if (args is Map) {
          deltaMs = (args['delta'] as num?)?.toInt() ?? 0;
          targetMs = (args['target'] as num?)?.toInt();
        } else if (args is num) {
          deltaMs = args.toInt();
        }
        unawaited(_seek(deltaMs, targetMs));
    }
  }

  /// PiP 的暂停/恢复必须落到当前播放器实例上。抖音播放页没有注册
  /// `PlPlayerController.playIfExists()` 使用的播放回调，只走回调会导致
  /// 暂停后无法恢复；回调为空或指向已重建的旧实例时退到实例 play/pause。
  static Future<void> _setPlaying(bool playing) async {
    final ctr = PlPlayerController.instance;
    if (playing) {
      // B 站视频页/直播页注册的回调优先，保留原有副作用。
      try {
        await (PlPlayerController.playIfExists() ?? Future<void>.value());
      } catch (e) {
        if (kDebugMode) debugPrint('PiP play callback failed: $e');
      }
      // 抖音页没有注册回调，或回调指向已重建的旧实例；以当前实例是否
      // 真的在播为准兜底，否则暂停后点开始会一直停在暂停。
      if (ctr != null && !ctr.playerStatus.isPlaying) {
        try {
          await ctr.play(hideControls: false);
        } catch (e) {
          if (kDebugMode) debugPrint('PiP resume failed: $e');
        }
      }
    } else {
      try {
        final pause = ctr != null
            ? ctr.pause()
            : PlPlayerController.pauseIfExists();
        await (pause ?? Future<void>.value());
      } catch (e) {
        if (kDebugMode) debugPrint('PiP pause failed: $e');
      }
    }
  }

  /// 原生已经算好目标位置；旧版本事件只带 delta，继续兼容。
  static Future<void> _seek(int deltaMs, int? targetMs) async {
    final ctr = PlPlayerController.instance;
    if (ctr == null) return;
    final target = targetMs != null
        ? Duration(milliseconds: targetMs)
        : Duration(milliseconds: ctr.positionInMilliseconds + deltaMs);
    await ctr.seekTo(target);
  }

  /// Enters PiP, or arms entering it automatically when the app goes to
  /// background if [autoEnter] is `true`.
  static void enter(
    int textureId, {
    required int? width,
    required int? height,
    required bool autoEnter,
    required Map<String, Object> state,
  }) {
    if (autoEnter) _autoEnter = true;
    _channel.invokeMethod('enter', {
      'textureId': textureId,
      'width': ?width,
      'height': ?height,
      'autoEnter': autoEnter,
      ...state,
    });
  }

  static void update(Map<String, Object> state) {
    _channel.invokeMethod('update', state);
  }

  static void disableAutoEnter() {
    if (_autoEnter) {
      _autoEnter = false;
      _channel.invokeMethod('disableAutoEnter');
    }
  }

  static void dispose() {
    _autoEnter = false;
    _channel.invokeMethod('dispose');
  }
}

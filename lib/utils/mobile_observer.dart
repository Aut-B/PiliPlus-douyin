import 'dart:async';

import 'package:PiliPlus/pages/douyin/diag_probe.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

/// 挂后台超过这个时长，resume 时标记为「长时间挂后台」。
const int _kLongIdleMs = 5 * 60 * 1000;

bool _lifecycleDiagAttached = false;
final _LifecycleDiagObserver _lifecycleDiagObserver = _LifecycleDiagObserver();

void _ensureLifecycleDiag() {
  if (_lifecycleDiagAttached) return;
  _lifecycleDiagAttached = true;
  WidgetsBinding.instance.addObserver(_lifecycleDiagObserver);
}

/// 全局只读的生命周期取证观察者：只写 diag_playback.log，不参与任何行为决策。
class _LifecycleDiagObserver with WidgetsBindingObserver {
  int _lastResumeAtMs = DateTime.now().millisecondsSinceEpoch;
  int? _backgroundAtMs;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final now = DateTime.now();
    final nowMs = now.millisecondsSinceEpoch;
    final idleMs = state == AppLifecycleState.resumed && _backgroundAtMs != null
        ? nowMs - _backgroundAtMs!
        : null;
    final longIdle = idleMs != null && idleMs >= _kLongIdleMs;
    DiagProbe.log('app-lifecycle', <String, Object?>{
      'state': state.name,
      'msSinceLastResume': nowMs - _lastResumeAtMs,
      'idleMs': idleMs,
      'utc': now.toUtc().toIso8601String(),
      'longIdleResume': longIdle,
    });
    if (state == AppLifecycleState.resumed) {
      _lastResumeAtMs = nowMs;
      _backgroundAtMs = null;
      DiagProbe.noteResume(nowMs, longIdle: longIdle);
    } else {
      _backgroundAtMs ??= nowMs;
    }
    // paused 后 isolate 可能马上被挂起，500ms 批写定时器等不到，立刻落盘。
    unawaited(DiagProbe.flush());
  }
}

void addObserverMobile(WidgetsBindingObserver observer) {
  if (PlatformUtils.isMobile) {
    _ensureLifecycleDiag();
    WidgetsBinding.instance.addObserver(observer);
  }
}

void removeObserverMobile(WidgetsBindingObserver observer) {
  if (PlatformUtils.isMobile) {
    WidgetsBinding.instance.removeObserver(observer);
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/qa_probe.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/repo.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

/// 真机自检。
///
/// 设计原则（都是踩过的坑换来的）：
///
/// * **零操作**：开关只在编译期定，App 启动后自己跑一段；不设任何 UI 按钮。
///   页面卡死时按钮点不动，靠点按钮触发的自检等于不存在。
/// * **配置只认 dart-define**：绝不读手机上的 `pip_qa.json` 之类的残留文件，
///   旧证据每次启动先删掉，runId 每轮新生成，跨轮不会互相污染。
/// * **分段落盘**：每走完一步（含 skip）就整份重写一次并 flush。进程被杀、
///   用户等不住退出时，磁盘上留的是最后一步的现场，而不是空文件。
/// * **绝不卡死**：每步都有超时，整条流程另有总超时；超时也要落盘。
/// * **只观测**：不碰 `player.dart` 的播放逻辑，不碰画中画原生实现。
abstract final class QaSelfCheck {
  /// 编译期开关。默认 false，不传就是完全关闭。
  static const bool enabled = bool.fromEnvironment('PILIPLUS_QA');

  static const int schema = 1;
  static const String fileName = 'pilip_selfcheck.json';

  /// 单步超时。
  static const Duration openTimeout = Duration(seconds: 8);
  static const Duration textureTimeout = Duration(seconds: 12);
  static const Duration backTimeout = Duration(seconds: 5);

  /// 整条流程总超时。到点无论走到哪都落盘并标 aborted。
  static const Duration totalTimeout = Duration(seconds: 45);

  static bool _started = false;

  /// 启动钩子。**开关关闭时必须是无副作用的空操作**：
  /// 不 await、不改启动顺序、不建目录、不订阅任何回调。
  static void schedule() {
    // 第一行就返回，后面一行代码都不执行。
    if (!enabled) return;
    if (_started) return;
    _started = true;
    // 甩到后台：调用方（main）不等它，启动顺序完全不变。
    unawaited(run());
  }

  static Future<void> run() async {
    final runId =
        'selfcheck-${BuildConfig.versionCode}-'
        '${DateTime.now().millisecondsSinceEpoch}';
    final evidence = _Evidence(runId);

    // 先清旧证据，再立刻写一份 running 的空壳：
    // 万一连第一步都没走完就崩了，磁盘上也能分辨是"这一轮跑过"。
    try {
      await evidence.resetOld();
      await evidence.flush(status: 'running');
    } catch (_) {}

    final watchdog = _Watchdog(Duration(milliseconds: totalTimeout.inMilliseconds));

    try {
      await _drive(evidence, watchdog);
    } catch (error, stack) {
      evidence.fail('unhandled', '$error', extra: '$stack');
    } finally {
      watchdog.cancel();
      try {
        await evidence.flush(
          status: watchdog.fired ? 'aborted' : 'done',
        );
      } catch (_) {}
    }
  }

  static Future<void> _drive(_Evidence evidence, _Watchdog watchdog) async {
    // 1. 通道探测：shortvideo_web 在不在。
    final channel = await evidence.step(
      'probe_channel',
      () => QaProbe.probeChannel(),
      watchdog: watchdog,
    );
    evidence.checks['shortvideo_web'] = channel;

    // 2. 取一条本地条目。这里只用收藏缓存，不联网、不开网页登录。
    final queue = _buildQueue();
    if (queue.isEmpty) {
      evidence.skip('open_player', '没有收藏条目，跳过播放流程');
      evidence.skip('wait_texture', '上一步跳过');
      evidence.skip('press_back', '上一步跳过');
      return;
    }
    final index = 0;
    final entry = queue[index];
    evidence.context['queueSize'] = queue.length;
    evidence.context['entryKey'] = entry.key;

    // 3. 打开播放页。导航本身可能是同步抛错，也可能是永远不返回，
    //    所以 fire-and-forget + 轮询判定，绝不 await 导航 future。
    final openWatch = Stopwatch()..start();
    unawaited(() async {
      try {
        await ShortVideoPlayerRouteNavigator.open(
          queue,
          index,
          showImmediately: true,
          replaceCurrent: true,
        );
      } catch (error) {
        evidence.context['openError'] = '$error';
      }
    }());

    final opened = await _waitUntil(
      () => QaProbe.playerPageOnTop,
      openTimeout,
      watchdog: watchdog,
    );
    openWatch.stop();
    evidence.checks['player_page'] = <String, Object?>{
      'opened': opened,
      'elapsedMs': openWatch.elapsedMilliseconds,
      'openError': evidence.context['openError'],
    };
    await evidence.stepDone(
      'open_player',
      opened ? 'ok' : 'fail',
      elapsedMs: openWatch.elapsedMilliseconds,
      detail: opened ? null : '播放页未在 ${openTimeout.inSeconds} 秒内出现在栈顶',
    );

    if (!opened) {
      evidence.skip('wait_texture', '播放页没打开');
      evidence.skip('press_back', '播放页没打开');
      return;
    }

    // 4. 等 texture + 首帧。
    final textureWatch = Stopwatch()..start();
    int? firstFrameMs;
    final gotTexture = await _waitUntil(() {
      final snapshot = QaProbe.playerSnapshot();
      if (snapshot['hasTexture'] != true) return false;
      // 拿到 texture 只是有了画布；再等播放器真的开始走，避免把 0 当首帧。
      return snapshot['positionMs'] is int && (snapshot['positionMs'] as int) > 0;
    }, textureTimeout, watchdog: watchdog);
    textureWatch.stop();
    if (gotTexture) firstFrameMs = textureWatch.elapsedMilliseconds;

    final snapshot = QaProbe.playerSnapshot();
    evidence.checks['texture'] = <String, Object?>{
      'hasVideoController': snapshot['hasTexture'],
      'textureId': snapshot['textureId'],
    };
    evidence.checks['first_frame'] = <String, Object?>{
      'ok': firstFrameMs != null,
      'ms': firstFrameMs,
      'playing': snapshot['playing'],
      'positionMs': snapshot['positionMs'],
    };
    await evidence.stepDone(
      'wait_texture',
      firstFrameMs != null ? 'ok' : 'fail',
      elapsedMs: textureWatch.elapsedMilliseconds,
      detail: firstFrameMs != null
          ? null
          : '${textureTimeout.inSeconds} 秒内没有 texture 或没有起播',
    );

    // 5. 返回。先做一次只读命中测试，再投真实点击；拿不准就报 unknown。
    final back = await _pressBack(watchdog);
    evidence.checks['back'] = back;
    await evidence.stepDone(
      'press_back',
      back['ok'] == true ? 'ok' : 'fail',
      elapsedMs: back['elapsedMs'] as int? ?? 0,
      detail: 'mode=${back['mode']}',
    );

    // 6. 返回之后再读一次通道状态：确认原生通道没被返回动作带崩。
    //    注意：兜底强制回首页后，通道仍应可用——不可用说明是原生侧真出事了。
    final afterBack = await evidence.step(
      'probe_channel_after_back',
      () => QaProbe.probeChannel(),
      watchdog: watchdog,
    );
    evidence.checks['after_back'] = <String, Object?>{
      'channelOk': afterBack['ok'],
      'error': afterBack['error'],
    };
  }

  /// 点返回，并区分结果。
  ///
  /// 三种结论都是「尽力而为」：
  /// * `ok` —— 页面真的退出了，这一定可信；
  /// * `not_hit` / `hit_no_effect` —— 只在证据链完整时才给；
  /// * `unknown` —— 拿不准就报这个，并附原始命中测试结果。
  ///
  /// 宁可说「不确定」，也不要给出看似精确但其实错的归因。
  static Future<Map<String, Object?>> _pressBack(_Watchdog watchdog) async {
    final hitBefore = QaProbe.hitTestAtBackButton();
    final buttons = QaProbe.describeBackButtons();
    final watch = Stopwatch()..start();
    final tapped = QaProbe.tapAtBackButton();
    if (!tapped) {
      watch.stop();
      return <String, Object?>{
        'ok': false,
        'mode': 'unknown',
        'elapsedMs': watch.elapsedMilliseconds,
        'tookEffectAt': null,
        'forcedReset': false,
        'reason': '找不到返回按钮',
        'hitTest': hitBefore,
        'buttons': buttons,
      };
    }

    // 等到页面真的退出，或者超时。
    var tookEffect = false;
    final deadline = DateTime.now().add(backTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!QaProbe.playerPageOnTop) {
        tookEffect = true;
        break;
      }
      if (watchdog.fired) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    watch.stop();

    if (tookEffect) {
      return <String, Object?>{
        'ok': true,
        'mode': 'ok',
        'elapsedMs': watch.elapsedMilliseconds,
        'tookEffectAt': watch.elapsedMilliseconds,
        'forcedReset': false,
        'hitTest': hitBefore,
        'buttons': buttons,
      };
    }

    // 没退。这里**不**贸然归因：只报原始证据 + unknown，除非证据链干净。
    final inChain = hitBefore['backButtonInChain'];
    final mode = switch (inChain) {
      // 几何上都没盖到按钮 —— 这是相对可信的「没点到」。
      false => 'not_hit',
      _ => 'unknown',
    };
    final result = <String, Object?>{
      'ok': false,
      'mode': mode,
      'elapsedMs': watch.elapsedMilliseconds,
      'tookEffectAt': null,
      'forcedReset': false,
      'reason': '${backTimeout.inSeconds} 秒内页面没有退出',
      'hitTest': hitBefore,
      'buttons': buttons,
    };

    // 兜底：强制回首页，让后面的步骤还能跑。这里绝不 await 到卡死。
    try {
      Get.until((route) => route.isFirst);
      result['forcedReset'] = true;
    } catch (error) {
      result['forcedReset'] = false;
      result['forcedResetError'] = '$error';
    }
    return result;
  }

  /// 用本地收藏拼一条队列。只读 `ShortVideoRepo`，不联网。
  static List<QueueEntry> _buildQueue() {
    try {
      return [
        for (final video in ShortVideoRepo.loadAll()) QueueEntry.fromShortVideo(video),
      ];
    } catch (_) {
      return const <QueueEntry>[];
    }
  }

  /// 轮询等待条件成立。超时返回 false，不抛错。
  static Future<bool> _waitUntil(
    bool Function() condition,
    Duration timeout, {
    required _Watchdog watchdog,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (watchdog.fired) return false;
      var ok = false;
      try {
        ok = condition();
      } catch (_) {
        ok = false;
      }
      if (ok) return true;
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return false;
  }
}

/// 总超时看门狗。到点只翻标志位，真正的落盘由主流程的 finally 做。
final class _Watchdog {
  _Watchdog(Duration timeout) {
    _timer = Timer(timeout, () {
      fired = true;
    });
  }

  late final Timer _timer;
  bool fired = false;

  void cancel() => _timer.cancel();
}

/// 证据累加器 + 分段落盘。
final class _Evidence {
  _Evidence(this.runId);

  final String runId;
  final Map<String, Object?> checks = <String, Object?>{};
  final Map<String, Object?> context = <String, Object?>{};
  final List<Map<String, Object?>> steps = <Map<String, Object?>>[];

  /// 当前磁盘路径，落盘后填上，方便回写进证据本身。
  String? path;
  String _status = 'running';

  /// 清掉上一轮的证据文件。只删自己这一个名字，不动别的日志。
  Future<void> resetOld() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${QaSelfCheck.fileName}');
    path = file.path;
    if (await file.exists()) await file.delete();
  }

  /// 走完一步：跑 action、记录结果、**立刻落盘**。
  Future<Map<String, Object?>> step(
    String name,
    Future<Map<String, Object?>> Function() action, {
    required _Watchdog watchdog,
  }) async {
    final watch = Stopwatch()..start();
    Map<String, Object?> result;
    String? detail;
    try {
      result = await action();
    } catch (error) {
      // 探针自己抛错（理论上不该发生，所有探针都吞异常）——算这一步失败。
      result = <String, Object?>{'ok': false, 'error': '$error'};
      detail = '$error';
    }
    watch.stop();
    if (watchdog.fired) result = {...result, 'watchdogFired': true};
    final outcome = result['ok'] == true ? 'ok' : 'fail';
    await stepDone(
      name,
      outcome,
      elapsedMs: watch.elapsedMilliseconds,
      detail: detail ?? (result['error'] == null ? null : '${result['error']}'),
    );
    return result;
  }

  /// 记录一步并落盘。skip 的步骤也必须走这里。
  Future<void> stepDone(
    String name,
    String result, {
    int elapsedMs = 0,
    String? detail,
  }) async {
    steps.add(<String, Object?>{
      'name': name,
      'result': result,
      'startedAt': DateTime.now().toIso8601String(),
      'elapsedMs': elapsedMs,
      'detail': detail,
    });
    await flush(status: _status);
  }

  Future<void> skip(String name, String reason) =>
      stepDone(name, 'skip', detail: reason);

  void fail(String name, String detail, {String? extra}) {
    steps.add(<String, Object?>{
      'name': name,
      'result': 'fail',
      'startedAt': DateTime.now().toIso8601String(),
      'elapsedMs': 0,
      'detail': detail,
      if (extra != null) 'extra': extra,
    });
  }

  /// 整份重写 + flush。任何一步结束都调它。
  Future<void> flush({required String status}) async {
    _status = status;
    final payload = <String, Object?>{
      'schema': QaSelfCheck.schema,
      'status': status,
      'at': DateTime.now().toIso8601String(),
      'runId': runId,
      'build': <String, Object?>{
        'versionCode': BuildConfig.versionCode,
        'versionName': BuildConfig.versionName,
        'commit': BuildConfig.commitHash,
      },
      'checks': checks,
      'context': context,
      'steps': steps,
      'pass': _pass,
      'writtenTo': path,
    };
    final encoded = const JsonEncoder.withIndent('  ').convert(payload);
    try {
      final file = path == null
          ? File(
              '${(await getApplicationDocumentsDirectory()).path}/'
              '${QaSelfCheck.fileName}',
            )
          : File(path!);
      path = file.path;
      await file.writeAsString(encoded, flush: true);
    } catch (_) {
      // 落盘失败不能反过来弄崩 App，自检自己吞掉。
    }
  }

  /// 全部通过才为 true。缺项按不通过算。
  ///
  /// `pass` 只回答「这些检查项是不是都过了」，不回答「这轮跑完了没」——
  /// 后者看 `status`：`running` 中途落盘时 `pass` 必然是 false，
  /// `aborted` 的结论要以 `status` 为准，不能拿 `pass` 当成败。
  bool get _pass {
    final channel = checks['shortvideo_web'];
    if (channel is! Map || channel['ok'] != true) return false;
    final page = checks['player_page'];
    if (page is! Map || page['opened'] != true) return false;
    final texture = checks['texture'];
    if (texture is! Map || texture['hasVideoController'] != true) return false;
    final firstFrame = checks['first_frame'];
    if (firstFrame is! Map || firstFrame['ok'] != true) return false;
    final back = checks['back'];
    if (back is! Map || back['ok'] != true) return false;
    final afterBack = checks['after_back'];
    if (afterBack is! Map || afterBack['channelOk'] != true) return false;
    return true;
  }
}

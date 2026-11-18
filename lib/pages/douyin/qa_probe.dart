import 'dart:async';

import 'package:PiliPlus/pages/douyin/player_bridge.dart';
import 'package:PiliPlus/pages/douyin/web.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';

/// 自检用的只读探针。
///
/// 只观测、不修复：这里不碰 `player.dart` 的播放逻辑，也不碰画中画原生实现。
/// 所有方法都带超时，任何一步拿不到就返回「不确定」，绝不阻塞调用方。
abstract final class QaProbe {
  /// 探测通道用的方法名。
  ///
  /// 选 `deviceMemory` 是因为它只读、无副作用，而且**一定会**回调 `result()`：
  /// 通道在就返回内存字节数，通道不在就抛 `MissingPluginException`。不像 `start`
  /// 那样依赖网页控制器已经创建，也不会在原生侧留下任何状态。
  static const String probeMethod = 'deviceMemory';

  /// 通道探测。拿不到就报不确定（超时 / 通道缺失），不抛错。
  static Future<Map<String, Object?>> probeChannel({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final watch = Stopwatch()..start();
    try {
      final bytes = await ShortVideoWeb.deviceMemory().timeout(timeout);
      watch.stop();
      return <String, Object?>{
        'method': probeMethod,
        'ok': bytes > 0,
        // 只记大小不记原值：方便分辨机型内存档位，也不泄露别的信息。
        'value': bytes,
        'elapsedMs': watch.elapsedMilliseconds,
      };
    } on TimeoutException {
      watch.stop();
      return <String, Object?>{
        'method': probeMethod,
        'ok': false,
        'error': 'timeout',
        'elapsedMs': watch.elapsedMilliseconds,
      };
    } catch (error) {
      watch.stop();
      return <String, Object?>{
        'method': probeMethod,
        'ok': false,
        'error': '$error',
        'elapsedMs': watch.elapsedMilliseconds,
      };
    }
  }

  /// 播放器当前状态快照。
  ///
  /// `hasTexture` 为真表示 `PlPlayerController.videoController` 已经建出来，
  /// 也就是 texture 通道拿到了；`textureId` 是给它绑定的 Flutter texture 编号。
  static Map<String, Object?> playerSnapshot() {
    final controller = PlPlayerController.instance;
    if (controller == null) {
      return <String, Object?>{
        'controllerExists': false,
        'hasTexture': false,
        'textureId': null,
        'playing': false,
        'positionMs': 0,
        'durationMs': 0,
      };
    }
    final videoController = controller.videoController;
    return <String, Object?>{
      'controllerExists': true,
      'hasTexture': videoController != null,
      'textureId': videoController?.id.value,
      'playing': controller.playerStatus.isPlaying,
      'positionMs': controller.positionInMilliseconds,
      'durationMs': controller.durationInMilliseconds,
    };
  }

  /// 当前路由栈顶是不是短视频播放页。
  static bool get playerPageOnTop {
    final route = Get.routing.route;
    return route != null && route.settings.name == ShortVideoPlayerRoute.routeName;
  }

  /// 播放页的返回按钮。
  ///
  /// 按 tooltip 找：`player.dart` 的返回 `ComBtn` 是唯一带 `'返回'` tooltip 的。
  /// 找不到返回 null，由调用方记成「不确定」。
  static Finder? backButtonFinder() {
    final finder = find.byTooltip('返回');
    final matched = finder.evaluate();
    if (matched.isEmpty) return null;
    return finder.at(matched.length - 1);
  }

  /// 把页面里所有带「返回」tooltip 的 widget 列出来，供命中测试结果附带说明。
  static List<Map<String, Object?>> describeBackButtons() {
    final result = <Map<String, Object?>>[];
    final finder = find.byTooltip('返回');
    for (final element in finder.evaluate()) {
      final box = element.renderObject;
      String? rect;
      if (box is RenderBox && box.hasSize) {
        final offset = box.localToGlobal(Offset.zero);
        rect =
            '${offset.dx.toStringAsFixed(1)},'
            '${offset.dy.toStringAsFixed(1)},'
            '${box.size.width.toStringAsFixed(1)},'
            '${box.size.height.toStringAsFixed(1)}';
      }
      result.add(<String, Object?>{
        'type': '${element.widget.runtimeType}',
        'rect': rect,
      });
    }
    return result;
  }

  static Offset? _backButtonCenter() {
    final finder = backButtonFinder();
    if (finder == null) return null;
    final box = finder.evaluate().first.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  /// 一次「只做命中测试、不投事件」的探测。
  ///
  /// 用 `hitTestInView` 探视图在返回按钮中心点的命中链，只读，不触发任何回调。
  /// 结果原样回传，**不做归因**——归因由调用方谨慎处理。
  static Map<String, Object?> hitTestAtBackButton() {
    final center = _backButtonCenter();
    if (center == null) {
      return <String, Object?>{
        'available': false,
        'reason': 'no_back_button',
      };
    }
    final binding = WidgetsBinding.instance;
    if (binding.renderViews.isEmpty) {
      return <String, Object?>{
        'available': false,
        'reason': 'no_view',
      };
    }
    final view = binding.renderViews.first;
    final hit = HitTestResult();
    view.hitTest(hit, center);
    final chain = <String>[
      for (final entry in hit.path) '${entry.target.runtimeType}',
    ];
    return <String, Object?>{
      'available': true,
      'at': '${center.dx.toStringAsFixed(1)},${center.dy.toStringAsFixed(1)}',
      // true 只说明几何上盖着它，不代表事件一定送得到——
      // 拦截发生在命中之后的阶段。这里只报事实，不下结论。
      'backButtonInChain': _chainSeesBackButton(hit),
      'chainLength': chain.length,
      'chainHead': chain.length <= 10 ? chain : chain.sublist(0, 10),
    };
  }

  static bool _chainSeesBackButton(HitTestResult hit) {
    final finder = backButtonFinder();
    if (finder == null) return false;
    final target = finder.evaluate().first.renderObject;
    for (final entry in hit.path) {
      if (identical(entry.target, target)) return true;
    }
    return false;
  }

  static int _pointerId = 9000;

  /// 投一次真实的点击（down + up），走完整命中测试链。
  ///
  /// 和手指点屏幕是同一条路径，所以 `AbsorbPointer` 之类的拦截能如实复现。
  /// 返回是否成功投出（找不到按钮时为 false）。
  static bool tapAtBackButton() {
    final center = _backButtonCenter();
    if (center == null) return false;
    final pointer = ++_pointerId;
    final binding = WidgetsBinding.instance;
    binding.handlePointerEvent(PointerDownEvent(pointer: pointer, position: center));
    // 抬起放到下一帧，避免被当成 fling 起手；同时也让手势竞技场有机会结算。
    SchedulerBinding.instance.addPostFrameCallback((_) {
      binding.handlePointerEvent(
        PointerUpEvent(pointer: pointer, position: center),
      );
    });
    return true;
  }
}

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:PiliPlus/utils/android/bindings.g.dart';
import 'package:PiliPlus/utils/device_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:jni/jni.dart';

abstract final class PiliAndroidHelper {
  static final isPipAvailable = AndroidHelper.isPipAvailable;

  /// 原生 PiP 状态。MainActivity 在回调里先写静态字段再通知 Dart，
  /// 所以这里读到的一定是本次回调对应的值。
  static bool get isPipMode => Platform.isAndroid && AndroidHelper.isPipMode;

  static void biliSendCommAntifraud(
    int action,
    int oid,
    int type,
    int rpId,
    int root,
    int parent,
    int ctime,
    String commentText,
    List pictures,
    String sourceId,
    int uid,
    String cookie,
  ) {
    final jCommentText = commentText.toJString();
    final jSourceId = sourceId.toJString();
    final jCookie = cookie.toJString();
    final jPictures = pictures.isEmpty
        ? null
        : jsonEncode(pictures).toJString();

    try {
      AndroidHelper.biliSendCommAntifraud(
        action,
        oid,
        type,
        rpId,
        root,
        parent,
        ctime,
        jCommentText,
        jPictures,
        jSourceId,
        uid,
        jCookie,
      );
    } finally {
      jCommentText.release();
      jSourceId.release();
      jCookie.release();
      jPictures?.release();
    }
  }

  static bool openMusic(String title, String? artist, String? album) {
    final jTitle = title.toJString();
    final jArtist = artist?.toJString();
    final jAlbum = album?.toJString();
    try {
      return AndroidHelper.openMusic(jTitle, jArtist, jAlbum);
    } finally {
      jTitle.release();
      jArtist?.release();
      jAlbum?.release();
    }
  }

  @pragma('vm:prefer-inline')
  static void enterPip(
    int width,
    int height, {
    required bool autoEnter,
    required bool isLive,
    required bool isPlaying,
  }) => AndroidHelper.enterPip(
    PlatformDispatcher.instance.engineId!,
    width,
    height,
    autoEnter,
    isLive,
    isPlaying,
  );

  @pragma('vm:prefer-inline')
  static void disableAutoEnterPip() =>
      AndroidHelper.disableAutoEnterPip(PlatformDispatcher.instance.engineId!);

  /// 播放/暂停状态变化后同步 PiP 小窗的遥控按键（暂停/播放、快进）。
  /// 只在已进入 PiP 时由调用方触发，且调用方会按状态签名去重。
  static void updatePipActions({
    required bool isLive,
    required bool isPlaying,
  }) {
    if (!Platform.isAndroid || DeviceUtils.sdkInt < 26) return;
    AndroidHelper.updatePipActions(
      PlatformDispatcher.instance.engineId!,
      isLive,
      isPlaying,
    );
  }

  // `onPictureInPictureModeChanged` 是在 bindings.g.dart 生成之后才加的字段，
  // 生成文件不在本批范围内，这里用 JNI 动态查一次字段并缓存。
  static JClass? _toDartClass;
  static JStaticFieldId? _pipModeChangedField;
  static void Function()? _pipModeListener;

  static JStaticFieldId? _pipModeChangedFieldId() {
    try {
      final cls = _toDartClass ??= JClass.forName(
        r'com/example/piliplus/AndroidHelper$ToDart',
      );
      return _pipModeChangedField ??= cls.staticFieldId(
        'onPictureInPictureModeChanged',
        r'Ljava/lang/Runnable;',
      );
    } catch (_) {
      return null;
    }
  }

  /// 注册/注销原生 PiP 进入退出回调；传 null 注销。
  ///
  /// Java 静态字段自己持有 Runnable 引用，注册后即可释放 Dart 句柄，
  /// 和 controller 里 onUserLeaveHint 的写法保持一致。
  static void setPictureInPictureModeListener(void Function()? listener) {
    if (!Platform.isAndroid || DeviceUtils.sdkInt < 26) return;
    _pipModeListener = listener;
    final field = _pipModeChangedFieldId();
    final cls = _toDartClass;
    if (field == null || cls == null) return;
    if (listener == null) {
      field.set(cls, Runnable.type, null);
      return;
    }
    final func = Runnable.implement($Runnable(run: listener));
    try {
      field.set(cls, Runnable.type, func);
    } finally {
      func.release();
    }
  }

  /// 只有当前注册者仍是 [listener] 时才注销，避免旧页面把新页面的监听摘掉。
  static void clearPictureInPictureModeListener(void Function() listener) {
    if (!identical(_pipModeListener, listener)) return;
    setPictureInPictureModeListener(null);
  }

  static (int, int)? maxScreenSize() {
    final jIArr = AndroidHelper.maxScreenSize();
    if (jIArr != null) {
      try {
        return (jIArr[0], jIArr[1]);
      } finally {
        jIArr.release();
      }
    }
    return null;
  }

  static void createShortcut(String id, String uri, String label, String path) {
    final jId = id.toJString();
    final jUri = uri.toJString();
    final jLabel = label.toJString();
    final jPath = path.toJString();
    try {
      AndroidHelper.createShortcut(jId, jUri, jLabel, jPath);
    } finally {
      jId.release();
      jUri.release();
      jLabel.release();
      jPath.release();
    }
  }

  static void openUrl(String url, {String domain = '*.bilibili.com'}) {
    if (!Platform.isAndroid || DeviceUtils.sdkInt < 31) {
      PageUtils.launchURL(url);
      return;
    }
    final jDomain = domain.toJString();
    JString? jUrl;
    try {
      if (AndroidHelper.isDomainVerified(jDomain)) {
        jUrl = url.toJString();
        final jStr = AndroidHelper.openUrl(jUrl);
        if (jStr != null) {
          SmartDialog.showToast(jStr.toDartString(releaseOriginal: true));
        }
      } else {
        PageUtils.launchURL(url);
      }
    } finally {
      jDomain.release();
      jUrl?.release();
    }
  }
}

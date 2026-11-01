import 'dart:io';


import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/pages/douyin/models.dart';

/// 播放队列里的一条。
///
/// 抖音 / TikTok 是网页里抄到的一条 mp4 直链，B 站是 DASH（画面和声音分开），
/// 两种在这里统一成同一个条目，播放器只管「上一条 / 下一条」。
class QueueEntry {
  const QueueEntry({
    required this.key,
    required this.title,
    required this.author,
    required this.cover,
    required this.durationMs,
    this.short,
    this.bvid,
  });

  factory QueueEntry.fromShortVideo(ShortVideo video) => QueueEntry(
    key: 'short:${video.key}',
    title: video.title,
    author: video.author,
    cover: video.cover,
    durationMs: video.durationMs,
    short: video,
  );

  factory QueueEntry.fromBili({
    required String bvid,
    required String title,
    required String author,
    required String cover,
    required int durationMs,
  }) => QueueEntry(
    key: 'bili:$bvid',
    title: title,
    author: author,
    cover: cover,
    durationMs: durationMs,
    bvid: bvid,
  );

  final String key;
  final String title;
  final String author;
  final String cover;
  final int durationMs;

  /// 抖音 / TikTok 的原始条目。
  final ShortVideo? short;

  /// B 站视频的 bvid。
  final String? bvid;

  bool get isBili => bvid != null;

  String get durationText {
    if (durationMs <= 0) return '--:--';
    final total = durationMs ~/ 1000;
    return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
  }
}

/// 解析出来、可以直接交给播放器的东西。
class QueueMedia {
  const QueueMedia({
    required this.url,
    required this.userAgent,
    required this.referer,
  });

  /// 可能是普通 http 地址，也可能是 media_kit 的 `edl://`（B 站双流）。
  final String url;
  final String userAgent;
  final String referer;
}

const _biliUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15';

/// 把一个条目解析成可播放地址。失败返回 null（播放器会跳到下一条）。
Future<QueueMedia?> resolveQueueEntry(QueueEntry entry) async {
  if (entry.short case final video?) {
    final url = await _resolveShortVideo(video);
    if (url == null || url.isEmpty) return null;
    final platform =
        ShortVideoPlatform.fromId(video.platform) ?? ShortVideoPlatform.douyin;
    return QueueMedia(
      url: url,
      userAgent: platform.userAgent,
      referer: platform.referer,
    );
  }
  if (entry.bvid case final bvid?) {
    return _resolveBili(bvid);
  }
  return null;
}

/// 抖音 / TikTok：30 分钟内的签名直链直接用，过期的先探长期地址。
Future<String?> _resolveShortVideo(ShortVideo video) async {
  final age = DateTime.now().millisecondsSinceEpoch / 1000 - video.updatedAt;
  final fresh = video.updatedAt > 0 && age >= 0 && age < 30 * 60;
  if (!fresh) {
    final stable = video.stableUrl;
    if (stable != null && await _probe(stable, video)) return stable;
  }
  if (video.playUrl.isNotEmpty) return video.playUrl;
  return video.stableUrl;
}

/// 只取两个字节确认能播，别把整段视频拉下来。
Future<bool> _probe(String url, ShortVideo video) async {
  final platform =
      ShortVideoPlatform.fromId(video.platform) ?? ShortVideoPlatform.douyin;
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
  try {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
    request.headers.set(HttpHeaders.userAgentHeader, platform.userAgent);
    request.headers.set(HttpHeaders.refererHeader, platform.referer);
    final response = await request.close().timeout(const Duration(seconds: 6));
    final mime = response.headers.contentType?.mimeType ?? '';
    final ok =
        (response.statusCode == 200 || response.statusCode == 206) &&
        !mime.contains('html');
    await response.drain<void>();
    return ok;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// B 站：先要 cid，再要 playurl，最后把画面和声音拼成 `edl://`。
///
/// media_kit 的 B 站播放就是这么做的（DASH 是两条流），这里照着来，
/// 这样「全选 → 下一首播放」的队列里可以混着 B 站和抖音/TikTok。
Future<QueueMedia?> _resolveBili(String bvid) async {
  try {
    final intro = await VideoHttp.videoIntro(bvid: bvid);
    final cid = intro.dataOrNull?.cid;
    if (cid == null) return null;

    final play = await VideoHttp.videoUrl(
      bvid: bvid,
      cid: cid,
      qn: 64,
      tryLook: true,
      videoType: VideoType.ugc,
    );
    final dash = play.dataOrNull?.dash;
    final videos = dash?.video;
    if (videos == null || videos.isEmpty) return null;
    final videoUrl = videos.first.baseUrl;
    if (videoUrl == null || videoUrl.isEmpty) return null;
    final audios = dash?.audio;
    final audioUrl = audios != null && audios.isNotEmpty
        ? audios.first.baseUrl
        : null;

    final url = audioUrl == null || audioUrl.isEmpty
        ? videoUrl
        : 'edl://!no_chapters;%${videoUrl.length}%$videoUrl;'
              '!new_stream;!no_chapters;%${audioUrl.length}%$audioUrl';
    return QueueMedia(
      url: url,
      userAgent: _biliUserAgent,
      referer: 'https://www.bilibili.com',
    );
  } catch (_) {
    return null;
  }
}
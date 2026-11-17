import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/pages/douyin/auto_cache.dart';
import 'package:PiliPlus/pages/douyin/cache.dart';
import 'package:PiliPlus/pages/douyin/queue.dart';
import 'package:PiliPlus/pages/douyin/qa_config.dart';
import 'package:PiliPlus/pages/douyin/shuffle_store.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

abstract final class ShortVideoQa {
  static const String resultFileName = 'shortvideo_qa_result.json';
  static const String historyFileName = 'shortvideo_qa_history.jsonl';
  static const MethodChannel _dump = MethodChannel('PiliPlus/QaDump');

  static bool _scheduled = false;

  static void schedule() {
    if (!Platform.isIOS || _scheduled) return;
    _scheduled = true;
    unawaited(_runOncePerBuild());
  }

  static Future<void> _runOncePerBuild() async {
    final cacheSettled = await _waitForCacheSettled();
    await run(cacheSettled: cacheSettled, finalPass: false);
    await _waitForQaFinished();
    await run(
      cacheSettled: cacheSettled || _cacheSnapshotSettled(),
      finalPass: true,
    );
  }

  static bool _cacheSnapshotSettled() {
    final snapshot = ShortVideoAutoCache.snapshot();
    final doneAt = snapshot['doneAt'];
    return snapshot['running'] == false &&
        doneAt is int &&
        doneAt > 0;
  }

  static Future<bool> _waitForCacheSettled() async {
    const poll = Duration(seconds: 4);
    final deadline = DateTime.now().add(const Duration(seconds: 180));
    while (DateTime.now().isBefore(deadline)) {
      if (_cacheSnapshotSettled()) return true;
      await Future<void>.delayed(poll);
    }
    return _cacheSnapshotSettled();
  }

  static Future<void> _waitForQaFinished() async {
    const poll = Duration(seconds: 3);
    final deadline = DateTime.now().add(const Duration(seconds: 240));
    while (DateTime.now().isBefore(deadline)) {
      if (PipQaRuntime.isFinished) return;
      await Future<void>.delayed(poll);
    }
  }

  static Future<Map<String, Object?>> run({
    bool cacheSettled = true,
    bool finalPass = true,
  }) async {
    final autoCache = ShortVideoAutoCache.snapshot();
    final videos = ShortVideoAutoCache.collectVideos();
    var local = 0;
    var douyinTotal = 0;
    var douyinLocal = 0;
    var tiktokTotal = 0;
    var tiktokLocal = 0;
    final missing = <String>[];
    for (final video in videos) {
      final path = await ShortVideoMediaCache.localPath(video);
      final isLocal = path != null;
      if (isLocal) {
        local++;
      } else if (missing.length < 40) {
        missing.add(video.key);
      }
      if (video.platform == 'tiktok') {
        tiktokTotal++;
        if (isLocal) tiktokLocal++;
      } else {
        douyinTotal++;
        if (isLocal) douyinLocal++;
      }
    }

    final keys = videos.map((video) => video.key).toList(growable: false);
    final signature = ShortVideoShuffleStore.signatureOf(keys);
    final saved = await ShortVideoShuffleStore.load();
    final played =
        saved?.played.where(keys.toSet().contains).toList() ?? const [];
    final runId = PipQaConfig.active?.runId ?? 'auto-${BuildConfig.versionCode}';
    final pip = await _readPipSummary(runId);
    final advanceHistory = _advanceHistory(pip);
    final realSequence = <String>[
      for (final key in (pip.remove('sequence') as List?) ?? const []) '$key',
    ];
    final roundSize = (pip.remove('queueTotal') as int?) ?? keys.length;
    final shuffle = <String, Object?>{
      'queueSize': keys.length,
      'roundSize': roundSize,
      'persistedPlayed': played.length,
      'signatureMatch': saved == null ? null : saved.signature == signature,
      'algorithmNoRepeatInRound': _simulateRounds(keys),
      'realSequenceLength': realSequence.length,
      'realDistinctKeys': realSequence.toSet().length,
      'realNoRepeat': _noRepeatWithinRound(realSequence, roundSize),
      'realEvidence': realSequence.length >= 2,
      'realSequence': realSequence.length > 80
          ? realSequence.sublist(realSequence.length - 80)
          : realSequence,
      'advanceHistory': advanceHistory,
      'naturalCompletionCount': _historyCount(advanceHistory, 'completed'),
      'forcedAdvanceCount': _historyCount(advanceHistory, 'qaTimer') +
          _historyCount(advanceHistory, 'playbackError'),
    };

    final playStats = ShortVideoPlayStats.snapshot();
    final tiktokPlayed = (playStats['tiktokLocalHits'] as int? ?? 0) +
        (playStats['tiktokNetworkFallbacks'] as int? ?? 0);
    final tiktokLocalHits = playStats['tiktokLocalHits'] as int? ?? 0;
    final tiktokNetworkFallbacks =
        playStats['tiktokNetworkFallbacks'] as int? ?? 0;
    final tiktokLocalFirst = tiktokTotal == 0 ||
        (tiktokPlayed > 0 &&
            tiktokLocalHits > 0 &&
            tiktokNetworkFallbacks == 0);
    final tiktokCacheOk =
        tiktokTotal == 0 || (cacheSettled && tiktokLocal == tiktokTotal);
    final tiktokStatus = tiktokTotal == 0
        ? 'no-tiktok-videos'
        : !cacheSettled
            ? 'cache-incomplete'
            : tiktokLocal < tiktokTotal
                ? 'cache-missing'
                : tiktokPlayed == 0
                    ? 'no-play-evidence'
                    : tiktokLocalFirst
                        ? 'local-play-ok'
                        : 'network-fallback';

    final result = <String, Object?>{
      'generatedAt': DateTime.now().toIso8601String(),
      'runId': runId,
      'finalPass': finalPass,
      'build': <String, Object?>{
        'versionCode': BuildConfig.versionCode,
        'versionName': BuildConfig.versionName,
        'commit': BuildConfig.commitHash,
      },
      'cache': <String, Object?>{
        'total': videos.length,
        'local': local,
        'missing': missing,
        'douyin': <String, Object?>{'total': douyinTotal, 'local': douyinLocal},
        'tiktok': <String, Object?>{'total': tiktokTotal, 'local': tiktokLocal},
        'settled': cacheSettled,
        'autoCache': autoCache,
      },
      'tiktok': <String, Object?>{
        'localFirst': tiktokLocalFirst,
        'cacheOk': tiktokCacheOk,
        'status': tiktokStatus,
        'playStats': playStats,
      },
      'shuffle': shuffle,
      'pip': pip,
      'verdict': <String, Object?>{
        'cacheComplete': videos.isNotEmpty && local == videos.length,
        'tiktokLocalPlayable': tiktokCacheOk && tiktokLocalFirst,
        'shuffleNoRepeat': keys.length <= 1 ||
            (shuffle['algorithmNoRepeatInRound'] == true &&
                shuffle['realEvidence'] == true &&
                shuffle['realNoRepeat'] == true &&
                (shuffle['naturalCompletionCount'] as int) > 0),
        'pipBackground': (pip['pass'] ?? pip['passed']) == true,
      },
    };
    if (!finalPass) result['stage'] = 'interim';
    await _write(result);
    return result;
  }

  static bool _simulateRounds(List<String> keys) {
    if (keys.length <= 1) return true;
    final random = Random(20261116);
    final played = <String>{};
    var deck = <String>[];
    for (var round = 0; round < 2; round++) {
      final inRound = <String>{};
      for (var step = 0; step < keys.length; step++) {
        if (deck.isEmpty) {
          final remaining = keys.where((key) => !played.contains(key)).toList();
          if (remaining.isEmpty) {
            played.clear();
            deck = keys.toList()..shuffle(random);
          } else {
            deck = remaining..shuffle(random);
          }
        }
        if (deck.isEmpty) return false;
        final key = deck.removeAt(0);
        if (!inRound.add(key)) return false;
        played.add(key);
      }
    }
    return true;
  }

  static bool _noRepeatWithinRound(List<String> sequence, int round) {
    if (round <= 1) return true;
    final lastSeen = <String, int>{};
    for (var i = 0; i < sequence.length; i++) {
      final key = sequence[i];
      final previous = lastSeen[key];
      if (previous != null && i - previous < round) return false;
      lastSeen[key] = i;
    }
    return true;
  }

  static Future<String?> _readText(String name) async {
    try {
      final raw = await _dump.invokeMethod<String>('read', <String, Object?>{
        'name': name,
      });
      if (raw != null && raw.trim().isNotEmpty) return raw;
    } catch (_) {}
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$name');
      if (await file.exists()) return file.readAsString();
    } catch (_) {}
    return null;
  }

  static Future<Map<String, Object?>> _readJson(String name) async {
    final raw = await _readText(name);
    if (raw == null) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map((key, value) => MapEntry('$key', value));
      }
    } catch (_) {}
    return const <String, Object?>{};
  }

  static Future<Map<String, Object?>> _readPipSummary(String runId) async {
    final log = await _readJson(PipQaConfig.logFileName);
    final hostRaw = await _readText(PipQaConfig.hostDiagFileName);
    final nativeRaw = await _readText(PipQaConfig.nativeDiagFileName);
    final hostEvents = _jsonlForRun(hostRaw, runId);
    final nativeEvents = _jsonlForRun(nativeRaw, runId);
    final summary = <String, Object?>{
      'logFound': log.isNotEmpty,
      'configSource': PipQaConfig.source,
      'hostDiagFound': hostEvents.isNotEmpty,
      'nativeDiagFound': nativeEvents.isNotEmpty,
      'hostEvents': hostEvents.length,
      'nativeEvents': nativeEvents.length,
      'hostTail': _tailEvents(hostEvents),
      'nativeTail': _tailEvents(nativeEvents),
    };
    if (log.isEmpty) return summary;
    final logRunId = '${log['runId'] ?? ''}';
    if (logRunId != runId) {
      summary['staleRunId'] = logRunId;
      return summary;
    }
    for (final key in const [
      'pass',
      'passed',
      'verdict',
      'failures',
      'backgroundSeconds',
      'backgroundPositionAdvanced',
      'positionAdvanced',
      'pipActiveInBackground',
      'hostDiag',
      'nativeDiag',
    ]) {
      if (log.containsKey(key)) summary[key] = log[key];
    }
    final samples = log['samples'];
    if (samples is List) {
      final sequence = <String>[];
      var queueTotal = 0;
      for (final sample in samples) {
        if (sample is! Map) continue;
        queueTotal = (sample['total'] as num?)?.toInt() ?? queueTotal;
        final key = '${sample['displayedKey'] ?? ''}'.trim();
        if (key.isEmpty || key == 'null') continue;
        if (sequence.isEmpty || sequence.last != key) sequence.add(key);
      }
      summary['sequence'] = sequence;
      summary['queueTotal'] = queueTotal;
    }
    return summary;
  }

  static List<Map<String, Object?>> _jsonlForRun(String? raw, String runId) {
    if (raw == null || raw.trim().isEmpty) return const [];
    final events = <Map<String, Object?>>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map && '${decoded['runId'] ?? ''}' == runId) {
          events.add(decoded.map((key, value) => MapEntry('$key', value)));
        }
      } catch (_) {}
    }
    return events;
  }

  static List<Map<String, Object?>> _tailEvents(List<Map<String, Object?>> events) {
    if (events.length <= 12) return events;
    return events.sublist(events.length - 12);
  }

  static List<Map<String, Object?>> _advanceHistory(Map<String, Object?> pip) {
    final samples = pip['samples'];
    if (samples is! List) return const [];
    final seen = <String>{};
    final history = <Map<String, Object?>>[];
    for (final sample in samples) {
      if (sample is! Map) continue;
      final raw = sample['advanceHistory'];
      if (raw is! List) continue;
      for (final item in raw) {
        if (item is! Map) continue;
        final reason = '${item['reason'] ?? ''}';
        final at = '${item['at'] ?? ''}';
        final marker = '$at|$reason|${item['fromKey'] ?? ''}';
        if (seen.add(marker)) {
          history.add(item.map((key, value) => MapEntry('$key', value)));
        }
      }
    }
    if (history.length > 80) {
      return history.sublist(history.length - 80);
    }
    return history;
  }

  static int _historyCount(List<Map<String, Object?>> history, String reason) {
    return history
        .where((item) => '${item['reason'] ?? ''}' == reason)
        .length;
  }

  static Future<void> _write(Map<String, Object?> result) async {
    final encoded = jsonEncode(result);
    try {
      final dir = await getApplicationDocumentsDirectory();
      await File('${dir.path}/$resultFileName').writeAsString(encoded, flush: true);
      await File('${dir.path}/$historyFileName').writeAsString(
        '${jsonEncode(<String, Object?>{
          'at': result['generatedAt'],
          'runId': result['runId'],
          'finalPass': result['finalPass'],
          'cache': result['cache'],
          'verdict': result['verdict'],
        })}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
    try {
      await _dump.invokeMethod<List<Object?>>('write', <String, Object?>{
        'name': resultFileName,
        'content': encoded,
      });
    } catch (_) {}
  }
}

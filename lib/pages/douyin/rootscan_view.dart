import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/pages/douyin/rootscan.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 诊断结果面板。
///
/// 为什么要有这个页面：在 LiveContainer + SideStore 里跑时，App 的
/// Documents 目录既不出现在系统「文件」App，路径也随 LC 的容器结构走，
/// 用户很难把 `rootscan.json` 拿出来。与其让用户去找文件，不如把结论
/// 直接画在屏幕上——用户截个图就能把全部证据发出来。
class RootScanPage extends StatefulWidget {
  const RootScanPage({super.key});

  @override
  State<RootScanPage> createState() => _RootScanPageState();
}

class _RootScanPageState extends State<RootScanPage> {
  bool _running = false;
  String _status = '点下面按钮重新扫描；进播放页时会自动扫一次。';

  @override
  void initState() {
    super.initState();
    _refreshFromLast();
  }

  void _refreshFromLast() {
    final report = PiliRootScan.lastReport;
    if (report != null) {
      setState(() => _status = '已载入最近一次扫描');
    }
  }

  Future<void> _rescan() async {
    setState(() {
      _running = true;
      _status = '扫描中，约 4 秒…';
    });
    final path = await PiliRootScan.run();
    if (!mounted) return;
    setState(() {
      _running = false;
      _status = path == null
          ? '扫描完成，但写文件失败（结论仍显示在下方）'
          : '扫描完成，已写入：\n$path';
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = PiliRootScan.lastReport;
    return Scaffold(
      appBar: AppBar(
        title: const Text('根因诊断'),
        actions: [
          if (report != null)
            IconButton(
              tooltip: '复制完整 JSON',
              icon: const Icon(Icons.copy_all),
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: const JsonEncoder.withIndent('  ').convert(report),
                  ),
                );
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('完整 JSON 已复制')),
                  );
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _running ? null : _rescan,
            icon: _running
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_running ? '扫描中…' : '重新扫描'),
          ),
          const SizedBox(height: 20),
          if (report == null)
            const Text('还没有扫描结果。')
          else
            ..._buildReport(context, report),
        ],
      ),
    );
  }

  /// 结论放最前面，细节折叠在后面——用户截一张图就够我看。
  List<Widget> _buildReport(
    BuildContext context,
    Map<String, Object?> report,
  ) {
    final out = <Widget>[];
    final verdict = report['verdict'];
    out.add(Text('结论', style: Theme.of(context).textTheme.titleMedium));
    out.add(const SizedBox(height: 8));
    if (verdict is List) {
      for (final line in verdict) {
        out.add(
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• '),
                Expanded(child: SelectableText('$line')),
              ],
            ),
          ),
        );
      }
    }
    out.add(const SizedBox(height: 20));
    out.add(Text('关键数值', style: Theme.of(context).textTheme.titleMedium));
    out.add(const SizedBox(height: 8));
    for (final row in _keyNumbers(report)) {
      out.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              SizedBox(width: 140, child: Text(row.$1)),
              Expanded(
                child: SelectableText(
                  row.$2,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return out;
  }

  /// 只挑真正能定性的几个数。
  List<(String, String)> _keyNumbers(Map<String, Object?> report) {
    final rows = <(String, String)>[];
    final native = report['native'];
    if (native is Map) {
      final thread = native['mainThread'];
      if (thread is Map) {
        rows.add((
          '主线程阻塞',
          '${thread['dispatchDelayMs']} ms'
              '${thread['blocked'] == true ? '（已阻塞）' : '（正常）'}',
        ));
      }
      final frames = native['frames'];
      if (frames is Map) {
        rows.add((
          '帧率',
          '${_fmt(frames['fps'])} fps'
              '  均值 ${_fmt(frames['meanMs'])}ms'
              '  最差 ${_fmt(frames['worstMs'])}ms',
        ));
        rows.add(('掉帧数(>50ms)', '${frames['framesOver50ms']}'));
      }
      final hits = native['hitTests'];
      if (hits is List) {
        for (final hit in hits) {
          if (hit is! Map) continue;
          rows.add((
            '命中 ${hit['label']}',
            '${hit['topmost']}',
          ));
        }
      }
      final windows = native['windows'];
      if (windows is List && windows.isNotEmpty) {
        final first = windows.first;
        if (first is Map) {
          rows.add(('视图总数', '${first['viewCount']}'));
        }
      }
    }
    final dart = report['dart'];
    if (dart is Map) {
      final player = dart['player'];
      if (player is Map) {
        rows.add((
          'textureId',
          '${player['textureId'] ?? 'null'}',
        ));
        rows.add((
          '有 videoController',
          '${player['hasVideoController']}',
        ));
        rows.add(('播放器状态', '${player['dataStatus'] ?? '-'}'));
      }
      final channels = dart['channels'];
      if (channels is Map) {
        rows.add(('短链通道', '${channels['shortvideo_web']}'));
      }
    }
    return rows;
  }

  String _fmt(Object? value) {
    if (value is num) return value.toStringAsFixed(1);
    return '$value';
  }
}

//  lib/screens/stats_home_screen/dart

import 'package:flutter/material.dart';
import '../services/score_store.dart';
import '../models/score_record.dart';
import 'score_detail_screen.dart';

class StatsHomeScreen extends StatefulWidget {
  const StatsHomeScreen({super.key});

  @override
  State<StatsHomeScreen> createState() => _StatsHomeScreenState();
}

class _StatsHomeScreenState extends State<StatsHomeScreen> {
  late Future<List<ScoreRecord>> _future;

  @override
  void initState() {
    super.initState();
    _future = ScoreStore.instance.listAll();
  }

  Future<void> _reload() async {
    final list = await ScoreStore.instance.listAll();
    setState(() {
      _future = Future.value(list);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('成績'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('全削除しますか？'),
                  content: const Text('保存済みの成績をすべて削除します。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('キャンセル'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('削除'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await ScoreStore.instance.clearAll();
                if (context.mounted) _reload();
              }
            },
          ),
        ],
      ),
      body: FutureBuilder<List<ScoreRecord>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          if (items.isEmpty) {
            return const Center(child: Text('成績はまだありません'));
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = items[i];
              final dt = DateTime.fromMillisecondsSinceEpoch(r.timestamp);
              // 日付 + スコアのみ。単元/ミックスの表示はしない
              final subtitle =
                  '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')}  ${r.score}/${r.total}';
              return ListTile(
                title: Text(r.deckTitle.isEmpty ? r.deckId : r.deckTitle),
                subtitle: Text(subtitle),
                trailing: Text('${(r.accuracy * 100).toStringAsFixed(0)}%'),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ScoreDetailScreen(record: r),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

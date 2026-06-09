// lib/screens/result_screen.dart
import 'package:flutter/material.dart';
import 'package:health_quiz_app/widgets/quiz_analytics.dart'; // SummaryStackedBar, computeTopUnits, UnitStat, segmentColor

import '../models/score_record.dart';
import '../services/attempt_store.dart';
import '../services/score_saver.dart'; // 追加

// ▼ 追加（誤答のみリトライに必須）
import '../services/deck_loader.dart';
import '../models/deck.dart';
import '../models/card.dart';
import 'quiz_screen.dart';

import 'attempt_history_screen.dart';

class ResultScreen extends StatefulWidget {
  final int total;
  final int correct;
  final String? sessionId;
  final Map<String, int>? unitBreakdown;

  // 保存関連（任意）
  final String? deckId;
  final String? deckTitle;
  final int? durationSec;
  final int? timestamp;
  final List<String>? selectedUnitIds;
  final Map<String, TagStat>? tags;
  final Map<int, TagStat>? importanceStats;
  final Map<int, TagStat>? difficultyStats;
  final bool saveHistory;

  // 表示関連
  final Map<String, String>? unitTitleMap;
  final int initialMax;

  // ★ 追加：セッションタイプ（'normal' | 'mix' | 'review_test'）
  final String? sessionType;

  const ResultScreen({
    super.key,
    required this.total,
    required this.correct,
    this.sessionId,
    this.unitBreakdown,
    this.deckId,
    this.deckTitle,
    this.durationSec,
    this.timestamp,
    this.selectedUnitIds,
    this.tags,
    this.importanceStats,
    this.difficultyStats,
    this.saveHistory = true,
    this.unitTitleMap,
    this.initialMax = 10,
    this.sessionType,
  });

  @override
  State<ResultScreen> createState() => _ResultScreenState();
}

class _ResultScreenState extends State<ResultScreen> {
  bool _saved = false;

  // ── 誤答だけ再挑戦用（キャッシュ）
  Future<List<QuizCard>>? _wrongCardsFuture;

  @override
  void initState() {
    super.initState();
    _maybeSaveRecordOnce();
    _wrongCardsFuture = _getWrongCardsForThisSession(); // 先に仕込んでおく
  }

  Future<void> _maybeSaveRecordOnce() async {
    if (_saved) return;
    if (!widget.saveHistory) return;
    if (widget.deckId == null || widget.deckTitle == null) return;

    final record = ScoreRecord(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      deckId: widget.deckId!,
      deckTitle: widget.deckTitle!,
      score: widget.correct,
      total: widget.total,
      timestamp: widget.timestamp ?? DateTime.now().millisecondsSinceEpoch,
      durationSec: widget.durationSec,
      tags: widget.tags,
      selectedUnitIds: widget.selectedUnitIds,
      sessionId: widget.sessionId,
      unitBreakdown: widget.unitBreakdown,
    );

    try {
      await ScoreSaver.save(record);
      if (!mounted) return;
      setState(() => _saved = true);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('結果を保存しました')));
    } catch (_) {
      // 失敗は致命的でないので握りつぶす
    }
  }

  // ============ ここから：誤答カードの収集（stableIdベース） ============
  Future<List<QuizCard>> _getWrongCardsForThisSession() async {
    final sid = widget.sessionId;
    if (sid == null || sid.isEmpty) return <QuizCard>[];

    // このセッションに紐付いた誤答の stableId をユニークに取得
    final attempts = AttemptStore();
    final ids = await attempts.getWrongStableIdsUnique(
      onlySessionIds: <String>[sid],
    );

    if (ids.isEmpty) return <QuizCard>[];

    // stableId -> QuizCard に解決
    final loader = await DeckLoader.instance();
    final cards = loader.mapStableIdsToCards(ids);

    // デバッグ用：不一致があれば検知
    if (cards.isEmpty) {
      // ignore: avoid_print
      print(
        '[WRONG-RETRY] no cards were resolved from stableIds=${ids.take(5).toList()}',
      );
    }
    return cards;
  }
  // ============ ここまで：誤答カードの収集 ============

  @override
  Widget build(BuildContext context) {
    final total = widget.total;
    final correct = widget.correct;
    final wrong = (total - correct).clamp(0, total);

    // サマリバー用に Map<String,int> -> Map<String,UnitStat>(wrong=0) へ変換
    final ub = widget.unitBreakdown ?? const <String, int>{};
    final breakdownForBar = ub.map(
      (k, v) => MapEntry(k, UnitStat(asked: v, wrong: 0)),
    );
    final top = computeTopUnits(
      unitBreakdown: breakdownForBar,
      unitTitleMap: widget.unitTitleMap,
      topN: 4,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('結果')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            // ★ 追加：セッションタイプ別タイトルバッジ
            if (widget.sessionType != null) _buildSessionHeader(widget.sessionType!),
            const SizedBox(height: 12),

            // スコアヘッダ
            _scoreHeader(context, total: total, correct: correct, wrong: wrong),

            const SizedBox(height: 12),

            _MetadataBreakdownCard(
              title: '重要度別',
              stats: widget.importanceStats,
              labels: const {
                1: '最重要',
                2: '重要',
                3: '補助',
              },
            ),

            const SizedBox(height: 12),

            _MetadataBreakdownCard(
              title: '難易度別',
              stats: widget.difficultyStats,
              labels: const {
                1: '基礎',
                2: '標準',
                3: '応用',
              },
            ),

            const SizedBox(height: 12),

            _WrongTagCard(tags: widget.tags),

            const SizedBox(height: 16),

            // 出題サマリ（総計100% 横積みバー）
            Text('出題サマリー', style: Theme.of(context).textTheme.titleMedium),
            SummaryStackedBar(data: top),
            const SizedBox(height: 12),

            // 出題内訳カード
            if (ub.isNotEmpty)
              _UnitBreakdownCard(
                unitBreakdown: ub,
                totalQuestions: total,
                unitTitleMap: widget.unitTitleMap,
                initialMax: widget.initialMax,
              ),

            const SizedBox(height: 24),

            if (widget.durationSec != null)
              Text(
                '解答時間: ${_fmtDuration(widget.durationSec!)}',
                style: const TextStyle(fontSize: 16, color: Colors.black54),
              ),
            if (widget.deckTitle != null) ...[
              const SizedBox(height: 4),
              Text(
                'デッキ: ${widget.deckTitle!}',
                style: const TextStyle(fontSize: 16, color: Colors.black54),
              ),
            ],
            const SizedBox(height: 24),

            if (widget.sessionId != null && widget.sessionId!.isNotEmpty) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.history),
                label: const Text('今回の履歴を見る'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(double.infinity, 48),
                  textStyle: const TextStyle(fontSize: 18),
                ),
                onPressed: () {
                  debugPrint('[HISTORY/NAV] open sid=${widget.sessionId}');
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AttemptHistoryScreen(
                        sessionId: widget.sessionId!,
                        unitTitleMap: widget.unitTitleMap,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),

              // ★★ 誤答だけもう一度（stableIdベース／このセッション限定） ★★
              FutureBuilder<List<QuizCard>>(
                future: _wrongCardsFuture,
                builder: (context, snap) {
                  final ready = snap.connectionState == ConnectionState.done;
                  final list = snap.data ?? const <QuizCard>[];
                  final hasWrong = list.isNotEmpty;

                  return FilledButton.icon(
                    onPressed: (ready && hasWrong)
                        ? () async {
                            // ここが肝：overrideCards に誤答カードを渡す
                            final fakeDeck = Deck(
                              id: 'mixed',
                              title: '誤答だけもう一度',
                              isPurchased: true,
                              units: const [],
                            );
                            // 念のため安定順に軽くシャッフル（好みでOFF可）
                            final cards = List<QuizCard>.from(list)..shuffle();

                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => QuizScreen(
                                  deck: fakeDeck,
                                  overrideCards: cards,
                                  type: 'retry_wrong',
                                ),
                              ),
                            );
                          }
                        : null,
                    icon: const Icon(Icons.refresh),
                    label: Text(
                      ready ? (hasWrong ? '誤答だけもう一度（${list.length}問）' : '今回の誤答はありません') : '誤答を抽出中…',
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 48),
                      textStyle: const TextStyle(fontSize: 18),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
            ],

            FilledButton.icon(
              onPressed: () {
                Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil('/', (route) => false);
              },
              icon: const Icon(Icons.home),
              label: const Text('ホームへ'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                textStyle: const TextStyle(fontSize: 18),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ★ ここに追加
  Widget _buildSessionHeader(String type) {
    String title;
    Color? badgeColor;
    switch (type) {
      case 'review_test':
        title = '復習テスト';
        badgeColor = Colors.orange;
        break;
      case 'mix':
        title = 'ミックス練習';
        badgeColor = Colors.blue;
        break;
      default:
        title = '通常出題';
        badgeColor = Colors.grey;
    }
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: badgeColor.withOpacity(0.1),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: badgeColor),
          ),
          child: Text(
            'type: $type',
            style: TextStyle(color: badgeColor, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _scoreHeader(
    BuildContext context, {
    required int total,
    required int correct,
    required int wrong,
  }) {
    final rate = total > 0 ? (correct / total) : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '正解 $correct / $total（${(rate * 100).toStringAsFixed(1)}%）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (wrong > 0)
              Chip(
                label: Text('誤答 $wrong'),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }

  String _fmtDuration(int secs) {
    final m = secs ~/ 60;
    final s = secs % 60;
    return '$m分$s秒';
  }
}

class _MetadataBreakdownCard extends StatelessWidget {
  final String title;
  final Map<int, TagStat>? stats;
  final Map<int, String> labels;

  const _MetadataBreakdownCard({
    required this.title,
    required this.stats,
    required this.labels,
  });

  @override
  Widget build(BuildContext context) {
    final s = stats;
    if (s == null || s.isEmpty) return const SizedBox.shrink();

    final entries = labels.entries
        .map((entry) {
          final stat = s[entry.key] ?? const TagStat(correct: 0, wrong: 0);
          final total = stat.correct + stat.wrong;
          return (
            key: entry.key,
            label: entry.value,
            correct: stat.correct,
            wrong: stat.wrong,
            total: total,
          );
        })
        .where((e) => e.total > 0)
        .toList();

    if (entries.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            for (final e in entries)
              _row(
                context,
                e.label,
                e.correct,
                e.total,
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    int correct,
    int total,
  ) {
    final rate = total == 0 ? 0.0 : correct / total;
    final percent = (rate * 100).toStringAsFixed(0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '$correct / $total（$percent%）',
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: rate.clamp(0, 1),
              minHeight: 8,
            ),
          ),
        ],
      ),
    );
  }
}

class _WrongTagCard extends StatelessWidget {
  final Map<String, TagStat>? tags;

  const _WrongTagCard({required this.tags});

  bool _isUnitIdTag(String tag) {
    return RegExp(r'^s\d{2}_u\d{2}$').hasMatch(tag);
  }

  @override
  Widget build(BuildContext context) {
    final raw = tags;
    if (raw == null || raw.isEmpty) return const SizedBox.shrink();

    final items = raw.entries
        .where((e) => e.value.wrong > 0)
        .where((e) => e.key.trim().isNotEmpty)
        .where((e) => !_isUnitIdTag(e.key.trim()))
        .toList()
      ..sort((a, b) {
        final c = b.value.wrong.compareTo(a.value.wrong);
        return c != 0 ? c : a.key.compareTo(b.key);
      });

    final top = items.take(5).toList();
    if (top.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '今回間違えたテーマ',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final e in top)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.key,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                    Text(
                      '${e.value.wrong}回',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ===== 出題内訳カード（日本語タイトル対応・5件まで表示＆開閉） =====
class _UnitBreakdownCard extends StatefulWidget {
  final Map<String, int> unitBreakdown;
  final int totalQuestions;
  final Map<String, String>? unitTitleMap;

  /// 初期表示件数（デフォルト 5）
  final int initialMax;

  const _UnitBreakdownCard({
    required this.unitBreakdown,
    required this.totalQuestions,
    this.unitTitleMap,
    this.initialMax = 5,
  });

  @override
  State<_UnitBreakdownCard> createState() => _UnitBreakdownCardState();
}

class _UnitBreakdownCardState extends State<_UnitBreakdownCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.unitBreakdown.isEmpty) return const SizedBox.shrink();

    final entries = widget.unitBreakdown.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value); // 件数降順
        return c != 0 ? c : a.key.compareTo(b.key); // 同数ならキー昇順
      });

    final total = widget.totalQuestions;
    final showToggle = entries.length > widget.initialMax;
    final visibleCount = _expanded ? entries.length : entries.length.clamp(0, widget.initialMax);

    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '出題内訳',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            // 可視分のみ描画
            for (var i = 0; i < visibleCount; i++)
              _row(
                context: context,
                index: i,
                title: (widget.unitTitleMap?[entries[i].key] ?? entries[i].key),
                asked: entries[i].value,
                total:
                    total == 0 ? widget.unitBreakdown.values.fold<int>(0, (a, b) => a + b) : total,
              ),

            if (showToggle) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
                  label: Text(_expanded ? '閉じる' : 'もっと見る（全${entries.length}件）'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row({
    required BuildContext context,
    required int index,
    required String title,
    required int asked,
    required int total,
  }) {
    final ratio = total > 0 ? asked / total : 0.0;
    final pctStr = (ratio * 100).toStringAsFixed(0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // カラーインジケータ（サマリバー配色と合わせる）
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: segmentColor(index),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text('$asked問（$pctStr%）', style: const TextStyle(fontSize: 13)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: ratio.clamp(0, 1),
              minHeight: 8,
            ),
          ),
        ],
      ),
    );
  }
}

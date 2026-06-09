// lib/screens/quiz_screen.dart
import 'package:flutter/material.dart';
import '../models/deck.dart';
import '../models/card.dart';
import '../models/quiz_card_ext.dart'; // ← withChoiceOrder 拡張
import '../models/score_record.dart';
import 'result_screen.dart';
import 'package:uuid/uuid.dart';
import 'package:provider/provider.dart';
import '../services/app_settings.dart';
import '../services/deck_loader.dart';
import '../services/attempt_store.dart';
import '../models/attempt_entry.dart';
import '../utils/logger.dart';
import '../utils/stable_id.dart';

// ★ セッション保存/再開
import 'package:shared_preferences/shared_preferences.dart';
import '../models/quiz_session.dart';
import '../data/quiz_session_local_repository.dart';

class QuizScreen extends StatefulWidget {
  final Deck deck;
  final List<QuizCard>? overrideCards; // UnitSelect などからの限定セット
  final QuizSession? resumeSession; // 再開用
  final String? type; // ★追加

  // ★ 追加（ミックス新規開始用の入力）
  final List<String>? selectedUnitIds;
  final int? limit;

  const QuizScreen({
    super.key,
    required this.deck,
    this.overrideCards,
    this.type, // ★追加
    this.resumeSession,
    // ★ 追加
    this.selectedUnitIds,
    this.limit,
  });

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  // ===== ランタイム状態 =====
  late List<QuizCard> sequence; // 出題順に並んだカード（選択肢は各カード内で並び済み）
  late List<String> _stableOrder; // ★ 出題順に対応する「安定ID」列（保存・復元の唯一の根拠）
  String? _sessionId;

  int index = 0;
  int? selected;
  bool revealed = false;
  int correctCount = 0;
  bool _nextLock = false; // 再入防止

  final Stopwatch _sw = Stopwatch()..start();
  bool _savedOnce = false;
  DateTime? _qStart;

  // 解析用
  final Map<String, int> _tagCorrect = {};
  final Map<String, int> _tagWrong = {};
  final Map<String, int> _unitCount = {};

  // 重要度・難易度別集計用
  final Map<int, int> _importanceCorrect = {};
  final Map<int, int> _importanceWrong = {};
  final Map<int, int> _difficultyCorrect = {};
  final Map<int, int> _difficultyWrong = {};

  // 復元用：安定ID → 元カード
  late Map<String, QuizCard> _id2card;

  // 選択肢順の保存：安定ID → 並び順インデックス配列
  late Map<String, List<int>> _choiceOrders;

  // 画面安全化
  bool _initReady = false; // 初期化が完了したときだけ build する
  final bool _abortAndPop = false; // 復元不能時の安全フラグ

  // ===== ユーティリティ =====
  // QuizCardにunitIdが未実装でも安全に取得
  String _unitIdOf(QuizCard c) {
    try {
      final dyn = c as dynamic;
      final v = dyn.unitId;
      if (v is String && v.isNotEmpty) return v;
    } catch (_) {}
    return widget.deck.id;
  }

  // QuizCardにidが未実装でも安全に取得（Attempt保存時用）
  String _cardIdOf(QuizCard c, String fallback) {
    try {
      final v = (c as dynamic).id;
      if (v is String && v.trim().isNotEmpty) return v.trim();
    } catch (_) {}
    return fallback; // 取れなければ stableId など安全なIDにフォールバック
  }

  void _bumpTags(Iterable<String> tags, bool isCorrect) {
    for (final t in tags) {
      if (isCorrect) {
        _tagCorrect[t] = (_tagCorrect[t] ?? 0) + 1;
      } else {
        _tagWrong[t] = (_tagWrong[t] ?? 0) + 1;
      }
    }
  }

  int _normalizeMetaValue(int value) {
    if (value < 1) return 1;
    if (value > 3) return 3;
    return value;
  }

  void _bumpIntCounter(Map<int, int> map, int key) {
    map[key] = (map[key] ?? 0) + 1;
  }

  void _bumpMeta(QuizCard card, bool isCorrect) {
    final importance = _normalizeMetaValue(card.importance);
    final difficulty = _normalizeMetaValue(card.difficulty);

    if (isCorrect) {
      _bumpIntCounter(_importanceCorrect, importance);
      _bumpIntCounter(_difficultyCorrect, difficulty);
    } else {
      _bumpIntCounter(_importanceWrong, importance);
      _bumpIntCounter(_difficultyWrong, difficulty);
    }
  }

  Map<int, TagStat> _buildMetaStats(
    Map<int, int> correctMap,
    Map<int, int> wrongMap,
  ) {
    return {
      for (final key in const [1, 2, 3])
        key: TagStat(
          correct: correctMap[key] ?? 0,
          wrong: wrongMap[key] ?? 0,
        ),
    };
  }

  QuizCard get card => sequence[index];

  /// 与えられたカードを「インデックス順序のシャッフル」に従って並べ替えた新カードを返す。
  /// outOrder に 0..n-1 のシャッフル順を返す（保存用）。
  QuizCard _shuffledWithOrder(QuizCard c, {required List<int> outOrder}) {
    final s = context.read<AppSettings>();
    final idx = List<int>.generate(c.choices.length, (i) => i);
    if (s.randomize) {
      idx.shuffle();
    }
    outOrder
      ..clear()
      ..addAll(idx);
    return c.withChoiceOrder(idx); // ← 拡張を使用
  }

  // 復元失敗時の共通処理
  Future<void> _failAndClear(String message) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await QuizSessionLocalRepository(prefs).clear();
    } catch (_) {}
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    Navigator.pop(context);
  }

  /// ★ 追加：与えられた unitId 群が「複数デッキ」に跨っているかを判定
  Future<bool> _isCrossDeckByUnitIds(List<String>? unitIds) async {
    if (unitIds == null || unitIds.isEmpty) return false;
    if (unitIds.length == 1) return false;

    final loader = await DeckLoader.instance();
    final decks = await loader.loadAll();

    final unit2deck = <String, String>{};
    for (final d in decks) {
      for (final u in (d.units ?? const [])) {
        final uid = u.id.trim();
        if (uid.isEmpty) continue;
        unit2deck[uid] = d.id;
      }
    }

    final deckSet = <String>{};
    for (final uid in unitIds) {
      final did = unit2deck[uid];
      if (did != null && did.isNotEmpty) deckSet.add(did);
    }
    return deckSet.length > 1;
  }

  // ===== ライフサイクル =====
  @override
  void initState() {
    super.initState();
    _init(); // 非同期初期化に分離
  }

  @override
  void didUpdateWidget(covariant QuizScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 重要：overrideCards 指定時は再初期化しない（順序・選択肢の固定を維持）
    if (widget.overrideCards != null && widget.overrideCards!.isNotEmpty) {
      return; // 何もしない＝_init() を呼び直さない
    }
    // 通常デッキでウィジェット更新に応じて再初期化したい場合だけ、必要なら：
    // _init();
  }

  // mixed の保存用メタ（オートセーブ時に null で上書きされないように保持）
  late String _deckIdForSave; // 'mixed' or 通常 deck.id
  List<String>? _selectedUnitIdsForSave; // mixed のときに保持
  int? _limitForSave; // mixed のときに保持

  Future<void> _init() async {
    // ===== セッションIDの初期化 =====
    final isResume = widget.resumeSession != null; // ← resumeSession があるかどうかで判定
    if (isResume) {
      _sessionId = widget.resumeSession!.sessionId; // ← 前回のセッションIDを再利用
    } else {
      _sessionId ??= const Uuid().v4(); // ← 新規開始時は1回だけ発行
    }

    debugPrint('[SESSION] start sid=$_sessionId');

    final settings = Provider.of<AppSettings>(context, listen: false);
    _choiceOrders = {};
    sequence = [];
    _id2card = {};
    _selectedUnitIdsForSave = null;
    _limitForSave = null;

    // ───────── A) overrideCards 優先（ミックスはここで完結） ─────────
    if (widget.overrideCards != null && widget.overrideCards!.isNotEmpty) {
      _limitForSave = widget.limit;

      // 1) このセットに含まれるユニットIDを収集
      final base = List<QuizCard>.from(widget.overrideCards!);
      final unitIdsSet = <String>{};
      for (final c in base) {
        unitIdsSet.add(_unitIdOf(c));
      }

      // 2) デッキ跨ぎ判定（ユニット→デッキの逆引きを作成）
      final loader = await DeckLoader.instance();
      final decks = await loader.loadAll();
      final unit2deck = <String, String>{};
      for (final d in decks) {
        for (final u in (d.units ?? const [])) {
          final uid = u.id.trim();
          if (uid.isNotEmpty) unit2deck[uid] = d.id;
        }
      }
      final deckSet = <String>{
        for (final uid in unitIdsSet)
          if (unit2deck[uid]?.isNotEmpty == true) unit2deck[uid]!,
      };

      // 3) 単元 or ミックス の保存メタを決定
      if (unitIdsSet.length == 1 && deckSet.length <= 1) {
        // 単元として保存
        _deckIdForSave = deckSet.isNotEmpty ? deckSet.first : widget.deck.id;
        _selectedUnitIdsForSave = null; // 単元扱いなので保存しない
      } else {
        // ミックスとして保存
        _deckIdForSave = 'mixed';
        // selectedUnitIds が未指定なら、実カードからの集合を保存
        _selectedUnitIdsForSave = widget.selectedUnitIds ?? unitIdsSet.toList();
      }

      // 安定ID逆引き（元のテキスト順で）
      _id2card = {for (final c in base) stableIdForOriginal(c): c};
      final items = [for (final c in base) (stableIdForOriginal(c), c)];

      // 出題順は base の順をそのまま使用（均等配分を壊さない）
      sequence = [];
      _choiceOrders.clear();
      for (final it in items) {
        final id = it.$1;
        final orig = it.$2;
        final ord = <int>[];
        final shuffled = _shuffledWithOrder(orig, outOrder: ord); // 選択肢だけシャッフル
        _choiceOrders[id] = List<int>.from(ord);
        sequence.add(shuffled);
      }
      _stableOrder = [for (final it in items) it.$1];

      // 集計など
      index = 0;
      correctCount = 0;
      _qStart = DateTime.now();
      _unitCount.clear();
      for (final qc in sequence) {
        final uid = _unitIdOf(qc);
        _unitCount[uid] = (_unitCount[uid] ?? 0) + 1;
      }

      // 初回セーブ（mixed として）
      await _saveSession(
        QuizSession(
          sessionId: _sessionId!,
          deckId: 'mixed',
          unitId: null,
          selectedUnitIds: _selectedUnitIdsForSave,
          limit: _limitForSave,
          itemIds: _stableOrder,
          currentIndex: 0,
          answers: const {},
          updatedAt: DateTime.now(),
          isFinished: false,
          choiceOrders: _choiceOrders,
        ),
      );
      AppLog.d(
        '[MIX/SAVE-INIT] deck=mixed units=$_selectedUnitIdsForSave '
        'limit=$_limitForSave len=${_stableOrder.length} choiceOrders=${_choiceOrders.length}',
      );
      setState(() => _initReady = true);
      return;
    }

    final s = widget.resumeSession;

    // ───────── 0) ルート判定 ─────────
    final isMixedResume = (s != null && s.deckId == 'mixed');
    final isMixedNew = (s == null && (widget.selectedUnitIds?.isNotEmpty ?? false));

    // ───────── 1) ミックス“再開”（deckId=='mixed'）─────────
    if (isMixedResume) {
      _sessionId = s.sessionId;
      _deckIdForSave = 'mixed';
      _selectedUnitIdsForSave = s.selectedUnitIds;
      _limitForSave = s.limit;

      // 必須フィールドチェック
      if (s.selectedUnitIds == null || s.selectedUnitIds!.isEmpty || s.limit == null) {
        AppLog.d('[RESUME] mixed: missing fields selectedUnitIds/limit');
        await _failAndClear('再開に必要な情報が不足しています（mixed）。');
        return;
      }

      // 1) 母集団を QuizScreen 側で再構築（購入フィルタなし）
      final allDecks = await (await DeckLoader.instance()).loadAll();
      final unitSet = s.selectedUnitIds!.toSet();
      final List<QuizCard> base = [];
      for (final d in allDecks) {
        for (final c in d.cards) {
          final uid = _unitIdOf(c);
          if (unitSet.contains(uid)) base.add(c);
        }
      }

      // 2) 安定ID逆引き
      _id2card = {for (final c in base) stableIdForOriginal(c): c};

      // 3) 欠損チェック
      final missing = s.itemIds.where((id) => !_id2card.containsKey(id)).toList();
      if (missing.isNotEmpty) {
        AppLog.d(
          '[RESUME][MISSING] deck=mixed missing=${missing.length} sample=${missing.take(5).toList()}',
        );
        await _failAndClear('前回の出題を復元できませんでした（問題セットが更新された可能性）');
        return;
      }

      // 4) 復元（シャッフル禁止／choiceOrders を適用。なければ“互換のためだけに”ランダム）
      _stableOrder = List<String>.from(s.itemIds);
      for (final id in _stableOrder) {
        final orig = _id2card[id]!;
        final ord = s.choiceOrders?[id];
        final restored = (ord == null)
            ? _shuffledWithOrder(orig, outOrder: <int>[])
            : orig.withChoiceOrder(ord);
        sequence.add(restored);
        // _choiceOrders には現況を保持（以後のオートセーブで一貫）
        if (ord != null) {
          _choiceOrders[id] = List<int>.from(ord);
        } else {
          final tmp = <int>[];
          _shuffledWithOrder(orig, outOrder: tmp);
          _choiceOrders[id] = List<int>.from(tmp);
        }
      }

      // 5) 進行位置・集計
      index = s.currentIndex.clamp(0, sequence.length - 1);
      correctCount = 0;
      _qStart = DateTime.now();

      _unitCount.clear();
      for (final qc in sequence) {
        final uid = _unitIdOf(qc);
        _unitCount[uid] = (_unitCount[uid] ?? 0) + 1;
      }

      setState(() => _initReady = true);
      AppLog.d('[RESUME] navigate deck=mixed len=${_stableOrder.length}');
      return;
    }

    // ───────── 2) ミックス“新規開始”（selectedUnitIds/limit を受領）─────────
    if (isMixedNew) {
      //_sessionId = const Uuid().v4();
      _deckIdForSave = 'mixed';
      _selectedUnitIdsForSave = List<String>.from(widget.selectedUnitIds!);
      _limitForSave = widget.limit;

      // a) 母集団を再構築（購入フィルタなし）
      final allDecks = await (await DeckLoader.instance()).loadAll();
      final unitSet = widget.selectedUnitIds!.toSet();
      final base = <QuizCard>[];
      for (final d in allDecks) {
        for (final c in d.cards) {
          final uid = _unitIdOf(c);
          if (unitSet.contains(uid)) base.add(c);
        }
      }

      // b) limit 適用（ここで母集団に上限をかける）
      final limit = widget.limit;
      if (limit != null && limit > 0 && base.length > limit) {
        final s = context.read<AppSettings>();
        if (s.randomize) {
          base.shuffle(); // 切り詰め前に軽くシャッフル（ON時のみ）
        }
        base.removeRange(limit, base.length);
      }

      // c) 安定ID逆引き & 出題順（シャッフルはここだけ）
      _id2card = {for (final c in base) stableIdForOriginal(c): c};
      var items = [for (final c in base) (stableIdForOriginal(c), c)];
      if (settings.randomize) items.shuffle();

      // d) sequence を作りつつ、各カードの choiceOrder を記録
      sequence = [];
      _choiceOrders.clear();
      for (final it in items) {
        final id = it.$1;
        final orig = it.$2;
        final order = <int>[];
        final shuffled = _shuffledWithOrder(orig, outOrder: order);
        _choiceOrders[id] = List<int>.from(order);
        sequence.add(shuffled);
      }
      _stableOrder = [for (final it in items) it.$1];

      // e) 進行位置・集計
      index = 0;
      correctCount = 0;
      _qStart = DateTime.now();

      _unitCount.clear();
      for (final qc in sequence) {
        final uid = _unitIdOf(qc);
        _unitCount[uid] = (_unitCount[uid] ?? 0) + 1;
      }

      // f) 初回セーブ（deckId:'mixed' / selectedUnitIds / limit / choiceOrders を保存）
      await _saveSession(
        QuizSession(
          sessionId: _sessionId!,
          deckId: 'mixed',
          unitId: null,
          selectedUnitIds: _selectedUnitIdsForSave,
          limit: _limitForSave,
          itemIds: _stableOrder,
          currentIndex: 0,
          answers: const {},
          updatedAt: DateTime.now(),
          isFinished: false,
          choiceOrders: _choiceOrders,
        ),
      );
      AppLog.d(
        '[MIX/SAVE-INIT] deck=mixed units=$_selectedUnitIdsForSave '
        'limit=$_limitForSave len=${_stableOrder.length} '
        'choiceOrders=${_choiceOrders.length}',
      );

      setState(() => _initReady = true);
      if (sequence.isEmpty && mounted) {
        // 安全策：空なら失敗扱い
        await _failAndClear('出題を準備できませんでした。選択内容を見直してください。');
      }
      return;
    }

    // ───────── 3) 通常デッキ：新規 or 再開 ─────────
    // 1) ベース問題集合（新規時用：UnitSelect 等から来ていれば限定セット）
    final baseForNew = (widget.overrideCards ?? widget.deck.cards).toList();

    if (s == null) {
      // ─ 新規セッション（通常/限定）

      // a) 安定IDの逆引き（必ず「元の並び・元の選択肢」で計算する）
      _id2card = {for (final c in baseForNew) stableIdForOriginal(c): c};

      // b) 出題順（安定IDと対で保持）
      final items = [for (final c in baseForNew) (stableIdForOriginal(c), c)];
      if (settings.randomize) items.shuffle(); // ★ 出題順のシャッフルはここだけ

      // c) カード配列作成＋選択肢順を記録
      sequence = [];
      _choiceOrders.clear();
      for (final it in items) {
        final id = it.$1;
        final orig = it.$2;
        final order = <int>[];
        final shuffledCard = _shuffledWithOrder(orig, outOrder: order);
        _choiceOrders[id] = List<int>.from(order);
        sequence.add(shuffledCard);
      }

      // d) 出題順の安定ID列
      _stableOrder = [for (final it in items) it.$1];

      // e) セッションID・開始時刻
      //_sessionId = const Uuid().v4();
      _deckIdForSave = widget.deck.id; // 通常
      _qStart = DateTime.now();

      // f) ユニット内訳
      _unitCount.clear();
      for (final qc in sequence) {
        final uid = _unitIdOf(qc);
        _unitCount[uid] = (_unitCount[uid] ?? 0) + 1;
      }

      // g) 初期セーブ（単元練習では unitId / selectedUnitIds を記録）
      await _saveSession(
        QuizSession(
          sessionId: _sessionId!,
          deckId: _deckIdForSave, // 通常 deck.id
          unitId: widget.overrideCards != null && widget.overrideCards!.isNotEmpty
              ? _unitIdOf(widget.overrideCards!.first)
              : null,
          selectedUnitIds: widget.overrideCards != null && widget.overrideCards!.isNotEmpty
              ? [_unitIdOf(widget.overrideCards!.first)]
              : null,
          limit: null,
          itemIds: _stableOrder,
          currentIndex: 0,
          answers: const {},
          updatedAt: DateTime.now(),
          isFinished: false,
          choiceOrders: _choiceOrders,
        ),
      );

      setState(() => _initReady = true);
    } else {
      // ─ 再開セッション（通常デッキ）
      _sessionId = s.sessionId;
      _deckIdForSave = widget.deck.id;

      // ★ unitId が指定されている場合、そのユニットだけに絞る
      late final List<QuizCard> baseDefault;
      if (s.unitId != null && s.unitId!.isNotEmpty) {
        final targetUnit = widget.deck.units.firstWhere(
          (u) => u.id == s.unitId,
          orElse: () => widget.deck.units.first,
        );
        baseDefault = targetUnit.cards.toList() ?? widget.deck.cards.toList();
        AppLog.d(
          '[RESUME] single-unit mode detected: ${s.unitId} '
          'cards=${baseDefault.length}',
        );
      } else {
        baseDefault = (widget.overrideCards ?? widget.deck.cards).toList();
      }

      // ★ ここで逆引きを作ってから missing 判定
      _id2card = {for (final c in baseDefault) stableIdForOriginal(c): c};

      // a) 欠損チェック
      final missing = s.itemIds.where((id) => !_id2card.containsKey(id)).toList();
      if (missing.isNotEmpty) {
        AppLog.d(
          '[RESUME][MISSING] deck=${s.deckId} missing=${missing.length} '
          'sample=${missing.take(5).toList()}',
        );
        await _failAndClear('前回の出題を復元できませんでした（問題セットが更新された可能性）');
        return;
      }

      // b) 出題順
      _stableOrder = List<String>.from(s.itemIds);

      // c) 復元：choiceOrders があれば適用、なければランダム可（従来仕様）
      sequence = [];
      _choiceOrders.clear();
      for (final id in _stableOrder) {
        final orig = _id2card[id]!;
        final ord = s.choiceOrders?[id];
        final restored = (ord == null)
            ? _shuffledWithOrder(orig, outOrder: <int>[])
            : orig.withChoiceOrder(ord);
        sequence.add(restored);
        if (ord != null) {
          _choiceOrders[id] = List<int>.from(ord);
        } else {
          final tmp = <int>[];
          _shuffledWithOrder(orig, outOrder: tmp);
          _choiceOrders[id] = List<int>.from(tmp);
        }
      }

      // d) 進行位置・集計
      index = s.currentIndex.clamp(0, sequence.length - 1);
      correctCount = 0;
      _qStart = DateTime.now();

      _unitCount.clear();
      for (final qc in sequence) {
        final uid = _unitIdOf(qc);
        _unitCount[uid] = (_unitCount[uid] ?? 0) + 1;
      }

      setState(() => _initReady = true);
      AppLog.d('[RESUME] navigate deck=${s.deckId} len=${_stableOrder.length}');
    }
  }

  // ===== セッション保存ユーティリティ =====
  Future<void> _saveSession(QuizSession s) async {
    final prefs = await SharedPreferences.getInstance();
    await QuizSessionLocalRepository(prefs).save(s);
    AppLog.d(
      '[RESUME] saved: deck=${s.deckId} index=${s.currentIndex} '
      'len=${s.itemIds.length} finished=${s.isFinished}',
    );
  }

  Future<void> _markFinishedAndClear(QuizSession s) async {
    final prefs = await SharedPreferences.getInstance();
    final repo = QuizSessionLocalRepository(prefs);
    await repo.save(s.copyWith(isFinished: true));
    await repo.clear();
  }

  // ===== 選択・遷移 =====
  void _select(int i) {
    if (revealed) return;
    final app = Provider.of<AppSettings>(context, listen: false);
    final tapMode = app.tapMode;

    if (tapMode == TapAdvanceMode.oneTap) {
      setState(() => selected = i);
      _reveal();
    } else {
      if (selected == i) {
        _reveal();
      } else {
        setState(() => selected = i);
      }
    }
  }

  void _reveal() {
    if (selected == null) return;
    setState(() => revealed = true);
  }

  Future<void> _next() async {
    // ★ 再入防止ロック
    if (_nextLock) return;
    _nextLock = true;
    try {
      if (selected == card.answerIndex) correctCount++;
      final isCorrect = selected == card.answerIndex;
      _bumpTags(card.tags, isCorrect);
      _bumpMeta(card, isCorrect);

      // 1) 問題単位の Attempt 保存
      try {
        final ended = DateTime.now();
        final started = _qStart ?? ended;
        final durationMs = ended.difference(started).inMilliseconds;

        // ★ デバッグ：保存する stableId を確認
        AppLog.d('[ATTEMPT/SAVE] stableId=${_stableOrder[index]}');

        final attempt = AttemptEntry(
          attemptId: const Uuid().v4(),
          sessionId: _sessionId!,
          questionNumber: index + 1, // 1-based
          unitId: _unitIdOf(card),
          cardId: _cardIdOf(card, _stableOrder[index]),

          question: card.question,
          selectedIndex: (selected ?? 0) + 1, // 1-based
          correctIndex: (card.answerIndex) + 1, // 1-based
          isCorrect: isCorrect,
          durationMs: durationMs,
          timestamp: ended,
          // ★ ここが超重要：出題順の安定IDを保存する
          stableId: _stableOrder[index],
        );
        await AttemptStore().add(attempt);
        debugPrint(
          '[ATTEMPT] saved sid=$_sessionId '
          'stableId=${attempt.stableId} q=${attempt.questionNumber}',
        );
      } catch (_) {}
      // 2) オートセーブ（⚠️ 必ず _stableOrder を使う）
      try {
        await _saveSession(
          QuizSession(
            sessionId: _sessionId!,
            deckId: _deckIdForSave, // mixed のときは 'mixed'
            unitId: null,
            selectedUnitIds: _selectedUnitIdsForSave,
            limit: _limitForSave,
            itemIds: _stableOrder, // ← 常に出題順の安定ID列
            currentIndex: index + 1, // 次に解く位置
            answers: const {},
            updatedAt: DateTime.now(),
            isFinished: false,
            choiceOrders: _choiceOrders, // 選択肢順を常に保存
          ),
        );
      } catch (_) {}

      // 3) 最終問題ならスコア保存→クリア→結果へ
      if (index >= sequence.length - 1) {
        if (_savedOnce) return;
        _savedOnce = true;

        final deckIdSave = _deckIdForSave; // 表示用
        final total = sequence.length;
        final correct = correctCount;
        final timestamp = DateTime.now();
        final durationSec = _sw.elapsed.inSeconds;

        // デッキ/ユニットタイトル解決
        final decks = await (await DeckLoader.instance()).loadAll();
        final Map<String, String> deckTitleMap = {};
        final Map<String, String> unitTitleMap = {};
        for (final d in decks) {
          deckTitleMap[d.id.trim()] = d.title.trim().isNotEmpty ? d.title.trim() : d.id.trim();
          for (final u in (d.units ?? const [])) {
            final uid = u.id.trim();
            final ut = u.title.trim();
            if (uid.isNotEmpty) unitTitleMap[uid] = ut.isNotEmpty ? ut : uid;
          }
        }

        // ★★★ ここから：タイトル自動整理（デッキ跨ぎベース版）★★★
        String deckTitleById(String id) =>
            (deckTitleMap[id]?.trim().isNotEmpty ?? false) ? deckTitleMap[id]!.trim() : id;

        // 1) 今回出題したユニットIDを sequence から収集
        List<String> unitIdsForThisRun = [];
        if (_unitCount.isNotEmpty) {
          unitIdsForThisRun = _unitCount.keys.toList();
        } else if (sequence.isNotEmpty) {
          unitIdsForThisRun = sequence.map((c) => _unitIdOf(c)).toSet().toList();
        } else if ((_selectedUnitIdsForSave?.isNotEmpty ?? false)) {
          unitIdsForThisRun = List<String>.from(_selectedUnitIdsForSave!);
        }

        // 2) ユニット→デッキ対応表を作成
        final unit2deck = <String, String>{};
        for (final d in decks) {
          for (final u in (d.units ?? const [])) {
            final uid = u.id.trim();
            if (uid.isNotEmpty) unit2deck[uid] = d.id;
          }
        }

        // 3) 出題ユニットが属するデッキ集合を求める
        final deckSet = <String>{};
        for (final uid in unitIdsForThisRun) {
          final did = unit2deck[uid];
          if (did != null && did.isNotEmpty) deckSet.add(did);
        }
        final bool crossDeck = deckSet.length > 1;

        // 4) タイトル決定（type を最優先）
        final t = (widget.type ?? '').trim();
        final bool isReviewTest = (t == 'review_test');
        final bool isRetryWrong = (t == 'wrong_only' || t == 'retry_wrong');
        late final String titleForScore;

        if (isReviewTest) {
          // ★ 復習テストは単元跨ぎでも必ずこのタイトル
          titleForScore = '復習テスト';
        } else if (isRetryWrong) {
          titleForScore = crossDeck
              ? '誤答だけもう一度（ミックス練習）'
              : '誤答だけもう一度（${deckTitleById(deckSet.isNotEmpty ? deckSet.first : widget.deck.id)}）';
        } else {
          // 通常：単元 or ミックス
          titleForScore = crossDeck
              ? 'ミックス練習'
              : deckTitleById(deckSet.isNotEmpty ? deckSet.first : widget.deck.id);
        }
        // ★★★ ここまで：タイトル自動整理 ★★★

        // タグ統計
        final Map<String, TagStat> tagStats = {};
        final allKeys = <String>{..._tagCorrect.keys, ..._tagWrong.keys};
        for (final k in allKeys) {
          tagStats[k] = TagStat(correct: _tagCorrect[k] ?? 0, wrong: _tagWrong[k] ?? 0);
        }

        final importanceStats = _buildMetaStats(
          _importanceCorrect,
          _importanceWrong,
        );

        final difficultyStats = _buildMetaStats(
          _difficultyCorrect,
          _difficultyWrong,
        );

        // スコア保存
        try {
          debugPrint('[SCORE] save sid=$_sessionId total=${sequence.length} correct=$correctCount');

          await AttemptStore().addScore(
            ScoreRecord(
              id: const Uuid().v4(),
              deckId: deckIdSave,
              deckTitle: titleForScore, // ← ここを反映
              score: correct,
              total: total,
              durationSec: durationSec,
              timestamp: timestamp.millisecondsSinceEpoch,
              tags: tagStats.isEmpty ? null : tagStats,
              selectedUnitIds: _selectedUnitIdsForSave, // mixed のとき残る
              sessionId: _sessionId!,
              unitBreakdown: Map<String, int>.from(_unitCount),
            ),
          );
        } catch (_) {}

        // セッション終了保存→クリア
        try {
          await _markFinishedAndClear(
            QuizSession(
              sessionId: _sessionId!,
              deckId: deckIdSave,
              unitId: null,
              selectedUnitIds: _selectedUnitIdsForSave,
              limit: _limitForSave,
              itemIds: _stableOrder,
              currentIndex: sequence.length,
              answers: const {},
              updatedAt: DateTime.now(),
              isFinished: true,
              choiceOrders: _choiceOrders,
            ),
          );
        } catch (_) {}

        if (!mounted) return;
        await _onQuizEndDebugLog();
        if (!mounted) return;

        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => ResultScreen(
              total: total,
              correct: correct,
              sessionId: _sessionId!,
              unitBreakdown: Map<String, int>.from(_unitCount),
              deckId: deckIdSave,
              deckTitle: titleForScore, // ← ここを反映
              durationSec: durationSec,
              unitTitleMap: unitTitleMap,
              importanceStats: importanceStats,
              difficultyStats: difficultyStats,
            ),
          ),
        );
        return;
      }

      // 4) 次の問題へ
      setState(() {
        index++;
        selected = null;
        revealed = false;
        _qStart = DateTime.now();
      });
    } finally {
      _nextLock = false; // ★ 必ず解除
    }
  }

  Future<void> _primaryAction() async {
    if (revealed) {
      await _next();
    } else {
      _reveal();
    }
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    // 初期化前/中断時の安全ガード
    if (!_initReady || _abortAndPop || sequence.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('読み込み中…')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final isCorrect = revealed && selected == card.answerIndex;

    return Scaffold(
      appBar: AppBar(
        title: Text('問題 ${index + 1}/${sequence.length}'),
        bottom: PreferredSize(preferredSize: Size.fromHeight(6), child: _ProgressBar()),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // ① 上：スクロール領域（質問・選択肢・解説）
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (revealed && !_nextLock) _next();
                },
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        card.question,
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 16),

                      // 選択肢
                      ...List.generate(card.choices.length, (i) => _buildChoice(i)),

                      const SizedBox(height: 12),

                      // 解説
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        reverseDuration: const Duration(milliseconds: 180),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final slide = Tween<Offset>(
                            begin: const Offset(0, 0.06),
                            end: Offset.zero,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(position: slide, child: child),
                          );
                        },
                        child: (revealed && (card.explanation ?? '').trim().isNotEmpty)
                            ? _ExplanationCard(index: index, text: card.explanation!)
                            : const SizedBox.shrink(key: ValueKey('exp-empty')),
                      ),

                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),

            // ② 下：固定フッター（ボタン＋判定表示）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: (_nextLock || (selected == null && !revealed))
                          ? null
                          : () async {
                              await _primaryAction();
                            },
                      child: Text(
                        revealed ? (index == sequence.length - 1 ? '結果へ' : '次へ') : '答えを見る',
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  revealed
                      ? Text(
                          isCorrect ? '正解！' : '不正解…',
                          style: TextStyle(
                            color: isCorrect ? Colors.green : Colors.red,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChoice(int i) {
    final isAnswer = i == card.answerIndex;
    final isSelected = i == selected;

    Color bg = Colors.white;
    if (revealed) {
      if (isAnswer) {
        bg = Colors.green;
      } else if (isSelected) {
        bg = Colors.red;
      } else {
        bg = Colors.grey.shade300;
      }
    } else if (isSelected) {
      bg = Theme.of(context).colorScheme.primary.withValues(alpha: 0.9);
    }
    final fg = (revealed && (isAnswer || isSelected)) ? Colors.white : Colors.black87;

    IconData? trail;
    if (revealed) {
      if (isAnswer) {
        trail = Icons.check_rounded;
      } else if (isSelected) {
        trail = Icons.close_rounded;
      }
    } else {
      trail = isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked;
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            blurRadius: 6,
            offset: const Offset(0, 2),
            color: Colors.black.withValues(alpha: 0.06),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () {
            if (revealed) {
              if (!_nextLock) _next();
            } else {
              _select(i);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: (revealed && isAnswer) ? Colors.white24 : Colors.black12,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    String.fromCharCode('A'.codeUnitAt(0) + i),
                    style: TextStyle(color: fg, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    card.choices[i],
                    softWrap: true,
                    style: TextStyle(
                      color: fg,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ),
                if (trail != null) ...[const SizedBox(width: 10), Icon(trail, color: fg, size: 22)],
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 直近Attemptのデバッグログ
  Future<void> _onQuizEndDebugLog() async {
    try {
      final list = await AttemptStore().recent(limit: 5);
      for (final a in list) {
        AppLog.d(
          '[ATTEMPT] ${a.sessionId} Q${a.questionNumber} '
          '${a.isCorrect ? "○" : "×"} ${a.durationMs}ms',
        );
      }
    } catch (_) {}
  }
}

// 解説カード
class _ExplanationCard extends StatelessWidget {
  final int index;
  final String text;
  const _ExplanationCard({required this.index, required this.text});

  @override
  Widget build(BuildContext context) {
    return Card(
      key: ValueKey('exp-$index'),
      elevation: 1.5,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 20),
                const SizedBox(width: 8),
                Text(
                  '解説',
                  style: Theme.of(
                    context,
                  ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Text(
              text.trim(),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 18, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

// 進捗バー
class _ProgressBar extends StatelessWidget implements PreferredSizeWidget {
  const _ProgressBar();
  @override
  Size get preferredSize => const Size.fromHeight(6);
  @override
  Widget build(BuildContext context) {
    final state = context.findAncestorStateOfType<_QuizScreenState>();
    final value =
        (state == null || !state._initReady || state._abortAndPop || state.sequence.isEmpty)
        ? 0.0
        : (state.index + 1) / state.sequence.length;
    return LinearProgressIndicator(value: value, minHeight: 6);
  }
}

// lib/models/card.dart
import 'dart:math';

class QuizCard {
  final String question; // 問題文
  final List<String> choices; // 選択肢（4択想定）
  final int answerIndex; // 正解のindex（0-based）
  final String? explanation; // 解説（任意）
  final bool isPremium; // 有料かどうか
  final List<String> unitTags; // 分野タグ（複数可）
  final String? unitId; // 所属ユニットID（任意・後方互換）

  // 統計検定2級アプリ用メタデータ
  final int importance; // 1=最重要, 2=重要, 3=補助
  final int difficulty; // 1=基礎, 2=標準, 3=応用

  const QuizCard({
    required this.question,
    required this.choices,
    required this.answerIndex,
    this.explanation,
    this.isPremium = false,
    this.unitTags = const [],
    this.unitId,
    this.importance = 2,
    this.difficulty = 2,
  });

  QuizCard copyWith({
    String? question,
    List<String>? choices,
    int? answerIndex,
    String? explanation,
    bool? isPremium,
    List<String>? unitTags,
    String? unitId,
    int? importance,
    int? difficulty,
  }) {
    return QuizCard(
      question: question ?? this.question,
      choices: choices ?? this.choices,
      answerIndex: answerIndex ?? this.answerIndex,
      explanation: explanation ?? this.explanation,
      isPremium: isPremium ?? this.isPremium,
      unitTags: unitTags ?? this.unitTags,
      unitId: unitId ?? this.unitId,
      importance: importance ?? this.importance,
      difficulty: difficulty ?? this.difficulty,
    );
  }

  List<String> get tags => unitTags;

  /// JSON読み込み用
  factory QuizCard.fromJson(Map<String, dynamic> json) {
    List<String> readTags(Map<String, dynamic> j) {
      final raw = j['unitTags'] ?? j['tags'] ?? j['tag'] ?? j['tag_list'];
      if (raw is List) {
        return raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
      }
      if (raw is String) {
        return raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
      return const <String>[];
    }

    String? readUnitId(Map<String, dynamic> j) {
      final u = j['unitId'] ?? j['unit_id'];
      if (u == null) return null;
      final s = u.toString().trim();
      return s.isEmpty ? null : s;
    }

    int readIntMeta(
      Map<String, dynamic> j,
      String key, {
      required int fallback,
      int min = 1,
      int max = 3,
    }) {
      final raw = j[key];
      int? value;

      if (raw is int) {
        value = raw;
      } else if (raw is num) {
        value = raw.toInt();
      } else if (raw is String) {
        value = int.tryParse(raw.trim());
      }

      return (value ?? fallback).clamp(min, max);
    }

    return QuizCard(
      question: json['question'] as String,
      choices: List<String>.from(json['choices']),
      answerIndex: json['answerIndex'] as int,
      explanation: json['explanation'] as String?,
      isPremium: json['isPremium'] as bool? ?? false,
      unitTags: readTags(json),
      unitId: readUnitId(json),
      importance: readIntMeta(json, 'importance', fallback: 2),
      difficulty: readIntMeta(json, 'difficulty', fallback: 2),
    );
  }

  /// CSV読み込み用
  factory QuizCard.fromRowWithHeader(Map<String, int> idx, List<dynamic> row) {
    String s(String key) {
      final i = idx[key];
      if (i == null) return '';
      final v = row[i];
      return (v == null) ? '' : v.toString().trim();
    }

    int readIntFromRow(
      String key, {
      required int fallback,
      int min = 1,
      int max = 3,
    }) {
      if (!idx.containsKey(key)) return fallback;
      final parsed = int.tryParse(s(key));
      return (parsed ?? fallback).clamp(min, max);
    }

    List<String> readTagsFromRow() {
      if (!idx.containsKey('tags')) return const <String>[];
      final raw = s('tags');
      if (raw.isEmpty) return const <String>[];

      return raw.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    }

    bool readIsPremiumFromRow() {
      if (idx.containsKey('isPremium')) {
        final raw = s('isPremium').toLowerCase();
        return raw == 'true' || raw == '1' || raw == 'yes';
      }

      if (idx.containsKey('is_premium')) {
        final raw = s('is_premium').toLowerCase();
        return raw == 'true' || raw == '1' || raw == 'yes';
      }

      if (idx.containsKey('is_free')) {
        final raw = s('is_free').toLowerCase();
        final isFree = raw == 'true' || raw == '1' || raw == 'yes';
        return !isFree;
      }

      return false;
    }

    final c1 = s('choice1');
    final c2 = s('choice2');
    final c3 = s('choice3');
    final c4 = s('choice4');
    final ansRaw = s('answer_index');
    final exp = idx.containsKey('explanation') ? s('explanation') : null;

    final list = [c1, c2, c3, c4].where((e) => e.isNotEmpty).toList();

    var ans = int.tryParse(ansRaw) ?? 1;
    ans = (ans - 1).clamp(0, list.length - 1); // 1→0, 4→3 など

    final uid = idx.containsKey('unit_id') ? s('unit_id') : null;

    return QuizCard(
      question: s('question'),
      choices: list,
      answerIndex: ans,
      explanation: (exp != null && exp.isEmpty) ? null : exp,
      isPremium: readIsPremiumFromRow(),
      unitTags: readTagsFromRow(),
      unitId: (uid != null && uid.isEmpty) ? null : uid,
      importance: readIntFromRow('importance', fallback: 2),
      difficulty: readIntFromRow('difficulty', fallback: 2),
    );
  }
}

/// 選択肢をシャッフルして answerIndex を再計算した新しいカードを返す
extension QuizCardShuffle on QuizCard {
  QuizCard shuffled({Random? rnd, bool randomize = true}) {
    final pairs = List.generate(choices.length, (i) => MapEntry(i, choices[i]));
    if (randomize) {
      pairs.shuffle(rnd ?? Random());
    }

    final newChoices = pairs.map((e) => e.value).toList(growable: false);
    final newAnswerIndex = pairs.indexWhere((e) => e.key == answerIndex);

    return QuizCard(
      question: question,
      choices: newChoices,
      answerIndex: newAnswerIndex,
      explanation: explanation,
      isPremium: isPremium,
      unitTags: unitTags,
      unitId: unitId,
      importance: importance,
      difficulty: difficulty,
    );
  }
}

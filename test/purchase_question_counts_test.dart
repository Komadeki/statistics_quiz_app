import 'package:flutter_test/flutter_test.dart';
import 'package:health_quiz_app/models/card.dart';
import 'package:health_quiz_app/models/deck.dart';
import 'package:health_quiz_app/models/purchase_question_counts.dart';
import 'package:health_quiz_app/models/unit.dart';
import 'package:health_quiz_app/services/deck_loader.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('purchase counts separate free questions from unlock value', () {
    final deck = Deck(
      id: 'S01',
      title: '記述統計',
      isPurchased: false,
      units: [
        Unit(
          id: 's01_u01',
          title: '代表値',
          cards: const [
            QuizCard(
              question: 'free',
              choices: ['a', 'b'],
              answerIndex: 0,
            ),
            QuizCard(
              question: 'paid 1',
              choices: ['a', 'b'],
              answerIndex: 0,
              isPremium: true,
            ),
            QuizCard(
              question: 'paid 2',
              choices: ['a', 'b'],
              answerIndex: 0,
              isPremium: true,
            ),
          ],
        ),
      ],
    );

    final counts = PurchaseQuestionCounts.byDeck([deck])['s01']!;
    expect(counts.total, 3);
    expect(counts.free, 1);
    expect(counts.addedByUnlock, 2);
  });

  test('combined counts preserve total unlock value', () {
    final combined = PurchaseQuestionCounts.combined(const [
      PurchaseQuestionCounts(total: 10, free: 4),
      PurchaseQuestionCounts(total: 8, free: 3),
    ]);

    expect(combined.total, 18);
    expect(combined.free, 7);
    expect(combined.addedByUnlock, 11);
  });

  test('release assets expose the expected paid question value', () async {
    final loader = await DeckLoader.instance(forceReload: true);
    final byDeck = PurchaseQuestionCounts.byDeck(await loader.loadAll());
    final combined = PurchaseQuestionCounts.combined(byDeck.values);

    expect(byDeck, hasLength(8));
    expect(combined.total, 582);
    expect(combined.free, 277);
    expect(combined.addedByUnlock, 305);
    expect(
      byDeck.values.map((counts) => counts.addedByUnlock),
      everyElement(greaterThan(0)),
    );
  });
}

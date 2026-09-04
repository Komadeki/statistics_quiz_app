import 'deck.dart';

class PurchaseQuestionCounts {
  const PurchaseQuestionCounts({required this.total, required this.free});

  final int total;
  final int free;

  int get addedByUnlock => total - free;

  static Map<String, PurchaseQuestionCounts> byDeck(Iterable<Deck> decks) {
    return {
      for (final deck in decks)
        deck.id.toLowerCase(): PurchaseQuestionCounts(
          total: deck.cards.length,
          free: deck.cards.where((card) => !card.isPremium).length,
        ),
    };
  }

  static PurchaseQuestionCounts combined(
    Iterable<PurchaseQuestionCounts> counts,
  ) {
    return PurchaseQuestionCounts(
      total: counts.fold(0, (sum, value) => sum + value.total),
      free: counts.fold(0, (sum, value) => sum + value.free),
    );
  }
}

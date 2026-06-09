// lib/services/iap_service.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';

import 'purchase_store.dart';

/// ストアに登録した productId と**完全一致**させること
class ProductCatalog {
  // App Store / Play Console の productId（s01_unlock など）と対になるデッキID本体
  // ※ deck_unit_master.csv / deck_sXX.json の deck id と一致させる
  static const deckIds = [
    's01',
    's02',
    's03',
    's04',
    's05',
    's06',
    's07',
    's08',
  ];

  // セット/全体/Pro
  static const bundle5 = 'bundle_5decks_unlock'; // ← SKU名は既存どおり
  static const bundleAll = 'bundle_all_unlock';
  static const pro = 'pro_upgrade';

  // まとめ
  static const bundles = [bundle5, bundleAll];
  static const specials = [pro];

  static Set<String> allProductIds() => {
        ...deckIds.map((d) => '${d}_unlock'),
        ...bundles,
        ...specials,
      };
}

class IapService with ChangeNotifier {
  IapService._internal();
  static final IapService _instance = IapService._internal();
  factory IapService() => _instance;

  final InAppPurchase _iap = InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _sub;
  static bool _initialized = false;

  /// 価格表示用（ProductDetails.id -> ProductDetails）
  final Map<String, ProductDetails> products = {};

  /// ストア接続/製品取得の可否
  bool available = false;
  bool get isReady => available && products.isNotEmpty;

  // ===== 所有状態（メモリキャッシュ） =====
  /// 例: {'s01', 's02', ...}  ※単体デッキ購入の所有状況
  final Set<String> _ownedDeckIds = <String>{};

  /// Pro フラグ
  bool _isPro = false;
  bool get isPro => _isPro;

  /// ★選べる5単元パックの所有フラグ（権利そのもの）
  bool _hasFivePack = false;
  bool get hasFivePack => _hasFivePack;

  /// 初期化：products取得 → 所有状態ロード → purchaseStream購読 →（Androidのみ）restorePurchases()
  Future<void> init() async {
    // すでに初期化済みでも、products が空 or 購買ストリーム未購読なら再初期化
    if (_initialized && products.isNotEmpty && _sub != null) {
      debugPrint('IAP init: reuse existing (already initialized)');
      return;
    }
    available = await _iap.isAvailable();
    debugPrint('IAP available: $available');
    if (!available) {
      debugPrint('❌ IAP not available (Play Store無効/端末非対応 or 非Playビルド)');
      // 利用不可でも“初期化済み扱い”にして以降の再初期化を抑制
      _initialized = true;
      return;
    }

    final ids = ProductCatalog.allProductIds();
    debugPrint('Querying products: $ids');

    final resp = await _iap.queryProductDetails(ids);

    if (resp.error != null) {
      debugPrint('❌ queryProductDetails error: ${resp.error}');
    }
    if (resp.notFoundIDs.isNotEmpty) {
      debugPrint(
        '❗ notFoundIDs: ${resp.notFoundIDs} '
        '(productId不一致/未公開/テスター外の可能性)',
      );
    }

    products
      ..clear()
      ..addEntries(resp.productDetails.map((p) => MapEntry(p.id, p)));
    debugPrint('✅ Loaded products: ${products.keys.toList()} (count=${products.length})');

    // 所有状態をローカルストアからロード（=即時UI反映の基礎）
    await _reloadOwnershipFromStore();

    // 先に購読を開始（以降の restore で流れてくるイベントを受ける）
    _sub?.cancel();
    _sub = _iap.purchaseStream.listen(
      _onUpdated,
      onError: (e) => debugPrint('purchaseStream error: $e'),
    );

    // ▼ 過去購入の再送をトリガ（Androidは自動呼び出しOK / iOSはユーザー起点が望ましい）
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _iap.restorePurchases();
      }
    } catch (e) {
      debugPrint('restorePurchases on init failed: $e');
    }
    _initialized = true; // ← ★これを正常系の最後に追加！
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// 指定 productId が isOwnedProduct=true になるまで待機（購買ストリーム反映を待つ）
  Future<bool> waitUntilOwned(String productId,
      {Duration timeout = const Duration(seconds: 8)}) async {
    // 即時チェック
    if (isOwnedProduct(productId)) return true;
    final completer = Completer<bool>();
    late VoidCallback listener;
    listener = () {
      if (isOwnedProduct(productId) && !completer.isCompleted) {
        removeListener(listener);
        completer.complete(true);
      }
    };
    addListener(listener);
    // タイムアウト監視
    Future.delayed(timeout, () {
      if (!completer.isCompleted) {
        removeListener(listener);
        completer.complete(false);
      }
    });
    return completer.future;
  }

  // ---- API: 購入/復元 ----
  Future<void> buy(String productId) async {
    final p = products[productId];
    if (!isReady) {
      throw StateError('Store not ready (isReady=false)');
    }
    if (p == null) {
      throw StateError('Product not loaded: $productId');
    }
    await _iap.buyNonConsumable(purchaseParam: PurchaseParam(productDetails: p));
  }

  Future<void> restore() async {
    // Android/iOS 共通：過去購入の再送をトリガ
    await _iap.restorePurchases();
  }

  // ---- 内部: ストアから所有状態をロード ----
  Future<void> _reloadOwnershipFromStore() async {
    _ownedDeckIds
      ..clear()
      ..addAll(await PurchaseStore.getOwnedDeckIds());
    _isPro = await PurchaseStore.getPro();
    _hasFivePack = await PurchaseStore.isFivePackOwned(); // ← UI即時反映用
    // ★ ここで未選択なら自動割り当てを実施（サイレント修復）
    await PurchaseStore.autoAssignFivePackIfOwnedAndEmpty();
    notifyListeners();
  }

  // ---- ストリーム処理 ----
  Future<void> _onUpdated(List<PurchaseDetails> list) async {
    for (final p in list) {
      debugPrint('purchase updated: id=${p.productID}, status=${p.status}');
      switch (p.status) {
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          try {
            await _grantEntitlement(p.productID);
          } catch (e) {
            debugPrint('grantEntitlement failed: $e');
          } finally {
            if (p.pendingCompletePurchase) {
              await _iap.completePurchase(p);
            }
          }
          break;

        case PurchaseStatus.error:
        case PurchaseStatus.canceled:
          if (p.pendingCompletePurchase) {
            await _iap.completePurchase(p);
          }
          break;

        case PurchaseStatus.pending:
          // UI 側でスピナー等を表示するなら busy を使う
          break;
      }
    }
  }

  // ---- 付与ロジック（将来サーバ検証に差し替え可） ----
  Future<void> _grantEntitlement(String productId) async {
    // Pro: 機能解放
    if (productId == ProductCatalog.pro) {
      await PurchaseStore.setPro(true);
      debugPrint('✔ grant: pro enabled');
      _isPro = true;
      notifyListeners(); // ← UI即時反映
      return;
    }

    // 全体パック（＝全デッキの単体所有に寄せる互換運用）
    if (productId == ProductCatalog.bundleAll) {
      await PurchaseStore.addOwnedDecks(ProductCatalog.deckIds);
      debugPrint('✔ grant: bundle_all -> all deckIds');
      _ownedDeckIds
        ..clear()
        ..addAll(ProductCatalog.deckIds);
      notifyListeners();
      return;
    }

    // ★ 5単元パック（選べる方式）
    // ここでは「権利の付与」のみを行う（選択はUI側）。
    // ※ Restore時（新端末等）にも権利を復元できるよう、ここで永続化する。
    if (productId == ProductCatalog.bundle5) {
      await PurchaseStore.setFivePackOwned(true);
      debugPrint('✔ grant: five-pack entitlement only (no auto assignment)');
      _hasFivePack = true;
      notifyListeners();
      return;
    }

    // 個別デッキ: deck_Xxx_unlock -> deck_Xxx
    if (productId.endsWith('_unlock')) {
      final deckId =
          productId.substring(0, productId.length - '_unlock'.length).toLowerCase(); // 念のため小文字正規化
      await PurchaseStore.addOwnedDecks([deckId]);
      debugPrint('✔ grant: single deck -> $deckId');
      _ownedDeckIds.add(deckId);
      notifyListeners();
    }
  }

  // ---- 所有判定API（UI用）：この productId は購入済みか？ ----
  bool isOwnedProduct(String productId) {
    if (productId == ProductCatalog.pro) return _isPro;

    if (productId == ProductCatalog.bundleAll) {
      // 全デッキ所有で bundle_all を「購入済み」扱い
      return ProductCatalog.deckIds.every(_ownedDeckIds.contains);
    }

    if (productId == ProductCatalog.bundle5) {
      // 新方式：5パックの「権利」を持っているかで判定
      // 互換：旧「先頭5デッキ所有」ユーザーにも配慮
      final legacyOwnedFirst5 = ProductCatalog.deckIds.take(5).every(_ownedDeckIds.contains);
      return _hasFivePack || legacyOwnedFirst5;
    }

    if (productId.endsWith('_unlock')) {
      final deckId = productId.substring(0, productId.length - '_unlock'.length).toLowerCase();
      return _ownedDeckIds.contains(deckId);
    }

    return false;
  }

  // ---- （任意）デバッグ/表示用：所有状況の要約 ----
  String ownedSummaryFor(String productId) {
    if (productId == ProductCatalog.pro) return _isPro ? 'Pro: 有効' : 'Pro: 無効';
    if (productId == ProductCatalog.bundleAll) {
      final owned = ProductCatalog.deckIds.where(_ownedDeckIds.contains).length;
      return '全解放: $owned/${ProductCatalog.deckIds.length} 所有';
    }
    if (productId == ProductCatalog.bundle5) {
      return _hasFivePack ? '5単元パック: 権利あり' : '5単元パック: 未所有';
    }
    if (productId.endsWith('_unlock')) {
      final deckId = productId.substring(0, productId.length - '_unlock'.length).toLowerCase();
      return _ownedDeckIds.contains(deckId) ? '$deckId: 所有' : '$deckId: 未所有';
    }
    return '不明';
  }
}

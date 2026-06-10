// lib/screens/purchase_screen.dart
import 'package:flutter/material.dart';
import '../services/iap_service.dart';
import '../services/purchase_store.dart';
import '../services/deck_loader.dart';

// ★ DEV向け Fake IAP フラグ（起動時に --dart-define=USE_FAKE_IAP=true）
const bool kUseFakeIap = bool.fromEnvironment('USE_FAKE_IAP', defaultValue: false);
const bool kShowFivePack = false;

// ★ Fake価格（検証用）
const Map<String, String> _kFakePrices = {
  'stat_pro_upgrade': '¥700',
  'stat_bundle_all_unlock': '¥1000',
  'bundle_5decks_unlock': '¥600',
  's01_unlock': '¥200',
  's02_unlock': '¥200',
  's03_unlock': '¥200',
  's04_unlock': '¥200',
  's05_unlock': '¥200',
  's06_unlock': '¥200',
  's07_unlock': '¥200',
  's08_unlock': '¥200',
};

class PurchaseScreen extends StatefulWidget {
  const PurchaseScreen({super.key});
  @override
  State<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends State<PurchaseScreen> {
  final iap = IapService();

  bool loading = true;
  bool busy = false;
  bool isProLegacy = false;
  Set<String> ownedLegacy = {};

  String? _pendingProductId;
  late final VoidCallback _iapListener;

  Map<String, List<String>> _deckUnitTitles = {};

  // ★ 追加：5パック選択デッキ（アクセス判定に使用）
  Set<String> _fivePackDecks = {};

  // ---- helpers ----
  String _priceOf(String productId) {
    if (kUseFakeIap) return _kFakePrices[productId] ?? '¥---';
    return iap.products[productId]?.price ?? '';
  }

  // ★ 単元の所有判定：Proは含めず、個別購入デッキのみ
  //bool _ownedDeckLegacy(String deckId) => ownedLegacy.contains(deckId);

  // ★ アクセス可能：個別購入 ∨ 5単元パック選択デッキ（Proは含めない）
  bool _isDeckAccessible(String deckId) {
    final id = deckId.toLowerCase();
    return ownedLegacy.contains(id) || _fivePackDecks.contains(id);
  }

  String _safePrice(String productId) {
    final p = _priceOf(productId);
    return p.isEmpty ? '…' : p;
  }

  Widget _purchasedChip() => const Chip(
        avatar: Icon(Icons.check_circle, size: 18, color: Colors.green),
        label: Text('購入済み', style: TextStyle(fontWeight: FontWeight.w600)),
      );

  String? _unitPreview(List<String> units) {
    if (units.isEmpty) return null;
    const max = 5;
    final shown = units.take(max).toList();
    final rest = units.length - shown.length;
    final base = shown.join('／');
    return rest > 0 ? '$base／+$rest件' : base;
  }

  Widget _buyButton(String productId) {
    final busyThis = busy && _pendingProductId == productId;
    final hasPrice = _priceOf(productId).isNotEmpty;
    return ElevatedButton(
      onPressed: (!busy && _pendingProductId == null && hasPrice) ? () => _buy(productId) : null,
      child: busyThis
          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
          : const Text('購入'),
    );
  }

  @override
  void initState() {
    super.initState();
    _iapListener = () {
      if (mounted) setState(() {});
    };
    iap.addListener(_iapListener);
    _boot();
  }

  Future<void> _boot() async {
    try {
      if (!kUseFakeIap) {
        await iap.init();
      }
      // ★ 所有済みなのに未選択が空なら自動で埋める（サイレント）
      await PurchaseStore.autoAssignFivePackIfOwnedAndEmpty();

      isProLegacy = await PurchaseStore.getPro();
      ownedLegacy = (await PurchaseStore.getOwnedDeckIds()).toSet();
      _fivePackDecks = await PurchaseStore.getFivePackDecks(); // ★ 追加：初期ロード

      final loader = await DeckLoader.instance();
      const assetDeckIds = [
        's01',
        's02',
        's03',
        's04',
        's05',
        's06',
        's07',
        's08',
      ];
      final metaMap = await loader.unitTitlesFor(assetDeckIds);
      _deckUnitTitles = {
        for (final e in metaMap.entries) e.key.toLowerCase(): e.value,
      };
    } catch (e) {
      // 起動時の一時的な失敗は“静音化”し、ログのみにする
      debugPrint('IAP init (boot) warning: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    iap.removeListener(_iapListener);
    super.dispose();
  }

  Future<void> _refreshOwnedLegacy() async {
    isProLegacy = await PurchaseStore.getPro();
    ownedLegacy = (await PurchaseStore.getOwnedDeckIds()).toSet();
    _fivePackDecks = await PurchaseStore.getFivePackDecks(); // ★ 追加：状態更新時にも取得
    if (mounted) setState(() {});
  }

  // ▼▼▼ 実ストア or Fake を吸収する共通ヘルパー ▼▼▼
  Future<bool> _buySkuAndVerify(String sku) async {
    setState(() {
      busy = true;
      _pendingProductId = sku;
    });
    try {
      if (kUseFakeIap) {
        // —— Fake 決済UI ——
        final ok = await _showFakeCheckout(sku);
        if (!ok) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('購入は完了していません（キャンセルまたは未確定）')),
            );
          }
          return false;
        }
        // Fake: 付与（権利/所有）をローカルで確定
        await _grantLocally(sku);
        await _refreshOwnedLegacy();
        return true;
      } else {
        await iap.buy(sku);
        // ★ ストリーム反映を確実に待つ
        final ok = await iap.waitUntilOwned(sku);
        await _refreshOwnedLegacy();
        if (!ok && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('購入は完了していません（キャンセルまたは未確定）')),
          );
        }
        return ok;
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('購入に失敗しました: $e')),
        );
      }
      return false;
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          _pendingProductId = null;
        });
      }
    }
  }
  // ▲▲▲ 共通ヘルパーここまで ▲▲▲

  // 通常商品の購入（Pro/全解放/単体）
  Future<void> _buy(String productId) async {
    setState(() {
      busy = true;
      _pendingProductId = productId;
    });

    try {
      if (kUseFakeIap) {
        final ok = await _showFakeCheckout(productId);
        if (!ok) return;
        await _grantLocally(productId);
        await _refreshOwnedLegacy();

        if (!mounted) return;
        final unlocked = _successText(productId);
        await _showSuccessDialog(unlocked);
        Navigator.of(context).pop(true);
      } else {
        await iap.buy(productId);
        // ★ 実ストアでも反映を待つ
        final ok = await iap.waitUntilOwned(productId);
        await _refreshOwnedLegacy();

        if (!mounted) return;

        if (ok || iap.isOwnedProduct(productId)) {
          final unlocked = _successText(productId);
          await _showSuccessDialog(unlocked);
          // ★ 成功時は Home に更新を伝える
          Navigator.of(context).pop(true);
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('購入に失敗しました: $e')));
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          _pendingProductId = null;
        });
      }
    }
  }

  String _successText(String productId) {
    if (productId == 'stat_bundle_all_unlock') return '全単元が解放されました';
    if (productId == 'bundle_5decks_unlock') return '5単元パックが解放されました';
    if (productId == 'stat_pro_upgrade') return 'Pro機能が有効になりました';
    if (productId.endsWith('_unlock')) return '対象の単元が解放されました';
    return '購入が反映されました';
  }

  Future<void> _showSuccessDialog(String message) {
    return showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('購入が完了しました'),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
        ],
      ),
    );
  }

  // —— Fake 決済ダイアログ —— //
  Future<bool> _showFakeCheckout(String sku) async {
    final price = _safePrice(sku);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('テスト決済（Fake）'),
        content: Text('商品: $sku\n金額: $price\n\nこの内容で決済を完了しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('キャンセル')),
          ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true), child: const Text('決済完了する')),
        ],
      ),
    );
    return ok == true;
  }

  // —— Fake: ローカル付与ロジック —— //
  Future<void> _grantLocally(String productId) async {
    if (productId == 'stat_pro_upgrade') {
      await PurchaseStore.setPro(true);
      return;
    }
    if (productId == 'stat_bundle_all_unlock') {
      await PurchaseStore.addOwnedDecks([
        's01',
        's02',
        's03',
        's04',
        's05',
        's06',
        's07',
        's08',
      ]);
      return;
    }
    if (productId == 'bundle_5decks_unlock') {
      await PurchaseStore.setFivePackOwned(true);
      return;
    }
    if (productId.endsWith('_unlock')) {
      final deckId = productId.substring(0, productId.length - '_unlock'.length).toLowerCase();
      await PurchaseStore.addOwnedDecks([deckId]);
      return;
    }
  }

  Future<void> _restore() async {
    setState(() {
      busy = true;
      _pendingProductId = null;
    });
    try {
      if (kUseFakeIap) {
        await _refreshOwnedLegacy();
      } else {
        await iap.restore();
        await _refreshOwnedLegacy();
      }
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('復元が完了しました'),
          content: const Text('過去の購入が反映されました。'),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('復元に失敗しました: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // デッキ選択ダイアログ（候補＝未購入デッキのみ／確定条件＝選択数==max）
  // ─────────────────────────────────────────────────────────────
  Future<Set<String>?> _openFiveDeckSelectorFiltered() async {
    final loader = await DeckLoader.instance();
    final decks = await loader.loadAll();
    final owned = (await PurchaseStore.getOwnedDeckIds()).map((e) => e.toLowerCase()).toSet();

    final available = <Map<String, String>>[];
    for (final d in decks) {
      final dyn = d as dynamic;
      final id = (dyn.id as String).toLowerCase();
      if (!owned.contains(id)) {
        available.add({'id': id, 'title': (dyn.title as String? ?? id.toUpperCase())});
      }
    }

    if (available.isEmpty || !mounted) return null;

    final ownedCount = owned.length;
    if (ownedCount >= 4 && ownedCount <= 7) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('ご確認'),
          content: const Text('すでに複数の単元を購入済みのため、5単元パックを最大限に利用できません。よろしいですか？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false), child: const Text('キャンセル')),
            TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('OK')),
          ],
        ),
      );
      if (ok != true) return null;
    }

    final int maxSelect = available.length < 5 ? available.length : 5;
    final working = <String>{};
    return showDialog<Set<String>>(
      context: context,
      builder: (context) {
        return StatefulBuilder(builder: (context, setSt) {
          final remain = (maxSelect - working.length).clamp(0, 999);
          final canConfirm = working.length == maxSelect; // ★ 0件/1〜2件は確定不可
          return AlertDialog(
            title: Text('単元を選択（${working.length}/$maxSelect）'),
            content: SizedBox(
              width: double.maxFinite,
              height: 420,
              child: ListView.builder(
                itemCount: available.length,
                itemBuilder: (_, i) {
                  final id = available[i]['id']!;
                  final title = available[i]['title']!;
                  final checked = working.contains(id);
                  final disabled = !checked && remain <= 0;
                  return CheckboxListTile(
                    value: checked,
                    onChanged: disabled
                        ? null
                        : (v) {
                            setSt(() {
                              if (checked) {
                                working.remove(id);
                              } else if (working.length < maxSelect) {
                                working.add(id);
                              }
                            });
                          },
                    title: Text(title),
                    subtitle: _deckUnitTitles[id] != null
                        ? Text(
                            '単元構成：${_unitPreview(_deckUnitTitles[id]!) ?? ''}',
                            style: const TextStyle(fontSize: 12),
                          )
                        : null,
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, null),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: canConfirm ? () => Navigator.pop(context, working) : null,
                child: const Text('確定'),
              ),
            ],
          );
        });
      },
    );
  }

  // 5単元パックの購入フロー（選択→IAP→保存）※キャンセル時は保存しない
  Future<void> _buyFivePackWithSelection() async {
    // 1) 候補から選ばせる（未購入のみ／選択数==maxで確定可）
    final picked = await _openFiveDeckSelectorFiltered();
    if (picked == null || picked.isEmpty) return;

    // 2) 課金実行
    setState(() {
      busy = true;
      _pendingProductId = 'bundle_5decks_unlock';
    });
    bool ok = false;
    try {
      if (kUseFakeIap) {
        await PurchaseStore.setFivePackOwned(true);
        ok = true;
      } else {
        await iap.buy('bundle_5decks_unlock');
        ok = await iap.waitUntilOwned('bundle_5decks_unlock');
      }
    } finally {
      // busy は最後に解除
    }
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('購入の反映を確認できませんでした')),
        );
      }
      setState(() {
        busy = false;
        _pendingProductId = null;
      });
      return;
    }

    // 3) IAP成功時のみ保存・権利付与（Fake/Real共通の整合点）
    await PurchaseStore.setFivePackDecks(picked);
    await PurchaseStore.setFivePackOwned(true);

    // ★ 5パック選択デッキを最新化してUI反映
    _fivePackDecks = await PurchaseStore.getFivePackDecks();

    if (!mounted) return;
    await _showSuccessDialog('選択した単元が解放されました。');
    // ★ Home に更新を伝える（購入画面を閉じる）
    Navigator.of(context).pop(true);
    setState(() {}); // 念のため（戻らずに残った場合にも表示更新）
    setState(() {
      busy = false;
      _pendingProductId = null;
    });
  }

  // 単元タイル（個別デッキ）
  ListTile _deckTile({required String deckId, required String title}) {
    final productId = '${deckId}_unlock';
    // ★ アクセス可否で「購入済み」を判定（個別所有/Pro ∪ 5パック選択）
    final bought = _isDeckAccessible(deckId);
    final price = _safePrice(productId);

    final titleRow = Row(
      children: [
        Expanded(child: Text(title)),
        if (bought) _purchasedChip(),
      ],
    );

    final isBusyThis = busy && _pendingProductId == productId;

    final unitLine = _unitPreview(_deckUnitTitles[deckId] ?? const []);
    final subtitle = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(bought ? '購入済' : price),
        if (unitLine != null) ...[
          const SizedBox(height: 2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 4),
                child: Icon(Icons.menu_book, size: 14),
              ),
              Expanded(
                child: Text('単元構成：$unitLine', style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ],
      ],
    );

    return ListTile(
      leading: Icon(bought ? Icons.lock_open : Icons.lock_outline),
      title: titleRow,
      subtitle: subtitle,
      // ★ アクセス可能なら購入ボタンは出さない
      trailing: (bought || isBusyThis) ? null : _buyButton(productId),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final owned5 = iap.isOwnedProduct('bundle_5decks_unlock');
    final ownedAll = iap.isOwnedProduct('stat_bundle_all_unlock');
    final ownedPro = iap.isOwnedProduct('stat_pro_upgrade') || isProLegacy;

    // ★ 全デッキのアクセシビリティを算出（個別所有/Pro ∪ 5パック選択）
    const allDeckIds = [
      's01',
      's02',
      's03',
      's04',
      's05',
      's06',
      's07',
      's08',
    ];
    final accessibleCount = allDeckIds.where(_isDeckAccessible).length;
    final allAccessible = accessibleCount == allDeckIds.length;

    return Scaffold(
      appBar: AppBar(title: Text('購入${kUseFakeIap ? '（テストモード）' : ''}')),
      body: Stack(
        children: [
          ListView(
            children: [
              const ListTile(title: Text('アプリ内購入')),

              // 単元（デッキ）
              _deckTile(deckId: 's01', title: 'データの要約（記述統計）'),
              _deckTile(deckId: 's02', title: 'データ間の関係'),
              _deckTile(deckId: 's03', title: '確率'),
              _deckTile(deckId: 's04', title: '確率分布'),
              _deckTile(deckId: 's05', title: '標本分布'),
              _deckTile(deckId: 's06', title: '推定'),
              _deckTile(deckId: 's07', title: '仮説検定'),
              _deckTile(deckId: 's08', title: '線形モデルと実験'),

              if (kShowFivePack) ...[
                const Divider(),

                // 5単元パック（状態付き表示）
                FutureBuilder<bool>(
                future: PurchaseStore.isFivePackOwned(),
                builder: (context, snap) {
                  final fiveOwned = (snap.data ?? false) || owned5;
                  return ListTile(
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: Row(
                      children: [
                        const Expanded(child: Text('選べる5単元パック')),
                        if (fiveOwned) _purchasedChip(),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(fiveOwned ? '購入済' : _safePrice('bundle_5decks_unlock')),
                        const SizedBox(height: 2),
                        if (!fiveOwned)
                          const Text(
                            '未解放単元から5つを選んでお得に購入できます。',
                            style: TextStyle(fontSize: 12),
                          ),
                      ],
                    ),
                    onTap: null,
                  );
                },
              ),

              // 未所有時：1ボタン（選択して購入）。未購入デッキが0なら無効化。
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: FutureBuilder<bool>(
                  future: PurchaseStore.isFivePackOwned(),
                  builder: (context, snap) {
                    final fiveOwned = (snap.data ?? false) || owned5;
                    if (fiveOwned) {
                      return const SizedBox.shrink();
                    }

                    return FutureBuilder<Set<String>>(
                      future: PurchaseStore.getOwnedDeckIds(),
                      builder: (context, ownedSnap) {
                        final ownedDecks =
                            (ownedSnap.data ?? <String>{}).map((e) => e.toLowerCase()).toSet();
                        return FutureBuilder<List<dynamic>>(
                          future: DeckLoader.instance().then((l) => l.loadAll()),
                          builder: (context, decksSnap) {
                            final allDecks = (decksSnap.data ?? []);
                            final total = allDecks.length;
                            final available = total - ownedDecks.length; // 未購入数
                            final hasPrice = _priceOf('bundle_5decks_unlock').isNotEmpty;
                            final enabled = !busy && hasPrice && available > 0;

                            return SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: enabled ? _buyFivePackWithSelection : null,
                                child: const Text('選択して購入'),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),

                const Divider(),
              ],

              // 全単元フル解放（表示判定は「全解放SKU購入」or「個別/5パックで全デッキ解放済」）
              Builder(
                builder: (context) {
                  const allDeckIds = [
                    's01',
                    's02',
                    's03',
                    's04',
                    's05',
                    's06',
                    's07',
                    's08',
                  ];

                  // 個別購入 ∪ 5パック選択で全デッキをカバーしているか（Proは含めない）
                  final combined = {...ownedLegacy, ..._fivePackDecks};
                  final allCoveredByDecks = allDeckIds.every(combined.contains);

                  // SKUとしての全解放購入
                  final ownedAllSku = ownedAll;

                  return ListTile(
                    leading: const Icon(Icons.school_outlined),
                    title: Row(
                      children: [
                        const Expanded(child: Text('全単元フル解放（学び放題）')),
                        // ✅ チップは「SKU購入済み」のときだけ出す
                        if (ownedAllSku) _purchasedChip(),
                      ],
                    ),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(ownedAll
                            ? '購入済'
                            : (allCoveredByDecks
                                ? 'すべて解放済（購入不要）'
                                : _safePrice('stat_bundle_all_unlock'))),
                        const SizedBox(height: 2),
                        const Text(
                          'すべての単元が勉強し放題。',
                          style: TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 2),
                        // ★ 買いたくなる1行コピー（お好みで調整OK）
                        const Text(
                          '制限ゼロ。迷わず最短で力がつく“学び放題”。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),

                    // ボタンは SKU購入済 or 積み上げで全解放済 なら非表示
                    trailing: (ownedAllSku ||
                            allCoveredByDecks ||
                            (busy && _pendingProductId == 'stat_bundle_all_unlock'))
                        ? null
                        : _buyButton('stat_bundle_all_unlock'),
                  );
                },
              ),

              const Divider(),

              // Pro アップグレード
              ListTile(
                leading: Icon(
                  ownedPro ? Icons.workspace_premium : Icons.workspace_premium_outlined,
                ),
                title: Row(
                  children: [
                    Expanded(child: Text(ownedPro ? 'Pro機能 有効' : 'Pro機能')),
                    if (ownedPro) _purchasedChip(),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ownedPro ? '購入済' : _safePrice('stat_pro_upgrade')),
                    const SizedBox(height: 4),
                    const Text(
                      '間違えた問題を効率よく復習するための機能を解放します。',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    const Text('・見直しモード', style: TextStyle(fontSize: 12)),
                    const Text('・復習テストモード', style: TextStyle(fontSize: 12)),
                    const Text('・復習リマインダー', style: TextStyle(fontSize: 12)),
                  ],
                ),
                trailing: (ownedPro || (busy && _pendingProductId == 'stat_pro_upgrade'))
                    ? null
                    : _buyButton('stat_pro_upgrade'),
              ),

              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: busy ? null : _restore,
                  icon: const Icon(Icons.restore),
                  label: const Text('購入を復元'),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
          if (busy && _pendingProductId == null)
            Container(
              color: Colors.black.withOpacity(0.04),
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }
}

// lib/screens/licenses_and_credits_screen.dart
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class LicensesAndCreditsScreen extends StatelessWidget {
  const LicensesAndCreditsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ライセンス／クレジット')),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snap) {
          final ver = snap.hasData
              ? 'v${snap.data!.version}（build ${snap.data!.buildNumber}）'
              : '取得中…';
          return ListView(
            children: [
              ListTile(
                leading: const Icon(Icons.description),
                title: const Text('オープンソースライセンス'),
                subtitle: Text('アプリ：統計検定2級 一問一答 / $ver'),
                onTap: () => showLicensePage(
                  context: context,
                  applicationName: '統計検定2級 一問一答',
                  applicationVersion: snap.hasData
                      ? 'v${snap.data!.version}（build ${snap.data!.buildNumber}）'
                      : null,
                  applicationLegalese: '© 2025 もけけapp',
                ),
              ),
              const Divider(height: 1),
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  '【制作】もけけapp\n'
                  '【使用ツール】Flutter / Dart / Figma / Canva ほか\n'
                  '【フォント】Noto Sans JP — OFL 1.1\n'
                  '【アイコン/画像】Material Icons — Apache-2.0\n'
                  'Canvaで作成したデザイン素材を一部使用しています。\n'
                  '（必要に応じて追記）',
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

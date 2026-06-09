// lib/app_config.dart

/// アプリの実行環境フレーバー
enum AppEnv { dev, qa, prod }

class AppConfig {
  // Flutter 実行時に渡す: --dart-define=FLAVOR=prod
  static const _envStr = String.fromEnvironment('FLAVOR', defaultValue: 'prod');

  static const env = _envStr == 'prod'
      ? AppEnv.prod
      : _envStr == 'qa'
      ? AppEnv.qa
      : AppEnv.dev;

  /// デバッグUI（課金切替ボタンなど）を表示するか
  static bool get purchaseDebug => env == AppEnv.dev;

  /// 詳細ログを出すか
  static bool get verboseLog => env != AppEnv.prod;

  /// ソフトゲートをバイパスできるか（dev限定）
  static bool get allowSoftGateOverride => env == AppEnv.dev;

  /// 表示用アプリタイトル（AppBarや MaterialApp.title に使用）
  static String get appTitle {
    switch (env) {
      case AppEnv.dev:
        return '統計検定2級対策（DEV）';
      case AppEnv.qa:
        return '統計検定2級対策（QA）';
      case AppEnv.prod:
        return '統計検定2級 一問一答';
    }
  }

  /// ログ出力などで環境名を文字列で欲しい場合
  static String get name => _envStr;
}

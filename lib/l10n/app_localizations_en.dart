// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Makay File Manager';

  @override
  String get settingsTitle => 'Settings';

  @override
  String get vaultTitle => 'Vault';

  @override
  String get networkAccessTitle => 'Network access';

  @override
  String get cloudAdvancedTitle => 'Cloud connections';

  @override
  String get continueAction => 'Continue';

  @override
  String get cancelAction => 'Cancel';
}

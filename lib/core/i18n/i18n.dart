import 'package:flutter/widgets.dart';

/// UI languages. Arabic (RTL) is the default; English is LTR.
enum AppLanguage {
  ar,
  en;

  Locale get locale => Locale(name);
  TextDirection get direction =>
      this == AppLanguage.ar ? TextDirection.rtl : TextDirection.ltr;

  static AppLanguage fromName(Object? name) =>
      values.asNameMap()[name] ?? AppLanguage.ar;
}

/// Current UI language. Set by the app root from the user's settings; read
/// by [tr] everywhere (including non-widget code such as failure messages).
abstract final class I18n {
  static AppLanguage current = AppLanguage.ar;
  static bool get isEnglish => current == AppLanguage.en;

  /// Rebuilds every widget under [context] after a language change, so
  /// strings computed by [tr] in build methods refresh.
  static void rebuildAll(BuildContext context) {
    void mark(Element e) {
      e.markNeedsBuild();
      e.visitChildren(mark);
    }

    (context as Element).visitChildren(mark);
  }
}

/// Picks the string for the current language. Both variants live next to
/// each other at the call site, so a missing translation is impossible.
String tr(String ar, String en) => I18n.current == AppLanguage.en ? en : ar;

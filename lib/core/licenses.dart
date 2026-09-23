import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Adds bundled non-package content to Flutter's license page (About →
/// Open-source licenses). Packages register their own licenses.
void registerThirdPartyLicenses() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'IBM Plex Sans Arabic',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['The Block List Project (bundled domain lists)'],
      'Gambling, porn and drugs domain lists from '
      'https://github.com/blocklistproject/Lists, converted to hashed '
      'form. Repository licence: The Unlicense (public domain '
      'dedication); list file headers state the MIT License. The lists '
      'aggregate upstream sources automatically and may contain errors.',
    );
  });
}

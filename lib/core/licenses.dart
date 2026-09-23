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
  LicenseRegistry.addLicense(() async* {
    yield const LicenseEntryWithLineBreaks(
      ['nsfw_model (bundled image model, MobileNetV2 v1.1.0)'],
      'https://github.com/GantMan/nsfw_model — saved_model.tflite from '
      'release 1.1.0, unmodified.\n\n'
      'MIT License\n\n'
      'Copyright (c) 2020 The nsfw_model Developers\n\n'
      'Permission is hereby granted, free of charge, to any person obtaining a '
      'copy of this software and associated documentation files (the '
      '"Software"), to deal in the Software without restriction, including '
      'without limitation the rights to use, copy, modify, merge, publish, '
      'distribute, sublicense, and/or sell copies of the Software, and to '
      'permit persons to whom the Software is furnished to do so, subject to '
      'the following conditions:\n\n'
      'The above copyright notice and this permission notice shall be '
      'included in all copies or substantial portions of the Software.\n\n'
      'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, '
      'EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF '
      'MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND '
      'NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE '
      'LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION '
      'OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION '
      'WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.',
    );
  });
}

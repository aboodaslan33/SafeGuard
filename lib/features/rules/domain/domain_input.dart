/// Client-side validation for domains typed by the user.
///
/// Mirrors the native `DomainName.parseRuleDomain` so the user gets instant
/// feedback; the native side re-validates and is the authority (it also
/// converts internationalised names to punycode).
abstract final class DomainInput {
  static final _label = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
  static final _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');

  /// Normalised domain, or null if [input] clearly isn't one.
  static String? normalize(String input) {
    var s = input.trim();
    if (s.isEmpty || s.length > 2048) return null;
    final scheme = s.indexOf('://');
    if (scheme >= 0) s = s.substring(scheme + 3);
    s = s.split(RegExp(r'[/?#]')).first;
    if (s.contains('@')) s = s.substring(s.lastIndexOf('@') + 1);
    if (s.startsWith('[')) return null;
    s = s.split(':').first.toLowerCase();
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    if (s.startsWith('www.')) s = s.substring(4);
    if (s.isEmpty || s.length > 253 || _ipv4.hasMatch(s)) return null;

    // Non-ASCII (e.g. Arabic IDN): leave the conversion to the native side.
    final ascii = s.codeUnits.every((c) => c < 128);
    final labels = s.split('.');
    if (labels.length < 2 || labels.any((l) => l.isEmpty)) return null;
    if (ascii) {
      if (!labels.every(_label.hasMatch)) return null;
      if (RegExp(r'^\d+$').hasMatch(labels.last)) return null;
    }
    return s;
  }
}

import '../../diagnostics/domain/diagnostic_report.dart';
import '../../protection/domain/protection.dart';

enum FeedbackType {
  falsePositive('false_positive'),
  missedContent('missed_content'),
  technicalProblem('technical_problem');

  const FeedbackType(this.id);
  final String id;

  static FeedbackType fromId(String? id) =>
      values.firstWhere((t) => t.id == id, orElse: () => technicalProblem);
}

/// What the user chose to send. Nothing is attached automatically: no
/// domain, URL, search text, screenshot or log. The description is only
/// what the user typed; diagnostics only if they tick the box.
class FeedbackDraft {
  const FeedbackDraft({
    required this.type,
    this.category,
    this.source,
    this.description = '',
    this.includeDiagnostics = false,
  });

  final FeedbackType type;
  final ProtectionCategory? category;
  final EventSourceKind? source;
  final String description;
  final bool includeDiagnostics;

  static const maxDescription = 500;

  FeedbackDraft copyWith({
    FeedbackType? type,
    ProtectionCategory? category,
    bool clearCategory = false,
    EventSourceKind? source,
    bool clearSource = false,
    String? description,
    bool? includeDiagnostics,
  }) => FeedbackDraft(
    type: type ?? this.type,
    category: clearCategory ? null : category ?? this.category,
    source: clearSource ? null : source ?? this.source,
    description: description ?? this.description,
    includeDiagnostics: includeDiagnostics ?? this.includeDiagnostics,
  );

  /// The exact text the user sees in the preview and copies or saves.
  String toText({
    required String appVersion,
    required String flavor,
    DiagnosticReport? diagnostics,
  }) {
    final text = description.trim();
    final b = StringBuffer()
      ..writeln('SafeGuard feedback')
      ..writeln('type: ${type.id}')
      ..writeln('app: $appVersion ($flavor)');
    if (category != null) b.writeln('category: ${category!.id}');
    if (source != null) b.writeln('source: ${source!.name}');
    if (text.isNotEmpty) {
      b
        ..writeln('description:')
        ..writeln(
          text.length > maxDescription
              ? text.substring(0, maxDescription)
              : text,
        );
    }
    if (includeDiagnostics && diagnostics != null) {
      b
        ..writeln()
        ..write(diagnostics.toText());
    }
    return b.toString().trimRight();
  }
}

/// Hints shown when the description looks like it contains something the
/// user may not want to share (a link, an email, a long number).
List<String> sensitiveHints(String text) {
  final hints = <String>[];
  if (RegExp(r'https?://|www\.', caseSensitive: false).hasMatch(text)) {
    hints.add('link');
  }
  if (RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+').hasMatch(text)) hints.add('email');
  if (RegExp(r'\d{6,}').hasMatch(text)) hints.add('number');
  return hints;
}

import '../../../core/i18n/i18n.dart';
import 'protection.dart';

/// AI Content Shield state, as reported by the native side. Mirrors
/// `ShieldState` in engine/shield/ContentShield.kt.
enum ShieldState {
  /// The user hasn't turned the shield on.
  off('off'),

  /// Text and image classification both running.
  active('active'),

  /// Running, but not every content type is covered (e.g. no image model).
  partial('partial'),

  /// Turned on, but nothing is actually being inspected.
  unavailable('unavailable');

  const ShieldState(this.id);
  final String id;

  static ShieldState fromId(Object? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return unavailable;
  }

  String get label => switch (this) {
    off => tr('متوقف', 'Off'),
    active => tr('يعمل', 'Active'),
    partial => tr('يعمل جزئيًا', 'Partially active'),
    unavailable => tr('غير متاح', 'Unavailable'),
  };
}

/// Why the shield isn't fully active. Mirrors `ShieldIssue`.
enum ShieldIssue {
  protectionOff('protection_off'),
  aiDisabled('ai_disabled'),
  accessibilityOff('accessibility_off'),
  accessibilityUnavailable('accessibility_unavailable'),
  noApps('no_apps'),
  textModelUnavailable('text_model_unavailable'),
  imageModelUnavailable('image_model_unavailable'),
  inferenceSlow('inference_slow');

  const ShieldIssue(this.id);
  final String id;

  static ShieldIssue? fromId(Object? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return null;
  }

  String get message => switch (this) {
    protectionOff => tr(
      'الحماية متوقفة أو مؤقتًا معطّلة، فلا يُفحص أي محتوى.',
      'Protection is off or paused, so no content is checked.',
    ),
    aiDisabled => tr(
      'الحماية الذكية متوقفة في إعداداتك.',
      'AI protection is turned off in your settings.',
    ),
    accessibilityOff => tr(
      'خدمة «درع المحتوى الذكي» غير مفعّلة في إعدادات تسهيل الاستخدام.',
      'The “AI Content Shield” service is off in Accessibility settings.',
    ),
    accessibilityUnavailable => tr(
      'هذا الجهاز لا يسمح بخدمات تسهيل الاستخدام لـ SafeGuard.',
      "This device doesn't allow SafeGuard's accessibility services.",
    ),
    noApps => tr(
      'لم يبقَ أي تطبيق مدعوم مفعّلًا.',
      'No supported app is left on.',
    ),
    textModelUnavailable => tr(
      'نموذج النصوص غير متاح حاليًا.',
      'The text model is unavailable right now.',
    ),
    imageModelUnavailable => tr(
      'لا يوجد نموذج صور في هذا الإصدار: الصور والفيديو لا تُفحص.',
      'No image model in this version: images and video are not checked.',
    ),
    inferenceSlow => tr(
      'التحليل بطيء على هذا الجهاز، فأُوقف مؤقتًا.',
      'Analysis is too slow on this device, so it is paused for now.',
    ),
  };
}

/// Why image classification can't run. Mirrors `ImageModelState`.
enum ImageModelState {
  notBundled('not_bundled'),
  noRuntime('no_runtime'),
  corrupted('corrupted'),
  loadFailed('load_failed'),
  outOfMemory('out_of_memory'),
  ready('ready'),
  notLoaded('not_loaded');

  const ImageModelState(this.id);
  final String id;

  static ImageModelState fromId(Object? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return notBundled;
  }

  bool get usable => this == ready || this == notLoaded;

  String get label => switch (this) {
    notBundled => tr(
      'غير مضمَّن في هذا الإصدار',
      'Not included in this version',
    ),
    noRuntime => tr('لا يوجد محرك تشغيل', 'No runtime available'),
    corrupted => tr('الملف تالف أو غير موثوق', 'File damaged or not trusted'),
    loadFailed => tr('تعذّر التحميل', "Couldn't load"),
    outOfMemory => tr('الذاكرة غير كافية', 'Not enough memory'),
    ready => tr('جاهز', 'Ready'),
    notLoaded => tr('جاهز (يُحمَّل عند الحاجة)', 'Ready (loads when needed)'),
  };
}

/// What SafeGuard expects to be able to read in an app. Mirrors `SupportLevel`.
enum ShieldSupportLevel {
  text('text'),
  textLimited('text_limited');

  const ShieldSupportLevel(this.id);
  final String id;

  static ShieldSupportLevel fromId(Object? id) =>
      id == 'text' ? text : textLimited;

  String get label => switch (this) {
    text => tr('نصوص الصفحات والمنشورات', 'Page and post text'),
    textLimited => tr(
      'نصوص محدودة (عناوين ووصف)',
      'Limited text (titles and captions)',
    ),
  };
}

/// Known reasons content may be missed. Mirrors `ShieldLimitation`.
enum ShieldLimitation {
  imagesNeedModel('images_need_model'),
  mostlyVideo('mostly_video'),
  customRendering('custom_rendering'),
  secureSurfaces('secure_surfaces'),
  uiChanges('ui_changes'),
  privateMessagesVisible('private_messages_visible');

  const ShieldLimitation(this.id);
  final String id;

  static ShieldLimitation? fromId(Object? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return null;
  }

  String get message => switch (this) {
    imagesNeedModel => tr(
      'الصور والفيديو لا تُفحص (لا يوجد نموذج صور).',
      "Photos and video aren't checked (no image model).",
    ),
    mostlyVideo => tr(
      'معظم المحتوى فيديو؛ يُفحص نص العناوين والوصف فقط.',
      'Mostly video; only titles and captions are checked.',
    ),
    customRendering => tr(
      'قد لا يُظهر التطبيق بعض النصوص لخدمات تسهيل الاستخدام.',
      'The app may not expose some text to accessibility services.',
    ),
    secureSurfaces => tr(
      'الشاشات المحمية في التطبيق لا يمكن قراءتها.',
      "Screens the app marks as secure can't be read.",
    ),
    uiChanges => tr(
      'قد تغيّر تحديثات التطبيق ما يمكن قراءته في أي وقت.',
      'App updates can change what can be read at any time.',
    ),
    privateMessagesVisible => tr(
      'الرسائل الظاهرة على الشاشة تُفحص في الذاكرة مثل أي نص، ولا تُخزَّن.',
      "Messages shown on screen are checked in memory like any text, and aren't stored.",
    ),
  };
}

class ShieldApp {
  const ShieldApp({
    required this.key,
    required this.name,
    required this.packages,
    required this.level,
    required this.limitations,
    required this.enabled,
    required this.installed,
    required this.verifiedOnDevice,
  });

  final String key;
  final String name;
  final List<String> packages;
  final ShieldSupportLevel level;
  final List<ShieldLimitation> limitations;
  final bool enabled;
  final bool installed;

  /// True only after a real-device test run (docs/FINAL_AI_TESTING.md).
  final bool verifiedOnDevice;

  static ShieldApp? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final name = raw['name'];
    if (key is! String || name is! String) return null;
    return ShieldApp(
      key: key,
      name: name,
      packages: [
        for (final p in (raw['packages'] as List?) ?? const [])
          if (p is String) p,
      ],
      level: ShieldSupportLevel.fromId(raw['level']),
      limitations: [
        for (final l in (raw['limitations'] as List?) ?? const [])
          ?ShieldLimitation.fromId(l),
      ],
      enabled: raw['enabled'] != false,
      installed: raw['installed'] == true,
      verifiedOnDevice: raw['verifiedOnDevice'] == true,
    );
  }
}

class ShieldStatus {
  const ShieldStatus({
    required this.enabled,
    required this.state,
    required this.issues,
    required this.textActive,
    required this.imageActive,
    required this.accessibility,
    required this.textModel,
    required this.textModelAvailable,
    required this.imageModelState,
    required this.apps,
  });

  /// The user turned the shield on.
  final bool enabled;
  final ShieldState state;
  final List<ShieldIssue> issues;
  final bool textActive;
  final bool imageActive;

  /// State of the shield's own accessibility service.
  final AccessibilityStatus accessibility;
  final String textModel;
  final bool textModelAvailable;
  final ImageModelState imageModelState;
  final List<ShieldApp> apps;

  /// Shown on platforms without the native layer.
  static const unsupported = ShieldStatus(
    enabled: false,
    state: ShieldState.unavailable,
    issues: [],
    textActive: false,
    imageActive: false,
    accessibility: AccessibilityStatus.unsupported,
    textModel: 'sg-text-1',
    textModelAvailable: false,
    imageModelState: ImageModelState.notBundled,
    apps: [],
  );

  bool get isChecking => textActive || imageActive;

  static ShieldStatus fromMap(Map<Object?, Object?> m) => ShieldStatus(
    enabled: m['enabled'] == true,
    state: ShieldState.fromId(m['state']),
    issues: [
      for (final i in (m['issues'] as List?) ?? const [])
        ?ShieldIssue.fromId(i),
    ],
    textActive: m['textActive'] == true,
    imageActive: m['imageActive'] == true,
    accessibility: AccessibilityStatus.fromId(m['accessibility']),
    textModel: m['textModel'] is String ? m['textModel']! as String : '',
    textModelAvailable: m['textModelAvailable'] == true,
    imageModelState: ImageModelState.fromId(m['imageModelState']),
    apps: [
      for (final a in (m['apps'] as List?) ?? const []) ?ShieldApp.fromMap(a),
    ],
  );

  ShieldStatus copyWith({bool? enabled, List<ShieldApp>? apps}) => ShieldStatus(
    enabled: enabled ?? this.enabled,
    state: state,
    issues: issues,
    textActive: textActive,
    imageActive: imageActive,
    accessibility: accessibility,
    textModel: textModel,
    textModelAvailable: textModelAvailable,
    imageModelState: imageModelState,
    apps: apps ?? this.apps,
  );
}

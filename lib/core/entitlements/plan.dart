/// Monetisation abstraction (Phase 8) — no billing is implemented.
///
/// Rule: protection is never paid-for. Every [ProtectionFeature] below is
/// core and available on every plan; the protection engine doesn't import
/// this file at all, so no payment state can switch protection off.
/// A future Premium could only add conveniences listed in
/// [PremiumFeature], and would use Google Play Billing with server-side
/// purchase verification (see docs/ARCHITECTURE_REVIEW.md, docs/SECURITY.md).
enum Plan { free, premium }

/// Safety features — always available, on every plan, offline or not.
enum ProtectionFeature {
  dnsFiltering,
  safeSearch,
  searchProtection,
  appProtection,
  aiProtection,
  customLists,
  keywords,
  pinProtection,
  modes,
  alerts,
  statistics,
  privacyControls,
}

/// Possible future extras. None exist today.
enum PremiumFeature { none }

/// Where the current plan comes from. The only implementation is local and
/// always FREE. A billing-backed one must verify purchases on a server,
/// handle refunds / expiry / offline grace — and must never be the sole
/// source of truth on the client.
abstract interface class EntitlementSource {
  Future<Plan> currentPlan();
}

class FreeEntitlements implements EntitlementSource {
  const FreeEntitlements();
  @override
  Future<Plan> currentPlan() async => Plan.free;
}

abstract final class Entitlements {
  /// Always true: protection doesn't depend on a plan.
  static bool protectionAvailable(ProtectionFeature feature, Plan plan) => true;

  static bool premiumAvailable(PremiumFeature feature, Plan plan) =>
      feature != PremiumFeature.none && plan == Plan.premium;
}

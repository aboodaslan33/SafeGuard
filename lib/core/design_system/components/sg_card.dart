import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/sg_tokens.dart';

/// Base surface. Cards are flat with a hairline border; hierarchy comes from
/// surface tone and typography rather than drop shadows.
class SgCard extends StatelessWidget {
  const SgCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(SgSpace.x5),
    this.color,
    this.borderColor,
    this.onTap,
    this.radius = SgRadius.lgAll,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final BorderRadius radius;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: SgElevation.raised(dark: context.isDark),
      ),
      child: Material(
        color: color ?? c.surface,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: borderColor ?? c.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A card that stacks rows separated by inset hairlines — the standard
/// container for settings and category lists.
class SgGroupedCard extends StatelessWidget {
  const SgGroupedCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      items.add(children[i]);
      if (i != children.length - 1) {
        items.add(
          Divider(
            indent: SgSpace.x4 + 40 + SgSpace.x3,
            endIndent: 0,
            color: c.border,
          ),
        );
      }
    }
    return SgCard(
      padding: EdgeInsets.zero,
      child: Column(mainAxisSize: MainAxisSize.min, children: items),
    );
  }
}

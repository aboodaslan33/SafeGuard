import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../tokens/sg_tokens.dart';

/// Standard scrolling page: large start-aligned title, gutter, and a max
/// content width so tablets and landscape don't stretch rows edge to edge.
class SgPage extends StatelessWidget {
  const SgPage({
    super.key,
    required this.children,
    this.title,
    this.subtitle,
    this.header,
    this.showBack = false,
    this.bottom,
  });

  final String? title;
  final String? subtitle;

  /// Replaces the title block entirely (used by Home).
  final Widget? header;
  final bool showBack;
  final List<Widget> children;

  /// Pinned footer (e.g. a primary action).
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: showBack
          ? AppBar(automaticallyImplyLeading: true, toolbarHeight: 52)
          : null,
      body: SafeArea(
        bottom: bottom == null,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: SgContentWidth(
                child: Padding(
                  padding: EdgeInsets.only(
                    top: showBack ? SgSpace.x1 : SgSpace.x6,
                  ),
                  child:
                      header ??
                      (title == null
                          ? const SizedBox.shrink()
                          : _TitleBlock(title: title!, subtitle: subtitle)),
                ),
              ),
            ),
            SliverList.list(
              children: [
                for (final child in children) SgContentWidth(child: child),
                const SizedBox(height: SgSpace.x10),
              ],
            ),
          ],
        ),
      ),
      bottomNavigationBar: bottom == null
          ? null
          : SafeArea(
              child: SgContentWidth(
                child: Padding(
                  padding: const EdgeInsets.only(
                    top: SgSpace.x3,
                    bottom: SgSpace.x4,
                  ),
                  child: bottom,
                ),
              ),
            ),
    );
  }
}

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SgSpace.x1),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: context.text.headlineSmall),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: SgSpace.x1),
            Text(subtitle!, style: context.text.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// Centers content with the screen gutter and a max width.
class SgContentWidth extends StatelessWidget {
  const SgContentWidth({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: SgSpace.maxContentWidth),
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: SgSpace.gutter),
            child: child,
          ),
        ),
      ),
    );
  }
}

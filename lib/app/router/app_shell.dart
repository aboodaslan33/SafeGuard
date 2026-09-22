import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_system/design_system.dart';

/// Bottom navigation for the three primary areas.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});

  final StatefulNavigationShell shell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: shell,
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: context.colors.border)),
        ),
        child: NavigationBar(
          selectedIndex: shell.currentIndex,
          onDestinationSelected: (i) =>
              shell.goBranch(i, initialLocation: i == shell.currentIndex),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.shield_outlined),
              selectedIcon: Icon(Icons.shield_rounded),
              label: 'الحماية',
            ),
            NavigationDestination(
              icon: Icon(Icons.monitor_heart_outlined),
              selectedIcon: Icon(Icons.monitor_heart_rounded),
              label: 'الحالة',
            ),
            NavigationDestination(
              icon: Icon(Icons.tune_rounded),
              selectedIcon: Icon(Icons.tune_rounded),
              label: 'الإعدادات',
            ),
          ],
        ),
      ),
    );
  }
}

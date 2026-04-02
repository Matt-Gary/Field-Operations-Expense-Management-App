import 'package:flutter/material.dart';
import '../theme/enterprise_colors.dart';

/// Wrap screen bodies with this to get the app-wide gradient background.
class GradientBackground extends StatelessWidget {
  final Widget child;
  const GradientBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kGradientStart, kGradientEnd],
        ),
      ),
      child: child,
    );
  }
}

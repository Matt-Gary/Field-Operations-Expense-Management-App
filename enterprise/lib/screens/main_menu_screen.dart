import 'package:flutter/material.dart';
import '../theme/enterprise_colors.dart';

class MainMenuScreen extends StatelessWidget {
  const MainMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const maxContentWidth = 420.0;

    // Get user role from arguments
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    final role = (args?['role'] ?? '').toString().toLowerCase();
    final isAdmin = role == 'admin';
    final isClient = role == 'client' || isAdmin;
    final isTivit = role == 'tivit' || isAdmin;

    return Scaffold(
      appBar: AppBar(
        // Show role for debugging or info? Maybe not needed.
        // title: Text('Menu ($role)'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: maxContentWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
            children: [
              // Logo
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 20),
                  child: Image.asset(
                    'assets/images/tivit_logo.png',
                    height: 72,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.high,
                    semanticLabel: 'TIVIT',
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ),

              // Section: ENTERPRISE Líderes (Client)
              if (isClient)
                _SectionCard(
                  title: 'CLIENTE',
                  description:
                      'Acesso exclusivo para líderes: criação de solicitação e aprovação de tarefas.',
                  leadingIcon: Icons.verified_user_outlined,
                  headerColor: kPrimaryDark,
                  headerTint: Colors.white,
                  children: [
                    _MenuButton(
                      label: 'Solicitação de tarefa',
                      onPressed: () => Navigator.pushNamed(
                        context,
                        '/solicitacao',
                        arguments: args,
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        backgroundColor: kPrimary,
                        foregroundColor: Colors.white,
                        textStyle: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      semanticsHint:
                          'Abrir a tela de Solicitação para líderes ENTERPRISE',
                    ),
                    const SizedBox(height: 12),
                    _MenuButton(
                      label: 'Aprovação de tarefas',
                      onPressed: () =>
                          Navigator.pushNamed(context, '/aprovacao'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        backgroundColor: kPrimary,
                        foregroundColor: Colors.white,
                        textStyle: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      semanticsHint:
                          'Abrir a tela de Aprovação de tarefas para líderes ENTERPRISE',
                    ),
                    const SizedBox(height: 12),
                    _MenuButton(
                      label: 'Gestão de despesas',
                      onPressed: () => Navigator.pushNamed(
                        context,
                        '/despesas/gestaodedespesas',
                      ),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        backgroundColor: kPrimary,
                        foregroundColor: Colors.white,
                        textStyle: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      semanticsHint: 'Abrir a tela de Gestão de despesas',
                    ),
                    if (isAdmin) ...[
                      const SizedBox(height: 12),
                      _MenuButton(
                        label: 'Baixar Arquivos',
                        onPressed: () => Navigator.pushNamed(
                          context,
                          '/arquivos/baixar',
                          arguments: args,
                        ),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          backgroundColor: kPrimaryDark,
                          foregroundColor: Colors.white,
                          textStyle: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        semanticsHint:
                            'Abrir a tela de download de arquivos por período',
                      ),
                    ],
                  ],
                ),


              if (isClient && isTivit) const SizedBox(height: 16),

              // Section: TIVIT Colaboradores
              if (isTivit)
                _SectionCard(
                  title: 'TIVIT',
                  description:
                      'Ambiente para registro de atividades e despesas.',
                  leadingIcon: Icons.badge_outlined,
                  headerColor: kPrimaryDark,
                  headerTint: Colors.white,
                  children: [
                    _MenuButton(
                      label: 'Registro de tarefa',
                      onPressed: () =>
                          Navigator.pushNamed(context, '/registro'),
                      style: AppButtonStyles.tonal(
                        minSize: const Size.fromHeight(52),
                        textStyle: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      semanticsHint:
                          'Abrir a tela de Registro para colaboradores TIVIT',
                    ),
                    const SizedBox(height: 12),
                    _MenuButton(
                      label: 'Painel do usuário',
                      onPressed: () =>
                          Navigator.pushNamed(context, '/panel_usuario'),
                      style: AppButtonStyles.tonal(
                        minSize: const Size.fromHeight(52),
                        textStyle: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      semanticsHint:
                          'Abrir a tela de Panel do Usuario para colaboradores TIVIT',
                    ),
                    const SizedBox(height: 12),
                    _MenuButton(
                      label: 'Registro do KM',
                      onPressed: () =>
                          Navigator.pushNamed(context, '/km', arguments: args),
                      style: AppButtonStyles.tonal(
                        minSize: const Size.fromHeight(52),
                        bg: kPrimary,
                        fg: Colors.white,
                        textStyle: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      semanticsHint:
                          'Abrir a tela de Registra Viagem para colaboradores TIVIT',
                    ),
                    const SizedBox(height: 12),
                    _MenuButton(
                      label: 'Registro de despesas',
                      onPressed: () => Navigator.pushNamed(
                        context,
                        '/despesas',
                        arguments: args,
                      ), // Pass args to sub-menu
                      style: AppButtonStyles.tonal(
                        minSize: const Size.fromHeight(52),
                        bg: kPrimary,
                        fg: Colors.white,
                        textStyle: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      semanticsHint:
                          'Abrir a tela de Despesas para colaboradores TIVIT',
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A reusable section card with a colored header and a list of children (buttons).
class _SectionCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData leadingIcon;
  final Color headerColor;
  final Color headerTint;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.description,
    required this.leadingIcon,
    required this.headerColor,
    required this.headerTint,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            color: headerColor,
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: Row(
              children: [
                Icon(leadingIcon, color: headerTint),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: headerTint,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: headerTint..withValues(alpha: 0.9),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Content
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            child: Column(
              children: [
                for (int i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1) const SizedBox(height: 12),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A wide, accessible button used across sections.
class _MenuButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final ButtonStyle? style;
  final String? semanticsHint;

  const _MenuButton({
    required this.label,
    required this.onPressed,
    this.style,
    this.semanticsHint,
  });

  @override
  Widget build(BuildContext context) {
    final button = FilledButton(
      onPressed: onPressed,
      style:
          style ??
          FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [Text(label), const Icon(Icons.chevron_right_rounded)],
      ),
    );

    return Semantics(
      button: true,
      label: label,
      hint: semanticsHint,
      child: button,
    );
  }
}

/// Centralized button styles (works on all stable Flutter versions).
class AppButtonStyles {
  static ButtonStyle tonal({
    required Size minSize,
    Color? bg,
    Color? fg,
    TextStyle? textStyle,
    Color? overlay,
  }) {
    return FilledButton.styleFrom(
      minimumSize: minSize,
      backgroundColor: bg ?? kPrimary, // light green
      foregroundColor: fg ?? Colors.white, // dark green text
      textStyle: textStyle,
      overlayColor: overlay,
    );
  }
}

import 'package:flutter/material.dart';

class DespesasMenuScreen extends StatelessWidget {
  const DespesasMenuScreen({super.key});


  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Get user role from arguments
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    final role = (args?['role'] ?? '').toString().toLowerCase();
    final isAdmin = role == 'admin';

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Despesas'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Image.asset('assets/images/tivit_logo.png', height: 28),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            color: cs.surface.withValues(alpha: 0.98),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () =>
                          Navigator.pushNamed(context, '/despesas/registrar'),
                      child: const Text('Registrar Despesa'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () =>
                          Navigator.pushNamed(context, '/despesas/minhas'),
                      child: const Text('Minhas despesas'),
                    ),
                  ),
                  if (isAdmin) ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pushNamed(context, '/despesas/gestaodedespesas');
                        },
                        child: const Text('Gestão de despesas'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

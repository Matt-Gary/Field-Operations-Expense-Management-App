import 'package:flutter/material.dart';
import '../services/user_session.dart';

class KmMenuScreen extends StatelessWidget {
  const KmMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final session = UserSession();
    final args =
        ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Registro do KM'),
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
                      onPressed: () => Navigator.pushNamed(
                        context,
                        '/km/registrar',
                        arguments: args,
                      ),
                      child: const Text('Registrar KMs'),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: OutlinedButton(
                      onPressed: () => Navigator.pushNamed(
                        context,
                        '/km/meus',
                        arguments: args,
                      ),
                      child: const Text('Meus KMs'),
                    ),
                  ),
                  if (session.isAdmin) ...[
                    const SizedBox(height: 32),
                    const Divider(),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.orange.shade800,
                        ),
                        onPressed: () =>
                            Navigator.pushNamed(context, '/vehicle/add'),
                        icon: const Icon(Icons.add_road),
                        label: const Text('Adicionar Placa'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.deepPurple.shade700,
                        ),
                        onPressed: () =>
                            Navigator.pushNamed(context, '/medicao/veiculos'),
                        icon: const Icon(Icons.speed),
                        label: const Text('Medição veículos'),
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

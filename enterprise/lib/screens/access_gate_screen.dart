import 'dart:math';
import 'package:flutter/material.dart';
import '../services/enterprise_api_service.dart';
import '../services/user_session.dart';

class AccessGateScreen extends StatefulWidget {
  const AccessGateScreen({super.key});

  @override
  State<AccessGateScreen> createState() => _AccessGateScreenState();
}

class _AccessGateScreenState extends State<AccessGateScreen> {
  final TextEditingController _pinController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();

  List<Map<String, dynamic>> _users = [];
  int? _selectedUserId;
  String? _selectedUserName;
  bool _loading = false;
  bool _loadingUsers = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  @override
  void dispose() {
    _pinController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    try {
      final list = await EnterpriseApiService.getUserList();
      if (!mounted) return;
      setState(() {
        _users = list;
        _loadingUsers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingUsers = false);
      _showMessage('Erro ao carregar usuários.');
      debugPrint('Error fetching users: $e');
    }
  }

  Future<void> _verifyAccess() async {
    if (_selectedUserId == null || _pinController.text.isEmpty) {
      _showMessage('Selecione um usuário e insira o PIN.');
      return;
    }

    setState(() => _loading = true);
    final user = await EnterpriseApiService.verifyUserPin(
      _selectedUserId!,
      _pinController.text,
    );
    if (!mounted) return;
    setState(() => _loading = false);

    if (user != null) {
      // Store user session
      // For tivit role, user_id from user-pin table = glpi_users.id
      final glpiUserId = _selectedUserId!;
      UserSession().setUser(
        userId: _selectedUserId!,
        userName: user['name']?.toString() ?? '',
        role: user['role']?.toString() ?? '',
        glpiUserId: glpiUserId,
      );

      // Pass user data (including role) to the main menu
      Navigator.pushReplacementNamed(
        context,
        '/',
        arguments: user, // { 'name': ..., 'pin': ..., 'role': ... }
      );
    } else {
      _showMessage('PIN incorreto. Tente novamente.');
    }
  }

  void _showMessage(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Iterable<Map<String, dynamic>> _filterUsers(String query) {
    if (query.trim().isEmpty) return _users.take(10); // show top few by default
    final q = query.trim().toLowerCase();
    // simple scoring: startsWith first, then contains
    final starts = <Map<String, dynamic>>[];
    final contains = <Map<String, dynamic>>[];
    for (final u in _users) {
      final name = (u['name'] ?? '').toString();
      final ln = name.toLowerCase();
      if (ln.startsWith(q)) {
        starts.add(u);
      } else if (ln.contains(q)) {
        contains.add(u);
      }
    }
    return [...starts, ...contains].take(20);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Acesso ao Aplicativo')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: 480,
          ), // a bit wider for search UX
          child: Card(
            color: cs.surface.withValues(alpha: 0.96),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SafeArea(
                top: false,
                bottom: false,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Search + suggestions
                      _loadingUsers
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 24),
                              child: Center(child: CircularProgressIndicator()),
                            )
                          : _UserSearch(
                              controller: _searchController,
                              users: _users,
                              filterUsers: _filterUsers,
                              selectedUserId: _selectedUserId,
                              selectedUserName: _selectedUserName,
                              onSelected: (user) {
                                setState(() {
                                  _selectedUserId = user['user_id'] as int?;
                                  _selectedUserName = (user['name'] ?? '')
                                      .toString();
                                });
                              },
                              onClear: () {
                                setState(() {
                                  _selectedUserId = null;
                                  _selectedUserName = null;
                                });
                              },
                            ),

                      const SizedBox(height: 12),

                      // PIN field
                      TextField(
                        controller: _pinController,
                        keyboardType: TextInputType.number,
                        obscureText: true,
                        maxLength: 4,
                        decoration: const InputDecoration(
                          labelText: 'PIN',
                          counterText: '',
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Confirm button
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _loading ? null : _verifyAccess,
                          icon: _loading
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.lock_open),
                          label: Text(_loading ? 'Verificando...' : 'Entrar'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small, focused widget that renders a Material 3 SearchBar + suggestions
class _UserSearch extends StatefulWidget {
  final TextEditingController controller;
  final List<Map<String, dynamic>> users;
  final Iterable<Map<String, dynamic>> Function(String query) filterUsers;
  final int? selectedUserId;
  final String? selectedUserName;
  final void Function(Map<String, dynamic> user) onSelected;
  final VoidCallback onClear;

  const _UserSearch({
    required this.controller,
    required this.users,
    required this.filterUsers,
    required this.selectedUserId,
    required this.selectedUserName,
    required this.onSelected,
    required this.onClear,
  });

  @override
  State<_UserSearch> createState() => _UserSearchState();
}

class _UserSearchState extends State<_UserSearch> {
  // SearchAnchor keeps the suggestions popup aligned with the SearchBar.
  final SearchController _searchController = SearchController();

  @override
  void initState() {
    super.initState();
    // keep external controller text in sync if needed
    _searchController.text = widget.controller.text;
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedName = widget.selectedUserName;
    final hasSelection =
        widget.selectedUserId != null && (selectedName ?? '').isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SearchAnchor.bar(
          searchController: _searchController,
          barHintText: 'Buscar usuário pelo nome',
          viewConstraints: const BoxConstraints(maxHeight: 320, maxWidth: 480),
          isFullScreen: false,
          // Build suggestions dynamically as the user types
          suggestionsBuilder: (ctx, controller) {
            final q = controller.text;
            final results = widget.filterUsers(q).toList();
            if (results.isEmpty) {
              return [
                const ListTile(
                  leading: Icon(Icons.person_off),
                  title: Text('Nenhum usuário encontrado'),
                ),
              ];
            }
            // Render up to 20 items
            return List<ListTile>.generate(min(results.length, 20), (i) {
              final user = results[i];
              final name = (user['name'] ?? '').toString();
              return ListTile(
                leading: const Icon(Icons.person),
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('ID: ${user['user_id']}'),
                onTap: () {
                  // commit selection
                  widget.onSelected(user);
                  controller.closeView(null);
                  controller.text = name; // keep visible
                },
              );
            });
          },
          barTrailing: [
            if (_searchController.text.isNotEmpty)
              IconButton(
                tooltip: 'Limpar busca',
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _searchController.clear();
                  _searchController
                      .openView(); // re-open to show default suggestions
                },
              ),
          ],
          // Make the bar look like a form field
          viewHintText: 'Digite para pesquisar...',
        ),

        const SizedBox(height: 8),

        // Selected chip / status line
        if (hasSelection)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              InputChip(
                avatar: const Icon(Icons.person, size: 18),
                label: Text(selectedName!),
                onDeleted: widget.onClear,
                deleteIcon: const Icon(Icons.close),
              ),
            ],
          )
        else
          const Text(
            'Nenhum usuário selecionado',
            style: TextStyle(fontStyle: FontStyle.italic),
          ),
      ],
    );
  }
}

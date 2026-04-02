import 'package:flutter/material.dart';
import 'package:dropdown_search/dropdown_search.dart';
import '../services/enterprise_api_service.dart';
import '../models/service_model.dart';
import '../models/service_selection.dart';
import '../models/lider_model.dart';

// ── Standalone screen (used when navigating to '/solicitacao' directly) ──────
class ServiceContractScreen extends StatelessWidget {
  const ServiceContractScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Líder Enterprise - Contratação de Serviços"),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Image.asset('assets/images/tivit_logo.png', height: 28),
          ),
        ],
      ),
      body: const ServiceContractBody(),
    );
  }
}

// ── Reusable body widget (used inside SolicitacaoTabScreen tab 1) ─────────────
class ServiceContractBody extends StatefulWidget {
  const ServiceContractBody({super.key});

  @override
  State<ServiceContractBody> createState() => _ServiceContractBodyState();
}

class _ServiceContractBodyState extends State<ServiceContractBody>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _commentController = TextEditingController();
  String? _selectedType;
  List<ServiceModel> _availableServices = [];
  final List<ServiceSelection> _selectedServices = [];
  List<String> _serviceTypes = [];
  List<Lider> _availableLiders = [];
  Lider? _selectedLider;

  // GLPI users (from /glpi/users)
  List<Map<String, dynamic>> _glpiUsers = [];
  bool _loadingUsers = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    fetchServiceTypes();
    _loadLiders();
    _loadGlpiUsers();
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> fetchServiceTypes() async {
    try {
      final types = await EnterpriseApiService.getServiceTypes();
      if (!mounted) return;
      setState(() => _serviceTypes = types);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Falha ao carregar tipos: $e')));
    }
  }

  Future<void> fetchServices(String type) async {
    try {
      final services = await EnterpriseApiService.getServices(type);
      if (!mounted) return;
      setState(() {
        _availableServices = services;
        _selectedServices.clear();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Falha ao carregar serviços: $e')));
    }
  }

  Future<void> _loadLiders() async {
    try {
      final lideres = await EnterpriseApiService.getLiders().timeout(
        const Duration(seconds: 10),
      );
      if (!mounted) return;
      setState(() => _availableLiders = lideres);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Falha ao carregar líderes: $e')));
    }
  }

  Future<void> _loadGlpiUsers() async {
    try {
      setState(() => _loadingUsers = true);
      final users = await EnterpriseApiService.getGlpiUsers().timeout(
        const Duration(seconds: 15),
      );
      if (!mounted) return;
      setState(() {
        _glpiUsers = users;
        _loadingUsers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingUsers = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao carregar usuários GLPI: $e')),
      );
    }
  }

  Future<void> sendForm() async {
    if (_selectedLider == null ||
        _selectedType == null ||
        _selectedServices.isEmpty ||
        _commentController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preencha todos os campos obrigatórios!')),
      );
      return;
    }

    final success = await EnterpriseApiService.submitForm(
      lider: _selectedLider!.fullName,
      tipoServico: _selectedType!,
      servicos: _selectedServices,
      comentario: _commentController.text,
    );

    if (!mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Falha ao enviar formulário!')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Formulário enviado com sucesso!')),
    );

    // 🔹 Pergunta se mantém os dados
    final keepData = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Manter dados preenchidos?'),
          content: const Text('Você quer manter os dados preenchidos?'),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false); // NÃO manter
              },
              child: const Text('Não'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(true); // SIM manter
              },
              child: const Text('Sim'),
            ),
          ],
        );
      },
    );

    if (!mounted) return;

    // Se usuário escolher NÃO, limpamos o formulário
    if (keepData == false) {
      setState(() {
        _selectedLider = null;
        _selectedType = null;
        _selectedServices.clear();
        _commentController.clear();
        _availableServices.clear();
      });
    }
    // Se keepData == true ou null -> não fazemos nada, mantemos os dados
  }

  void _pickDate(ServiceSelection selection) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: selection.expectedDate ?? DateTime.now(),
      firstDate: DateTime(2000), // allow past dates
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => selection.expectedDate = picked);
    }
  }

  // Helper to get selected user Map by id (for dropdown's selectedItem)
  Map<String, dynamic>? _userById(int? id) {
    if (id == null) return null;
    try {
      return _glpiUsers.firstWhere((u) => (u['id'] as num).toInt() == id);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Card(
            elevation: 0,
            color: cs.surface.withValues(alpha: 0.98),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ListView(
                children: [
                  DropdownSearch<Lider>(
                    items: _availableLiders,
                    selectedItem: _selectedLider,
                    itemAsString: (l) => l.fullName,
                    compareFn: (a, b) =>
                        a.nome == b.nome && a.sobrenome == b.sobrenome,
                    dropdownDecoratorProps: const DropDownDecoratorProps(
                      dropdownSearchDecoration: InputDecoration(
                        labelText: "Nome do Líder",
                      ),
                    ),
                    onChanged: (l) => setState(() => _selectedLider = l),
                    popupProps: const PopupProps.menu(showSearchBox: true),
                  ),
                  const SizedBox(height: 16),
                  DropdownSearch<String>(
                    items: _serviceTypes,
                    selectedItem: _selectedType,
                    dropdownDecoratorProps: const DropDownDecoratorProps(
                      dropdownSearchDecoration: InputDecoration(
                        labelText: "Tipo de Serviço",
                      ),
                    ),
                    onChanged: (type) {
                      if (type == null) return;
                      setState(() => _selectedType = type);
                      fetchServices(type);
                    },
                    popupProps: const PopupProps.menu(showSearchBox: true),
                  ),
                  const SizedBox(height: 16),

                  DropdownSearch<ServiceModel>.multiSelection(
                    items: _availableServices,
                    selectedItems: _selectedServices
                        .map((s) => s.service)
                        .toList(),
                    itemAsString: (service) => service.atividade ?? '',
                    filterFn: (service, filter) {
                      final q = (filter ?? '').trim().toLowerCase();
                      if (q.isEmpty) return true;
                      final nome = (service.atividade ?? '').toLowerCase();
                      final item = (service.item ?? '').toLowerCase();
                      return nome.contains(q) || item.contains(q);
                    },
                    dropdownDecoratorProps: const DropDownDecoratorProps(
                      dropdownSearchDecoration: InputDecoration(
                        labelText: "Serviços (selecione múltiplos)",
                      ),
                    ),
                    onChanged: (selectedList) {
                      setState(() {
                        final newSelections = <ServiceSelection>[];
                        for (final service in selectedList) {
                          final existing = _selectedServices
                              .where((s) => s.service.item == service.item)
                              .toList();
                          if (existing.isNotEmpty) {
                            newSelections.add(existing.first);
                          } else {
                            newSelections.add(
                              ServiceSelection(service: service),
                            );
                          }
                        }
                        _selectedServices
                          ..clear()
                          ..addAll(newSelections);
                      });
                    },
                    popupProps: PopupPropsMultiSelection.menu(
                      showSearchBox: true,
                      searchFieldProps: TextFieldProps(
                        decoration: const InputDecoration(
                          hintText: 'Pesquisar por nome ou ITEM...',
                          contentPadding: EdgeInsets.symmetric(horizontal: 12),
                        ),
                      ),
                      itemBuilder: (context, service, isSelected) {
                        final key = GlobalKey<TooltipState>();
                        final desc = (service.descricaoDetalhada ?? '').trim();
                        return MouseRegion(
                          cursor: SystemMouseCursors.help,
                          onEnter: (_) =>
                              key.currentState?.ensureTooltipVisible(),
                          onExit: (_) => key.currentState?.deactivate(),
                          child: Tooltip(
                            key: key,
                            triggerMode: TooltipTriggerMode.longPress,
                            waitDuration: const Duration(milliseconds: 250),
                            showDuration: const Duration(seconds: 6),
                            message: desc.isNotEmpty ? desc : 'Sem descrição',
                            child: ListTile(
                              title: Text(service.atividade ?? ''),
                              subtitle: Text(
                                service.item ?? '',
                              ), // já mostra o ITEM
                              dense: true,
                            ),
                          ),
                        );
                      },
                    ),
                    dropdownBuilder: (context, selectedItems) {
                      if (selectedItems.isEmpty) {
                        return const SizedBox.shrink();
                      }
                      return Wrap(
                        spacing: 8,
                        runSpacing: -6,
                        children: selectedItems.map((s) {
                          final desc = (s.descricaoDetalhada ?? '').trim();
                          return Tooltip(
                            message: desc.isNotEmpty ? desc : 'Sem descrição',
                            waitDuration: const Duration(milliseconds: 250),
                            showDuration: const Duration(seconds: 6),
                            child: Chip(
                              label: Text(s.atividade ?? s.item ?? 'Serviço'),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                  const SizedBox(height: 16),

                  if (_selectedServices.isNotEmpty)
                    const Text(
                      "Defina a data de conclusão, quantidade e o usuário para cada serviço:",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),

                  ..._selectedServices.map(
                    (selection) => Card(
                      key: ValueKey(selection.service.item),
                      margin: const EdgeInsets.symmetric(vertical: 8),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              selection.service.atividade ?? '',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(selection.service.item ?? ''),
                            const SizedBox(height: 4),
                            Text(
                              selection.service.descricaoDetalhada ?? '',
                              style: const TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 8),

                            // Row: Date + Quantidade
                            Row(
                              children: [
                                Expanded(
                                  child: ElevatedButton(
                                    onPressed: () => _pickDate(selection),
                                    child: Text(
                                      selection.expectedDate == null
                                          ? "Data estimada de conclusão"
                                          : "${selection.expectedDate!.day}/${selection.expectedDate!.month}/${selection.expectedDate!.year}",
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: 120,
                                  child: TextField(
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                          signed: false,
                                        ),
                                    decoration: const InputDecoration(
                                      labelText: "Qtd.",
                                      border: OutlineInputBorder(),
                                    ),
                                    controller: TextEditingController(
                                      text: selection.quantidade.toString(),
                                    ),
                                    onChanged: (value) {
                                      final parsed = double.tryParse(
                                        value.replaceAll(',', '.'),
                                      );
                                      setState(() {
                                        selection.quantidade =
                                            (parsed != null && parsed > 0)
                                            ? parsed
                                            : 1.0;
                                      });
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),

                            

                            // Searchable dropdown: assign GLPI user (per task)
                            if (_loadingUsers)
                              const LinearProgressIndicator()
                            else
                              DropdownSearch<Map<String, dynamic>>(
                                items: _glpiUsers,
                                selectedItem: _userById(
                                  selection.assignedUserId,
                                ),
                                itemAsString: (u) =>
                                    (u['name'] as String?) ?? 'Sem nome',
                                compareFn: (a, b) =>
                                    (a['id'] as num).toInt() ==
                                    (b['id'] as num).toInt(),
                                dropdownDecoratorProps:
                                    const DropDownDecoratorProps(
                                      dropdownSearchDecoration: InputDecoration(
                                        labelText: "Atribuir usuário (GLPI)",
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                popupProps: PopupProps.menu(
                                  showSearchBox: true,
                                  searchFieldProps: TextFieldProps(
                                    decoration: const InputDecoration(
                                      hintText: 'Pesquisar por nome...',
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                    ),
                                  ),
                                  itemBuilder: (context, user, isSelected) =>
                                      ListTile(
                                        dense: true,
                                        title: Text(
                                          (user['name'] as String?) ??
                                              'Sem nome',
                                        ),
                                        subtitle: Text('ID: ${user['id']}'),
                                      ),
                                  emptyBuilder: (context, s) => const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Text('Nenhum usuário encontrado'),
                                  ),
                                  loadingBuilder: (context, s) => const Padding(
                                    padding: EdgeInsets.all(12),
                                    child: Center(
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                ),
                                onChanged: (u) {
                                  setState(() {
                                    selection.assignedUserId = u == null
                                        ? null
                                        : (u['id'] as num).toInt();
                                  });
                                },
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),

                  TextField(
                    controller: _commentController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: "Comentário",
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Center(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(200, 50),
                      ),
                      onPressed: sendForm,
                      child: const Text('Enviar'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

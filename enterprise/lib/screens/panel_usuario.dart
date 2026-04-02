import 'package:flutter/material.dart';
import 'package:dropdown_search/dropdown_search.dart';
import '../services/enterprise_api_service.dart';
import '../services/user_session.dart';

class UserPanelScreen extends StatefulWidget {
  const UserPanelScreen({super.key});

  @override
  State<UserPanelScreen> createState() => UserPanelScreenState();
}

class UserPanelScreenState extends State<UserPanelScreen> {
  // Controllers / state
  final searchCtrl = TextEditingController();
  final ScrollController vScroll = ScrollController();
  final ScrollController hScroll = ScrollController();

  List<Map<String, dynamic>> users = [];
  List<Map<String, dynamic>> tasks = [];
  List<Map<String, dynamic>> filtered = [];

  int? selectedUserId;
  String? selectedUserName;
  bool loading = false;
  bool usersLoading = false;
  String? errorMsg;
  bool isUserFieldLocked = false; // For tivit role users

  // Filters
  String? fStatus;
  final List<String> statusOptions = const [
    'Novo',
    'Pendente',
    'Fechado',
    'Planejado',
    'Cancelado',
    'Aguardando Aprovação',
    'Em Andamento',
    'Reprovado',
  ];

  @override
  void initState() {
    super.initState();
    loadUsers();
    searchCtrl.addListener(applyFilter);
  }

  @override
  void dispose() {
    searchCtrl.dispose();
    vScroll.dispose();
    hScroll.dispose();
    super.dispose();
  }

  Future<void> loadUsers() async {
    setState(() => usersLoading = true);
    try {
      final u = await EnterpriseApiService.getGlpiUsers();

      // Check if current user is tivit role and auto-select
      final session = UserSession();
      final isTivit = session.isTivit;
      final glpiUserId = session.glpiUserId;

      if (isTivit && glpiUserId != null) {
        // Find the user in the list
        final currentUser = u.firstWhere(
          (user) => user['id'] == glpiUserId,
          orElse: () => {},
        );

        if (currentUser.isNotEmpty) {
          setState(() {
            users = u;
            selectedUserId = glpiUserId;
            selectedUserName = currentUser['name']?.toString();
            isUserFieldLocked = true;
          });

          // Auto-load tasks for the locked user
          loadUserTasks(glpiUserId);
        } else {
          setState(() => users = u);
        }
      } else {
        setState(() => users = u);
      }
    } catch (e) {
      setState(() => errorMsg = 'Falha ao carregar usuários: $e');
    } finally {
      setState(() => usersLoading = false);
    }
  }

  Future<void> loadUserTasks(int userId) async {
    setState(() {
      loading = true;
      errorMsg = null;
      tasks = [];
      filtered = [];
    });

    try {
      final t = await EnterpriseApiService.getUserTasks(userId);
      setState(() {
        tasks = t;
        filtered = List.of(t);
      });
    } catch (e) {
      setState(() => errorMsg = 'Falha ao carregar tarefas: $e');
      setState(() => loading = false);
    }
  }

  void applyFilter() {
    setState(() {
      filtered = tasks.where((task) {
        final searchTerm = searchCtrl.text.toLowerCase();
        final name = (task['name'] ?? '').toString().toLowerCase();
        final status = (task['status_name'] ?? '').toString().toLowerCase();

        if (fStatus != null &&
            fStatus!.isNotEmpty &&
            !status.contains(fStatus!.toLowerCase())) {
          return false;
        }
        if (searchTerm.isEmpty) return true;

        return name.contains(searchTerm) ||
            status.contains(searchTerm) ||
            (task['item'] ?? '').toString().toLowerCase().contains(searchTerm);
      }).toList();
    });
  }

  Widget buildUserSelector() {
    return DropdownSearch<Map<String, dynamic>>(
      popupProps: const PopupProps.menu(
        showSearchBox: true,
        searchFieldProps: TextFieldProps(
          decoration: InputDecoration(
            labelText: 'Buscar usuário',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      items: users,
      itemAsString: (user) => user['name'] ?? '',
      selectedItem: selectedUserId != null
          ? users.firstWhere((u) => u['id'] == selectedUserId, orElse: () => {})
          : null,
      enabled: !isUserFieldLocked, // Disable for tivit users
      dropdownDecoratorProps: DropDownDecoratorProps(
        dropdownSearchDecoration: InputDecoration(
          labelText: isUserFieldLocked
              ? 'Selecionar Usuário (bloqueado)'
              : 'Selecionar Usuário',
          border: const OutlineInputBorder(),
        ),
      ),
      onChanged: isUserFieldLocked
          ? null // Disable callback when locked
          : (user) {
              if (user != null) {
                setState(() {
                  selectedUserId = user['id'];
                  selectedUserName = user['name'];
                });
                loadUserTasks(user['id']);
              }
            },
    );
  }

  Widget buildFilters() {
    return Row(
      children: [
        Expanded(
          child: DropdownSearch<String>(
            items: statusOptions,
            selectedItem: fStatus,
            popupProps: const PopupProps.menu(showSearchBox: true),
            clearButtonProps: const ClearButtonProps(isVisible: true),
            dropdownDecoratorProps: const DropDownDecoratorProps(
              dropdownSearchDecoration: InputDecoration(
                labelText: 'Filtrar por Status',
                isDense: true,
                border: OutlineInputBorder(),
              ),
            ),
            onChanged: (v) {
              setState(() => fStatus = v);
              applyFilter();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            controller: searchCtrl,
            decoration: const InputDecoration(
              labelText: 'Buscar tarefa...',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget buildTableHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 72,
            child: Text(
              'Ações',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: Align(
              alignment: Alignment.centerLeft,
              child: headerText('Tarefa'),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(width: 120, child: headerText('Status')),
          const SizedBox(width: 8),
          SizedBox(width: 100, child: headerText('Item')),
          const SizedBox(width: 8),
          SizedBox(width: 120, child: headerText('Início Real')),
          const SizedBox(width: 8),
          SizedBox(width: 120, child: headerText('Fim Real')),
          const SizedBox(width: 8),
          SizedBox(width: 60, child: headerText('Qtd')),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: headerText('Comentário'),
            ),
          ),
        ],
      ),
    );
  }

  Text cellText(
    String text, {
    FontWeight? fw,
    TextAlign? align,
    int maxLines = 2,
  }) => Text(
    text,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
    softWrap: false,
    textAlign: align,
    style: TextStyle(fontSize: 12, fontWeight: fw),
  );

  Text headerText(String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    softWrap: false,
    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
  );

  // ---------- date/time helpers ----------
  DateTime? parseLocalDateTime(dynamic s) {
    if (s == null) return null;
    final raw = s.toString().trim();
    if (raw.isEmpty) return null;

    try {
      // Treat as ISO or normalize space to 'T'
      final dt = DateTime.parse(
        raw.contains('T') ? raw : raw.replaceFirst(' ', 'T'),
      );
      // CRITICAL: Always convert back to Local if it was parsed as UTC
      return dt.toLocal();
    } catch (_) {
      return null;
    }
  }

  String fmtDateTime(dynamic s) {
    final dt = parseLocalDateTime(s);
    if (dt == null) return '-';
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString().padLeft(4, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mi = dt.minute.toString().padLeft(2, '0');
    return '$dd/$mm/$yyyy $hh:$mi';
  }
  // ---------------------------------------

  Widget buildTableBody() {
    if (filtered.isEmpty && !loading) {
      return const Center(child: Text('Nenhuma tarefa encontrada.'));
    }

    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(1.0)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final needsHScroll = constraints.maxWidth < 1200;

          Widget tableContent = ListView.builder(
            controller: vScroll,
            itemCount: filtered.length,
            itemBuilder: (context, index) {
              final task = filtered[index];
              return UserTaskTableRow(
                task: task,
                onEdit: () => openTaskEdit(task),
                onDelete: () => confirmDelete(task),
                fmtDateTime: fmtDateTime,
                cellText: cellText,
              );
            },
          );

          tableContent = Scrollbar(
            controller: vScroll,
            thumbVisibility: true,
            child: tableContent,
          );
          if (!needsHScroll) return tableContent;

          return Scrollbar(
            controller: hScroll,
            thumbVisibility: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              controller: hScroll,
              child: Container(
                constraints: BoxConstraints(
                  minWidth: 1200,
                  maxWidth: constraints.maxWidth > 1200
                      ? constraints.maxWidth
                      : 1200,
                ),
                child: tableContent,
              ),
            ),
          );
        },
      ),
    );
  }

  void openTaskEdit(Map<String, dynamic> task) {
    final isAdmin = UserSession().isAdmin;
    final isEditable = task['is_editable'] == true || isAdmin;
    if (isEditable) {
      showEditDialog(task);
    } else {
      showViewDialog(task);
    }
  }

  Future<void> confirmDelete(Map<String, dynamic> task) async {
    final statusId = task['projectstates_id'] as int?;
    final isAdmin = UserSession().isAdmin;
    final canDelete = statusId != 3 || isAdmin; // block approved unless admin
    if (!canDelete) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Não é permitido remover tarefas com status de Aprovação/Approved.',
          ),
        ),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remover tarefa'),
        content: Text(
          'Remover a tarefa "${task['name'] ?? ''}" do GLPI e do histórico (formas_enviadas)?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      await EnterpriseApiService.deleteTask(
        taskId: task['id'] as int,
        userId: selectedUserId!,
        isAdmin: isAdmin,
      );

      if (!mounted) return;

      loadUserTasks(selectedUserId!);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tarefa removida com sucesso.')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Falha ao remover: $e')));
      }
    }
  }

  Future<void> showEditDialog(Map<String, dynamic> task) async {
    final nameCtrl = TextEditingController(
      text: task['name']?.toString() ?? '',
    );
    final combinedComment =
        task['content']?.toString() ?? task['comentario']?.toString() ?? '';
    final comentarioCtrl = TextEditingController(text: combinedComment);
    final quantidadeCtrl = TextEditingController(
      text: (task['quantidade_tarefas'] ?? 1).toString(),
    );

    // LOCAL times
    DateTime? realStartDate = parseLocalDateTime(
      task['real_start_date'] ?? task['data_start_real'],
    );
    DateTime? realEndDate = parseLocalDateTime(
      task['real_end_date'] ?? task['user_conclude_date'],
    );
    DateTime? pendStart = parseLocalDateTime(task['data_start_pendente']);
    DateTime? pendEnd = parseLocalDateTime(task['data_end_pendente']);

    String? modoDeTrabalho = task['modo_de_trabalho']?.toString();

    // pre-aprovadas
    final uid = selectedUserId;
    List<String> tarefaOptions = [];
    String? selectedTarefa = task['name']?.toString();
    double? tempoPrevistoH;
    String? tipoEvidencia;

    if (uid != null) {
      try {
        final rawTasks = await EnterpriseApiService.getPreAprovadosTarefas(
          userId: uid,
        );
        tarefaOptions = rawTasks.map((e) => e['atividade'].toString()).toList();

        // FIX: Ensure current task name is in the list so it doesn't disappear
        if (selectedTarefa != null && !tarefaOptions.contains(selectedTarefa)) {
          if (selectedTarefa!.isNotEmpty) {
            tarefaOptions.add(selectedTarefa);
          }
        }

        if (selectedTarefa != null) {
          final info = await EnterpriseApiService.getPreAprovadoInfo(
            userId: uid,
            tarefa: selectedTarefa,
          );
          tempoPrevistoH = parseTempoPrevisto(info['tempo_previsto_h']);
          final te = info['tipo_de_evidencia'];
          tipoEvidencia = (te == null || te.toString().trim().isEmpty)
              ? null
              : te.toString().trim();
        }
      } catch (_) {}
    }

    // status read-only
    final String statusName = (task['status_name'] ?? '').toString();

    bool saving = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          Future<void> onSelectTarefa(String? v) async {
            setState(() => selectedTarefa = v);
            if (uid != null && v != null && v.isNotEmpty) {
              final info = await EnterpriseApiService.getPreAprovadoInfo(
                userId: uid,
                tarefa: v,
              );
              setState(() {
                tempoPrevistoH = parseTempoPrevisto(info['tempo_previsto_h']);
                final te = info['tipo_de_evidencia'];
                tipoEvidencia = (te == null || te.toString().trim().isEmpty)
                    ? null
                    : te.toString().trim();
              });
            } else {
              setState(() {
                tempoPrevistoH = null;
                tipoEvidencia = null;
              });
            }
          }

          Widget tarefaField;
          if (tarefaOptions.isNotEmpty) {
            tarefaField = DropdownSearch<String>(
              items: tarefaOptions,
              selectedItem: selectedTarefa,
              popupProps: const PopupProps.menu(
                showSearchBox: true,
                fit: FlexFit.loose,
                searchFieldProps: TextFieldProps(
                  decoration: InputDecoration(
                    labelText: 'Buscar tarefa',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              clearButtonProps: const ClearButtonProps(isVisible: true),
              dropdownDecoratorProps: const DropDownDecoratorProps(
                dropdownSearchDecoration: InputDecoration(
                  labelText: 'Nome da Tarefa (pré-aprovadas)',
                  border: OutlineInputBorder(),
                ),
              ),
              onChanged: (v) => onSelectTarefa(v),
            );
          } else {
            tarefaField = TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Nome da Tarefa',
                border: OutlineInputBorder(),
              ),
              maxLines: 2,
            );
          }

          Widget dateTile({
            required String label,
            required DateTime? value,
            required VoidCallback onTap,
            VoidCallback? onClear,
          }) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                const SizedBox(height: 4),
                InkWell(
                  onTap: onTap,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          value != null
                              ? '${value.day.toString().padLeft(2, '0')}/${value.month.toString().padLeft(2, '0')}/${value.year} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}'
                              : 'Selecionar data',
                          style: TextStyle(
                            color: value != null ? Colors.black : Colors.grey,
                          ),
                        ),
                        if (value != null && onClear != null)
                          InkWell(
                            onTap: onClear,
                            child: const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }

          return AlertDialog(
            title: const Text('Editar Tarefa'),
            content: SingleChildScrollView(
              child: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    tarefaField,
                    if (tempoPrevistoH != null ||
                        (tipoEvidencia != null && tipoEvidencia!.isNotEmpty))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            [
                              if (tempoPrevistoH != null)
                                'Tempo previsto: ${formatHoras(tempoPrevistoH!)}',
                              if (tipoEvidencia != null &&
                                  tipoEvidencia!.isNotEmpty)
                                'Evidência: $tipoEvidencia',
                            ].join(' • '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),

                    // Status read-only
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Status: ',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          Chip(
                            label: Text(statusName.isEmpty ? '-' : statusName),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Real start/end
                    Row(
                      children: [
                        Expanded(
                          child: dateTile(
                            label: 'Início Real',
                            value: realStartDate,
                            onTap: () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate: realStartDate ?? DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2035),
                              );
                              if (date != null) {
                                final time = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay.fromDateTime(
                                    realStartDate ?? DateTime.now(),
                                  ),
                                );
                                if (time != null) {
                                  setState(() {
                                    realStartDate = DateTime(
                                      date.year,
                                      date.month,
                                      date.day,
                                      time.hour,
                                      time.minute,
                                    );
                                  });
                                }
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: dateTile(
                            label: 'Fim Real',
                            value: realEndDate,
                            onTap: () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate: realEndDate ?? DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2035),
                              );
                              if (date != null) {
                                final time = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay.fromDateTime(
                                    realEndDate ?? DateTime.now(),
                                  ),
                                );
                                if (time != null) {
                                  setState(() {
                                    realEndDate = DateTime(
                                      date.year,
                                      date.month,
                                      date.day,
                                      time.hour,
                                      time.minute,
                                    );
                                  });
                                }
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // Pendente start/end
                    Row(
                      children: [
                        Expanded(
                          child: dateTile(
                            label: 'Início Pendente',
                            value: pendStart,
                            onClear: () => setState(() => pendStart = null),
                            onTap: () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate: pendStart ?? DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2035),
                              );
                              if (date != null) {
                                final time = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay.fromDateTime(
                                    pendStart ?? DateTime.now(),
                                  ),
                                );
                                if (time != null) {
                                  setState(() {
                                    pendStart = DateTime(
                                      date.year,
                                      date.month,
                                      date.day,
                                      time.hour,
                                      time.minute,
                                    );
                                  });
                                }
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: dateTile(
                            label: 'Fim Pendente',
                            value: pendEnd,
                            onClear: () => setState(() => pendEnd = null),
                            onTap: () async {
                              final date = await showDatePicker(
                                context: context,
                                initialDate: pendEnd ?? DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2035),
                              );
                              if (date != null) {
                                final time = await showTimePicker(
                                  context: context,
                                  initialTime: TimeOfDay.fromDateTime(
                                    pendEnd ?? DateTime.now(),
                                  ),
                                );
                                if (time != null) {
                                  setState(() {
                                    pendEnd = DateTime(
                                      date.year,
                                      date.month,
                                      date.day,
                                      time.hour,
                                      time.minute,
                                    );
                                  });
                                }
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: quantidadeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Quantidade de Tarefas',
                        border: OutlineInputBorder(),
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 12),

                    TextField(
                      controller: comentarioCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Comentário',
                        border: OutlineInputBorder(),
                      ),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 12),

                    DropdownButtonFormField<String>(
                      value: ['HC', 'FHC'].contains(modoDeTrabalho)
                          ? modoDeTrabalho
                          : null,
                      decoration: const InputDecoration(
                        labelText: 'Modo de Trabalho',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: null,
                          child: Text('Selecione...'),
                        ),
                        DropdownMenuItem(value: 'HC', child: Text('HC')),
                        DropdownMenuItem(value: 'FHC', child: Text('FHC')),
                      ],
                      onChanged: (v) => setState(() => modoDeTrabalho = v),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: saving
                    ? null
                    : () async {
                        final taskNameToSave = (tarefaOptions.isNotEmpty)
                            ? (selectedTarefa ?? '')
                            : nameCtrl.text.trim();

                        if (taskNameToSave.isEmpty) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Nome da tarefa é obrigatório'),
                            ),
                          );
                          return;
                        }

                        setState(() => saving = true);

                        final isAdmin =
                            UserSession().isAdmin; // Get admin status

                        try {
                          final oldName = (task['name'] ?? '').toString();
                          final success = await EnterpriseApiService.updateUserTask(
                            taskId: task['id'] as int,
                            name: taskNameToSave,
                            content: comentarioCtrl.text.trim(),
                            realStartDate: realStartDate,
                            realEndDate: realEndDate,
                            comentario: comentarioCtrl.text.trim(),
                            quantidadeTarefas:
                                double.tryParse(quantidadeCtrl.text) ?? 1,
                            projectstatesId: null, // status read-only
                            dataStartPendente: pendStart,
                            dataEndPendente: pendEnd,
                            modoDeTrabalho: modoDeTrabalho,
                            isAdmin: isAdmin, // Pass isAdmin flag
                          );

                          if (!success) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Falha ao atualizar tarefa'),
                              ),
                            );
                            return;
                          }

                          // Sync atividade + item if the name changed
                          if (selectedUserId != null &&
                              taskNameToSave != oldName) {
                            try {
                              await EnterpriseApiService.updateTaskAtividade(
                                taskId: task['id'] as int,
                                userId: selectedUserId!,
                                tarefa: taskNameToSave,
                                isAdmin: isAdmin,
                              );
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Atividade atualizada, mas falhou ao ajustar ITEM: $e',
                                    ),
                                  ),
                                );
                              }
                            }
                          }

                          if (!context.mounted) return;
                          Navigator.pop(context);
                          loadUserTasks(selectedUserId!);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Tarefa atualizada com sucesso!'),
                            ),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(
                            context,
                          ).showSnackBar(SnackBar(content: Text('Erro: $e')));
                        } finally {
                          if (context.mounted) setState(() => saving = false);
                        }
                      },
                child: saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Salvar'),
              ),
            ],
          );
        },
      ),
    );
  }

  void showViewDialog(Map<String, dynamic> task) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Detalhes da Tarefa - SOMENTE LEITURA'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              buildDetailRow('Tarefa:', task['name']?.toString() ?? ''),
              buildDetailRow('Status:', task['status_name']?.toString() ?? ''),
              buildDetailRow(
                'Início Real:',
                fmtDateTime(task['real_start_date'] ?? task['data_start_real']),
              ),
              buildDetailRow(
                'Fim Real:',
                fmtDateTime(
                  task['real_end_date'] ?? task['user_conclude_date'],
                ),
              ),
              buildDetailRow(
                'Início Pendente:',
                fmtDateTime(task['data_start_pendente']),
              ),
              buildDetailRow(
                'Fim Pendente:',
                fmtDateTime(task['data_end_pendente']),
              ),
              buildDetailRow(
                'Quantidade:',
                (task['quantidade_tarefas'] ?? 1).toString(),
              ),
              buildDetailRow(
                'Modo de Trabalho:',
                task['modo_de_trabalho']?.toString() ?? '',
              ),
              buildDetailRow(
                'Comentário:',
                task['comentario']?.toString() ?? '',
              ),
              if (task['item'] != null)
                buildDetailRow('Item:', task['item']?.toString() ?? ''),
              if (task['lider'] != null)
                buildDetailRow('Líder:', task['lider']?.toString() ?? ''),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  Widget buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Painel do Usuário • Tarefas'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Image.asset('assets/images/tivit_logo.png', height: 28),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Card(
          margin: EdgeInsets.zero,
          color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.98),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                buildUserSelector(),
                const SizedBox(height: 16),
                if (selectedUserId != null) ...[
                  buildFilters(),
                  const SizedBox(height: 16),
                  if (loading) const LinearProgressIndicator(),
                  if (errorMsg != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        errorMsg!,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  buildTableHeader(context),
                  const SizedBox(height: 8),
                  Expanded(child: buildTableBody()),
                ] else if (usersLoading) ...[
                  const Expanded(
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ] else ...[
                  const Expanded(
                    child: Center(
                      child: Text(
                        'Selecione um usuário para visualizar suas tarefas',
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class UserTaskTableRow extends StatelessWidget {
  final Map<String, dynamic> task;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final String Function(dynamic) fmtDateTime;
  final Text Function(String, {FontWeight? fw, TextAlign? align, int maxLines})
  cellText;

  const UserTaskTableRow({
    super.key,
    required this.task,
    required this.onEdit,
    required this.onDelete,
    required this.fmtDateTime,
    required this.cellText,
  });

  @override
  Widget build(BuildContext context) {
    final isAdmin = UserSession().isAdmin;
    final isEditable = task['is_editable'] == true || isAdmin;
    final statusId = task['projectstates_id'] as int?;
    final canDelete = statusId != 3 || isAdmin;

    final taskName = (task['name'] ?? '').toString();
    final status = (task['status_name'] ?? '').toString();
    final item = (task['item'] ?? '').toString();
    final startDate = fmtDateTime(
      task['real_start_date'] ?? task['data_start_real'],
    );
    final endDate = fmtDateTime(
      task['real_end_date'] ?? task['user_conclude_date'],
    );
    final quantity = (task['quantidade_tarefas'] ?? 1).toString();
    final comment = firstCommentFrom(task['comentario']);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onEdit,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 72,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: isEditable
                          ? 'Editar tarefa'
                          : 'Visualizar tarefa',
                      icon: Icon(
                        isEditable ? Icons.edit : Icons.visibility,
                        size: 18,
                        color: isEditable ? Colors.blue : Colors.grey,
                      ),
                      onPressed: onEdit,
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                    ),
                    IconButton(
                      tooltip: canDelete
                          ? 'Excluir tarefa'
                          : 'Não é possível excluir (Aprovado/Fechado)',
                      icon: Icon(
                        Icons.delete,
                        size: 18,
                        color: canDelete ? Colors.red : Colors.grey,
                      ),
                      onPressed: canDelete ? onDelete : null,
                      visualDensity: const VisualDensity(
                        horizontal: -4,
                        vertical: -4,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 3, child: cellText(taskName, maxLines: 2)),
              const SizedBox(width: 8),
              SizedBox(width: 120, child: cellText(status, maxLines: 1)),
              const SizedBox(width: 8),
              SizedBox(width: 100, child: cellText(item, maxLines: 1)),
              const SizedBox(width: 8),
              SizedBox(width: 120, child: cellText(startDate, maxLines: 1)),
              const SizedBox(width: 8),
              SizedBox(width: 120, child: cellText(endDate, maxLines: 1)),
              const SizedBox(width: 8),
              SizedBox(
                width: 60,
                child: cellText(quantity, maxLines: 1, align: TextAlign.center),
              ),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: cellText(comment, maxLines: 2)),
            ],
          ),
        ),
      ),
    );
  }

  String firstCommentFrom(dynamic content) {
    final raw = (content ?? '').toString().trim();
    if (raw.isEmpty) return '—';
    final idx = raw.indexOf('\n---');
    if (idx <= 0) return raw;
    return raw.substring(0, idx).trim().isEmpty
        ? '—'
        : raw.substring(0, idx).trim();
  }
}

// helpers
String formatHoras(double h) =>
    h % 1 == 0 ? '${h.toStringAsFixed(0)} h' : '${h.toStringAsFixed(1)} h';
double? parseTempoPrevisto(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString().replaceAll(',', '.'));
}

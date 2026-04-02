import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/enterprise_api_service.dart';
import 'package:dropdown_search/dropdown_search.dart';

class AprovacaoScreen extends StatefulWidget {
  const AprovacaoScreen({super.key});

  @override
  State<AprovacaoScreen> createState() => _AprovacaoScreenState();
}

class _AprovacaoScreenState extends State<AprovacaoScreen> {
  final _searchCtrl = TextEditingController();
  final _vScroll = ScrollController(); // vertical scroll controller
  final _hScroll = ScrollController(); // horizontal scroll controller

  bool _loading = false;
  bool _bulkLoading = false;
  String? _error;
  List<String> _optsAtividade = [];
  List<String> _optsRealizadoPor = [];
  List<String> _optsSolicitante = [];

  // Current selections (null = no filter)
  String? _fAtividade;
  String? _fRealizadoPor;
  String? _fSolicitante;

  // Status filter: default to Aguardando Aprovacao (7)
  final Set<int> _selectedStatuses = {7};

  List<Map<String, dynamic>> _tasks = [];
  List<Map<String, dynamic>> _filtered = [];

  // Only checkboxes toggle selection
  final Set<int> _selected = <int>{};

  final int _projectId = 599;
  final int _pageSize = 50;
  final int _currentPage = 0;
  int? _sortColumnIndex;
  bool _sortAsc = true;

  int _ts(dynamic v) {
    if (v == null) return 1 << 60; // nulls last
    try {
      return DateTime.parse(
        v.toString().replaceFirst(' ', 'T'),
      ).millisecondsSinceEpoch;
    } catch (_) {
      return 1 << 59; // unparsable after nulls
    }
  }

  int _cmpStr(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
  List<int> _parseDotted(String s) {
    if (s.isEmpty) return const [];
    return s.split('.').map((p) => int.tryParse(p) ?? -1).toList();
  }

  int _cmpDotted(String a, String b) {
    final A = _parseDotted(a);
    final B = _parseDotted(b);
    final len = (A.length > B.length) ? A.length : B.length;
    for (var i = 0; i < len; i++) {
      final ai = i < A.length ? A[i] : -1;
      final bi = i < B.length ? B[i] : -1;
      if (ai != bi) return ai.compareTo(bi);
    }
    // tie-breaker: plain string compare
    return _cmpStr(a, b);
  }

  void _applySort(
    int columnIndex,
    bool ascending,
    int Function(Map a, Map b) compare,
  ) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _sortAsc = ascending;
      _filtered.sort((a, b) {
        final c = compare(a, b);
        return ascending ? c : -c;
      });
    });
  }

  // Column indexes (your header layout has a checkbox at 0)
  static const _colSolicitante = 1;
  static const _colAtividade = 2;
  static const _colItem = 3;
  static const _colComentario = 4;
  static const _colTipoEvid = 5;
  static const _colRealizado = 6;
  static const _colInicio = 7;
  static const _colFim = 8;

  // Map each column to its comparator
  late final Map<int, int Function(Map<String, dynamic>, Map<String, dynamic>)>
  _comparators;

  void _sortWith(int columnIndex) {
    final cmp = _comparators[columnIndex];
    if (cmp == null) return;

    setState(() {
      if (_sortColumnIndex == columnIndex) {
        _sortAsc = !_sortAsc;
      } else {
        _sortColumnIndex = columnIndex;
        _sortAsc = true;
      }
      _filtered.sort((a, b) {
        final c = cmp(a, b);
        return _sortAsc ? c : -c;
      });
    });
  }

  /// Re-apply current sort after filtering/reloading
  void _reapplySortIfAny() {
    final idx = _sortColumnIndex;
    if (idx == null) return;
    final cmp = _comparators[idx];
    if (cmp == null) return;
    _filtered.sort((a, b) {
      final c = cmp(a, b);
      return _sortAsc ? c : -c;
    });
  }

  // Tiny visual on headers
  Widget _sortLabel(String text, int columnIndex) {
    final isActive = _sortColumnIndex == columnIndex;
    final icon = _sortAsc ? Icons.arrow_upward : Icons.arrow_downward;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
        ),
        if (isActive) ...[const SizedBox(width: 4), Icon(icon, size: 14)],
      ],
    );
  }

  List<Map<String, dynamic>> get _currentPageItems {
    final start = _currentPage * _pageSize;
    final end = start + _pageSize;
    return _filtered.length > start
        ? _filtered.sublist(
            start,
            end > _filtered.length ? _filtered.length : end,
          )
        : [];
  }

  @override
  void initState() {
    super.initState();
    _comparators =
        <int, int Function(Map<String, dynamic>, Map<String, dynamic>)>{
          _colSolicitante: (a, b) => _cmpStr(_leaderOf(a), _leaderOf(b)),
          _colAtividade: (a, b) => _cmpStr(
            (a['name'] ?? '').toString(),
            (b['name'] ?? '').toString(),
          ),
          _colItem: (a, b) => _cmpDotted(
            (a['item'] ?? '').toString(),
            (b['item'] ?? '').toString(),
          ),
          _colComentario: (a, b) => _cmpStr(
            _firstCommentFrom(a['content']),
            _firstCommentFrom(b['content']),
          ),
          _colTipoEvid: (a, b) => _cmpStr(
            (a['tipo_de_evidencia'] ?? '').toString(),
            (b['tipo_de_evidencia'] ?? '').toString(),
          ),
          _colRealizado: (a, b) => _cmpStr(_creatorOf(a), _creatorOf(b)),
          _colInicio: (a, b) =>
              _ts(a['real_start_date']) - _ts(b['real_start_date']),
          _colFim: (a, b) => _ts(a['real_end_date']) - _ts(b['real_end_date']),
        };
    _load();
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _vScroll.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  // Compact text for cells/headers
  Text _cellText(
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

  Text _headerText(String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    softWrap: false,
    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
  );

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _selected.clear();
    });
    try {
      final list = await EnterpriseApiService.getClosedTasks(
        projectId: _projectId,
        statusIds: _selectedStatuses.toList(),
      ).timeout(const Duration(seconds: 15));

      // Oldest first by real_end_date (user_conclude_date)
      list.sort((a, b) {
        int ts(dynamic v) {
          if (v == null) return 1 << 30;
          try {
            return DateTime.parse(
              v.toString().replaceFirst(' ', 'T'),
            ).millisecondsSinceEpoch;
          } catch (_) {
            return 1 << 29;
          }
        }

        return ts(a['real_end_date']) - ts(b['real_end_date']);
      });

      setState(() {
        _tasks = list;
        _filtered = List.of(list);
      });
      final atividades = <String>{};
      final realizadoPor = <String>{};
      final solicitantes = <String>{};

      for (final t in _tasks) {
        final a = (t['name'] ?? '').toString().trim();
        if (a.isNotEmpty) atividades.add(a);

        final r = _creatorOf(t).trim();
        if (r.isNotEmpty) realizadoPor.add(r);

        final s = _leaderOf(t).trim();
        if (s.isNotEmpty && s != '—') {
          solicitantes.add(s); // keep '—' out of list
        }
      }

      setState(() {
        _optsAtividade = atividades.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        _optsRealizadoPor = realizadoPor.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
        _optsSolicitante = solicitantes.toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

        // Clear selected filters if they don't exist in the new dataset
        if (_fAtividade != null && !_optsAtividade.contains(_fAtividade)) {
          _fAtividade = null;
        }
        if (_fRealizadoPor != null &&
            !_optsRealizadoPor.contains(_fRealizadoPor)) {
          _fRealizadoPor = null;
        }
        if (_fSolicitante != null &&
            !_optsSolicitante.contains(_fSolicitante)) {
          _fSolicitante = null;
        }
      });

      // Reapply dropdown filters to the newly loaded tasks
      _applyFilter();

      // Note: _recomputeAtividadeOptions() is called inside _applyFilter()

      _enrichRowsInBulkIfNeeded();
    } catch (e) {
      setState(() => _error = 'Falha ao carregar tarefas: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _enrichRowsInBulkIfNeeded() async {
    // Pick rows that are missing fields you want to show in the table.
    // Adjust the conditions to your needs (keep this lightweight).
    final needIds = <int>[];
    for (final t in _tasks) {
      final id = t['id'];
      if (id is! int) continue;
      final hasLider = (t['lider'] ?? '').toString().trim().isNotEmpty;
      final hasCreator = (t['criador_display'] ?? t['creator_name'] ?? '')
          .toString()
          .trim()
          .isNotEmpty;
      if (!hasLider || !hasCreator) {
        needIds.add(id);
      }
    }
    if (needIds.isEmpty) return;

    try {
      final enriched = await EnterpriseApiService.getTasksBulk(needIds);
      if (!mounted) return;

      // Merge by id into _tasks and _filtered
      final byId = {for (final e in enriched) e['id'] as int: e};
      for (var i = 0; i < _tasks.length; i++) {
        final id = _tasks[i]['id'];
        if (id is int && byId.containsKey(id)) {
          _tasks[i] = {..._tasks[i], ...byId[id]!};
        }
      }
      for (var i = 0; i < _filtered.length; i++) {
        final id = _filtered[i]['id'];
        if (id is int && byId.containsKey(id)) {
          _filtered[i] = {..._filtered[i], ...byId[id]!};
        }
      }
      setState(() {});
    } catch (_) {
      // Best-effort enrichment; swallow errors to not break the table
    }
  }

  String _creatorOf(Map<String, dynamic> task) {
    final v = task['criador_display'] ?? task['creator_name'];
    return (v is String && v.trim().isNotEmpty) ? v : '—';
  }

  String? _leaderFromMap(Map<String, dynamic>? m) {
    if (m == null) return null;
    const keys = [
      'lider',
      'leader',
      'lider_name',
      'liderNome',
      'lider_display',
    ];
    for (final k in keys) {
      final v = m[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  String _leaderOf(Map<String, dynamic> t) {
    final v = _leaderFromMap(t);
    return (v == null || v.isEmpty) ? '—' : v;
  }

  // Derive ONLY the first comment chunk from "content"
  String _firstCommentFrom(dynamic content) {
    final raw = (content ?? '').toString().trim();
    if (raw.isEmpty) return '—';
    final idx = raw.indexOf('\n---');
    if (idx <= 0) {
      return raw;
    }
    return raw.substring(0, idx).trim().isEmpty
        ? '—'
        : raw.substring(0, idx).trim();
  }

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

  void _applyFilter() {
    setState(() {
      _filtered = _tasks.where((t) {
        final a = (t['name'] ?? '').toString().trim();
        final r = _creatorOf(t).trim(); // "Realizado por"
        final s = _leaderOf(t).trim(); // "Solicitante" (líder)

        if (_fAtividade != null &&
            _fAtividade!.isNotEmpty &&
            a != _fAtividade) {
          return false;
        }
        if (_fRealizadoPor != null &&
            _fRealizadoPor!.isNotEmpty &&
            r != _fRealizadoPor) {
          return false;
        }
        if (_fSolicitante != null &&
            _fSolicitante!.isNotEmpty &&
            s != _fSolicitante) {
          return false;
        }

        return true;
      }).toList();
      _reapplySortIfAny();
    });
    // Recompute Atividade options based on newly filtered results
    _recomputeAtividadeOptions();
  }

  void _recomputeAtividadeOptions() {
    // Build from currently filtered/displayed tasks
    // This ensures the Atividade dropdown only shows activities
    // that exist in the current view (filtered by Status + Realizado por + Solicitante)
    final set = <String>{};
    for (final t in _filtered) {
      final a = (t['name'] ?? '').toString().trim();
      if (a.isNotEmpty) set.add(a);
    }
    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    setState(() {
      _optsAtividade = list;
      // if the currently selected atividade is no longer available, clear it
      if (_fAtividade != null && !_optsAtividade.contains(_fAtividade)) {
        _fAtividade = null;
      }
    });
  }

  Future<void> _openTaskDetails(int taskId) async {
    try {
      final details = await EnterpriseApiService.getTaskDetails(taskId);
      if (!mounted) return;

      final leader = _leaderFromMap(details);
      if (leader != null && leader.trim().isNotEmpty) {
        final idx = _tasks.indexWhere((e) => e['id'] == taskId);
        if (idx != -1) _tasks[idx] = {..._tasks[idx], 'lider': leader};
        final fidx = _filtered.indexWhere((e) => e['id'] == taskId);
        if (fidx != -1) _filtered[fidx] = {..._filtered[fidx], 'lider': leader};
        if (mounted) setState(() {});
      }

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => _TaskDetailsSheet(data: details),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Falha ao abrir tarefa: $e')));
    }
  }

  // === Approver picker ===
  Future<String?> _askApprover() async {
    List<String> names = const [];
    try {
      names = await EnterpriseApiService.getLiderNames();
      names = names.where((e) => e.trim().isNotEmpty).toSet().toList()..sort();
    } catch (e) {
      if (!mounted) return null;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao carregar aprovadores: $e')),
      );
      return null;
    }
    if (!mounted) return null;

    String? selected;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Quem está aprovando?'),
              content: DropdownButtonFormField<String>(
                initialValue: selected,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Aprovador',
                  border: OutlineInputBorder(),
                ),
                items: names
                    .map(
                      (n) => DropdownMenuItem<String>(value: n, child: Text(n)),
                    )
                    .toList(),
                onChanged: (v) => setLocal(() => selected = v),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: selected == null
                      ? null
                      : () => Navigator.of(ctx).pop(selected),
                  child: const Text('Confirmar'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _bulkRejectSelected() async {
    if (_selected.isEmpty) return;

    // Ask the “reprovador” once for all
    final approver = await _askApprover();
    if (approver == null || approver.isEmpty) return;

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Reprovar tarefas selecionadas'),
        content: Text('Confirmar reprovação de ${_selected.length} tarefa(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reprovar'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _bulkLoading = true);

    final ids = _selected.toList();
    const window = 4;
    int idx = 0;

    Future<void> worker() async {
      while (true) {
        if (idx >= ids.length) break;
        final i = idx++;
        final taskId = ids[i];
        try {
          await EnterpriseApiService.updateGlpiTaskStatus(
            taskId: taskId,
            projectstatesId: 9, // Reprovado
            userId: 0,
          );
          // record “aprovado_por/aprovado_data” even when reprovado (same endpoint)
          try {
            await EnterpriseApiService.recordFormApproval(
              taskId: taskId,
              aprovadoPor: approver,
              aprovadoData: DateTime.now(),
              statusForma: 'Reprovado',
            );
          } catch (_) {}
          await EnterpriseApiService.syncTaskStatus(taskId);
        } catch (_) {}
      }
    }

    await Future.wait(List.generate(window, (_) => worker()));

    _tasks.removeWhere((t) => _selected.contains(t['id']));
    _filtered.removeWhere((t) => _selected.contains(t['id']));
    _selected.clear();

    if (mounted) {
      setState(() => _bulkLoading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Reprovação enviada.')));
    }
  }

  Future<void> _bulkApproveSelected() async {
    if (_selected.isEmpty) return;

    // Ask approver once for all
    final approver = await _askApprover();
    if (approver == null || approver.isEmpty) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Aprovar tarefas selecionadas'),
        content: Text('Confirmar aprovação de ${_selected.length} tarefa(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Aprovar'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _bulkLoading = true);

    final ids = _selected.toList();
    final failedTasks = <int>[]; // Track failed tasks
    final successfulTasks = <int>[]; // Track successful tasks
    const window = 2;
    int idx = 0;

    Future<void> worker() async {
      while (true) {
        int i;
        // simple index reservation
        if (idx >= ids.length) break;
        i = idx++;
        final taskId = ids[i];
        try {
          final glpiSuccess = await EnterpriseApiService.updateGlpiTaskStatus(
            taskId: taskId,
            projectstatesId: 3,
            userId: 0,
          );
          if (!glpiSuccess) {
            failedTasks.add(taskId);
            continue;
          }
          // record approver (best-effort)
          try {
            await EnterpriseApiService.recordFormApproval(
              taskId: taskId,
              aprovadoPor: approver,
              aprovadoData: DateTime.now(),
              statusForma: 'Fechado',
            );
            successfulTasks.add(taskId);
          } catch (formError) {
            debugPrint(
              'FAILED to update formas_enviadas for task $taskId: $formError',
            );
            failedTasks.add(taskId);
          }
          await EnterpriseApiService.syncTaskStatus(taskId);
        } catch (e) {
          debugPrint('Unexpected error processing task $taskId: $e');
          failedTasks.add(taskId);
        }
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    await Future.wait(List.generate(window, (_) => worker()));

    _tasks.removeWhere((t) => successfulTasks.contains(t['id']));
    _filtered.removeWhere((t) => successfulTasks.contains(t['id']));
    _selected.clear();

    if (mounted) {
      setState(() => _bulkLoading = false);
      if (failedTasks.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Aprovação parcial: ${successfulTasks.length} sucesso, ${failedTasks.length} falhas',
            ),
            backgroundColor: Colors.orange,
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aprovação concluída com sucesso!')),
        );
      }
    }
  }

  Widget _buildFilters() {
    return Column(
      children: [
        // Status filter row (checkboxes)
        _buildStatusFilter(),
        const SizedBox(height: 8),

        // Existing filters row
        Row(
          children: [
            // Atividade
            Expanded(
              flex: 5,
              child: DropdownSearch<String>(
                items: _optsAtividade,
                selectedItem: _fAtividade,
                popupProps: const PopupProps.modalBottomSheet(
                  showSearchBox: true,
                ),
                clearButtonProps: const ClearButtonProps(isVisible: true),
                dropdownDecoratorProps: const DropDownDecoratorProps(
                  dropdownSearchDecoration: InputDecoration(
                    labelText: 'Atividade',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                onChanged: (v) {
                  setState(
                    () => _fAtividade = v?.trim().isEmpty == true ? null : v,
                  );
                  _applyFilter();
                },
              ),
            ),
            const SizedBox(width: 8),

            // Realizado por
            Expanded(
              flex: 3,
              child: DropdownSearch<String>(
                items: _optsRealizadoPor,
                selectedItem: _fRealizadoPor,
                popupProps: const PopupProps.modalBottomSheet(
                  showSearchBox: true,
                ),
                clearButtonProps: const ClearButtonProps(isVisible: true),
                dropdownDecoratorProps: const DropDownDecoratorProps(
                  dropdownSearchDecoration: InputDecoration(
                    labelText: 'Realizado por',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                onChanged: (v) {
                  setState(
                    () => _fRealizadoPor = v?.trim().isEmpty == true ? null : v,
                  );
                  _recomputeAtividadeOptions();
                  _applyFilter();
                },
              ),
            ),
            const SizedBox(width: 8),

            // Solicitante (líder)
            Expanded(
              flex: 3,
              child: DropdownSearch<String>(
                items: _optsSolicitante,
                selectedItem: _fSolicitante,
                popupProps: const PopupProps.modalBottomSheet(
                  showSearchBox: true,
                ),
                clearButtonProps: const ClearButtonProps(isVisible: true),
                dropdownDecoratorProps: const DropDownDecoratorProps(
                  dropdownSearchDecoration: InputDecoration(
                    labelText: 'Solicitante',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
                onChanged: (v) {
                  setState(
                    () => _fSolicitante = v?.trim().isEmpty == true ? null : v,
                  );
                  _recomputeAtividadeOptions();
                  _applyFilter();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatusFilter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Text(
            'Status:',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(width: 8),

          // Aguardando Aprovacao
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _selectedStatuses.contains(7),
                  onChanged: (val) {
                    // Prevent unchecking if it's the only one selected
                    if (val == false && _selectedStatuses.length == 1) return;
                    setState(() {
                      if (val == true) {
                        _selectedStatuses.add(7);
                      } else {
                        _selectedStatuses.remove(7);
                      }
                    });
                    _load();
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: const VisualDensity(
                    horizontal: -4,
                    vertical: -4,
                  ),
                ),
                const SizedBox(width: 4),
                const Flexible(
                  child: Text(
                    'Aguardando Aprovação',
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Aprovado
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _selectedStatuses.contains(3),
                  onChanged: (val) {
                    // Prevent unchecking if it's the only one selected
                    if (val == false && _selectedStatuses.length == 1) return;
                    setState(() {
                      if (val == true) {
                        _selectedStatuses.add(3);
                      } else {
                        _selectedStatuses.remove(3);
                      }
                    });
                    _load();
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: const VisualDensity(
                    horizontal: -4,
                    vertical: -4,
                  ),
                ),
                const SizedBox(width: 4),
                const Flexible(
                  child: Text(
                    'Aprovado',
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),

          // Reprovado
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: _selectedStatuses.contains(9),
                  onChanged: (val) {
                    // Prevent unchecking if it's the only one selected
                    if (val == false && _selectedStatuses.length == 1) return;
                    setState(() {
                      if (val == true) {
                        _selectedStatuses.add(9);
                      } else {
                        _selectedStatuses.remove(9);
                      }
                    });
                    _load();
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: const VisualDensity(
                    horizontal: -4,
                    vertical: -4,
                  ),
                ),
                const SizedBox(width: 4),
                const Flexible(
                  child: Text(
                    'Reprovado',
                    style: TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Aprovação • Tarefas'),
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
          color: cs.surface.withValues(alpha: 0.98),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                _buildFilters(),
                if (_loading) const LinearProgressIndicator(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 6),

                // Scrollable table: sticky header (vertical) + shared horizontal scroll
                // Scrollable table: sticky header (vertical) + shared horizontal scroll
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final needsHScroll = constraints.maxWidth < 1200;

                      // Column with header (fixed vertically) + scrollable body
                      Widget table = Column(
                        children: [
                          _buildTableHeader(context),
                          const SizedBox(height: 4),
                          Expanded(child: _buildOptimizedTableBody(context)),
                        ],
                      );

                      if (!needsHScroll) {
                        // On wide screens, no horizontal scroll needed
                        return table;
                      }

                      // On narrow screens, wrap header + body in a shared horizontal scroll
                      return Scrollbar(
                        controller: _hScroll,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _hScroll,
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                            width:
                                1200, // same logical width as your header/row layout
                            child: table,
                          ),
                        ),
                      );
                    },
                  ),
                ),

                if (_selected.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        // Bulk Approve
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _bulkLoading
                                ? null
                                : _bulkApproveSelected,
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.green.shade600,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            icon: _bulkLoading
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.check_circle,
                                    color: Colors.white,
                                  ),
                            label: Text(
                              _bulkLoading
                                  ? 'Aprovando...'
                                  : 'Aprovar selecionadas (${_selected.length})',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Bulk Reject
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: _bulkLoading
                                ? null
                                : _bulkRejectSelected,
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.red.shade600,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                            icon: _bulkLoading
                                ? const SizedBox(
                                    height: 18,
                                    width: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.cancel, color: Colors.white),
                            label: Text(
                              _bulkLoading
                                  ? 'Reprovando...'
                                  : 'Reprovar selecionadas (${_selected.length})',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTableHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          // Checkbox
          SizedBox(width: 22, child: _buildMasterCheckbox()),
          const SizedBox(width: 8),

          // Solicitante
          SizedBox(
            width: 110,
            child: InkWell(
              onTap: () => _sortWith(_colSolicitante),
              child: _sortLabel('Solicitante', _colSolicitante),
            ),
          ),
          const SizedBox(width: 8),

          // Atividade
          Expanded(
            flex: 45,
            child: InkWell(
              onTap: () => _sortWith(_colAtividade),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _sortLabel('Atividade', _colAtividade),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Item (NEW – fixed width, sortable with dotted comparator)
          SizedBox(
            width: 120,
            child: InkWell(
              onTap: () => _sortWith(_colItem),
              child: _sortLabel('Item', _colItem),
            ),
          ),
          const SizedBox(width: 8),
          // Comentário
          Expanded(
            flex: 55,
            child: InkWell(
              onTap: () => _sortWith(_colComentario),
              child: Align(
                alignment: Alignment.centerLeft,
                child: _sortLabel('Comentário', _colComentario),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // NEW: Tipo de Evidência
          SizedBox(
            width: 160,
            child: InkWell(
              onTap: () => _sortWith(_colTipoEvid),
              child: _sortLabel('Tipo de Evidência', _colTipoEvid),
            ),
          ),
          const SizedBox(width: 8),

          // Realizado por
          SizedBox(
            width: 120,
            child: InkWell(
              onTap: () => _sortWith(_colRealizado),
              child: _sortLabel('Realizado por', _colRealizado),
            ),
          ),
          const SizedBox(width: 8),

          // Início
          SizedBox(
            width: 120,
            child: InkWell(
              onTap: () => _sortWith(_colInicio),
              child: _sortLabel('Início', _colInicio),
            ),
          ),
          const SizedBox(width: 8),

          // Fim
          SizedBox(
            width: 120,
            child: InkWell(
              onTap: () => _sortWith(_colFim),
              child: _sortLabel('Fim', _colFim),
            ),
          ),
          const SizedBox(width: 8),

          // Actions
          const SizedBox(
            width: 34,
            child: Text(
              'Detail',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMasterCheckbox() {
    // Only consider tasks with status 7 (Aguardando Aprovacao) for selection
    final selectableTasks = _filtered
        .where((t) => t['projectstates_id'] == 7)
        .toList();

    if (selectableTasks.isEmpty) {
      return Checkbox(
        value: false,
        onChanged: null, // Disabled if no selectable tasks
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
      );
    }

    final allSelected = selectableTasks.every(
      (t) => _selected.contains(t['id']),
    );
    final someSelected = selectableTasks.any(
      (t) => _selected.contains(t['id']),
    );
    final bool? headerValue = allSelected
        ? true
        : (someSelected ? null : false);

    return Checkbox(
      value: headerValue,
      tristate: true,
      onChanged: (val) {
        setState(() {
          if (val == true) {
            _selected.addAll(selectableTasks.map((t) => t['id'] as int));
          } else {
            _selected.removeWhere(
              (id) => selectableTasks.any((t) => t['id'] == id),
            );
          }
        });
      },
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: const VisualDensity(horizontal: -4, vertical: -4),
    );
  }

  Widget _buildOptimizedTableBody(BuildContext context) {
    if (_filtered.isEmpty && !_loading) {
      return const Center(child: Text('Nenhuma tarefa encontrada.'));
    }

    return MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(1.0)),
      child: ListView.builder(
        controller: _vScroll,
        itemCount: _filtered.length,
        itemBuilder: (context, index) {
          final task = _filtered[index];
          return _TaskTableRow(
            task: task,
            isSelected: _selected.contains(task['id']),
            onSelectChanged: (selected) {
              setState(() {
                if (selected) {
                  _selected.add(task['id'] as int);
                } else {
                  _selected.remove(task['id'] as int);
                }
              });
            },
            onTap: () => _openTaskDetails(task['id'] as int),
            leaderOf: _leaderOf,
            fmtDateTime: fmtDateTime,
            firstCommentFrom: _firstCommentFrom,
            creatorOf: _creatorOf,
            cellText: _cellText,
          );
        },
      ),
    );
  }
}

class _TaskTableRow extends StatelessWidget {
  final Map<String, dynamic> task;
  final bool isSelected;
  final ValueChanged<bool> onSelectChanged;
  final VoidCallback onTap;
  final String Function(Map<String, dynamic>) leaderOf;
  final String Function(dynamic) fmtDateTime;
  final String Function(dynamic) firstCommentFrom;
  final String Function(Map<String, dynamic>) creatorOf;
  final Text Function(String, {FontWeight? fw, TextAlign? align, int maxLines})
  cellText;

  const _TaskTableRow({
    required this.task,
    required this.isSelected,
    required this.onSelectChanged,
    required this.onTap,
    required this.leaderOf,
    required this.fmtDateTime,
    required this.firstCommentFrom,
    required this.creatorOf,
    required this.cellText,
  });

  @override
  Widget build(BuildContext context) {
    // Pre-calculate all values once
    final lider = leaderOf(task);
    final enviado = fmtDateTime(task['enviado_em']);
    final atividade = (task['name'] ?? '').toString();
    final comentario = firstCommentFrom(task['content']);
    final item = (task['item'] ?? '').toString();
    final criador = creatorOf(task);
    final inicio = fmtDateTime(task['real_start_date']);
    final fim = fmtDateTime(task['real_end_date']);
    final tipoEvid = (task['tipo_de_evidencia'] ?? '').toString();

    // Determine row color based on status
    final projectstatesId = task['projectstates_id'] as int?;
    Color? rowColor;
    bool isSelectable = true;

    if (projectstatesId == 3) {
      // Aprovado - light green
      rowColor = const Color(0xFFC8E6C9);
      isSelectable = false;
    } else if (projectstatesId == 9) {
      // Reprovado - light red
      rowColor = const Color(0xFFFFCDD2);
      isSelectable = false;
    }

    return Material(
      color:
          rowColor ??
          (isSelected
              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.1)
              : Colors.transparent),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
          ),
          child: Row(
            children: [
              // Checkbox (disabled for Aprovado/Reprovado)
              SizedBox(
                width: 22,
                child: Checkbox(
                  value: isSelected,
                  onChanged: isSelectable
                      ? (val) => onSelectChanged(val ?? false)
                      : null,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: const VisualDensity(
                    horizontal: -4,
                    vertical: -4,
                  ),
                ),
              ),
              const SizedBox(width: 8),

              // Solicitante
              SizedBox(width: 110, child: cellText(lider, maxLines: 1)),
              const SizedBox(width: 8),
              // Atividade
              Expanded(flex: 45, child: cellText(atividade, maxLines: 3)),
              const SizedBox(width: 8),
              // Item (NEW)
              SizedBox(width: 120, child: cellText(item, maxLines: 1)),
              const SizedBox(width: 8),
              // Comentário
              Expanded(flex: 55, child: cellText(comentario, maxLines: 3)),
              const SizedBox(width: 8),
              // Tipo de Evidência (NEW)
              SizedBox(
                width: 160,
                child: cellText(tipoEvid.isEmpty ? '—' : tipoEvid, maxLines: 2),
              ),
              const SizedBox(width: 8),
              // Realizado por
              SizedBox(width: 120, child: cellText(criador, maxLines: 1)),
              const SizedBox(width: 8),

              // Início
              SizedBox(width: 120, child: cellText(inicio, maxLines: 1)),
              const SizedBox(width: 8),

              // Fim
              SizedBox(width: 120, child: cellText(fim, maxLines: 1)),
              const SizedBox(width: 8),

              // Actions
              SizedBox(
                width: 34,
                child: IconButton(
                  tooltip: 'Detalhes',
                  icon: const Icon(Icons.open_in_new, size: 18),
                  onPressed: onTap,
                  visualDensity: const VisualDensity(
                    horizontal: -4,
                    vertical: -4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: cs.onPrimaryContainer),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: cs.onPrimaryContainer)),
        ],
      ),
    );
  }
}

class _TaskDetailsSheet extends StatelessWidget {
  final Map<String, dynamic> data;

  const _TaskDetailsSheet({required this.data});

  String _fmtDateTime(dynamic s) {
    if (s == null) return '-';
    final raw = s.toString().trim();
    if (raw.isEmpty) return '-';

    try {
      final dt = DateTime.parse(
        raw.contains('T') ? raw : raw.replaceFirst(' ', 'T'),
      );
      final local = dt.toLocal();

      final dd = local.day.toString().padLeft(2, '0');
      final mm = local.month.toString().padLeft(2, '0');
      final yyyy = local.year.toString().padLeft(4, '0');
      final hh = local.hour.toString().padLeft(2, '0');
      final mi = local.minute.toString().padLeft(2, '0');
      return '$dd/$mm/$yyyy $hh:$mi';
    } catch (_) {
      return raw;
    }
  }

  String _fmtQtd(dynamic v) {
    if (v == null) return '—';
    if (v is num) {
      // if it's an int-like decimal, show as int
      return v % 1 == 0 ? v.toInt().toString() : v.toString();
    }
    final s = v.toString().trim();
    return s.isEmpty ? '—' : s;
  }

  String _resolveDocUrl(Map<String, dynamic> d) {
    final proxy = d['download_url']?.toString();
    if (proxy != null && proxy.isNotEmpty) {
      return proxy.startsWith('http') ? proxy : '$PORT$proxy';
    }
    final direct = d['url']?.toString();
    return direct ?? '';
  }

  @override
  Widget build(BuildContext context) {
    final docs =
        (data['documents'] as List?)?.cast<Map<String, dynamic>>() ??
        const <Map<String, dynamic>>[];
    final name = (data['name'] ?? '').toString();
    final creator = (data['criador_display'] ?? data['creator_name'] ?? '-')
        .toString();
    final lider = (data['lider'] ?? '-').toString();
    final start = _fmtDateTime(data['real_start_date']);
    final end = _fmtDateTime(data['real_end_date']);
    final content = (data['content'] ?? '').toString();
    final status = (data['status_name'] ?? '').toString();
    final qtdTarefas = _fmtQtd(data['quantidade_tarefas']);
    final enviado = _fmtDateTime(data['enviado_em']);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  _MetaChip(icon: Icons.person, label: 'Criador: $creator'),
                  _MetaChip(icon: Icons.badge, label: 'Líder: $lider'),
                  _MetaChip(
                    icon: Icons.send_time_extension,
                    label: 'Data solicitação: $enviado',
                  ),
                  _MetaChip(icon: Icons.flag, label: 'Status: $status'),
                  _MetaChip(icon: Icons.play_arrow, label: 'Início: $start'),
                  _MetaChip(icon: Icons.check_circle, label: 'Fim: $end'),
                  _MetaChip(
                    icon: Icons.format_list_numbered,
                    label: 'Qtd tarefas: $qtdTarefas',
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (content.isNotEmpty)
                Text(content, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 16),
              Text(
                'Documentos (${docs.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              if (docs.isEmpty)
                const Text('Nenhum documento anexado.')
              else
                Column(
                  children: docs.map((d) {
                    final label = (d['name'] ?? d['filename'] ?? 'Documento')
                        .toString();
                    final resolved = _resolveDocUrl(d);
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.attach_file),
                      title: Text(label),
                      trailing: TextButton.icon(
                        icon: const Icon(Icons.download),
                        label: const Text('Baixar'),
                        onPressed: resolved.isEmpty
                            ? null
                            : () async {
                                final uri = Uri.parse(resolved);
                                if (await canLaunchUrl(uri)) {
                                  await launchUrl(
                                    uri,
                                    mode: LaunchMode.externalApplication,
                                  );
                                }
                              },
                      ),
                    );
                  }).toList(),
                ),

              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  label: const Text('Fechar'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dropdown_search/dropdown_search.dart';
import '../services/enterprise_api_service.dart';
import 'package:url_launcher/url_launcher.dart';

class GestaoDespesasScreen extends StatefulWidget {
  const GestaoDespesasScreen({super.key});

  @override
  State<GestaoDespesasScreen> createState() => _GestaoDespesasScreenState();
}

class _GestaoDespesasScreenState extends State<GestaoDespesasScreen> {
  // Filters
  String? _selectedTipo; // 'Refeição' | 'Hospedagem'
  String? _selectedStatus; // 'Aguardando Aprovação' | 'Aprovado' | 'Reprovado'
  Map<String, dynamic>? _selectedUser;
  DateTime? _from;
  DateTime? _to;
  // Leader (required before actions)
  List<String> _lideres = [];
  String? _selectedLider;

  // Data
  bool _loadingFilters = false;
  bool _loading = false;
  bool _loadingMore = false;
  String? _error;
  List<Map<String, dynamic>> _rows = [];
  int _offset = 0;
  final int _limit = 50;

  // Users for filter
  List<Map<String, dynamic>> _users = [];

  // Selection for bulk
  final Set<int> _selectedIds = {};

  // Filter visibility
  bool _filterVisible = true;

  @override
  void initState() {
    super.initState();
    _loadFilters();
  }

  Future<void> _loadFilters() async {
    setState(() {
      _loadingFilters = true;
      _error = null;
    });
    try {
      final users = await EnterpriseApiService.getGlpiUsers();
      final lideres = await EnterpriseApiService.getLiderNames();
      setState(() {
        _users = users;
        _lideres = lideres;
      });
    } catch (e) {
      setState(() => _error = 'Falha ao carregar filtros: $e');
    } finally {
      setState(() => _loadingFilters = false);
    }
  }

  String _toYmd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickDate({required bool isFrom}) async {
    final now = DateTime.now();
    final initial = isFrom ? (_from ?? now) : (_to ?? now);
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        if (isFrom) {
          _from = picked;
        } else {
          _to = picked;
        }
      });
    }
  }

  Future<void> _load({bool reset = true}) async {
    if (_selectedLider == null || _selectedLider!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecione um Líder antes de continuar.')),
      );
      return;
    }

    if (reset) {
      setState(() {
        _loading = true;
        _rows = [];
        _offset = 0;
        _selectedIds.clear();
        _error = null;
      });
    } else {
      setState(() {
        _loadingMore = true;
      });
    }

    try {
      final list = await EnterpriseApiService.getDespesasAdmin(
        tipo: _selectedTipo,
        userId: _selectedUser != null ? _selectedUser!['id'] as int : null,
        status: _selectedStatus,
        fromYmd: _from != null ? _toYmd(_from!) : null,
        toYmd: _to != null ? _toYmd(_to!) : null,
        limit: _limit,
        offset: _offset,
      ).timeout(const Duration(seconds: 20));

      setState(() {
        _rows.addAll(list);
        _offset += list.length;
      });
    } catch (e) {
      setState(() => _error = 'Falha ao carregar despesas: $e');
    } finally {
      setState(() {
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Color _statusColor(String s, ColorScheme cs) {
    switch (s) {
      case 'Aprovado':
        return Colors.green;
      case 'Reprovado':
        return Colors.red;
      case 'Aguardando Aprovação':
        return Colors.amber.shade700;
      default:
        return cs.outline;
    }
  }

  Future<void> _approveSelected({required bool approve}) async {
    if (_selectedIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecione pelo menos uma despesa.')),
      );
      return;
    }
    final motivo = approve ? null : await _askMotivo();
    if (!mounted) return;

    try {
      final count = await EnterpriseApiService.setDespesaAprovacaoBulk(
        ids: _selectedIds.toList(),
        aprovacao: approve ? 'Aprovado' : 'Reprovado',
        aprovadoPor: _selectedLider!,
        motivo: motivo,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Atualizadas: $count')));
      await _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Falha: $e')));
    }
  }

  Future<String?> _askMotivo() async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Motivo da reprovação'),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'Descreva o motivo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Confirmar'),
          ),
        ],
      ),
    );
  }

  // ---------- FILTER BAR (overflow-safe, adaptive) ----------
  Widget _buildFilters(ColorScheme cs) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 900;

        // Common controls (no hard widths)
        final liderField = DropdownButtonFormField<String>(
          initialValue: _selectedLider,
          decoration: const InputDecoration(labelText: 'Líder (aprovador)'),
          items: _lideres
              .map((n) => DropdownMenuItem(value: n, child: Text(n)))
              .toList(),
          onChanged: (v) => setState(() => _selectedLider = v),
        );

        final statusField = DropdownButtonFormField<String?>(
          initialValue: _selectedStatus,
          isDense: true,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Status',
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: const [
            DropdownMenuItem(value: null, child: Text('Todos')),
            DropdownMenuItem(
              value: 'Aguardando Aprovação',
              child: Text('Aguardando Aprovação'),
            ),
            DropdownMenuItem(value: 'Aprovado', child: Text('Aprovado')),
            DropdownMenuItem(value: 'Reprovado', child: Text('Reprovado')),
          ],
          onChanged: (v) => setState(() => _selectedStatus = v),
        );

        final tipoField = DropdownButtonFormField<String?>(
          initialValue: _selectedTipo,
          isDense: true,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Tipo de Despesa',
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          ),
          items: const [
            DropdownMenuItem(value: null, child: Text('Todos')),
            DropdownMenuItem(value: 'Refeição', child: Text('Refeição')),
            DropdownMenuItem(value: 'Hospedagem', child: Text('Hospedagem')),
            DropdownMenuItem(value: 'Pedágio', child: Text('Pedágio')),
            DropdownMenuItem(
              value: 'Material de Escritório',
              child: Text('Material de Escritório'),
            ),
            DropdownMenuItem(value: 'EPI', child: Text('EPI')),
            DropdownMenuItem(value: 'Outros', child: Text('Outros')),
          ],
          onChanged: (v) => setState(() => _selectedTipo = v),
        );

        final usuarioField = DropdownSearch<Map<String, dynamic>>(
          items: _users,
          selectedItem: _selectedUser,
          itemAsString: (u) => '${u['name']} (ID: ${u['id']})',
          dropdownButtonProps: const DropdownButtonProps(),
          dropdownDecoratorProps: const DropDownDecoratorProps(
            dropdownSearchDecoration: InputDecoration(labelText: 'Usuário'),
          ),
          onChanged: (u) => setState(() => _selectedUser = u),
          popupProps: const PopupProps.modalBottomSheet(showSearchBox: true),
        );

        final deField = TextFormField(
          readOnly: true,
          controller: TextEditingController(
            text: _from == null
                ? ''
                : '${_from!.day.toString().padLeft(2, '0')}/${_from!.month.toString().padLeft(2, '0')}/${_from!.year}',
          ),
          decoration: const InputDecoration(
            labelText: 'De',
            suffixIcon: Icon(Icons.calendar_today),
          ),
          onTap: () => _pickDate(isFrom: true),
        );

        final ateField = TextFormField(
          readOnly: true,
          controller: TextEditingController(
            text: _to == null
                ? ''
                : '${_to!.day.toString().padLeft(2, '0')}/${_to!.month.toString().padLeft(2, '0')}/${_to!.year}',
          ),
          decoration: const InputDecoration(
            labelText: 'Até',
            suffixIcon: Icon(Icons.calendar_today),
          ),
          onTap: () => _pickDate(isFrom: false),
        );

        final buscarBtn = FilledButton.icon(
          onPressed: _loading
              ? null
              : () {
                  _load(reset: true);
                  setState(() => _filterVisible = false);
                },
          icon: const Icon(Icons.search),
          label: const Text('Buscar'),
        );

        if (wide) {
          // 3 rows, responsive Expanded — no overflow
          return Column(
            children: [
              Row(
                children: [
                  Expanded(flex: 2, child: liderField),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: statusField,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 1,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: tipoField,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(flex: 2, child: usuarioField),
                  const SizedBox(width: 12),
                  Expanded(flex: 1, child: deField),
                  const SizedBox(width: 12),
                  Expanded(flex: 1, child: ateField),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Spacer(),
                  SizedBox(height: 48, child: buscarBtn),
                ],
              ),
            ],
          );
        }

        // NARROW: stack vertically; spacing handles all sizes
        return Column(
          children: [
            liderField,
            const SizedBox(height: 10),
            statusField,
            const SizedBox(height: 10),
            tipoField,
            const SizedBox(height: 10),
            usuarioField,
            const SizedBox(height: 10),
            deField,
            const SizedBox(height: 10),
            ateField,
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, height: 48, child: buscarBtn),
          ],
        );
      },
    );
  }
  // ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Gestão de despesas'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Image.asset('assets/images/tivit_logo.png', height: 28),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                if (_loadingFilters) const LinearProgressIndicator(),

                // Filter card — collapsible
                Card(
                  color: cs.surface.withValues(alpha: 0.98),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      InkWell(
                        onTap: () =>
                            setState(() => _filterVisible = !_filterVisible),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              const Icon(Icons.filter_list),
                              const SizedBox(width: 8),
                              const Text(
                                'Filtros',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                              const Spacer(),
                              Icon(
                                _filterVisible
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_filterVisible)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          child: _buildFilters(cs),
                        ),
                    ],
                  ),
                ),

                const SizedBox(height: 8),

                // Bulk actions + selection - responsive with Wrap
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value:
                              _rows.isNotEmpty &&
                              _selectedIds.length == _rows.length,
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selectedIds
                                  ..clear()
                                  ..addAll(
                                    _rows.map((e) => e['despesa_id'] as int),
                                  );
                              } else {
                                _selectedIds.clear();
                              }
                            });
                          },
                        ),
                        const Text('Selecionar todos'),
                      ],
                    ),
                    OutlinedButton.icon(
                      onPressed: _rows.isEmpty
                          ? null
                          : () => _approveSelected(approve: false),
                      icon: const Icon(Icons.close, color: Colors.red),
                      label: const Text('Reprovar'),
                    ),
                    FilledButton.icon(
                      onPressed: _rows.isEmpty
                          ? null
                          : () => _approveSelected(approve: true),
                      icon: const Icon(Icons.check),
                      label: const Text('Aprovar'),
                    ),
                  ],
                ),

                const SizedBox(height: 8),

                if (_loading) const LinearProgressIndicator(),

                Expanded(
                  child: _rows.isEmpty && !_loading
                      ? Card(
                          color: cs.surface.withValues(alpha: 0.98),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                'Nenhuma despesa pendente para aprovação.',
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _rows.length + 1, // +1 for "load more"
                          itemBuilder: (context, index) {
                            if (index == _rows.length) {
                              // Load more
                              return Center(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  child: _loadingMore
                                      ? const CircularProgressIndicator()
                                      : OutlinedButton(
                                          onPressed: () => _load(reset: false),
                                          child: const Text('Carregar mais'),
                                        ),
                                ),
                              );
                            }

                            final d = _rows[index];
                            final id = d['despesa_id'] as int;

                            final bool prestacaoRealizadaFlag =
                                (d['prestacao_realizada']
                                        ?.toString()
                                        .toUpperCase() ??
                                    'NÃO') ==
                                'SIM';

                            return _AdminDespesaCard(
                              data: d,
                              selected: _selectedIds.contains(id),
                              onSelected: (sel) {
                                setState(() {
                                  if (sel) {
                                    _selectedIds.add(id);
                                  } else {
                                    _selectedIds.remove(id);
                                  }
                                });
                              },

                              // >>> Internal + callback (já existente)
                              internal:
                                  (d['internal']?.toString() ?? 'nao') == 'sim',
                              onInternalChanged: (value) async {
                                final ctx = context;
                                final newValue = value ? 'sim' : 'nao';

                                try {
                                  await EnterpriseApiService.setDespesaInternal(
                                    despesaId: id,
                                    internal: newValue,
                                  );

                                  if (!ctx.mounted) return;
                                  setState(() {
                                    _rows[index]['internal'] = newValue;
                                  });

                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        value
                                            ? 'Despesa marcada como Internal.'
                                            : 'Despesa desmarcada como Internal.',
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Falha ao atualizar Internal: $e',
                                      ),
                                    ),
                                  );
                                }
                              },

                              // >>> NOVO: Prestação Realizada + callback
                              prestacaoRealizada: prestacaoRealizadaFlag,
                              onPrestacaoRealizadaChanged: (value) async {
                                final ctx = context;
                                final newValue = value ? 'SIM' : 'NÃO';

                                try {
                                  await EnterpriseApiService.setPrestacaoRealizada(
                                    despesaId: id,
                                    realizada: value,
                                  );

                                  if (!ctx.mounted) return;
                                  setState(() {
                                    _rows[index]['prestacao_realizada'] =
                                        newValue;
                                  });

                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        value
                                            ? 'Prestação marcada como realizada.'
                                            : 'Prestação marcada como NÃO realizada.',
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Falha ao atualizar Prestação Realizada: $e',
                                      ),
                                    ),
                                  );
                                }
                              },

                              statusColor: _statusColor,
                              onApprove: () async {
                                final ctx = context;
                                try {
                                  await EnterpriseApiService.setDespesaAprovacao(
                                    despesaId: id,
                                    aprovacao: 'Aprovado',
                                    aprovadoPor: _selectedLider!,
                                  );
                                  if (!ctx.mounted) return;
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(content: Text('Aprovado.')),
                                  );
                                  await _load(reset: true);
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(content: Text('Falha: $e')),
                                  );
                                }
                              },
                              onReject: () async {
                                final ctx = context;
                                final motivo = await _askMotivo();
                                try {
                                  await EnterpriseApiService.setDespesaAprovacao(
                                    despesaId: id,
                                    aprovacao: 'Reprovado',
                                    aprovadoPor: _selectedLider!,
                                    motivo: motivo,
                                  );
                                  if (!ctx.mounted) return;
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    const SnackBar(content: Text('Reprovado.')),
                                  );
                                  await _load(reset: true);
                                } catch (e) {
                                  if (!ctx.mounted) return;
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                    SnackBar(content: Text('Falha: $e')),
                                  );
                                }
                              },
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AdminDespesaCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final Color Function(String, ColorScheme) statusColor;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final bool internal;
  final ValueChanged<bool> onInternalChanged;
  // >>> NOVO:
  final bool prestacaoRealizada;
  final ValueChanged<bool> onPrestacaoRealizadaChanged;

  const _AdminDespesaCard({
    required this.data,
    required this.selected,
    required this.onSelected,
    required this.statusColor,
    required this.onApprove,
    required this.onReject,
    required this.internal,
    required this.onInternalChanged,
    required this.prestacaoRealizada,
    required this.onPrestacaoRealizadaChanged,
  });

  @override
  State<_AdminDespesaCard> createState() => _AdminDespesaCardState();
}

class _AdminDespesaCardState extends State<_AdminDespesaCard> {
  bool _justificativaExpanded = false;

  // Arquivos
  bool _filesExpanded = false;
  bool _filesLoading = false;
  List<Map<String, dynamic>>? _files; // null = not loaded yet

  Future<void> _loadFiles() async {
    if (_files != null) return; // already loaded
    setState(() => _filesLoading = true);
    try {
      final id = widget.data['despesa_id'] as int;
      final files = await EnterpriseApiService.getDespesaFiles(id);
      if (mounted) setState(() => _files = files);
    } catch (_) {
      if (mounted) setState(() => _files = []);
    } finally {
      if (mounted) setState(() => _filesLoading = false);
    }
  }

  String _formatDate(String? ymd) {
    if (ymd == null || ymd.isEmpty) return '-';
    try {
      final d = DateTime.parse(ymd).toLocal();
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    } catch (_) {
      return ymd;
    }
  }

  String _formatMoney(dynamic v) {
    if (v == null) return 'R\$ 0,00';
    final num n = (v is num) ? v : num.tryParse(v.toString()) ?? 0;
    return 'R\$ ${n.toStringAsFixed(2).replaceAll('.', ',')}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tipo = widget.data['tipo_de_despesa']?.toString() ?? '-';
    final valor = _formatMoney(widget.data['valor_despesa']);
    final dataConsumo = _formatDate(widget.data['data_consumo']?.toString());
    final qtd = widget.data['quantidade']?.toString() ?? '0';
    final contrato = widget.data['contrato']?.toString() ?? '';
    final aprovacao = widget.data['aprovacao']?.toString() ?? '';
    final userName = widget.data['user_name']?.toString() ?? '';
    final userId = widget.data['user_id']?.toString() ?? '';
    final justificativa = widget.data['justificativa']?.toString().trim();
    final photoUrl = widget.data['photo_url']?.toString();
    final photoDocId = widget.data['photo_docid'] as int?;
    final proxyUrl = (photoDocId != null)
        ? EnterpriseApiService.glpiDocProxyUrl(photoDocId)
        : null;

    return Card(
      color: cs.surface.withValues(alpha: 0.98),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Checkbox(
                  value: widget.selected,
                  onChanged: (v) => widget.onSelected(v ?? false),
                ),
                Expanded(
                  child: Text(
                    tipo,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: widget
                        .statusColor(aprovacao, cs)
                        .withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: widget.statusColor(aprovacao, cs),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.verified,
                        size: 14,
                        color: widget.statusColor(aprovacao, cs),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        aprovacao,
                        style: TextStyle(
                          color: widget.statusColor(aprovacao, cs),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Expandable Justificativa Section
            InkWell(
              onTap: () {
                setState(() {
                  _justificativaExpanded = !_justificativaExpanded;
                });
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(
                      _justificativaExpanded
                          ? Icons.expand_less
                          : Icons.expand_more,
                      size: 20,
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Justificativa:',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: cs.onSurface.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_justificativaExpanded) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
                ),
                child: Text(
                  (justificativa == null || justificativa.isEmpty)
                      ? '-'
                      : justificativa,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 6),

            // Arquivos anexados
            InkWell(
              onTap: () {
                final opening = !_filesExpanded;
                setState(() => _filesExpanded = opening);
                if (opening) _loadFiles();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: cs.outline.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(
                      _filesExpanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.attach_file, size: 16),
                    const SizedBox(width: 4),
                    Text(
                      'Arquivos',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: cs.onSurface.withValues(alpha: 0.8),
                      ),
                    ),
                    if (_files != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '(${_files!.length})',
                        style: TextStyle(
                          fontSize: 13,
                          color: cs.onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (_filesExpanded) ...[
              const SizedBox(height: 6),
              if (_filesLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                )
              else if (_files == null || _files!.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    'Nenhum arquivo anexado.',
                    style: TextStyle(
                      color: cs.onSurface.withValues(alpha: 0.6),
                      fontSize: 13,
                    ),
                  ),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [for (final f in _files!) _FileChip(file: f)],
                ),
            ],
            const SizedBox(height: 6),

            // >>> Checkbox "Internal" controlado pelo líder/admin
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: widget.internal,
                      onChanged: (v) => widget.onInternalChanged(v ?? false),
                    ),
                    const Text('Internal'),
                  ],
                ),
                const SizedBox(width: 16),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: widget.prestacaoRealizada,
                      onChanged: (v) =>
                          widget.onPrestacaoRealizadaChanged(v ?? false),
                    ),
                    const Text('Prestação Realizada'),
                  ],
                ),
              ],
            ),

            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                _InfoChip(icon: Icons.person, label: '$userName (ID: $userId)'),
                _InfoChip(icon: Icons.calendar_today, label: dataConsumo),
                _InfoChip(icon: Icons.confirmation_number, label: 'Qtd: $qtd'),
                if (contrato.isNotEmpty)
                  _InfoChip(icon: Icons.badge, label: contrato),
              ],
            ),
            Row(
              children: [
                // NEW: open via backend proxy (recommended)
                if (proxyUrl != null) ...[
                  const Icon(Icons.download, size: 16),
                  const SizedBox(width: 6),
                  Flexible(
                    child: TextButton(
                      onPressed: () => launchUrl(
                        Uri.parse(proxyUrl),
                        mode: LaunchMode.externalApplication,
                      ),
                      child: const Text(
                        'Abrir documento',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],

                // Existing: show raw GLPI link + copy
                if (photoUrl != null && photoUrl.isNotEmpty) ...[
                  const Icon(Icons.link, size: 16),
                  const SizedBox(width: 4),
                  Flexible(
                    child: SelectableText(
                      photoUrl,
                      maxLines: 1,
                      style: TextStyle(
                        color: cs.primary,
                        decoration: TextDecoration.underline,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: () async {
                      try {
                        // Ensure we await the async clipboard op
                        await Clipboard.setData(ClipboardData(text: photoUrl));

                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Link copiado para a área de transferência',
                            ),
                          ),
                        );
                      } catch (e) {
                        if (!context.mounted) return;
                        // Fallback UX if the browser blocks clipboard (e.g., HTTP origin)
                        showDialog<void>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Não foi possível copiar'),
                            content: SelectableText(
                              photoUrl,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx),
                                child: const Text('Fechar'),
                              ),
                            ],
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('Copiar'),
                  ),
                ],

                const Spacer(),
                Text(
                  valor,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: widget.onReject,
                  icon: const Icon(Icons.close, color: Colors.red),
                  label: const Text('Reprovar'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: widget.onApprove,
                  icon: const Icon(Icons.check),
                  label: const Text('Aprovar'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: cs.onSurface.withValues(alpha: 0.7)),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.9)),
          ),
        ],
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  final Map<String, dynamic> file;
  const _FileChip({required this.file});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final filename = file['filename']?.toString() ?? '';
    final url = file['url']?.toString();
    final sizeBytes = (file['size'] as num?)?.toInt() ?? 0;
    final sizeKb = (sizeBytes / 1024).toStringAsFixed(1);

    return InkWell(
      onTap: url != null
          ? () =>
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)
          : null,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: cs.primaryContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: cs.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file, size: 14, color: cs.primary),
            const SizedBox(width: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: Text(
                filename,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: cs.onSurface),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              '$sizeKb KB',
              style: TextStyle(
                fontSize: 11,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

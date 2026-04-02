import 'package:flutter/material.dart';
import 'package:dropdown_search/dropdown_search.dart';
import '../services/enterprise_api_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/user_session.dart';


class MinhasDespesasScreen extends StatefulWidget {
  const MinhasDespesasScreen({super.key});

  @override
  State<MinhasDespesasScreen> createState() => _MinhasDespesasScreenState();
}

class _MinhasDespesasScreenState extends State<MinhasDespesasScreen> {
  final _scrollCtrl = ScrollController();

  // Users
  bool _loadingUsers = false;
  String? _error;
  List<Map<String, dynamic>> _users = [];
  Map<String, dynamic>? _selectedUser;
  bool _isUserFieldLocked = false; // For tivit role users

  // Despesas
  bool _loading = false;
  List<Map<String, dynamic>> _despesas = [];

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() {
      _loadingUsers = true;
      _error = null;
    });
    try {
      final data = await EnterpriseApiService.getGlpiUsers().timeout(
        const Duration(seconds: 10),
      );

      // Check if current user is tivit role and auto-select
      final session = UserSession();
      final isTivit = session.isTivit;
      final glpiUserId = session.glpiUserId;

      if (isTivit && glpiUserId != null) {
        // Find the user in the list
        final currentUser = data.firstWhere(
          (u) => u['id'] == glpiUserId,
          orElse: () => {},
        );

        if (currentUser.isNotEmpty) {
          setState(() {
            _users = data;
            _selectedUser = currentUser;
            _isUserFieldLocked = true;
          });

          // Auto-load despesas for the locked user
          _loadDespesas();
        } else {
          setState(() => _users = data);
        }
      } else {
        setState(() => _users = data);
      }
    } catch (e) {
      setState(() => _error = 'Falha ao carregar usuários GLPI: $e');
    } finally {
      setState(() => _loadingUsers = false);
    }
  }

  Future<void> _loadDespesas() async {
    if (_selectedUser == null) {
      setState(() => _despesas = []);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await EnterpriseApiService.getDespesasByUser(
        userId: _selectedUser!['id'] as int,
      ).timeout(const Duration(seconds: 15));
      setState(() => _despesas = rows);
    } catch (e) {
      setState(() => _error = 'Falha ao carregar despesas: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  String _formatDate(String? ymd) {
    if (ymd == null || ymd.isEmpty) return '-';
    try {
      final d = DateTime.parse(ymd); // "YYYY-MM-DD"
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

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Minhas despesas'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Image.asset('assets/images/tivit_logo.png', height: 28),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadDespesas,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              controller: _scrollCtrl,
              padding: const EdgeInsets.all(16),
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                if (_loadingUsers) const LinearProgressIndicator(),
                // User dropdown
                DropdownSearch<Map<String, dynamic>>(
                  items: _users,
                  selectedItem: _selectedUser,
                  itemAsString: (u) =>
                      '${u['name'] ?? ''} (ID: ${u['id'] ?? ''})',
                  enabled: !_isUserFieldLocked, // Disable for tivit users
                  dropdownDecoratorProps: DropDownDecoratorProps(
                    dropdownSearchDecoration: InputDecoration(
                      labelText: _isUserFieldLocked
                          ? 'Usuário (GLPI) - (bloqueado)'
                          : 'Usuário (GLPI)',
                    ),
                  ),
                  onChanged: _isUserFieldLocked
                      ? null // Disable callback when locked
                      : (u) {
                          setState(() => _selectedUser = u);
                          _loadDespesas();
                        },
                  popupProps: const PopupProps.menu(showSearchBox: true),
                ),
                const SizedBox(height: 16),

                if (_loading) const LinearProgressIndicator(),

                if (!_loading && _selectedUser != null && _despesas.isEmpty)
                  Card(
                    color: cs.surface.withValues(alpha: 0.98),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Nenhuma despesa encontrada para este usuário.',
                      ),
                    ),
                  ),

                // Cards list
                ..._despesas.map((d) {
                  return _DespesaCard(
                    data: d,
                    formatMoney: _formatMoney,
                    formatDateBr: _formatDate,
                    onSaved: _loadDespesas, // refresh list after save
                  );
                }),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DespesaCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final String Function(dynamic) formatMoney;
  final String Function(String?) formatDateBr;
  final Future<void> Function() onSaved;

  const _DespesaCard({
    required this.data,
    required this.formatMoney,
    required this.formatDateBr,
    required this.onSaved,
  });

  @override
  State<_DespesaCard> createState() => _DespesaCardState();
}class _DespesaCardState extends State<_DespesaCard> {
  bool _editing = false;
  bool _saving = false;
  bool _loadingArquivos = false;
  List<Map<String, dynamic>> _arquivos = [];

  late TextEditingController _tipoCtrl;
  late TextEditingController _valorCtrl;
  late TextEditingController _qtdCtrl;
  late TextEditingController _justCtrl;
  DateTime? _dataConsumo;

  @override
  void initState() {
    super.initState();
    final d = widget.data;

    _tipoCtrl = TextEditingController(text: d['tipo_de_despesa']?.toString() ?? '');
    _valorCtrl = TextEditingController(
      text: (d['valor_despesa'] == null)
          ? ''
          : (d['valor_despesa'] is num
              ? (d['valor_despesa'] as num).toStringAsFixed(2).replaceAll('.', ',')
              : d['valor_despesa'].toString()),
    );
    _qtdCtrl = TextEditingController(text: d['quantidade']?.toString() ?? '');
    _justCtrl = TextEditingController(text: d['justificativa']?.toString() ?? '');

    try {
      _dataConsumo = d['data_consumo'] != null ? DateTime.parse(d['data_consumo']) : null;
    } catch (_) {
      _dataConsumo = null;
    }
    _loadArquivos();
  }

  @override
  void didUpdateWidget(covariant _DespesaCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data['despesa_id'] != widget.data['despesa_id']) {
      _loadArquivos();
    }
  }

  Future<void> _loadArquivos() async {
    final despesaId = widget.data['despesa_id'] as int?;
    if (despesaId == null) return;
    if (!mounted) return;
    setState(() => _loadingArquivos = true);
    try {
      final res = await EnterpriseApiService.getDespesaFiles(despesaId);
      if (mounted) setState(() => _arquivos = res);
    } catch (e) {
      debugPrint('Error loading files: $e');
    } finally {
      if (mounted) setState(() => _loadingArquivos = false);
    }
  }

  @override
  void dispose() {
    _tipoCtrl.dispose();
    _valorCtrl.dispose();
    _qtdCtrl.dispose();
    _justCtrl.dispose();
    super.dispose();
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

  Future<void> _removeFile(int fileId) async {
    final despesaId = widget.data['despesa_id'] as int?;
    if (despesaId == null) return;

    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover arquivo?'),
        content: const Text('O arquivo será removido fisicamente e desvinculado desta despesa.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remover')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _saving = true);
    try {
      await EnterpriseApiService.deleteDespesaFile(despesaId, fileId);
      await widget.onSaved(); // optional parent refresh
      await _loadArquivos(); // refresh local list
      if (!mounted) return;
      _show('Arquivo removido.');
    } catch (e) {
      _show('Falha ao remover: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addFiles() async {
    final despesaId = widget.data['despesa_id'] as int?;
    if (despesaId == null) return;

    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'pdf', 'txt', 'doc', 'docx', 'heic'],
    );
    if (picked == null || picked.files.isEmpty) return;

    setState(() => _saving = true);
    try {
      await EnterpriseApiService.uploadDocuments(
        despesaId: despesaId,
        files: picked.files,
      );

      await widget.onSaved(); // optional parent refresh
      await _loadArquivos();
      if (!mounted) return;
      _show('Arquivo(s) adicionado(s).');
    } catch (e) {
      _show('Falha ao enviar: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final initial = _dataConsumo ?? now;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _dataConsumo = picked);
    }
  }

  Future<void> _save() async {
    final despesaId = widget.data['despesa_id'] as int?;
    if (despesaId == null) return;

    // validations (minimal)
    final tipo = _tipoCtrl.text.trim();
    if (tipo.isEmpty) {
      _show('Tipo de despesa é obrigatório');
      return;
    }
    final rawValor = _valorCtrl.text.trim().replaceAll(',', '.');
    final valor = double.tryParse(rawValor);
    if (valor == null) {
      _show('Valor de despesa inválido');
      return;
    }
    final qtd = int.tryParse(_qtdCtrl.text.trim());
    if (qtd == null) {
      _show('Quantidade inválida');
      return;
    }
    if (_dataConsumo == null) {
      _show('Data de consumo é obrigatória');
      return;
    }

    setState(() => _saving = true);
    try {
      await EnterpriseApiService.updateDespesa(
        despesaId: despesaId,
        tipoDespesa: tipo,
        valor: valor,
        dataConsumo: _dataConsumo!,
        quantidade: qtd,
        justificativa: _justCtrl.text.trim(),
      );
      await widget.onSaved();
      if (!mounted) return;
      setState(() => _editing = false);
      _show('Despesa atualizada com sucesso');
    } catch (e) {
      _show('Falha ao atualizar: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _show(String msg) {
    final ctx = context;
    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _deleteDespesa() async {
    final despesaId = widget.data['despesa_id'] as int?;
    if (despesaId == null) return;

    final ctx = context;
    final confirm = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: const Text('Excluir despesa'),
        content: const Text(
          'Esta ação apagará a despesa e o arquivo no GLPI (se existir). Deseja continuar?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _saving = true);

    try {
      await EnterpriseApiService.deleteDespesa(despesaId);
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(
        ctx,
      ).showSnackBar(const SnackBar(content: Text('Despesa excluída')));
      await widget.onSaved(); // refresh list
    } catch (e) {
      if (!ctx.mounted) return;
      ScaffoldMessenger.of(
        ctx,
      ).showSnackBar(SnackBar(content: Text('Falha ao excluir: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final d = widget.data;
    final tipo = d['tipo_de_despesa']?.toString() ?? '-';
    final valor = widget.formatMoney(d['valor_despesa']);
    final data = widget.formatDateBr(d['data_consumo']?.toString());
    final qtd = d['quantidade']?.toString() ?? '0';
    final contrato = d['contrato']?.toString() ?? '';
    final justificativa = d['justificativa']?.toString() ?? '';
    final aprovacao = d['aprovacao']?.toString() ?? '-';
    final motivo = d['aprovacao_motivo']?.toString().trim();
    final canEdit = aprovacao != 'Aprovado';

    return Card(
      color: cs.surface.withValues(alpha: 0.98),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // header row
            Row(
              children: [
                Expanded(
                  child: Text(
                    tipo,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                // Status chip
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _statusColor(aprovacao, cs).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _statusColor(aprovacao, cs)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.verified,
                        size: 14,
                        color: _statusColor(aprovacao, cs),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        aprovacao,
                        style: TextStyle(
                          color: _statusColor(aprovacao, cs),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Edit button
                if (!canEdit)
                  Tooltip(
                    message: 'Registro aprovado não pode ser editado',
                    child: Icon(Icons.lock, color: cs.outline),
                  )
                else
                  TextButton.icon(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _editing = !_editing),
                    icon: Icon(_editing ? Icons.close : Icons.edit),
                    label: Text(_editing ? 'Cancelar' : 'Editar'),
                  ),
              ],
            ),
            const SizedBox(height: 6),

            if (!_editing) ...[
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _InfoChip(icon: Icons.calendar_today, label: data),
                  _InfoChip(
                    icon: Icons.confirmation_number,
                    label: 'Qtd: $qtd',
                  ),
                  if (contrato.isNotEmpty)
                    _InfoChip(icon: Icons.badge, label: contrato),
                ],
              ),
              if (justificativa.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  justificativa,
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.8)),
                ),
              ],
              const SizedBox(height: 8),
              const Text(
                'Arquivos',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),

              if (_loadingArquivos)
                const LinearProgressIndicator()
              else if (_arquivos.isEmpty)
                Text(
                  'Nenhum arquivo anexado.',
                  style: TextStyle(color: cs.onSurface.withValues(alpha: 0.7)),
                )
              else
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _arquivos.map((arq) {
                    final url = arq['url'] as String;
                    return InputChip(
                      avatar: const Icon(Icons.attach_file, size: 16),
                      label: Text(
                        arq['filename']?.toString() ?? 'Arquivo',
                        style: const TextStyle(fontSize: 12),
                      ),
                      onPressed: () {
                        final ext = url.split('.').last.toLowerCase();
                        if (['jpg', 'jpeg', 'png', 'gif'].contains(ext)) {
                          showDialog(
                            context: context,
                            builder: (ctx) => Dialog(
                              insetPadding: const EdgeInsets.all(16),
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  InteractiveViewer(
                                    child: Image.network(url, fit: BoxFit.contain),
                                  ),
                                  Positioned(
                                    top: 8,
                                    right: 8,
                                    child: IconButton(
                                      icon: const Icon(Icons.close, color: Colors.white),
                                      style: IconButton.styleFrom(backgroundColor: Colors.black54),
                                      onPressed: () => Navigator.pop(ctx),
                                    ),
                                  )
                                ],
                              ),
                            ),
                          );
                        } else {
                          launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
                        }
                      },
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: (canEdit && !_saving) ? () => _removeFile(arq['id'] as int) : null,
                    );
                  }).toList(),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text(
                    valor,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  if (canEdit)
                    OutlinedButton.icon(
                      onPressed: _saving ? null : _deleteDespesa,
                      icon: const Icon(Icons.delete_forever, color: Colors.red),
                      label: const Text('Excluir despesa'),
                    ),
                ],
              ),
              if (canEdit)
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _addFiles,
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Adicionar arquivo(s)'),
                  ),
                ),
              // show motivo if present (only when Reprovado or reason exists)
              if (motivo != null && motivo.isNotEmpty) ...[
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.withValues(alpha: 0.08),
                    border: Border.all(
                      color: Colors.red.withValues(alpha: 0.4),
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: Colors.red,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          motivo,
                          style: TextStyle(
                            color: Colors.red.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 6),
            ] else ...[
              const SizedBox(height: 8),
              // Edit fields
              LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth > 600;
                  return Column(
                    children: [
                      if (isWide)
                        Row(
                          children: [
                            Expanded(
                              child: _LabeledField(
                                label: 'Tipo de Despesa',
                                child: DropdownButtonFormField<String>(
                                  initialValue: _tipoCtrl.text.isEmpty
                                      ? null
                                      : _tipoCtrl.text,
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'Refeição',
                                      child: Text('Refeição'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'Hospedagem',
                                      child: Text('Hospedagem'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'Estacionamento',
                                      child: Text('Estacionamento'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'Material de Escritório',
                                      child: Text('Material de Escritório'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'EPI',
                                      child: Text('EPI'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'Outros',
                                      child: Text('Outros'),
                                    ),
                                  ],
                                  onChanged: (v) =>
                                      setState(() => _tipoCtrl.text = v ?? ''),
                                  decoration: const InputDecoration(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _LabeledField(
                                label: 'Valor de Despesa',
                                child: TextField(
                                  controller: _valorCtrl,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  decoration: const InputDecoration(
                                    hintText: '0,00',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      else ...[
                        _LabeledField(
                          label: 'Tipo de Despesa',
                          child: DropdownButtonFormField<String>(
                            initialValue: _tipoCtrl.text.isEmpty
                                ? null
                                : _tipoCtrl.text,
                            items: const [
                              DropdownMenuItem(
                                value: 'Refeição',
                                child: Text('Refeição'),
                              ),
                              DropdownMenuItem(
                                value: 'Hospedagem',
                                child: Text('Hospedagem'),
                              ),
                              DropdownMenuItem(
                                value: 'Estacionamento',
                                child: Text('Estacionamento'),
                              ),
                              DropdownMenuItem(
                                value: 'Material de Escritório',
                                child: Text('Material de Escritório'),
                              ),
                              DropdownMenuItem(
                                value: 'EPI',
                                child: Text('EPI'),
                              ),
                              DropdownMenuItem(
                                value: 'Outros',
                                child: Text('Outros'),
                              ),
                            ],
                            onChanged: (v) =>
                                setState(() => _tipoCtrl.text = v ?? ''),
                            decoration: const InputDecoration(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _LabeledField(
                          label: 'Valor de Despesa',
                          child: TextField(
                            controller: _valorCtrl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(hintText: '0,00'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      if (isWide)
                        Row(
                          children: [
                            Expanded(
                              child: _LabeledField(
                                label: 'Data de Consumo',
                                child: InkWell(
                                  onTap: _pickDate,
                                  child: InputDecorator(
                                    decoration: const InputDecoration(),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _dataConsumo == null
                                              ? 'Selecionar data'
                                              : '${_dataConsumo!.day.toString().padLeft(2, '0')}/${_dataConsumo!.month.toString().padLeft(2, '0')}/${_dataConsumo!.year}',
                                        ),
                                        const Icon(
                                          Icons.calendar_today,
                                          size: 18,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _LabeledField(
                                label: 'Quantidade',
                                child: TextField(
                                  controller: _qtdCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    hintText: '0',
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      else ...[
                        _LabeledField(
                          label: 'Data de Consumo',
                          child: InkWell(
                            onTap: _pickDate,
                            child: InputDecorator(
                              decoration: const InputDecoration(),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    _dataConsumo == null
                                        ? 'Selecionar data'
                                        : '${_dataConsumo!.day.toString().padLeft(2, '0')}/${_dataConsumo!.month.toString().padLeft(2, '0')}/${_dataConsumo!.year}',
                                  ),
                                  const Icon(Icons.calendar_today, size: 18),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        _LabeledField(
                          label: 'Quantidade',
                          child: TextField(
                            controller: _qtdCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(hintText: '0'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      _LabeledField(
                        label: 'Justificativa',
                        child: TextField(
                          controller: _justCtrl,
                          maxLines: 3,
                          decoration: const InputDecoration(
                            hintText: 'Digite a justificativa',
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.icon(
                          onPressed: _saving ? null : _save,
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.save),
                          label: const Text('Salvar'),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
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

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  const _LabeledField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

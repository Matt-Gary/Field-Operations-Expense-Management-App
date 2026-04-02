import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dropdown_search/dropdown_search.dart';
import '../services/enterprise_api_service.dart';

class MedicaoVeiculosScreen extends StatefulWidget {
  const MedicaoVeiculosScreen({super.key});

  @override
  State<MedicaoVeiculosScreen> createState() => _MedicaoVeiculosScreenState();
}

class _MedicaoVeiculosScreenState extends State<MedicaoVeiculosScreen> {
  final _formKey = GlobalKey<FormState>();

  // Dropdowns data
  List<String> _lideres = [];
  List<Map<String, dynamic>> _glpiUsers = [];
  bool _loadingData = false;

  // Form state
  DateTime? _mes;
  DateTime? _dataInicio;
  DateTime? _dataFim;
  String? _solicitante;
  String? _grupoEnterprise;
  String? _tipoVeiculo;
  String? _periodoUtiliza;
  final _qtdCtrl = TextEditingController();
  Map<String, dynamic>? _selectedUser;
  String? _status;

  bool _submitting = false;

  static const _gruposEnterprise = [
    'SUPERVISÃO LOGÍSTICO',
    'GESTÃO ADM',
    'OPERAÇÃO DE REDES',
    'SUPORTE TI',
    'ENGENHARIA',
    'FISCALIZAÇÃO OBRAS',
    'SUPERVISÃO ADM',
    'TEC OPERACIONAL',
    'TEC TELECOM',
  ];

  static const _tiposVeiculo = [
    'Veículo leve',
    'Veículo médio 4 x 2',
    'Veículo 4x4',
  ];

  static const _periodosUtiliza = [
    'Mensal',
    'Quinzenal',
    'Semanal',
    'Diária',
  ];

  static const _statusOptions = [
    'Aprovado',
    'Aguardando Aprovação',
    'Reprovado',
    'Pendente',
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    _qtdCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _loadingData = true);
    try {
      final results = await Future.wait([
        EnterpriseApiService.getLiderNames(),
        EnterpriseApiService.getGlpiUsers(),
      ]);
      if (!mounted) return;
      setState(() {
        _lideres = results[0] as List<String>;
        _glpiUsers = results[1] as List<Map<String, dynamic>>;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Falha ao carregar dados: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingData = false);
    }
  }

  Future<void> _pickDate({
    required String label,
    required DateTime? current,
    required ValueChanged<DateTime> onPicked,
  }) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) onPicked(picked);
  }

  String _formatDate(DateTime? d) {
    if (d == null) return '';
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  String _toYmd(DateTime d) {
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _submitting = true);
    try {
      await EnterpriseApiService.createMedicaoVeiculo(
        mes: _mes != null ? _toYmd(_mes!) : null,
        dataInicio: _dataInicio != null ? _toYmd(_dataInicio!) : null,
        dataFim: _dataFim != null ? _toYmd(_dataFim!) : null,
        solicitante: _solicitante,
        grupoEnterprise: _grupoEnterprise,
        tipoVeiculo: _tipoVeiculo,
        periodoUtiliza: _periodoUtiliza,
        qtd: _qtdCtrl.text.trim().isEmpty
            ? null
            : int.tryParse(_qtdCtrl.text.trim()),
        user: _selectedUser != null
            ? _selectedUser!['name']?.toString()
            : null,
        userId: _selectedUser != null ? _selectedUser!['id'] as int? : null,
        status: _status,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Medição registrada com sucesso.')),
      );
      _resetForm();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Erro: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _resetForm() {
    setState(() {
      _mes = null;
      _dataInicio = null;
      _dataFim = null;
      _solicitante = null;
      _grupoEnterprise = null;
      _tipoVeiculo = null;
      _periodoUtiliza = null;
      _qtdCtrl.clear();
      _selectedUser = null;
      _status = null;
    });
  }

  Widget _dateTile({
    required String label,
    required DateTime? value,
    required VoidCallback onTap,
  }) {
    return TextFormField(
      readOnly: true,
      controller: TextEditingController(text: _formatDate(value)),
      decoration: InputDecoration(
        labelText: label,
        suffixIcon: const Icon(Icons.calendar_today),
      ),
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Medição de Veículos'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Image.asset('assets/images/tivit_logo.png', height: 28),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Card(
            color: cs.surface.withValues(alpha: 0.98),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _formKey,
                child: ListView(
                  children: [
                    if (_loadingData) const LinearProgressIndicator(),
                    const SizedBox(height: 8),

                    // Mês
                    _dateTile(
                      label: 'Mês',
                      value: _mes,
                      onTap: () => _pickDate(
                        label: 'Mês',
                        current: _mes,
                        onPicked: (d) => setState(() => _mes = d),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Data Início / Data Fim (side by side on wide)
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final wide = constraints.maxWidth >= 500;
                        if (wide) {
                          return Row(
                            children: [
                              Expanded(
                                child: _dateTile(
                                  label: 'Data Início',
                                  value: _dataInicio,
                                  onTap: () => _pickDate(
                                    label: 'Data Início',
                                    current: _dataInicio,
                                    onPicked: (d) =>
                                        setState(() => _dataInicio = d),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: _dateTile(
                                  label: 'Data Fim',
                                  value: _dataFim,
                                  onTap: () => _pickDate(
                                    label: 'Data Fim',
                                    current: _dataFim,
                                    onPicked: (d) =>
                                        setState(() => _dataFim = d),
                                  ),
                                ),
                              ),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            _dateTile(
                              label: 'Data Início',
                              value: _dataInicio,
                              onTap: () => _pickDate(
                                label: 'Data Início',
                                current: _dataInicio,
                                onPicked: (d) =>
                                    setState(() => _dataInicio = d),
                              ),
                            ),
                            const SizedBox(height: 12),
                            _dateTile(
                              label: 'Data Fim',
                              value: _dataFim,
                              onTap: () => _pickDate(
                                label: 'Data Fim',
                                current: _dataFim,
                                onPicked: (d) => setState(() => _dataFim = d),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),

                    // Solicitante
                    DropdownSearch<String>(
                      items: _lideres,
                      selectedItem: _solicitante,
                      dropdownDecoratorProps: const DropDownDecoratorProps(
                        dropdownSearchDecoration: InputDecoration(
                          labelText: 'Solicitante',
                        ),
                      ),
                      onChanged: (v) => setState(() => _solicitante = v),
                      popupProps: const PopupProps.menu(showSearchBox: true),
                    ),
                    const SizedBox(height: 12),

                    // Grupo Enterprise
                    DropdownButtonFormField<String>(
                      initialValue: _grupoEnterprise,
                      decoration: const InputDecoration(
                        labelText: 'Grupo Enterprise',
                      ),
                      items: _gruposEnterprise
                          .map((g) =>
                              DropdownMenuItem(value: g, child: Text(g)))
                          .toList(),
                      onChanged: (v) => setState(() => _grupoEnterprise = v),
                    ),
                    const SizedBox(height: 12),

                    // Tipo Veículo
                    DropdownButtonFormField<String>(
                      initialValue: _tipoVeiculo,
                      decoration: const InputDecoration(
                        labelText: 'Tipo de Veículo',
                      ),
                      items: _tiposVeiculo
                          .map((t) =>
                              DropdownMenuItem(value: t, child: Text(t)))
                          .toList(),
                      onChanged: (v) => setState(() => _tipoVeiculo = v),
                    ),
                    const SizedBox(height: 12),

                    // Período de Utilização
                    DropdownButtonFormField<String>(
                      initialValue: _periodoUtiliza,
                      decoration: const InputDecoration(
                        labelText: 'Período de Utilização',
                      ),
                      items: _periodosUtiliza
                          .map((p) =>
                              DropdownMenuItem(value: p, child: Text(p)))
                          .toList(),
                      onChanged: (v) => setState(() => _periodoUtiliza = v),
                    ),
                    const SizedBox(height: 12),

                    // Quantidade
                    TextFormField(
                      controller: _qtdCtrl,
                      decoration: const InputDecoration(labelText: 'Quantidade'),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                    const SizedBox(height: 12),

                    // User (GLPI)
                    DropdownSearch<Map<String, dynamic>>(
                      items: _glpiUsers,
                      selectedItem: _selectedUser,
                      itemAsString: (u) =>
                          '${u['name'] ?? ''} (ID: ${u['id'] ?? ''})',
                      dropdownDecoratorProps: const DropDownDecoratorProps(
                        dropdownSearchDecoration: InputDecoration(
                          labelText: 'Usuário (GLPI)',
                        ),
                      ),
                      onChanged: (u) => setState(() => _selectedUser = u),
                      popupProps: const PopupProps.menu(showSearchBox: true),
                    ),
                    const SizedBox(height: 12),

                    // Status
                    DropdownButtonFormField<String>(
                      initialValue: _status,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: _statusOptions
                          .map((s) =>
                              DropdownMenuItem(value: s, child: Text(s)))
                          .toList(),
                      onChanged: (v) => setState(() => _status = v),
                    ),
                    const SizedBox(height: 24),

                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: _submitting ? null : _submit,
                        icon: _submitting
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.send),
                        label: const Text('Enviar'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(160, 48),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

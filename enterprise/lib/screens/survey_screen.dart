import 'package:flutter/material.dart';
import 'package:dropdown_search/dropdown_search.dart';
import '../services/enterprise_api_service.dart';

class SurveyScreen extends StatefulWidget {
  const SurveyScreen({super.key});

  @override
  State<SurveyScreen> createState() => _SurveyScreenState();
}

class _SurveyScreenState extends State<SurveyScreen>
    with AutomaticKeepAliveClientMixin {
  final _formKey = GlobalKey<FormState>();

  // Dropdown data
  List<Map<String, dynamic>> _liders = [];
  List<Map<String, dynamic>> _sites = [];
  bool _loading = true;

  // Selected values
  Map<String, dynamic>? _selectedLider;
  Map<String, dynamic>? _selectedSite;

  // Text controllers
  final _projetoCtrl = TextEditingController();
  final _objetivoCtrl = TextEditingController();
  final _empresaCtrl = TextEditingController();
  final _entregavelCtrl = TextEditingController();
  final _dataExecucaoCtrl = TextEditingController();
  final _horarioCtrl = TextEditingController();

  DateTime? _dataExecucao;
  TimeOfDay? _horarioAgendado;

  bool _submitting = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadDropdowns();
  }

  @override
  void dispose() {
    _projetoCtrl.dispose();
    _objetivoCtrl.dispose();
    _empresaCtrl.dispose();
    _entregavelCtrl.dispose();
    _dataExecucaoCtrl.dispose();
    _horarioCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadDropdowns() async {
    try {
      final results = await Future.wait([
        EnterpriseApiService.getLidersWithId(),
        EnterpriseApiService.getSitesEnterprise(),
      ]);
      if (!mounted) return;
      setState(() {
        _liders = results[0];
        _sites = results[1];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Falha ao carregar dados: $e')));
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dataExecucao ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null && mounted) {
      setState(() {
        _dataExecucao = picked;
        _dataExecucaoCtrl.text =
            '${picked.day.toString().padLeft(2, '0')}/'
            '${picked.month.toString().padLeft(2, '0')}/'
            '${picked.year}';
      });
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _horarioAgendado ?? TimeOfDay.now(),
    );
    if (picked != null && mounted) {
      setState(() {
        _horarioAgendado = picked;
        _horarioCtrl.text =
            '${picked.hour.toString().padLeft(2, '0')}:'
            '${picked.minute.toString().padLeft(2, '0')}';
      });
    }
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Campo obrigatório' : null;

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() ||
        _selectedLider == null ||
        _selectedSite == null ||
        _dataExecucao == null ||
        _horarioAgendado == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preencha todos os campos obrigatórios!')),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      await EnterpriseApiService.createSurveyEnterprise(
        solicitanteId: (_selectedLider!['id'] as num).toInt(),
        projeto: _projetoCtrl.text.trim(),
        objetivo: _objetivoCtrl.text.trim(),
        siteEnterpriseId: (_selectedSite!['id'] as num).toInt(),
        dataDeExecucao: _dataExecucao!,
        horarioAgendado: _horarioAgendado!,
        empresaResponsavel: _empresaCtrl.text.trim(),
        entregavelPrevisto: _entregavelCtrl.text.trim(),
      );
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Survey enviado com sucesso!')),
      );

      final keepData = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Manter dados preenchidos?'),
          content: const Text('Você quer manter os dados preenchidos?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Não'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Sim'),
            ),
          ],
        ),
      );

      if (!mounted) return;
      if (keepData == false) _resetForm();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erro ao enviar survey: $e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _resetForm() {
    setState(() {
      _selectedLider = null;
      _selectedSite = null;
      _dataExecucao = null;
      _horarioAgendado = null;
    });
    _projetoCtrl.clear();
    _objetivoCtrl.clear();
    _empresaCtrl.clear();
    _entregavelCtrl.clear();
    _dataExecucaoCtrl.clear();
    _horarioCtrl.clear();
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
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : Form(
                      key: _formKey,
                      child: ListView(
                        children: [
                          // ── Solicitante ──────────────────────────
                          DropdownSearch<Map<String, dynamic>>(
                            items: _liders,
                            selectedItem: _selectedLider,
                            itemAsString: (l) => (l['nome'] as String?) ?? '',
                            compareFn: (a, b) =>
                                (a['id'] as num).toInt() ==
                                (b['id'] as num).toInt(),
                            dropdownDecoratorProps:
                                const DropDownDecoratorProps(
                                  dropdownSearchDecoration: InputDecoration(
                                    labelText: 'Solicitante',
                                  ),
                                ),
                            onChanged: (v) =>
                                setState(() => _selectedLider = v),
                            popupProps: const PopupProps.menu(
                              showSearchBox: true,
                            ),
                          ),
                          const SizedBox(height: 16),

                          // ── Projeto ──────────────────────────────
                          TextFormField(
                            controller: _projetoCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Projeto',
                              border: OutlineInputBorder(),
                            ),
                            maxLength: 255,
                            validator: _required,
                          ),
                          const SizedBox(height: 16),

                          // ── Objetivo ─────────────────────────────
                          TextFormField(
                            controller: _objetivoCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Objetivo',
                              border: OutlineInputBorder(),
                            ),
                            maxLength: 255,
                            validator: _required,
                          ),
                          const SizedBox(height: 16),

                          // ── Site ENTERPRISE ───────────────────────────
                          DropdownSearch<Map<String, dynamic>>(
                            items: _sites,
                            selectedItem: _selectedSite,
                            itemAsString: (s) => (s['site'] as String?) ?? '',
                            compareFn: (a, b) =>
                                (a['id'] as num).toInt() ==
                                (b['id'] as num).toInt(),
                            dropdownDecoratorProps:
                                const DropDownDecoratorProps(
                                  dropdownSearchDecoration: InputDecoration(
                                    labelText: 'Site ENTERPRISE',
                                  ),
                                ),
                            onChanged: (v) => setState(() => _selectedSite = v),
                            popupProps: const PopupProps.menu(
                              showSearchBox: true,
                            ),
                          ),
                          const SizedBox(height: 16),

                          // ── Data de execução + Horário ───────────
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  controller: _dataExecucaoCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Data de execução',
                                    border: OutlineInputBorder(),
                                    suffixIcon: Icon(Icons.calendar_today),
                                  ),
                                  readOnly: true,
                                  onTap: _pickDate,
                                  validator: _required,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _horarioCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Horário Agendado',
                                    border: OutlineInputBorder(),
                                    suffixIcon: Icon(Icons.access_time),
                                  ),
                                  readOnly: true,
                                  onTap: _pickTime,
                                  validator: _required,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // ── Empresa Responsável ──────────────────
                          TextFormField(
                            controller: _empresaCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Empresa Responsável',
                              border: OutlineInputBorder(),
                            ),
                            maxLength: 255,
                            validator: _required,
                          ),
                          const SizedBox(height: 16),

                          // ── Entregável Previsto ──────────────────
                          TextFormField(
                            controller: _entregavelCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Entregável Previsto',
                              border: OutlineInputBorder(),
                            ),
                            maxLength: 255,
                            validator: _required,
                          ),
                          const SizedBox(height: 24),

                          // ── Submit ───────────────────────────────
                          Center(
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
                                backgroundColor: Colors.red,
                                foregroundColor: Colors.white,
                                minimumSize: const Size(200, 50),
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

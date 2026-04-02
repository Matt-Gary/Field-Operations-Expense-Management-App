import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:dropdown_search/dropdown_search.dart';
import 'package:file_picker/file_picker.dart';

import '../services/enterprise_api_service.dart';
import '../services/user_session.dart';
import '../utils/image_compressor.dart';

class RegistrarDespesaScreen extends StatefulWidget {
  const RegistrarDespesaScreen({super.key});

  @override
  State<RegistrarDespesaScreen> createState() => _RegistrarDespesaScreenState();
}

class _RegistrarDespesaScreenState extends State<RegistrarDespesaScreen> {
  final _formKey = GlobalKey<FormState>();

  // GLPI users
  bool _loadingUsers = false;
  String? _error;
  List<Map<String, dynamic>> _users = [];
  Map<String, dynamic>? _selectedUser;
  bool _isUserFieldLocked = false; // For tivit role users

  // Fixed "Enterprise"
  final TextEditingController _contratoCtrl = TextEditingController(
    text: 'Enterprise',
  );

  // Fields
  String? _tipoDespesa; // Refeição | Hospedagem
  final TextEditingController _valorCtrl = TextEditingController();
  final TextEditingController _dataConsumoCtrl = TextEditingController();
  DateTime? _dataConsumo;
  final TextEditingController _quantidadeCtrl = TextEditingController();
  final TextEditingController _justificativaCtrl = TextEditingController();

  // Photos (multi)
  final List<PlatformFile> _photos = [];

  bool _submitting = false;

  // File upload config
  int _maxFileSize = 2097152; // default 2MB
  List<String> _allowedExtensions = [
    'jpg',
    'jpeg',
    'png',
    'pdf',
    'txt',
    'doc',
    'docx',
    'heic',
  ];

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _loadFileUploadConfig();
  }

  Future<void> _loadFileUploadConfig() async {
    try {
      final config = await EnterpriseApiService.getFileUploadConfig();
      if (!mounted) return;
      setState(() {
        _maxFileSize = (config['maxFileSize'] as num?)?.toInt() ?? _maxFileSize;
        final exts = config['allowedExtensions'];
        if (exts is List && exts.isNotEmpty) {
          _allowedExtensions = exts
              .map((e) => e.toString().toLowerCase())
              .toList();
        }
      });
    } catch (_) {
      // keep defaults
    }
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

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Campo obrigatório' : null;

  Future<void> _pickDataConsumo() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dataConsumo ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _dataConsumo = picked;
        _dataConsumoCtrl.text =
            '${picked.day.toString().padLeft(2, '0')}/${picked.month.toString().padLeft(2, '0')}/${picked.year}';
      });
    }
  }

  Future<void> _pickPhotos() async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.any,
      withData: true, // ensure bytes available (web + mobile)
    );
    if (res == null) return;

    final valid = <PlatformFile>[];
    final rejected = <String>[];

    for (final f in res.files) {
      final ext = (f.extension ?? '').toLowerCase();
      if (!_allowedExtensions.contains(ext)) {
        rejected.add('${f.name}: extensão ".$ext" não permitida');
        continue;
      }
      if (f.size > _maxFileSize) {
        final maxMB = (_maxFileSize / (1024 * 1024)).toStringAsFixed(1);
        rejected.add('${f.name}: tamanho excede $maxMB MB');
        continue;
      }
      valid.add(f);
    }

    if (valid.isNotEmpty) {
      setState(() => _photos.addAll(valid));
    }

    if (rejected.isNotEmpty && mounted) {
      final maxMB = (_maxFileSize / (1024 * 1024)).toStringAsFixed(1);
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange,
            size: 32,
          ),
          title: const Text('Arquivos rejeitados'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Tamanho máximo: $maxMB MB'),
                Text('Extensões permitidas: ${_allowedExtensions.join(", ")}'),
                const SizedBox(height: 12),
                ...rejected.map(
                  (r) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '• $r',
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() ||
        _selectedUser == null ||
        _tipoDespesa == null ||
        _dataConsumo == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preencha os campos obrigatórios.')),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _submitting = true);

    try {
      // normalize valor: accept "123,45" or "123.45"
      final rawValor = _valorCtrl.text.trim().replaceAll(',', '.');
      final valor = double.tryParse(rawValor);
      if (valor == null) throw Exception('Valor de despesa inválido');

      // 1) Cria o registro da despesa e pega o ID
      final despesaId = await EnterpriseApiService.createDespesa(
        userId: _selectedUser!['id'] as int,
        userName: _selectedUser!['name'] as String,
        contrato: _contratoCtrl.text.trim(),
        tipoDespesa: _tipoDespesa!,
        valor: valor,
        dataConsumoIso: _dataConsumo!.toIso8601String(),
        quantidade: int.parse(_quantidadeCtrl.text),
        justificativa: _justificativaCtrl.text.trim(),
      );
      if (!mounted) return;

      if (despesaId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Falha ao registrar despesa.')),
        );
        if (!mounted) return;
        setState(() => _submitting = false);
        return;
      }

      // 2) Envia fotos
      int uploaded = 0;
      final failures = <String>[];

      if (_photos.isNotEmpty) {
        final user = _sanitizeName(
          _selectedUser!['name']?.toString() ?? 'Usuario',
        );
        final tipo = _sanitizeName(_tipoDespesa!);
        final ymd = _toYmd(_dataConsumo!); // YYYY-MM-DD

        // base: "<User> - <Tipo> - <YYYY-MM-DD>"
        final base = '$user - $tipo - $ymd';

        // Build all compressed files before sending
        final fileEntries = <MapEntry<String, Uint8List>>[];
        for (int i = 0; i < _photos.length; i++) {
          final pf = _photos[i];
          final ext = (pf.extension ?? 'jpg').toLowerCase();
          final seq = _photos.length > 1 ? ' - ${_two(i + 1)}' : '';
          final filename = '$base$seq.$ext';

          final bytes = pf.bytes;
          if (bytes == null || bytes.isEmpty) {
            failures.add('${pf.name}: sem bytes');
            continue;
          }
          final compressed = ImageCompressor.compress(bytes);
          fileEntries.add(MapEntry(filename, compressed));
        }

        // Send all files in a single request
        if (fileEntries.isNotEmpty) {
          try {
            final result = await EnterpriseApiService.uploadManyBytesToDespesa(
              despesaId: despesaId,
              fileEntries: fileEntries,
            );
            if (!mounted) return;
            uploaded = (result['count'] as num?)?.toInt() ?? fileEntries.length;
            final failed = result['failed'] as List?;
            if (failed != null) {
              for (final f in failed) {
                failures.add('${f['original']}: ${f['error']}');
              }
            }
          } catch (e) {
            if (!mounted) return;
            for (final entry in fileEntries) {
              failures.add('${entry.key}: $e');
            }
          }
        }
      }

      // 3) Feedback
      if (!mounted) return;
      if (uploaded > 0 && failures.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Despesa registrada e fotos enviadas.')),
        );
        if (!mounted) return;
        _resetForm();
      } else if (uploaded > 0 && failures.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Despesa registrada. Fotos: $uploaded enviada(s), falhas: ${failures.length}',
            ),
          ),
        );
        if (!mounted) return;
        _resetForm();
      } else if (_photos.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Despesa registrada. Nenhuma foto enviada.'),
          ),
        );
        if (!mounted) return;
        _resetForm();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Despesa registrada, porém as fotos falharam: ${failures.join(' | ')}',
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Erro: $e')));
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  void _resetForm() {
    setState(() {
      _selectedUser = null;
      _tipoDespesa = null;
      _valorCtrl.clear();
      _dataConsumo = null;
      _dataConsumoCtrl.clear();
      _quantidadeCtrl.clear();
      _justificativaCtrl.clear();
      _contratoCtrl.text = 'Enterprise';
      _photos.clear();
    });
  }

  String _sanitizeName(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _toYmd(DateTime d) {
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final da = d.day.toString().padLeft(2, '0');
    return '$y-$m-$da';
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Registrar Despesa'),
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
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    if (_loadingUsers) const LinearProgressIndicator(),

                    // User (GLPI)
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
                          : (u) => setState(() => _selectedUser = u),
                      popupProps: const PopupProps.menu(showSearchBox: true),
                    ),
                    const SizedBox(height: 12),

                    // Contrato (readonly)
                    TextFormField(
                      controller: _contratoCtrl,
                      decoration: const InputDecoration(labelText: 'Contrato'),
                      readOnly: true,
                    ),
                    const SizedBox(height: 12),

                    // Tipo de Despesa
                    DropdownButtonFormField<String>(
                      initialValue: _tipoDespesa,
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
                          value: 'Pedágio',
                          child: Text('Pedágio'),
                        ),
                        DropdownMenuItem(
                          value: 'Material de Escritório',
                          child: Text('Material de Escritório'),
                        ),
                        DropdownMenuItem(value: 'EPI', child: Text('EPI')),
                        DropdownMenuItem(
                          value: 'Lavagem de Veículo',
                          child: Text('Lavagem de Veículo'),
                        ),
                        DropdownMenuItem(
                          value: 'Estacionamento',
                          child: Text('Estacionamento'),
                        ),
                        DropdownMenuItem(
                          value: 'Outros',
                          child: Text('Outros'),
                        ),
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Tipo de Despesa',
                      ),
                      validator: (v) => v == null ? 'Campo obrigatório' : null,
                      onChanged: (v) => setState(() => _tipoDespesa = v),
                    ),
                    const SizedBox(height: 12),

                    // Valor
                    TextFormField(
                      controller: _valorCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Valor de Despesa',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp(r'^\d+([.,]\d{0,2})?$'),
                        ),
                      ],
                      validator: _required,
                    ),
                    const SizedBox(height: 12),

                    // Data Consumo
                    TextFormField(
                      controller: _dataConsumoCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Data de Consumo',
                        suffixIcon: Icon(Icons.calendar_today),
                      ),
                      readOnly: true,
                      onTap: _pickDataConsumo,
                      validator: _required,
                    ),
                    const SizedBox(height: 12),

                    // Quantidade
                    TextFormField(
                      controller: _quantidadeCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Quantidade',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      validator: _required,
                    ),
                    const SizedBox(height: 12),

                    // Justificativa
                    TextFormField(
                      controller: _justificativaCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Justificativa',
                      ),
                      maxLines: 3,
                      validator: _required,
                    ),
                    const SizedBox(height: 20),

                    // Photos (multi)
                    Text(
                      'Fotos da despesa',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        OutlinedButton.icon(
                          onPressed: _submitting ? null : _pickPhotos,
                          icon: const Icon(Icons.add_photo_alternate),
                          label: const Text('Adicionar anexo'),
                        ),
                        const SizedBox(width: 12),
                        if (_photos.isNotEmpty)
                          TextButton.icon(
                            onPressed: _submitting
                                ? null
                                : () => setState(() => _photos.clear()),
                            icon: const Icon(Icons.clear),
                            label: const Text('Limpar'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_photos.isEmpty)
                      const Text('Nenhuma foto selecionada')
                    else
                      Card(
                        child: Column(
                          children: [
                            for (int i = 0; i < _photos.length; i++)
                              ListTile(
                                dense: true,
                                leading: const Icon(Icons.image),
                                title: Text(_photos[i].name),
                                subtitle: Text(
                                  '${(_photos[i].size / 1024).toStringAsFixed(1)} KB',
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: _submitting
                                      ? null
                                      : () =>
                                            setState(() => _photos.removeAt(i)),
                                ),
                              ),
                          ],
                        ),
                      ),

                    const SizedBox(height: 20),

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

import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:dropdown_search/dropdown_search.dart';
import '../models/vehicle.dart';
import '../services/enterprise_api_service.dart';
import '../services/user_session.dart';
import '../utils/image_compressor.dart';

class RegistraViagemScreen extends StatefulWidget {
  const RegistraViagemScreen({super.key});

  @override
  State<RegistraViagemScreen> createState() => _RegistraViagemScreenState();
}

class _RegistraViagemScreenState extends State<RegistraViagemScreen> {
  final _formKey = GlobalKey<FormState>();
  // GLPI user
  Map<String, dynamic>? _selectedUser;
  List<Map<String, dynamic>> _users = [];
  // Vehicles
  List<Vehicle> _vehicles = [];
  Vehicle? _selectedVehicle;
  bool _loadingVehicles = false;
  String? _error;
  bool _isUserFieldLocked = false; // For tivit role users

  // Fields
  final TextEditingController _tipoVeiculoCtrl = TextEditingController();
  final TextEditingController _hodoInicioCtrl = TextEditingController();
  final TextEditingController _hodoFimCtrl = TextEditingController();
  final TextEditingController _origemCtrl = TextEditingController();
  final TextEditingController _destinoCtrl = TextEditingController();
  final TextEditingController _motivoCtrl = TextEditingController();

  // Data da Viagem
  final TextEditingController _dataViagemCtrl = TextEditingController();
  DateTime? _dataViagem;

  // Photos
  Uint8List? _bytesInicio;
  Uint8List? _bytesFim;

  bool _submitting = false;
  bool _loadingUsers = false;

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
  ];

  @override
  void initState() {
    super.initState();
    _loadVehicles();
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

  Future<void> _loadVehicles() async {
    setState(() {
      _loadingVehicles = true;
      _error = null;
    });
    try {
      final list = await EnterpriseApiService.getVehicles().timeout(
        const Duration(seconds: 10),
      );
      setState(() => _vehicles = list);
    } catch (e) {
      setState(() => _error = 'Falha ao carregar veículos: $e');
    } finally {
      setState(() => _loadingVehicles = false);
    }
  }

  Future<void> _pickImage({required bool inicio}) async {
    final res = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.any,
      withData: true,
    );
    if (res == null || res.files.isEmpty) return;

    final f = res.files.single;
    final ext = (f.extension ?? '').toLowerCase();

    if (!_allowedExtensions.contains(ext)) {
      if (mounted) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange,
              size: 32,
            ),
            title: const Text('Arquivo rejeitado'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Extensão ".$ext" não permitida.'),
                const SizedBox(height: 8),
                Text('Extensões permitidas: ${_allowedExtensions.join(", ")}'),
              ],
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
      return;
    }

    if (f.size > _maxFileSize) {
      if (mounted) {
        final maxMB = (_maxFileSize / (1024 * 1024)).toStringAsFixed(1);
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(
              Icons.warning_amber_rounded,
              color: Colors.orange,
              size: 32,
            ),
            title: const Text('Arquivo rejeitado'),
            content: Text('${f.name}: tamanho excede $maxMB MB'),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      return;
    }

    if (f.bytes != null) {
      setState(() {
        if (inicio) {
          _bytesInicio = f.bytes;
        } else {
          _bytesFim = f.bytes;
        }
      });
    }
  }

  // date picker for "Data da Viagem"
  Future<void> _pickDataViagem() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dataViagem ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _dataViagem = picked;
        _dataViagemCtrl.text =
            '${picked.day.toString().padLeft(2, '0')}/'
            '${picked.month.toString().padLeft(2, '0')}/'
            '${picked.year}';
      });
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() ||
        _selectedVehicle == null ||
        _selectedUser == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Preencha os campos obrigatórios.')),
      );
      return;
    }
    if (!mounted) return;
    setState(() => _submitting = true);

    try {
      // 1) Save the travel record and get its ID
      final viagemId = await EnterpriseApiService.createViagem(
        userId: _selectedUser!['id'] as int,
        name: _selectedUser!['name'] as String,
        plate: _selectedVehicle!.registrationPlate,
        vehicleType: _selectedVehicle!.vehicleType,
        startKm: int.tryParse(_hodoInicioCtrl.text) ?? 0,
        finishKm: int.tryParse(_hodoFimCtrl.text) ?? 0,
        localStart: _origemCtrl.text.trim(),
        localDestination: _destinoCtrl.text.trim(),
        reason: _motivoCtrl.text.trim(),
        travelDateIso: _dataViagem!.toIso8601String(),
      );
      if (!mounted) return;

      if (viagemId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Falha ao registrar viagem.')),
        );
        if (!mounted) return;
        setState(() => _submitting = false);
        return;
      }

      int uploaded = 0;
      final failures = <String>[];

      // 2) Upload Inicio photo (server renames using viagem metadata)
      if (_bytesInicio != null && _bytesInicio!.isNotEmpty) {
        const fileName = 'inicio.jpg';
        final compressedInicio = ImageCompressor.compress(_bytesInicio!);
        try {
          await EnterpriseApiService.uploadPhotoBytesToTask(
            taskId: 0,
            bytes: compressedInicio,
            filename: fileName,
            viagemId: viagemId,
            fotoTipo: 'inicio',
          );
          if (!mounted) return;
          uploaded++;
        } catch (e) {
          if (!mounted) return;
          failures.add('Início: $e');
        }
      }

      // 5) Upload Fim photo
      if (_bytesFim != null && _bytesFim!.isNotEmpty) {
        const fileName = 'fim.jpg';
        final compressedFim = ImageCompressor.compress(_bytesFim!);
        try {
          await EnterpriseApiService.uploadPhotoBytesToTask(
            taskId: 0,
            bytes: compressedFim,
            filename: fileName,
            viagemId: viagemId,
            fotoTipo: 'fim',
          );
          if (!mounted) return;
          uploaded++;
        } catch (e) {
          if (!mounted) return;
          failures.add('Fim: $e');
        }
      }

      // 6) Feedback
      if (!mounted) return;
      if (uploaded > 0 && failures.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Viagem registrada e $uploaded foto(s) enviada(s).'),
          ),
        );
        if (!mounted) return;
        _resetForm();
      } else if (uploaded > 0 && failures.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Viagem registrada. Fotos: $uploaded enviada(s); falhas: ${failures.join(' | ')}',
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Viagem registrada. Nenhuma foto enviada.'),
          ),
        );
        if (!mounted) return;
        _resetForm();
      }
    } catch (e) {
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
      _selectedVehicle = null;
      _tipoVeiculoCtrl.clear();
      _hodoInicioCtrl.clear();
      _hodoFimCtrl.clear();
      _origemCtrl.clear();
      _destinoCtrl.clear();
      _motivoCtrl.clear();
      _dataViagem = null;
      _dataViagemCtrl.clear();
      _bytesInicio = null;
      _bytesFim = null;
    });
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Campo obrigatório' : null;

  String? _validateHodometros(String? _) {
    final ini = int.tryParse(_hodoInicioCtrl.text);
    final fim = int.tryParse(_hodoFimCtrl.text);
    if (ini == null || fim == null) {
      return null; // other validators cover empty/invalid
    }
    if (ini > fim) {
      return 'Hodômetro início não pode ser menor que o fim';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Registra Viagem'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Image.asset('assets/images/tivit_logo.png', height: 28),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
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

                    DropdownSearch<Map<String, dynamic>>(
                      items: _users,
                      itemAsString: (u) =>
                          '${u['name'] ?? ''} (ID: ${u['id'] ?? ''})',
                      selectedItem: _selectedUser,
                      enabled: !_isUserFieldLocked, // Disable for tivit users
                      dropdownDecoratorProps: DropDownDecoratorProps(
                        dropdownSearchDecoration: InputDecoration(
                          labelText: _isUserFieldLocked
                              ? 'Name (GLPI) - (bloqueado)'
                              : 'Name (GLPI)',
                        ),
                      ),
                      onChanged: _isUserFieldLocked
                          ? null // Disable callback when locked
                          : (u) {
                              setState(() {
                                _selectedUser = u;
                              });
                            },
                      popupProps: const PopupProps.menu(showSearchBox: true),
                    ),

                    const SizedBox(height: 16),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ),
                    if (_loadingVehicles) const LinearProgressIndicator(),

                    // Placa (Dropdown with search)
                    DropdownSearch<Vehicle>(
                      items: _vehicles,
                      selectedItem: _selectedVehicle,
                      itemAsString: (v) => v.registrationPlate,
                      compareFn: (a, b) =>
                          a.registrationPlate == b.registrationPlate,
                      dropdownDecoratorProps: const DropDownDecoratorProps(
                        dropdownSearchDecoration: InputDecoration(
                          labelText: 'Placa',
                        ),
                      ),
                      popupProps: const PopupProps.menu(showSearchBox: true),
                      onChanged: (v) {
                        setState(() {
                          _selectedVehicle = v;
                          _tipoVeiculoCtrl.text = v?.vehicleType ?? '';
                        });
                      },
                    ),
                    const SizedBox(height: 12),

                    // Tipo de veículo (auto-filled, read-only)
                    TextFormField(
                      controller: _tipoVeiculoCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Tipo de veículo',
                      ),
                      readOnly: true,
                    ),
                    const SizedBox(height: 12),

                    // NEW: Data da Viagem (required)
                    TextFormField(
                      controller: _dataViagemCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Data da Viagem',
                        suffixIcon: Icon(Icons.calendar_today),
                      ),
                      readOnly: true,
                      onTap: _pickDataViagem,
                      validator: _required,
                    ),
                    const SizedBox(height: 12),

                    // Hodômetro início
                    TextFormField(
                      controller: _hodoInicioCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Hodômetro início',
                      ),
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),

                    // Hodômetro fim
                    TextFormField(
                      controller: _hodoFimCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Hodômetro fim',
                      ),
                      keyboardType: TextInputType.number,
                      validator: _validateHodometros,
                      onChanged: (_) =>
                          setState(() {}), // re-validate paired rule
                    ),
                    const SizedBox(height: 12),

                    // Local de origem
                    TextFormField(
                      controller: _origemCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Local de origem',
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Local de destino
                    TextFormField(
                      controller: _destinoCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Local de destino',
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Motivo
                    TextFormField(
                      controller: _motivoCtrl,
                      decoration: const InputDecoration(labelText: 'Motivo'),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 16),

                    // Photos row
                    LayoutBuilder(
                      builder: (context, c) {
                        final isWide = c.maxWidth > 600;
                        final children = [
                          _PhotoPickerCard(
                            title: 'Foto Hodômetro Início',
                            bytes: _bytesInicio,
                            onPick: () => _pickImage(inicio: true),
                          ),
                          _PhotoPickerCard(
                            title: 'Foto Hodômetro Fim',
                            bytes: _bytesFim,
                            onPick: () => _pickImage(inicio: false),
                          ),
                        ];
                        return isWide
                            ? Row(
                                children: children
                                    .map(
                                      (w) => Expanded(
                                        child: Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8.0,
                                          ),
                                          child: w,
                                        ),
                                      ),
                                    )
                                    .toList(),
                              )
                            : Column(children: children);
                      },
                    ),
                    const SizedBox(height: 16),

                    // Submit
                    Align(
                      alignment: Alignment.centerRight,
                      child: FilledButton.icon(
                        onPressed: _submitting
                            ? null
                            : () {
                                if (_formKey.currentState?.validate() ??
                                    false) {
                                  _submit();
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Verifique os campos obrigatórios.',
                                      ),
                                    ),
                                  );
                                }
                              },
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
                        label: const Text('Registrar Viagem'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(180, 48),
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

class _PhotoPickerCard extends StatelessWidget {
  final String title;
  final Uint8List? bytes;
  final VoidCallback onPick;

  const _PhotoPickerCard({
    required this.title,
    required this.bytes,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      color: cs.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Container(
              height: 140,
              width: double.infinity,
              decoration: BoxDecoration(
                border: Border.all(color: cs.outline, width: 1.5),
                borderRadius: BorderRadius.circular(8),
                color: cs.surface,
              ),
              alignment: Alignment.center,
              child: bytes == null
                  ? const Text('Sem imagem selecionada')
                  : Image.memory(bytes!, fit: BoxFit.cover),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.photo_library),
              label: const Text('Selecionar Foto'),
            ),
          ],
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:dropdown_search/dropdown_search.dart';
import '../services/enterprise_api_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/user_session.dart';
import '../models/vehicle.dart';

class MeusKmsScreen extends StatefulWidget {
  const MeusKmsScreen({super.key});

  @override
  State<MeusKmsScreen> createState() => _MeusKmsScreenState();
}

class _MeusKmsScreenState extends State<MeusKmsScreen> {
  final _scrollCtrl = ScrollController();

  // Users
  bool _loadingUsers = false;
  String? _error;
  List<Map<String, dynamic>> _users = [];
  Map<String, dynamic>? _selectedUser;
  bool _isUserFieldLocked = false;

  // Viagens
  bool _loading = false;
  List<Map<String, dynamic>> _viagens = [];

  // Vehicles (cached for editing)
  List<Vehicle> _vehicles = [];

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _loadVehicles();
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
      final session = UserSession();
      final isTivit = session.isTivit;
      final glpiUserId = session.glpiUserId;

      if (isTivit && glpiUserId != null) {
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
          _loadViagens();
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
    try {
      final list = await EnterpriseApiService.getVehicles();
      setState(() => _vehicles = list);
    } catch (e) {
      debugPrint('Error loading vehicles: $e');
    }
  }

  Future<void> _loadViagens() async {
    if (_selectedUser == null) {
      setState(() => _viagens = []);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await EnterpriseApiService.getViagens(
        userId: _selectedUser!['id'] as int,
      ).timeout(const Duration(seconds: 15));
      setState(() => _viagens = rows);
    } catch (e) {
      setState(() => _error = 'Falha ao carregar viagens: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  String _formatDate(String? ymd) {
    if (ymd == null || ymd.isEmpty) return '-';
    try {
      final d = DateTime.parse(ymd);
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    } catch (_) {
      return ymd;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Meus KMs'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Image.asset('assets/images/tivit_logo.png', height: 28),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadViagens,
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
                DropdownSearch<Map<String, dynamic>>(
                  items: _users,
                  selectedItem: _selectedUser,
                  itemAsString: (u) =>
                      '${u['name'] ?? ''} (ID: ${u['id'] ?? ''})',
                  enabled: !_isUserFieldLocked,
                  dropdownDecoratorProps: DropDownDecoratorProps(
                    dropdownSearchDecoration: InputDecoration(
                      labelText: _isUserFieldLocked
                          ? 'Usuário (GLPI) - (bloqueado)'
                          : 'Usuário (GLPI)',
                    ),
                  ),
                  onChanged: (u) {
                    setState(() => _selectedUser = u);
                    _loadViagens();
                  },
                  popupProps: const PopupProps.menu(showSearchBox: true),
                ),
                const SizedBox(height: 16),

                if (_loading) const LinearProgressIndicator(),

                if (!_loading && _selectedUser != null && _viagens.isEmpty)
                  Card(
                    color: cs.surface.withValues(alpha: 0.98),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'Nenhuma viagem encontrada para este usuário.',
                      ),
                    ),
                  ),

                ..._viagens.map(
                  (v) => _ViagemCard(
                    key: ValueKey(v['viagem_id']), // Added Key
                    data: v,
                    vehicles: _vehicles,
                    formatDateBr: _formatDate,
                    onSaved: _loadViagens,
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

class _ViagemCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final List<Vehicle> vehicles;
  final String Function(String?) formatDateBr;
  final Future<void> Function() onSaved;

  const _ViagemCard({
    super.key,
    required this.data,
    required this.vehicles,
    required this.formatDateBr,
    required this.onSaved,
  });

  @override
  State<_ViagemCard> createState() => _ViagemCardState();
}

class _ViagemCardState extends State<_ViagemCard> {
  bool _editing = false;
  bool _saving = false;
  bool _loadingArquivos = false;
  List<Map<String, dynamic>> _arquivos = [];

  late TextEditingController _hodoInicioCtrl;
  late TextEditingController _hodoFimCtrl;
  late TextEditingController _origemCtrl;
  late TextEditingController _destinoCtrl;
  late TextEditingController _motivoCtrl;
  DateTime? _dataViagem;
  Vehicle? _selectedVehicle;

  @override
  void initState() {
    super.initState();
    final v = widget.data;
    _hodoInicioCtrl = TextEditingController(text: v['start_km']?.toString() ?? '');
    _hodoFimCtrl = TextEditingController(text: v['finish_km']?.toString() ?? '');
    _origemCtrl = TextEditingController(text: v['local_start']?.toString() ?? '');
    _destinoCtrl = TextEditingController(text: v['local_destination']?.toString() ?? '');
    _motivoCtrl = TextEditingController(text: v['reason']?.toString() ?? '');
    try {
      _dataViagem = v['data_viagem'] != null ? DateTime.parse(v['data_viagem']) : null;
    } catch (_) {}

    _selectedVehicle = widget.vehicles.firstWhere(
      (vec) => vec.registrationPlate == v['plate'],
      orElse: () => Vehicle(
        registrationPlate: v['plate'] ?? '',
        vehicleType: v['vehicle_type'] ?? '',
      ),
    );
    _loadArquivos();
  }

  Future<void> _loadArquivos() async {
    final viagemId = widget.data['viagem_id'] as int?;
    if (viagemId == null) return;
    if (!mounted) return;
    setState(() => _loadingArquivos = true);
    try {
      final res = await EnterpriseApiService.getViagemFiles(viagemId);
      if (mounted) setState(() => _arquivos = res);
    } catch (e) {
      debugPrint('Error loading files: $e');
    } finally {
      if (mounted) setState(() => _loadingArquivos = false);
    }
  }

  @override
  void didUpdateWidget(_ViagemCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data != oldWidget.data && !_editing) {
      final v = widget.data;
      _hodoInicioCtrl.text = v['start_km']?.toString() ?? '';
      _hodoFimCtrl.text = v['finish_km']?.toString() ?? '';
      _origemCtrl.text = v['local_start']?.toString() ?? '';
      _destinoCtrl.text = v['local_destination']?.toString() ?? '';
      _motivoCtrl.text = v['reason']?.toString() ?? '';
      try {
        _dataViagem = v['data_viagem'] != null ? DateTime.parse(v['data_viagem']) : null;
      } catch (_) {}

      _selectedVehicle = widget.vehicles.firstWhere(
        (vec) => vec.registrationPlate == v['plate'],
        orElse: () => Vehicle(
          registrationPlate: v['plate'] ?? '',
          vehicleType: v['vehicle_type'] ?? '',
        ),
      );
    }
    if (widget.data['viagem_id'] != oldWidget.data['viagem_id']) {
      _loadArquivos();
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await EnterpriseApiService.updateViagem(
        viagemId: widget.data['viagem_id'] as int,
        plate: _selectedVehicle?.registrationPlate,
        vehicleType: _selectedVehicle?.vehicleType,
        startKm: int.tryParse(_hodoInicioCtrl.text),
        finishKm: int.tryParse(_hodoFimCtrl.text),
        localStart: _origemCtrl.text.trim(),
        localDestination: _destinoCtrl.text.trim(),
        reason: _motivoCtrl.text.trim(),
        dataViagem: _dataViagem,
      );

      if (!mounted) return;
      setState(() => _editing = false);
      await widget.onSaved(); // Parent refresh

      _show('Viagem atualizada.');
    } catch (e) {
      if (mounted) {
        _show('Falha: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir viagem'),
        content: const Text('Deseja excluir este registro de KM?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Excluir'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _saving = true);
    try {
      await EnterpriseApiService.deleteViagem(widget.data['viagem_id'] as int);
      await widget.onSaved();
      _show('Registro excluído.');
    } catch (e) {
      _show('Erro: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addFiles() async {
    final viagemId = widget.data['viagem_id'] as int?;
    if (viagemId == null) return;

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
        viagemId: viagemId,
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

  Future<void> _removeFile(int fileId) async {
    final viagemId = widget.data['viagem_id'] as int?;
    if (viagemId == null) return;

    if (!mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover arquivo?'),
        content: const Text('O arquivo será removido fisicamente e desvinculado desta viagem.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remover')),
        ],
      ),
    );
    if (confirm != true) return;

    setState(() => _saving = true);
    try {
      await EnterpriseApiService.deleteViagemFile(viagemId, fileId);
      await widget.onSaved(); 
      await _loadArquivos(); 
      if (!mounted) return;
      _show('Arquivo removido.');
    } catch (e) {
      _show('Falha ao remover: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _show(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = widget.data;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _editing ? _buildEditForm(cs) : _buildViewMode(cs, v),
      ),
    );
  }

  Widget _buildViewMode(ColorScheme cs, Map<String, dynamic> v) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${v['plate']} - ${v['vehicle_type']}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            TextButton.icon(
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.edit, size: 18),
              label: const Text('Editar'),
            ),
          ],
        ),
        Text('Data: ${widget.formatDateBr(v['data_viagem'])}'),
        Text('KM: ${v['start_km']} -> ${v['finish_km']} (${v['km_sum']} km)'),
        Text('De: ${v['local_start']}'),
        Text('Para: ${v['local_destination']}'),
        Text('Motivo: ${v['reason']}'),
        const Divider(),

        const Text('Arquivos:', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),

        if (_loadingArquivos)
          const LinearProgressIndicator()
        else if (_arquivos.isEmpty)
          const Text('Nenhum arquivo anexado.', style: TextStyle(fontStyle: FontStyle.italic))
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
                onDeleted: _saving ? null : () => _removeFile(arq['id'] as int),
              );
            }).toList(),
          ),

        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _saving ? null : _addFiles,
              icon: const Icon(Icons.upload_file),
              label: const Text('Adicionar arquivo(s)'),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.delete_forever, color: Colors.red),
              onPressed: _delete,
              tooltip: 'Excluir viagem',
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildEditForm(ColorScheme cs) {
    return Column(
      children: [
        DropdownSearch<Vehicle>(
          items: widget.vehicles,
          selectedItem: _selectedVehicle,
          itemAsString: (v) => v.registrationPlate,
          onChanged: (v) => setState(() => _selectedVehicle = v),
          dropdownDecoratorProps: const DropDownDecoratorProps(
            dropdownSearchDecoration: InputDecoration(labelText: 'Placa'),
          ),
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: _hodoInicioCtrl,
          decoration: const InputDecoration(labelText: 'KM Início'),
          keyboardType: TextInputType.number,
        ),
        TextFormField(
          controller: _hodoFimCtrl,
          decoration: const InputDecoration(labelText: 'KM Fim'),
          keyboardType: TextInputType.number,
        ),
        TextFormField(
          controller: _origemCtrl,
          decoration: const InputDecoration(labelText: 'Origem'),
        ),
        TextFormField(
          controller: _destinoCtrl,
          decoration: const InputDecoration(labelText: 'Destino'),
        ),
        TextFormField(
          controller: _motivoCtrl,
          decoration: const InputDecoration(labelText: 'Motivo'),
          maxLines: 2,
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => setState(() => _editing = false),
              child: const Text('Cancelar'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('Salvar'),
            ),
          ],
        ),
      ],
    );
  }
}


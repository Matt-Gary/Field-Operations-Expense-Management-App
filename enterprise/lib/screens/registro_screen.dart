import 'package:dropdown_search/dropdown_search.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/enterprise_api_service.dart';
import '../services/user_session.dart';

enum FlowMode { programadas, preaprovadas }

class RegistroScreen extends StatefulWidget {
  const RegistroScreen({super.key});

  @override
  State<RegistroScreen> createState() => _RegistroScreenState();
}

class _RegistroScreenState extends State<RegistroScreen> {
  // GLPI user
  Map<String, dynamic>? _selectedUser;
  List<Map<String, dynamic>> _users = [];
  // Activities tied to user (from GLPI)
  Map<String, dynamic>? _selectedActivity;
  List<Map<String, dynamic>> _activities = [];
  // Picked files
  final List<PlatformFile> _pickedFiles = [];
  String? _leaderFirstComment;
  String? _leaderAuthorName;
  bool _loadingLeaderComment = false;
  bool _loadingUsers = false;
  bool _loadingActivities = false;
  final bool _uploading = false;
  bool _isSubmitting = false;
  bool _isUserFieldLocked = false; // For tivit role users

  List<String> _favoritePreTasks = [];
  bool _loadingFavorites = false;
  bool _updatingFavorite = false;

  double? _quantidadeTarefas; // Programadas: read-only display
  final TextEditingController _qtyCtrl = TextEditingController(
    text: '1',
  ); // Pré-aprovadas: input
  final TextEditingController _qtyProgCtrl = TextEditingController(text: '1');
  // status
  int?
  _statusId; // 1=Novo, 2=Pendente, 3=Fechado, 4=Planejado, 6=Cancelado, 7=Enviar para aprovação, 8=Em Andamento
  final TextEditingController _statusCommentCtrl = TextEditingController();
  final _statusOptions = const <Map<String, dynamic>>[
    {'id': 8, 'label': 'Em Andamento'},
    {'id': 2, 'label': 'Pendente'},
    {'id': 7, 'label': 'Enviar para aprovação'},
    {'id': 6, 'label': 'Cancelado'},
  ];
  //tempo previsto:
  double? _tempoPrevistoH;
  String? _tipoEvidencia;
  // Real end/start dates
  DateTime? _realEndDate; // used in Programadas when closing
  DateTime? _realStartDate; // used in Programadas when activity is New
  DateTime? _preRealStartDate; // used in Preaprovadas create
  DateTime? _preRealEndDate; // used in Preaprovadas close

  // NEW: Pendente window (kept only in memory for now)
  DateTime? _pendStart;
  DateTime? _pendEnd;

  bool _considerFhc = false;
  bool _sobreaviso = false;

  bool get _isSobreavisoEligible {
    if (_flowMode == FlowMode.programadas) {
      return _selectedActivity?['item']?.toString().trim() == '3.5.22';
    } else {
      return _selectedPreTask?['item']?.toString().trim() == '3.5.22';
    }
  }

  String? _error;

  // Current flow (default: programadas)
  FlowMode _flowMode = FlowMode.programadas;

  bool get _isClosing => _statusId == 7;

  // show start-date input if the selected activity is currently "New"
  bool get _activityIsNew {
    final sid =
        _selectedActivity?['state_id'] ??
        _selectedActivity?['projectstates_id'];
    if (sid is num) return sid.toInt() == 1;
    if (sid is String) return int.tryParse(sid) == 1;
    return false;
  }

  @override
  void dispose() {
    _statusCommentCtrl.dispose();
    _qtyCtrl.dispose();
    _qtyProgCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    setState(() {
      _loadingUsers = true;
      _error = null;
      _qtyCtrl.text = '1'; // ADD
      _quantidadeTarefas = null;
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

          // Auto-load activities for the locked user
          _loadActivities(glpiUserId);
          // Load pre-approved tasks for preaprovadas flow
          _loadPreaprovadasTarefas(glpiUserId);
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

  Future<void> _loadActivities(int userId) async {
    setState(() {
      _loadingActivities = true;
      _error = null;
    });
    try {
      final data = await EnterpriseApiService.getGlpiActivities(
        userId,
      ).timeout(const Duration(seconds: 10));

      // sort by data_conclusao DESC (nulls last)
      data.sort((a, b) {
        final sa = a['data_conclusao'] as String?;
        final sb = b['data_conclusao'] as String?;
        if (sa == null && sb == null) return 0;
        if (sa == null) return 1;
        if (sb == null) return -1;
        final da = DateTime.tryParse(sa)?.millisecondsSinceEpoch ?? 0;
        final db = DateTime.tryParse(sb)?.millisecondsSinceEpoch ?? 0;
        return da - db;
      });

      setState(() {
        _activities = data;
        _selectedActivity = null;
      });
    } catch (e) {
      setState(() => _error = 'Falha ao carregar atividades: $e');
    } finally {
      setState(() => _loadingActivities = false);
    }
  }

  // LOAD tarefas from "preaprovados" (column tarefa)
  Future<void> _loadPreaprovadasTarefas(int userId) async {
    setState(() => _loadingPreTasks = true);
    try {
      final raw = await EnterpriseApiService.getPreAprovadosTarefas(
        userId: userId,
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;

      // Sort by atividade
      raw.sort((a, b) {
        final na = (a['atividade'] as String?) ?? '';
        final nb = (b['atividade'] as String?) ?? '';
        return na.compareTo(nb);
      });

      setState(() {
        _preTasks = raw;
        _selectedPreTask = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Falha ao carregar Tarefas pré-aprovadas: $e')),
      );
    } finally {
      if (mounted) setState(() => _loadingPreTasks = false);
    }
  }

  bool _loadingPreTasks = false;
  List<Map<String, dynamic>> _preTasks = const [];
  Map<String, dynamic>? _selectedPreTask;
  Future<void> _loadFavoritePreTasks(int userId) async {
    setState(() => _loadingFavorites = true);
    try {
      final favs = await EnterpriseApiService.getPreAprovadosFavoritos(
        userId: userId,
      ).timeout(const Duration(seconds: 10));

      setState(() {
        _favoritePreTasks = favs;
      });
    } catch (e) {
      // opcional: snackbar ou debugPrint
      debugPrint('Falha ao carregar favoritos: $e');
    } finally {
      if (mounted) setState(() => _loadingFavorites = false);
    }
  }

  Future<void> _handlePreTaskSelected(Map<String, dynamic>? v) async {
    setState(() {
      _selectedPreTask = v;
      _tempoPrevistoH = null;
      _tipoEvidencia = null;
      _considerFhc = false;
    });

    final uid = (_selectedUser?['id'] as num?)?.toInt();
    if (uid != null && v != null) {
      final tarefaName = v['atividade'] as String?;
      if (tarefaName != null && tarefaName.trim().isNotEmpty) {
        try {
          final info = await EnterpriseApiService.getPreAprovadoInfo(
            userId: uid,
            tarefa: tarefaName.trim(),
          );
          if (!mounted) return;
          setState(() {
            final raw = info['tempo_previsto_h'];
            _tempoPrevistoH = (raw is num)
                ? raw.toDouble()
                : double.tryParse('${raw ?? ''}');
            _tipoEvidencia = (info['tipo_de_evidencia'] as String?)?.trim();
          });
        } catch (_) {
          if (!mounted) return;
          setState(() {
            _tempoPrevistoH = null;
            _tipoEvidencia = null;
          });
        }
      }
    }
  }

  String _labelWithDate(Map<String, dynamic> a) {
    final String name = (a['task_name'] as String?)?.trim() ?? '';
    final String? iso = (a['data_conclusao'] as String?)?.trim();

    String datePart = '';
    if (iso != null && iso.isNotEmpty) {
      final dtRaw = DateTime.tryParse(iso);
      if (dtRaw != null) {
        final dt = dtRaw.toLocal();
        final dd = dt.day.toString().padLeft(2, '0');
        final mm = dt.month.toString().padLeft(2, '0');
        final yyyy = dt.year.toString();
        datePart = '[$dd/$mm/$yyyy] ';
      }
    }

    int? stateId;
    final dynamic rawId = a['state_id'] ?? a['projectstates_id'];
    if (rawId is num) {
      stateId = rawId.toInt();
    } else if (rawId is String) {
      stateId = int.tryParse(rawId);
    }

    final String? stateName = (a['state_name'] as String?)?.trim();
    final Map<int, String> idToLabel = {
      for (final s in _statusOptions) (s['id'] as int): (s['label'] as String),
      4: 'Planejado',
    };
    final String? statusLabel = (stateName != null && stateName.isNotEmpty)
        ? stateName
        : (stateId != null ? (idToLabel[stateId] ?? 'Estado $stateId') : null);

    final String statusPart = statusLabel != null ? '[$statusLabel] ' : '';
    return '$datePart$statusPart$name'.trim();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: kIsWeb,
    );
    if (result == null) return;

    setState(() {
      _pickedFiles.addAll(result.files);
    });
  }

  String _fmtDisplay(DateTime dt) {
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year.toString();
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$dd/$mm/$yyyy $hh:$min';
  }

  InputDecoration _hlDecor(
    String label, {
    String? errorText,
    bool filled = false,
  }) {
    final baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
    );
    final green = Colors.green;
    final greenBorder = baseBorder.copyWith(
      borderSide: BorderSide(color: green, width: 2),
    );
    final greenFocusBorder = baseBorder.copyWith(
      borderSide: BorderSide(color: green, width: 2.5),
    );

    return InputDecoration(
      labelText: label,
      border: baseBorder,
      errorText: errorText,
      enabledBorder: filled ? greenBorder : null,
      focusedBorder: filled ? greenFocusBorder : null,
      filled: filled,
      fillColor: filled ? green.withValues(alpha: 0.08) : null,
    );
  }

  Future<void> _pickRealEndDate() async {
    final now = DateTime.now();
    final initial = _realEndDate ?? now;

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Selecione a Data real de fim',
    );
    if (date == null) return;
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Selecione o horário',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null) return;

    setState(() {
      _realEndDate = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      if (_realStartDate != null && _realEndDate != null) {
        _considerFhc = _getDefaultConsiderFhc(_realStartDate!, _realEndDate!);
      }
    });
    // Check for overlapping tasks after end date is set.
    // Use _realStartDate when available (task was Novo), otherwise use _realEndDate
    // as the reference day (task was Em Andamento — only end date is picked).
    if (!mounted) return;
    final uid = (_selectedUser?['id'] as num?)?.toInt();
    final refDate = _realStartDate ?? _realEndDate;
    if (uid != null && refDate != null) {
      await _checkAndWarnOverlap(uid, refDate, _realEndDate);
    }
  }

  Future<void> _pickPreStartDateTime() async {
    final now = DateTime.now();
    final initial = _preRealStartDate ?? now;

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Data real de início',
    );
    if (date == null) return;
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Horário de início',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null) return;

    setState(() {
      _preRealStartDate = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      if (_preRealStartDate != null && _preRealEndDate != null) {
        _considerFhc = _getDefaultConsiderFhc(
          _preRealStartDate!,
          _preRealEndDate!,
        );
      }
    });
    // Check for overlapping tasks after start date is set
    if (!mounted) return;
    final uid = (_selectedUser?['id'] as num?)?.toInt();
    if (uid != null && _preRealStartDate != null) {
      await _checkAndWarnOverlap(uid, _preRealStartDate!, _preRealEndDate);
    }
  }

  Future<void> _pickPreEndDateTime() async {
    final base = _preRealStartDate ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Data real de fim',
    );
    if (date == null) return;
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
      helpText: 'Horário de fim',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null) return;

    setState(() {
      _preRealEndDate = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      if (_preRealStartDate != null && _preRealEndDate != null) {
        _considerFhc = _getDefaultConsiderFhc(
          _preRealStartDate!,
          _preRealEndDate!,
        );
      }
    });
    // Check for overlapping tasks after end date is set
    if (!mounted) return;
    final uid = (_selectedUser?['id'] as num?)?.toInt();
    if (uid != null && _preRealStartDate != null) {
      await _checkAndWarnOverlap(uid, _preRealStartDate!, _preRealEndDate);
    }
  }

  Future<void> _pickRealStartDate() async {
    final now = DateTime.now();
    final initial = _realStartDate ?? now;

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Selecione a Data real de início',
    );
    if (date == null) return;
    if (!mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Selecione o horário',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null) return;

    setState(() {
      _realStartDate = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
      if (_realStartDate != null && _realEndDate != null) {
        _considerFhc = _getDefaultConsiderFhc(_realStartDate!, _realEndDate!);
      }
    });
    // Check for overlapping tasks after start date is set
    if (!mounted) return;
    final uid = (_selectedUser?['id'] as num?)?.toInt();
    if (uid != null && _realStartDate != null) {
      await _checkAndWarnOverlap(uid, _realStartDate!, _realEndDate);
    }
  }

  // NEW: pickers for Pendente window (kept in memory)
  Future<void> _pickPendStart() async {
    final now = DateTime.now();
    final initial = _pendStart ?? now;

    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Data início de Pendente',
    );
    if (date == null) return;
    if (!mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      helpText: 'Horário de início (Pendente)',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null) return;

    setState(() {
      _pendStart = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  Future<void> _pickPendEnd() async {
    final base = _pendStart ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'Data fim de Pendente',
    );
    if (date == null) return;
    if (!mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
      helpText: 'Horário de fim (Pendente)',
      builder: (ctx, child) => MediaQuery(
        data: MediaQuery.of(ctx).copyWith(alwaysUse24HourFormat: true),
        child: child!,
      ),
    );
    if (time == null) return;

    setState(() {
      _pendEnd = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  /// Checks for time overlaps with existing tasks for [userId] and
  /// shows a non-blocking warning dialog if any are found.
  /// Both conflict types (overlap + in-progress) are purely informational.
  Future<void> _checkAndWarnOverlap(
    int userId,
    DateTime start,
    DateTime? end,
  ) async {
    final result = await EnterpriseApiService.checkTimeOverlap(
      userId: userId,
      start: start,
      end: end,
    );
    if (!mounted) return;

    final conflicts =
        (result['conflicts'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final inProgress =
        (result['inProgress'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    if (conflicts.isEmpty && inProgress.isEmpty) return;

    String fmtTaskTime(Map<String, dynamic> t, {bool showEnd = true}) {
      String fmtDt(String? raw) {
        if (raw == null) return '?';
        final dt = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
        if (dt == null) return raw;
        final hh = dt.hour.toString().padLeft(2, '0');
        final mm = dt.minute.toString().padLeft(2, '0');
        final dd = dt.day.toString().padLeft(2, '0');
        final mo = dt.month.toString().padLeft(2, '0');
        return '$dd/$mo ${dt.year} $hh:$mm';
      }

      final startStr = fmtDt(t['data_start_real'] as String?);
      if (!showEnd) return 'Início: $startStr';
      final endStr = fmtDt(t['user_conclude_date'] as String?);
      return '$startStr – $endStr';
    }

    if (conflicts.isNotEmpty) {
      // --- Overlap conflict dialog ---
      final items = conflicts
          .map((t) {
            final name = (t['atividade'] as String? ?? 'Tarefa').trim();
            final time = fmtTaskTime(t);
            return '📋 $name\n     $time';
          })
          .join('\n\n');

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(
            Icons.warning_amber_rounded,
            color: Colors.orange,
            size: 32,
          ),
          title: const Text('Conflito de horário'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'O horário escolhido se sobrepõe com uma tarefa já registrada:',
                ),
                const SizedBox(height: 12),
                Text(
                  items,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 12),
                const Text('Verifique os horários antes de continuar.'),
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
    } else if (inProgress.isNotEmpty) {
      // --- In-progress task warning dialog ---
      final items = inProgress
          .map((t) {
            final name = (t['atividade'] as String? ?? 'Tarefa').trim();
            final time = fmtTaskTime(t, showEnd: false);
            return '📋 $name\n     $time';
          })
          .join('\n\n');

      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(
            Icons.info_outline_rounded,
            color: Colors.blue,
            size: 32,
          ),
          title: const Text('Tarefa em andamento'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Existe uma tarefa sem data de fim que iniciou neste dia:',
                ),
                const SizedBox(height: 12),
                Text(
                  items,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 12),
                const Text('Verifique se os horários não se sobrepõem.'),
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

  // Combined "Enviar" used in preaprovadas flow:
  Future<void> _enviarPreAprovada() async {
    if (_selectedUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecione o usuário (GLPI).')),
      );
      return;
    }
    if (_selectedPreTask == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selecione uma tarefa (preaprovadas).')),
      );
      return;
    }
    if (_statusId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Selecione um status.')));
      return;
    }

    // start is mandatory for any status (preaprovadas)
    if (_preRealStartDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Informe a "Data real de início".')),
      );
      return;
    }
    // if closing, require end
    if (_statusId == 7 && _preRealEndDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Informe a "Data real de fim" para fechar.'),
        ),
      );
      return;
    }
    // NEW: when Pendente, pendStart is required
    if (_statusId == 2 && _pendStart == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Informe a "Data início de Pendente".')),
      );
      return;
    }
    final double safeQty = _parseQty(_qtyCtrl.text) ?? 1.0;
    if (safeQty < 1.0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Informe uma quantidade válida (≥ 1).')),
      );
      return;
    }

    // Warn if there is any time overlap (non-blocking)
    final uid = (_selectedUser!['id'] as num).toInt();
    if (_preRealStartDate != null) {
      await _checkAndWarnOverlap(uid, _preRealStartDate!, _preRealEndDate);
    }
    if (!mounted) return;

    try {
      // 1) Create GLPI task + DB row (formas_enviadas)
      final taskId = await EnterpriseApiService.createPreAprovadaTask(
        tarefa: (_selectedPreTask!['atividade'] as String).trim(),
        userId: (_selectedUser!['id'] as num).toInt(),
        projectstatesId: _statusId!,
        comment: _statusCommentCtrl.text.trim(),
        realStartDate: _preRealStartDate!,
        userConcludeDate: _statusId == 7 ? _preRealEndDate : null,
        pendenteStart: (_statusId == 2 || _statusId == 7) ? _pendStart : null,
        pendenteEnd: (_statusId == 7) ? _pendEnd : null,
        quantidadeTarefas: safeQty,
        considerFhc: _considerFhc,
        sobreaviso: _isSobreavisoEligible ? _sobreaviso : false,
      );

      // 2) If there are files, upload to the newly created task
      if (_pickedFiles.isNotEmpty) {
        await EnterpriseApiService.uploadDocuments(
          itemtype: 'ProjectTask',
          itemsId: taskId,
          files: _pickedFiles,
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Tarefa criada (ID $taskId) e enviada ao GLPI.'),
        ),
      );

      // Optional: refresh activities for the user so the new task appears (if eligible)
      if (_selectedUser?['id'] != null && _flowMode == FlowMode.programadas) {
        await _loadActivities((_selectedUser!['id'] as num).toInt());
      }

      // 3) Clean form
      _resetForm();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red,
          content: Text('Falha ao enviar: $e'),
        ),
      );
    }
  }

  Future<void> _enviarProgramadas() async {
    if (_selectedActivity == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Selecione uma atividade.')));
      return;
    }
    if (_statusId == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Selecione um status.')));
      return;
    }
    if (_isClosing && _realEndDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Informe a "Data real de fim" para fechar a atividade.',
          ),
        ),
      );
      return;
    }
    // If leaving Pendente(2) to Aprovação(7), "fim de pendente" is mandatory
    final dynamic sidRaw =
        _selectedActivity?['state_id'] ??
        _selectedActivity?['projectstates_id'];
    final int? curState = sidRaw is num
        ? sidRaw.toInt()
        : (sidRaw is String ? int.tryParse(sidRaw) : null);
    if (curState == 2 && _statusId == 7 && _pendEnd == null) {
      final ok = await _ensurePendEndForClose();
      if (!ok) return;
    }
    // Warn if there is any time overlap (non-blocking).
    // Use _realStartDate if available (activity was Novo), otherwise fall back to
    // _realEndDate (activity was Em Andamento — user only picks an end date).
    // Either date gives us the right calendar day to query.
    if (_selectedUser != null) {
      final uid = (_selectedUser!['id'] as num).toInt();
      final refDate = _realStartDate ?? _realEndDate;
      if (refDate != null) {
        // Pass start=refDate and end=whatever end we have
        await _checkAndWarnOverlap(uid, refDate, _realEndDate);
        if (!mounted) return;
      }
    }
    final confirm = await _confirmEnviarProgramadas();
    if (!confirm) return;

    final dynamic rawId = _selectedActivity?['task_id'];
    final int? taskId = (rawId is num)
        ? rawId.toInt()
        : (rawId is String ? int.tryParse(rawId) : null);

    if (taskId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Atividade inválida: task_id ausente.')),
      );
      return;
    }
    final userId = _selectedUser!['id'] as int;

    // Ask for "Data real de início" ONLY if the activity is currently New (1).
    // If it's coming from Em Andamento (8), we do NOT force realStartDate again.
    if (_statusId == 2) {
      if (_activityIsNew && _realStartDate == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Informe a "Data real de início".')),
        );
        return;
      }
      if (!mounted) return;
      if (_pendStart == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Informe a "Data início de Pendente".')),
        );
        return;
      }
    }

    bool statusOk = false;
    String? statusErr;

    int uploadedCount = 0;
    String? uploadErr;
    final double qtyProg =
        _parseQty(_qtyProgCtrl.text) ?? (_quantidadeTarefas ?? 1.0);
    final double safeQtyProg = qtyProg < 1.0 ? 1.0 : qtyProg;
    // 1) Update status first (now sending both fields independently)
    try {
      statusOk = await EnterpriseApiService.updateGlpiTaskStatus(
        taskId: taskId,
        projectstatesId: _statusId!,
        userId: userId,
        comment: _statusCommentCtrl.text.trim(),
        realEndDate: _realEndDate,
        realStartDate: _realStartDate, // <- do NOT overwrite from pendente
        dataStartPendente: _pendStart, // <- sent independently
        dataEndPendente: _pendEnd, // usually null here
        quantidadeTarefas: safeQtyProg,
        considerFhc: _considerFhc,
        sobreaviso: _isSobreavisoEligible ? _sobreaviso : false,
      );
      if (!statusOk) {
        statusErr = 'Falha ao atualizar status no GLPI.';
      } else {
        await EnterpriseApiService.syncTaskStatus(taskId);
      }
    } catch (e) {
      statusOk = false;
      statusErr = 'Erro ao atualizar status: $e';
    }

    // 2) If files exist, upload them (unchanged)
    if (_pickedFiles.isNotEmpty) {
      try {
        final res = await EnterpriseApiService.uploadDocuments(
          itemtype: 'ProjectTask',
          itemsId: taskId,
          files: _pickedFiles,
        );
        uploadedCount = (res['count'] ?? 0) as int;
      } catch (e) {
        uploadErr = 'Falha no upload: $e';
      }
    }
    // If activity currently is PENDENTE (2) and switching to ANDAMENTO (8), require pendente end
    final dynamic sidRaw_ =
        _selectedActivity?['state_id'] ??
        _selectedActivity?['projectstates_id'];
    final int? curState_ = sidRaw_ is num
        ? sidRaw_.toInt()
        : (sidRaw_ is String ? int.tryParse(sidRaw_) : null);
    if (!mounted) return;
    if (curState_ == 2 && _statusId == 8 && _pendEnd == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Informe a "Data fim de Pendente".')),
      );
      return;
    }
    // 3) Show result (unchanged)
    final parts = <String>[];
    if (statusOk) {
      parts.add('Status atualizado');
    } else {
      parts.add(statusErr ?? 'Falha ao atualizar status');
    }
    parts.add('e $uploadedCount documento(s) enviado');
    if (uploadErr != null) parts.add('($uploadErr)');

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(parts.join(' '))));

    // 4) Refresh/clear if ok (unchanged)
    if (statusOk) {
      if (_selectedUser?['id'] != null) {
        await _loadActivities((_selectedUser!['id'] as num).toInt());
      }
      _resetForm();
    }
  }

  Future<bool> _confirmEnviarProgramadas() async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Confirmar envio'),
            content: const Text(
              'Isso vai atualizar o status da atividade. Deseja continuar?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Enviar'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<bool> _ensurePendEndForClose() async {
    // Only for Programadas, when current GLPI state is Pendente(2) and user sets status -> Aprovação(7)
    if (_flowMode != FlowMode.programadas ||
        _statusId != 7 ||
        _selectedActivity == null) {
      return true;
    }
    final dynamic sidRaw =
        _selectedActivity?['state_id'] ??
        _selectedActivity?['projectstates_id'];
    final int? curState = sidRaw is num
        ? sidRaw.toInt()
        : (sidRaw is String ? int.tryParse(sidRaw) : null);
    if (curState != 2) return true; // not leaving Pendente

    // If pendente end already provided, ok
    if (_pendEnd != null) return true;

    // Fetch stored start from DB and inform the user that "fim de pendente" is required
    final dynamic rawId = _selectedActivity?['task_id'];
    final int? taskId = (rawId is num)
        ? rawId.toInt()
        : (rawId is String ? int.tryParse(rawId) : null);
    if (taskId == null) return false;
    DateTime? pendStart;
    try {
      pendStart = await EnterpriseApiService.getPendenteStart(taskId);
    } catch (_) {
      pendStart = null;
    }

    final startTxt = pendStart != null
        ? _fmtDisplay(pendStart)
        : 'não informado';
    if (!mounted) return false;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Fim de Pendente é obrigatório'),
        content: Text(
          'Esta atividade iniciou Pendente em: $startTxt.\n\n'
          'Para enviar para aprovação, informe a "Data fim de Pendente".',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return false; // block send until user fills _pendEnd
  }

  void _resetForm() {
    setState(() {
      _statusId = null;
      _statusCommentCtrl.clear();
      _realEndDate = null;
      _realStartDate = null;
      _preRealStartDate = null;
      _preRealEndDate = null;

      //reset pendente window
      _pendStart = null;
      _pendEnd = null;
      _quantidadeTarefas = null;
      _qtyCtrl.text = '1';
      _qtyProgCtrl.text = '1';
      _pickedFiles.clear();
      _leaderFirstComment = null;
      _leaderAuthorName = null;
      _loadingLeaderComment = false;
      _tempoPrevistoH = null;
      _tipoEvidencia = null;
      _considerFhc = false;
      _sobreaviso = false;
    });
  }

  double? _parseQty(String? s) {
    if (s == null) return null;
    final t = s.replaceAll(',', '.').trim();
    final v = double.tryParse(t);
    return v;
  }

  String _fmtQty(double? v) {
    if (v == null) return '-';
    final r = v.roundToDouble();
    if (v == r) return r.toStringAsFixed(0); // 3.0 -> "3"
    return v.toString(); // e.g., 3.5 -> "3.5"
  }

  bool _anyWeekend(DateTime start, DateTime end) {
    final sw = start.weekday, ew = end.weekday;
    bool wk(int w) => w == DateTime.saturday || w == DateTime.sunday;
    return wk(sw) || wk(ew);
  }

  /// Categorizes a time into: 'core', 'transition', or 'night'
  /// - core: 08:01 - 16:59
  /// - transition: 07:00 - 08:00 or 17:00 - 18:00
  /// - night: 18:01 - 06:59
  String _getTimeCategory(DateTime dt) {
    final mins = dt.hour * 60 + dt.minute;

    // Core hours: 08:01 - 16:59 (481 - 1019 minutes)
    if (mins >= 481 && mins <= 1019) {
      return 'core';
    }

    // Transition morning: 07:00 - 08:00 (420 - 480 minutes)
    // Transition evening: 17:00 - 18:00 (1020 - 1080 minutes)
    if ((mins >= 420 && mins <= 480) || (mins >= 1020 && mins <= 1080)) {
      return 'transition';
    }

    // Everything else is night: 18:01 - 06:59
    return 'night';
  }

  /// Returns the default value for _considerFhc based on the time range
  /// - core hours: false (HC)
  /// - transition hours: false (HC default, can choose FHC)
  /// - night hours: true (FHC default, can choose HC)
  bool _getDefaultConsiderFhc(DateTime start, DateTime end) {
    final startCat = _getTimeCategory(start);
    final endCat = _getTimeCategory(end);

    // If either start or end is in night category, default to FHC
    if (startCat == 'night' || endCat == 'night') {
      return true;
    }

    // Otherwise default to HC (false)
    return false;
  }

  /// Determines if HC/FHC checkbox should be shown
  /// Returns a map with 'show' (bool), 'defaultValue' (bool), and 'category' (String)
  Map<String, dynamic> _shouldShowHcFhcCheckbox(DateTime start, DateTime end) {
    final startCat = _getTimeCategory(start);
    final endCat = _getTimeCategory(end);

    // If both are in core hours, lock to HC (no checkbox)
    if (startCat == 'core' && endCat == 'core') {
      return {'show': false, 'defaultValue': false, 'category': 'core'};
    }

    // If any is in night hours, show checkbox with FHC default
    if (startCat == 'night' || endCat == 'night') {
      return {'show': true, 'defaultValue': true, 'category': 'night'};
    }

    // If any is in transition hours, show checkbox with HC default
    if (startCat == 'transition' || endCat == 'transition') {
      return {'show': true, 'defaultValue': false, 'category': 'transition'};
    }

    // Fallback: lock to HC
    return {'show': false, 'defaultValue': false, 'category': 'core'};
  }

  bool _isFavoritePreTask(String? tarefa) {
    if (tarefa == null) return false;
    return _favoritePreTasks.contains(tarefa.trim());
  }

  @override
  Widget build(BuildContext context) {
    String fmtSize(int bytes) {
      const units = ['B', 'KB', 'MB', 'GB'];
      double b = bytes.toDouble();
      int i = 0;
      while (b >= 1024 && i < units.length - 1) {
        b /= 1024;
        i++;
      }
      return '${b.toStringAsFixed(1)} ${units[i]}';
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Registro'),
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
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              elevation: 0,
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.98),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
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

                    // Name (GLPI)
                    DropdownSearch<Map<String, dynamic>>(
                      items: _users,
                      itemAsString: (u) =>
                          '${u['name'] ?? ''} (ID: ${u['id'] ?? ''})',
                      selectedItem: _selectedUser,
                      enabled: !_isUserFieldLocked, // Disable for tivit users
                      dropdownDecoratorProps: DropDownDecoratorProps(
                        dropdownSearchDecoration: _hlDecor(
                          _isUserFieldLocked ? 'Nome (bloqueado)' : 'Nome',
                          filled: _selectedUser != null,
                        ),
                      ),
                      onChanged: _isUserFieldLocked
                          ? null // Disable callback when locked
                          : (u) async {
                              setState(() {
                                _selectedUser = u;
                                _selectedActivity = null;
                                _activities = [];
                                _realStartDate = null;
                                _realEndDate = null;
                                _statusId = null;
                                _statusCommentCtrl.clear();
                                _pickedFiles.clear();
                                _qtyCtrl.text = '1'; // ADD
                                _quantidadeTarefas = null; // ADD
                                _tempoPrevistoH = null;
                                _tipoEvidencia = null;
                                // Reset pendente window
                                _pendStart = null;
                                _pendEnd = null;
                              });
                              if (u?['id'] != null) {
                                final uid = (u!['id'] as num).toInt();
                                await _loadActivities(uid);
                                if (_flowMode == FlowMode.preaprovadas) {
                                  await _loadPreaprovadasTarefas(uid);
                                  await _loadFavoritePreTasks(uid);
                                }
                              }
                            },
                      popupProps: const PopupProps.menu(showSearchBox: true),
                    ),

                    // Flow mode selector (only after user is selected)
                    if (_selectedUser != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Tipo de tarefa',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),

                      RadioGroup<FlowMode>(
                        groupValue: _flowMode,
                        onChanged: (v) async {
                          if (v == null) return;

                          if (v == FlowMode.programadas) {
                            setState(() {
                              _flowMode = v; // keep rest of form unchanged
                            });
                            return;
                          }

                          if (v == FlowMode.preaprovadas) {
                            setState(() {
                              _flowMode = v;
                              _selectedPreTask = null;
                              _preTasks = const [];
                              _preRealStartDate = null;
                              _preRealEndDate = null;
                              _leaderFirstComment = null;
                              _leaderAuthorName = null;
                              _loadingLeaderComment = false;

                              // Reset pendente window
                              _pendStart = null;
                              _pendEnd = null;

                              _selectedActivity = null; // clear GLPI activity
                            });

                            final uid = (_selectedUser?['id'] as num?)?.toInt();
                            if (uid != null) {
                              await _loadPreaprovadasTarefas(uid);
                              await _loadFavoritePreTasks(uid);
                            }
                          }
                        },
                        child: Column(
                          children: const [
                            RadioListTile<FlowMode>(
                              value: FlowMode.programadas,
                              title: Text('Tarefas programadas'),
                            ),
                            RadioListTile<FlowMode>(
                              value: FlowMode.preaprovadas,
                              title: Text('Tarefas pré-aprovado'),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 16),

                    // Activities (GLPI) list — only in "programadas"
                    if (_flowMode == FlowMode.programadas) ...[
                      if (_loadingActivities) const LinearProgressIndicator(),
                      DropdownSearch<Map<String, dynamic>>(
                        items: _activities,
                        selectedItem: _selectedActivity,
                        itemAsString: _labelWithDate,
                        compareFn: (a, b) => a['task_id'] == b['task_id'],
                        filterFn: (activity, filter) {
                          final q = filter.trim().toLowerCase();
                          if (q.isEmpty) return true;

                          final taskName =
                              (activity['task_name'] as String?)
                                  ?.toLowerCase() ??
                              '';
                          final item =
                              (activity['item'] as String?)?.toLowerCase() ??
                              '';
                          final taskId = (activity['task_id']?.toString() ?? '')
                              .toLowerCase();

                          // Search in task name, ITEM number, or task ID
                          return taskName.contains(q) ||
                              item.contains(q) ||
                              taskId.contains(q);
                        },
                        dropdownDecoratorProps: DropDownDecoratorProps(
                          dropdownSearchDecoration: _hlDecor(
                            'Atividades (Projetos / Tarefas GLPI)',
                            filled: _selectedActivity != null,
                          ),
                        ),
                        onChanged: (a) async {
                          setState(() {
                            _selectedActivity = a;
                            _realStartDate = null;
                            _realEndDate = null;
                            _statusId = null;
                            _statusCommentCtrl.clear();
                            _leaderFirstComment = null;
                            _leaderAuthorName = null;
                            _loadingLeaderComment = false;
                            _qtyCtrl.text = '1'; // ADD
                            _quantidadeTarefas = null; // ADD
                            _tempoPrevistoH = null;
                            _tipoEvidencia = null;
                            // Reset pendente window
                            _pendStart = null;
                            _pendEnd = null;
                            _considerFhc = false;
                            _sobreaviso = false;
                          });

                          if (a != null) {
                            // SAFELY parse task_id (can be num or string or null)
                            final dynamic rawId = a['task_id'];
                            final int? taskId = (rawId is num)
                                ? rawId.toInt()
                                : (rawId is String
                                      ? int.tryParse(rawId)
                                      : null);

                            if (taskId == null) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Atividade inválida: task_id ausente.',
                                  ),
                                ),
                              );
                              return;
                            }

                            setState(() => _loadingLeaderComment = true);
                            try {
                              final map =
                                  await EnterpriseApiService.getLeaderFirstCommentWithAuthor(
                                    taskId,
                                  );
                              if (!mounted) return;
                              setState(() {
                                _leaderAuthorName = map['author'];
                                _leaderFirstComment = map['comment'];

                                // quantidade_tarefas as DOUBLE (clamp to ≥ 1.0)
                                final Object? q = map['quantidade_tarefas'];
                                double? parsed;
                                if (q is num) {
                                  parsed = q.toDouble();
                                } else {
                                  parsed = double.tryParse(
                                    (q ?? '').toString(),
                                  );
                                }
                                _quantidadeTarefas =
                                    (parsed == null || parsed <= 0)
                                    ? 1.0
                                    : parsed;
                                _qtyProgCtrl.text = _fmtQty(_quantidadeTarefas);

                                final tp = map['tempo_previsto_h'];
                                _tempoPrevistoH = (tp is num)
                                    ? tp.toDouble()
                                    : double.tryParse('${tp ?? ''}');
                                _tipoEvidencia =
                                    (map['tipo_de_evidencia'] as String?)
                                        ?.trim();
                              });
                            } catch (e) {
                              if (!mounted) return;
                              debugPrint('Failed to get leader comment: $e');
                            } finally {
                              if (mounted) {
                                setState(() => _loadingLeaderComment = false);
                              }
                            }
                          }
                        },
                        popupProps: PopupProps.menu(
                          showSearchBox: true,
                          searchFieldProps: TextFieldProps(
                            decoration: const InputDecoration(
                              hintText: 'Pesquisar por nome, ITEM ou ID...',
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    // right here 👇
                    if (_flowMode == FlowMode.programadas &&
                        _selectedActivity != null) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _qtyProgCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^\d+([,.]\d{0,3})?$'),
                          ),
                        ],
                        decoration:
                            _hlDecor(
                              'Quantidade',
                              filled:
                                  (_parseQty(_qtyProgCtrl.text) ?? 0) >= 1.0,
                            ).copyWith(
                              helperText: 'Mínimo 0.20',
                              prefixIcon: const Icon(
                                Icons.format_list_numbered,
                              ),
                            ),
                        onChanged: (v) {
                          final d = _parseQty(v) ?? 1.0;
                          setState(() {
                            _quantidadeTarefas = (d <= 0) ? 1.0 : d;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_flowMode == FlowMode.programadas &&
                        _selectedActivity != null &&
                        _tempoPrevistoH != null) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Icon(Icons.schedule, size: 18),
                          const SizedBox(width: 8),
                          Text(
                            'Tempo previsto de execução (h): '
                            '${_tempoPrevistoH!.toStringAsFixed(_tempoPrevistoH!.truncateToDouble() == _tempoPrevistoH ? 0 : 2)}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    // Preaprovadas tarefas dropdown (only in that mode)
                    if (_flowMode == FlowMode.preaprovadas) ...[
                      const SizedBox(height: 16),
                      if (_favoritePreTasks.isNotEmpty) ...[
                        if (_loadingFavorites) const LinearProgressIndicator(),
                        const SizedBox(height: 8),
                        Text(
                          'Favoritas desse usuário',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Builder(
                          builder: (context) {
                            final favSet = _favoritePreTasks
                                .map((e) => e.trim())
                                .toSet();

                            // Mantém só as tarefas que existem na lista atual
                            final favTasks = _preTasks.where((task) {
                              final name = (task['atividade'] as String?)
                                  ?.trim();
                              return name != null && favSet.contains(name);
                            }).toList();

                            if (favTasks.isEmpty) {
                              return const SizedBox.shrink();
                            }

                            return Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: favTasks.map((task) {
                                final atividade =
                                    (task['atividade'] as String?) ?? '';
                                final item = (task['item'] as String?) ?? '';
                                final isSelected =
                                    identical(_selectedPreTask, task) ||
                                    ((_selectedPreTask?['atividade'] as String?)
                                            ?.trim() ==
                                        atividade.trim());

                                return ChoiceChip(
                                  label: Text(
                                    '$atividade (ITEM: $item)',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  selected: isSelected,
                                  onSelected: (_) {
                                    _handlePreTaskSelected(task);
                                  },
                                );
                              }).toList(),
                            );
                          },
                        ),
                        const SizedBox(height: 12),
                      ],
                      if (_loadingPreTasks) const LinearProgressIndicator(),

                      DropdownSearch<Map<String, dynamic>>(
                        items: _preTasks,
                        selectedItem: _selectedPreTask,
                        itemAsString: (task) =>
                            '${task['atividade']} (ITEM: ${task['item']})',
                        filterFn: (task, filter) {
                          final q = filter.trim().toLowerCase();
                          if (q.isEmpty) return true;

                          final atividade =
                              (task['atividade'] as String?)?.toLowerCase() ??
                              '';
                          final item =
                              (task['item'] as String?)?.toLowerCase() ?? '';

                          return atividade.contains(q) || item.contains(q);
                        },
                        dropdownDecoratorProps: DropDownDecoratorProps(
                          dropdownSearchDecoration: _hlDecor(
                            'Tarefas (pré-aprovado)',
                            filled: _selectedPreTask != null,
                          ),
                        ),
                        onChanged: (v) async {
                          setState(() {
                            _selectedPreTask = v;
                            _tempoPrevistoH = null;
                            _tipoEvidencia = null;
                            _considerFhc = false;
                            _sobreaviso = false;
                          });

                          final uid = (_selectedUser?['id'] as num?)?.toInt();
                          if (uid != null && v != null) {
                            final tarefaName = v['atividade'] as String?;
                            if (tarefaName != null &&
                                tarefaName.trim().isNotEmpty) {
                              try {
                                final info =
                                    await EnterpriseApiService.getPreAprovadoInfo(
                                      userId: uid,
                                      tarefa: tarefaName.trim(),
                                    );
                                if (!mounted) return;
                                setState(() {
                                  final raw = info['tempo_previsto_h'];
                                  _tempoPrevistoH = (raw is num)
                                      ? raw.toDouble()
                                      : double.tryParse('${raw ?? ''}');
                                  _tipoEvidencia =
                                      (info['tipo_de_evidencia'] as String?)
                                          ?.trim();
                                });
                              } catch (_) {
                                if (!mounted) return;
                                setState(() {
                                  _tempoPrevistoH = null;
                                  _tipoEvidencia = null;
                                });
                              }
                            }
                          }
                        },
                        popupProps: PopupProps.menu(
                          showSearchBox: true,
                          searchFieldProps: TextFieldProps(
                            decoration: const InputDecoration(
                              hintText: 'Pesquisar por atividade ou ITEM...',
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Botão de estrela para marcar / desmarcar favorito
                      if (_selectedPreTask != null &&
                          _selectedUser != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(
                                _isFavoritePreTask(
                                      (_selectedPreTask?['atividade']
                                          as String?),
                                    )
                                    ? Icons.star
                                    : Icons.star_border,
                              ),
                              color: Colors.amber,
                              tooltip:
                                  _isFavoritePreTask(
                                    _selectedPreTask?['atividade'] as String?,
                                  )
                                  ? 'Remover dos favoritos'
                                  : 'Marcar como favorito',
                              onPressed: _updatingFavorite
                                  ? null
                                  : () async {
                                      final uid = (_selectedUser!['id'] as num)
                                          .toInt();
                                      final tarefaName =
                                          (_selectedPreTask!['atividade']
                                                  as String?)
                                              ?.trim() ??
                                          '';
                                      if (tarefaName.isEmpty) return;

                                      setState(() => _updatingFavorite = true);
                                      try {
                                        if (_isFavoritePreTask(
                                          (_selectedPreTask?['atividade']
                                                  as String?)
                                              ?.trim(),
                                        )) {
                                          await EnterpriseApiService.removePreAprovadoFavorito(
                                            userId: uid,
                                            tarefa: tarefaName,
                                          );
                                          setState(() {
                                            _favoritePreTasks.removeWhere(
                                              (t) =>
                                                  t.trim() == tarefaName.trim(),
                                            );
                                          });
                                        } else {
                                          await EnterpriseApiService.addPreAprovadoFavorito(
                                            userId: uid,
                                            tarefa: tarefaName,
                                          );
                                          setState(() {
                                            if (!_favoritePreTasks.any(
                                              (t) =>
                                                  t.trim() == tarefaName.trim(),
                                            )) {
                                              _favoritePreTasks = [
                                                ..._favoritePreTasks,
                                                tarefaName,
                                              ];
                                            }
                                          });
                                        }
                                      } catch (e) {
                                        if (!context.mounted) return;
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            backgroundColor: Colors.red,
                                            content: Text(
                                              'Falha ao atualizar favorito: $e',
                                            ),
                                          ),
                                        );
                                      } finally {
                                        if (context.mounted) {
                                          setState(
                                            () => _updatingFavorite = false,
                                          );
                                        }
                                      }
                                    },
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _isFavoritePreTask(
                                    _selectedPreTask?['atividade'] as String?,
                                  )
                                  ? 'Favorito para este usuário'
                                  : 'Marcar como favorito',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ],

                      const SizedBox(height: 12),

                      if (_tempoPrevistoH != null) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            const Icon(Icons.schedule, size: 18),
                            const SizedBox(width: 8),
                            Text(
                              'Tempo previsto de execução (h): '
                              '${_tempoPrevistoH!.toStringAsFixed(_tempoPrevistoH!.truncateToDouble() == _tempoPrevistoH ? 0 : 2)}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      ],

                      TextField(
                        controller: _qtyCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'^\d+([,.]\d{0,3})?$'),
                          ),
                        ],
                        decoration: _hlDecor(
                          'Quantidade',
                          filled: (_parseQty(_qtyCtrl.text) ?? 0) >= 1.0,
                        ).copyWith(helperText: 'Mínimo 1'),
                        onChanged: (v) {
                          final d = _parseQty(v) ?? 1.0;
                          if (d <= 0) {
                            _qtyCtrl
                              ..text = '1'
                              ..selection = const TextSelection.collapsed(
                                offset: 1,
                              );
                          }
                        },
                      ),

                      const SizedBox(height: 12),
                      // Preaprovadas: Data real de início (sempre obrigatório)
                      InputDecorator(
                        decoration: _hlDecor(
                          'Data real de início',
                          errorText: _preRealStartDate == null
                              ? 'Obrigatório'
                              : null,
                          filled: _preRealStartDate != null,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _preRealStartDate == null
                                    ? 'Nenhuma data/hora selecionada'
                                    : _fmtDisplay(_preRealStartDate!),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _pickPreStartDateTime,
                              icon: const Icon(Icons.event),
                              label: const Text('Escolher'),
                            ),
                            if (_preRealStartDate != null) ...[
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Limpar',
                                icon: const Icon(Icons.clear),
                                onPressed: () =>
                                    setState(() => _preRealStartDate = null),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Preaprovadas: End date only if closing
                      if (_statusId == 7) ...[
                        InputDecorator(
                          decoration: _hlDecor(
                            'Data real de fim',
                            errorText: _preRealEndDate == null
                                ? 'Obrigatório ao fechar'
                                : null,
                            filled: _preRealEndDate != null,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _preRealEndDate == null
                                      ? 'Nenhuma data/hora selecionada'
                                      : _fmtDisplay(_preRealEndDate!),
                                ),
                              ),
                              const SizedBox(width: 8),
                              OutlinedButton.icon(
                                onPressed: _pickPreEndDateTime,
                                icon: const Icon(Icons.event),
                                label: const Text('Escolher'),
                              ),
                              if (_preRealEndDate != null) ...[
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip: 'Limpar',
                                  icon: const Icon(Icons.clear),
                                  onPressed: () =>
                                      setState(() => _preRealEndDate = null),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],

                    const SizedBox(height: 24),
                    // NEW: Preaprovadas — modo_de_trabalho hint / checkbox
                    if (_statusId == 7 &&
                        _preRealStartDate != null &&
                        _preRealEndDate != null) ...[
                      if (_anyWeekend(
                        _preRealStartDate!,
                        _preRealEndDate!,
                      )) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.event_available,
                                color: Colors.deepPurple,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Modo de trabalho: FDS (fim de semana)',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        Builder(
                          builder: (context) {
                            final logic = _shouldShowHcFhcCheckbox(
                              _preRealStartDate!,
                              _preRealEndDate!,
                            );
                            final show = logic['show'] as bool;
                            final category = logic['category'] as String;

                            if (!show) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.work_history,
                                      color: Colors.green,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Modo de trabalho: HC (Horário Comercial)',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              );
                            }

                            final isNight = category == 'night';
                            final title = isNight
                                ? 'Considerar como HC (Horário Comercial)'
                                : 'Considerar como FHC (Fora de Horário Comercial)';

                            return CheckboxListTile(
                              value: isNight ? !_considerFhc : _considerFhc,
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() {
                                  _considerFhc = isNight ? !v : v;
                                });
                              },
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(title),
                              subtitle: Text(
                                isNight
                                    ? 'Horário noturno detectado. Padrão: FHC.'
                                    : 'Horário de transição. Padrão: HC.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                    if (_flowMode == FlowMode.programadas) ...[
                      if (_loadingActivities || _loadingLeaderComment)
                        const LinearProgressIndicator(),
                      if ((_leaderFirstComment != null &&
                          _leaderFirstComment!.isNotEmpty)) ...[
                        const SizedBox(height: 8),
                        Card(
                          elevation: 0,
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest
                              .withValues(alpha: 0.6),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Comentário do criador',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                                const SizedBox(height: 8),
                                if (_leaderAuthorName != null &&
                                    _leaderAuthorName!.isNotEmpty)
                                  Text(
                                    _leaderAuthorName!,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                if (_leaderAuthorName != null &&
                                    _leaderAuthorName!.isNotEmpty)
                                  const SizedBox(height: 4),
                                Text(
                                  _leaderFirstComment!,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],

                    /* Text(
                      'Anexos (serão enviados para a atividade selecionada)',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: _uploading ? null : _pickFiles,
                          icon: const Icon(Icons.attach_file),
                          label: const Text('Selecionar arquivos'),
                        ),
                        const SizedBox(width: 12),
                        if (_pickedFiles.isNotEmpty)
                          TextButton.icon(
                            onPressed: _uploading
                                ? null
                                : () => setState(() => _pickedFiles.clear()),
                            icon: const Icon(Icons.clear),
                            label: const Text('Limpar'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    if (_pickedFiles.isEmpty)
                      const Text('Nenhum arquivo selecionado')
                    else
                      Card(
                        child: Column(
                          children: [
                            for (int i = 0; i < _pickedFiles.length; i++)
                              ListTile(
                                dense: true,
                                leading:
                                    const Icon(Icons.insert_drive_file),
                                title: Text(_pickedFiles[i].name),
                                subtitle:
                                    Text(fmtSize(_pickedFiles[i].size)),
                                trailing: IconButton(
                                  icon:
                                      const Icon(Icons.delete_outline),
                                  onPressed: _uploading
                                      ? null
                                      : () => setState(
                                          () => _pickedFiles.removeAt(i),
                                        ),
                                ),
                              ),
                            if (_uploading) const LinearProgressIndicator(),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    const SizedBox(height: 16),*/
                    if (_isSobreavisoEligible) ...[
                      CheckboxListTile(
                        title: const Text(
                          "Sobreaviso",
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                        value: _sobreaviso,
                        onChanged: (val) {
                          if (val != null) {
                            setState(() => _sobreaviso = val);
                          }
                        },
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                      const SizedBox(height: 12),
                    ],

                    // Status selector + dates (kept for both modes)
                    DropdownButtonFormField<int>(
                      initialValue: _statusId,
                      items: _statusOptions
                          .map(
                            (s) => DropdownMenuItem<int>(
                              value: s['id'] as int,
                              child: Text('${s['label']} (id: ${s['id']})'),
                            ),
                          )
                          .toList(),
                      decoration: _hlDecor(
                        'Status da Atividade (GLPI)',
                        filled: _statusId != null,
                      ),
                      onChanged: (v) => setState(() {
                        _statusId = v;

                        // When leaving Close, clear end date
                        if (_statusId != 7) {
                          _realEndDate = null;
                          _preRealEndDate = null;
                        }

                        // NEW: Reset Pendente window if status is not 2 nor 7
                        if (_statusId != 2 && _statusId != 7) {
                          _pendStart = null;
                          _pendEnd = null;
                        }
                      }),
                    ),

                    const SizedBox(height: 16),

                    // Programadas: Start date for activities currently "New"
                    if (_activityIsNew && _flowMode == FlowMode.programadas)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InputDecorator(
                            decoration: _hlDecor(
                              'Data real de início (GLPI)',
                              filled: _realStartDate != null,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _realStartDate == null
                                        ? 'Nenhuma data/hora selecionada'
                                        : _fmtDisplay(_realStartDate!),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: _pickRealStartDate,
                                  icon: const Icon(Icons.event),
                                  label: const Text('Escolher'),
                                ),
                                if (_realStartDate != null) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Limpar',
                                    icon: const Icon(Icons.clear),
                                    onPressed: () =>
                                        setState(() => _realStartDate = null),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),

                    // Programadas: End date when closing
                    if (_flowMode == FlowMode.programadas && _isClosing) ...[
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          InputDecorator(
                            decoration: _hlDecor(
                              'Data real de fim (GLPI)',
                              errorText: _isClosing && _realEndDate == null
                                  ? 'Obrigatório ao fechar a atividade'
                                  : null,
                              filled: _realEndDate != null,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _realEndDate == null
                                        ? 'Nenhuma data/hora selecionada'
                                        : _fmtDisplay(_realEndDate!),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: _pickRealEndDate,
                                  icon: const Icon(Icons.event),
                                  label: const Text('Escolher'),
                                ),
                                if (_realEndDate != null) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Limpar',
                                    icon: const Icon(Icons.clear),
                                    onPressed: () =>
                                        setState(() => _realEndDate = null),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                        ],
                      ),
                    ],
                    // NEW: Programadas — modo_de_trabalho hint / checkbox
                    if (_flowMode == FlowMode.programadas &&
                        _isClosing &&
                        _realStartDate != null &&
                        _realEndDate != null) ...[
                      if (_anyWeekend(_realStartDate!, _realEndDate!)) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.event_available,
                                color: Colors.deepPurple,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Modo de trabalho: FDS (fim de semana)',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ] else ...[
                        Builder(
                          builder: (context) {
                            final logic = _shouldShowHcFhcCheckbox(
                              _realStartDate!,
                              _realEndDate!,
                            );
                            final show = logic['show'] as bool;
                            final category = logic['category'] as String;

                            if (!show) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Row(
                                  children: [
                                    const Icon(
                                      Icons.work_history,
                                      color: Colors.green,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      'Modo de trabalho: HC (Horário Comercial)',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              );
                            }

                            final isNight = category == 'night';
                            final title = isNight
                                ? 'Considerar como HC (Horário Comercial)'
                                : 'Considerar como FHC (Fora de Horário Comercial)';

                            return CheckboxListTile(
                              value: isNight ? !_considerFhc : _considerFhc,
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() {
                                  _considerFhc = isNight ? !v : v;
                                });
                              },
                              dense: true,
                              controlAffinity: ListTileControlAffinity.leading,
                              title: Text(title),
                              subtitle: Text(
                                isNight
                                    ? 'Horário noturno detectado. Padrão: FHC.'
                                    : 'Horário de transição. Padrão: HC.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            );
                          },
                        ),
                      ],
                    ],
                    // ---------- Unified Pendente window when closing (status == 7) ----------
                    if (_statusId == 7) ...[
                      Builder(
                        builder: (context) {
                          final dynamic sidRaw =
                              _selectedActivity?['state_id'] ??
                              _selectedActivity?['projectstates_id'];
                          final int? curState = sidRaw is num
                              ? sidRaw.toInt()
                              : (sidRaw is String
                                    ? int.tryParse(sidRaw)
                                    : null);

                          // Only mandatory when leaving Pendente (2) -> Aprovação (7) in Programadas
                          final bool requirePendEndNow =
                              _flowMode == FlowMode.programadas &&
                              curState == 2 &&
                              _statusId == 7;

                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Pendente start (optional on close)
                              InputDecorator(
                                decoration: _hlDecor(
                                  'Data início de Pendente (opcional)',
                                  filled: _pendStart != null,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _pendStart == null
                                            ? 'Nenhuma data/hora selecionada'
                                            : _fmtDisplay(_pendStart!),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      onPressed: _pickPendStart,
                                      icon: const Icon(Icons.event),
                                      label: const Text('Escolher'),
                                    ),
                                    if (_pendStart != null) ...[
                                      const SizedBox(width: 8),
                                      IconButton(
                                        tooltip: 'Limpar',
                                        icon: const Icon(Icons.clear),
                                        onPressed: () =>
                                            setState(() => _pendStart = null),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),

                              // Pendente end (mandatory only for Programadas on 2 -> 7)
                              InputDecorator(
                                decoration: _hlDecor(
                                  'Data fim de Pendente',
                                  errorText:
                                      requirePendEndNow && _pendEnd == null
                                      ? 'Obrigatório ao sair do Pendente'
                                      : null,
                                  filled: _pendEnd != null,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        _pendEnd == null
                                            ? 'Nenhuma data/hora selecionada'
                                            : _fmtDisplay(_pendEnd!),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      onPressed: _pickPendEnd,
                                      icon: const Icon(Icons.event),
                                      label: const Text('Escolher'),
                                    ),
                                    if (_pendEnd != null) ...[
                                      const SizedBox(width: 8),
                                      IconButton(
                                        tooltip: 'Limpar',
                                        icon: const Icon(Icons.clear),
                                        onPressed: () =>
                                            setState(() => _pendEnd = null),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                          );
                        },
                      ),
                    ],
                    // Show "fim do Pendente" only when leaving Pendente (2) to Andamento (8)
                    if (_flowMode == FlowMode.programadas) ...[
                      Builder(
                        builder: (context) {
                          final dynamic sidRaw =
                              _selectedActivity?['state_id'] ??
                              _selectedActivity?['projectstates_id'];
                          final int? curState = sidRaw is num
                              ? sidRaw.toInt()
                              : (sidRaw is String
                                    ? int.tryParse(sidRaw)
                                    : null);
                          if (curState == 2 && _statusId == 8) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 12),
                                InputDecorator(
                                  decoration: _hlDecor(
                                    'Data fim de Pendente',
                                    errorText: _pendEnd == null
                                        ? 'Obrigatório ao sair do Pendente'
                                        : null,
                                    filled: _pendEnd != null,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _pendEnd == null
                                              ? 'Nenhuma data/hora selecionada'
                                              : _fmtDisplay(_pendEnd!),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      OutlinedButton.icon(
                                        onPressed: _pickPendEnd,
                                        icon: const Icon(Icons.event),
                                        label: const Text('Escolher'),
                                      ),
                                      if (_pendEnd != null) ...[
                                        const SizedBox(width: 8),
                                        IconButton(
                                          tooltip: 'Limpar',
                                          icon: const Icon(Icons.clear),
                                          onPressed: () =>
                                              setState(() => _pendEnd = null),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 16),
                              ],
                            );
                          }
                          return const SizedBox.shrink();
                        },
                      ),
                    ],

                    // =========================
                    // NEW: PENDENTE PICKERS UI
                    // =========================

                    // When status == 2 (Pendente) → required start of Pendente
                    if (_statusId == 2) ...[
                      InputDecorator(
                        decoration: _hlDecor(
                          'Data início de Pendente',
                          errorText: _pendStart == null
                              ? 'Obrigatório para status Pendente'
                              : null,
                          filled: _pendStart != null,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _pendStart == null
                                    ? 'Nenhuma data/hora selecionada'
                                    : _fmtDisplay(_pendStart!),
                              ),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _pickPendStart,
                              icon: const Icon(Icons.event),
                              label: const Text('Escolher'),
                            ),
                            if (_pendStart != null) ...[
                              const SizedBox(width: 8),
                              IconButton(
                                tooltip: 'Limpar',
                                icon: const Icon(Icons.clear),
                                onPressed: () =>
                                    setState(() => _pendStart = null),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if ((_tipoEvidencia ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.fact_check, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Tipo de evidência: $_tipoEvidencia',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    TextField(
                      controller: _statusCommentCtrl,
                      maxLines: 3,
                      decoration: _hlDecor(
                        'Comentário da atualização',
                        filled: _statusCommentCtrl.text.trim().isNotEmpty,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Buttons area:
                    if (_flowMode == FlowMode.programadas) ...[
                      FilledButton.icon(
                        onPressed: _isSubmitting
                            ? null
                            : () async {
                                setState(() => _isSubmitting = true);
                                try {
                                  await _enviarProgramadas();
                                } finally {
                                  if (mounted) {
                                    setState(() => _isSubmitting = false);
                                  }
                                }
                              },
                        icon: const Icon(Icons.send),
                        label: const Text('Enviar'),
                      ),
                    ] else ...[
                      // Single "Enviar" for preaprovadas
                      FilledButton.icon(
                        onPressed: _isSubmitting
                            ? null
                            : () async {
                                setState(() => _isSubmitting = true);
                                try {
                                  await _enviarPreAprovada();
                                } finally {
                                  if (mounted) {
                                    setState(() => _isSubmitting = false);
                                  }
                                }
                              },
                        icon: const Icon(Icons.send),
                        label: const Text('Enviar'),
                      ),
                    ],
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

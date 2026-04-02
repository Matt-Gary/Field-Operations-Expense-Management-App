import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/enterprise_api_service.dart';
import '../theme/enterprise_colors.dart';

class BaixarArquivosScreen extends StatefulWidget {
  const BaixarArquivosScreen({super.key});

  @override
  State<BaixarArquivosScreen> createState() => _BaixarArquivosScreenState();
}

class _BaixarArquivosScreenState extends State<BaixarArquivosScreen> {
  DateTime? _from;
  DateTime? _to;

  bool _loading = false;
  bool _searched = false;
  bool _zipDownloaded = false;
  String? _error;

  List<dynamic> _despesasFiles = [];
  List<dynamic> _viagensFiles = [];

  // ── helpers ──────────────────────────────────────────────────────────────

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  String _fmtDisplay(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.year}';

  Future<void> _pickDate({required bool isFrom}) async {
    final initial = isFrom ? (_from ?? DateTime.now()) : (_to ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _from = picked;
        // ensure `to` is not before `from`
        if (_to != null && _to!.isBefore(picked)) _to = picked;
      } else {
        _to = picked;
        if (_from != null && _from!.isAfter(picked)) _from = picked;
      }
    });
  }

  Future<void> _buscar() async {
    if (_from == null || _to == null) {
      setState(() => _error = 'Selecione as datas de início e fim.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _searched = false;
      _zipDownloaded = false;
    });

    try {
      final data = await EnterpriseApiService.getArquivosDownloadList(
        from: _fmt(_from!),
        to: _fmt(_to!),
      );
      setState(() {
        _despesasFiles = (data['despesas'] as List?) ?? [];
        _viagensFiles = (data['viagens'] as List?) ?? [];
        _searched = true;
      });
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _downloadZip() async {
    if (_from == null || _to == null) return;

    final url = EnterpriseApiService.buildArquivosDownloadZipUrl(
      from: _fmt(_from!),
      to: _fmt(_to!),
    );

    final uri = Uri.parse(url);
    if (!await canLaunchUrl(uri)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Não foi possível abrir o link de download.')),
        );
      }
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    
    if (mounted) {
      setState(() {
        _zipDownloaded = true;
      });
    }
  }

  Future<void> _confirmDelete() async {
    final act = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Excluir Arquivos'),
        content: const Text(
            'Tem certeza que deseja apagar todos os arquivos encontrados neste período?\n\n'
            'Esta ação é irreversível e os removerá permanentemente do servidor.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: kError),
            child: const Text('Excluir', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (act == true) {
      await _deleteFiles();
    }
  }

  Future<void> _deleteFiles() async {
    if (_from == null || _to == null) return;
    setState(() {
      _loading = true;
    });
    try {
      await EnterpriseApiService.deleteArquivosPeriod(
        from: _fmt(_from!),
        to: _fmt(_to!),
      );
      setState(() {
        _despesasFiles = [];
        _viagensFiles = [];
        _searched = false;
        _zipDownloaded = false;
        _from = null;
        _to = null;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Arquivos excluídos com sucesso!')),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _openFile(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final totalFiles = _despesasFiles.length + _viagensFiles.length;

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Baixar Arquivos'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Image.asset('assets/images/tivit_logo.png', height: 28),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
        children: [
          // ── Date Range Card ─────────────────────────────────────────────
          Card(
            color: cs.surface.withValues(alpha: 0.98),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Selecione o período',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _DateButton(
                          label: 'De',
                          value: _from != null ? _fmtDisplay(_from!) : null,
                          onTap: () => _pickDate(isFrom: true),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _DateButton(
                          label: 'Até',
                          value: _to != null ? _fmtDisplay(_to!) : null,
                          onTap: () => _pickDate(isFrom: false),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  FilledButton.icon(
                    onPressed: _loading ? null : _buscar,
                    icon: _loading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.search),
                    label: Text(_loading ? 'Buscando…' : 'Buscar'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                      backgroundColor: kPrimary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Error ────────────────────────────────────────────────────────
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kError.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kError.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, color: kError, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: kError),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ── Results summary + ZIP button ─────────────────────────────────
          if (_searched) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$totalFiles arquivo${totalFiles == 1 ? '' : 's'} encontrado${totalFiles == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface.withValues(alpha: 0.7),
                        ),
                  ),
                ),
                if (totalFiles > 0)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: [
                      FilledButton.icon(
                        onPressed: _downloadZip,
                        icon: const Icon(Icons.download_rounded),
                        label: const Text('Baixar ZIP'),
                        style: FilledButton.styleFrom(
                          backgroundColor: kPrimaryDark,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: _zipDownloaded ? _confirmDelete : null,
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('Excluir arquivos'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: kError,
                          side: BorderSide(
                            color: _zipDownloaded ? kError.withValues(alpha: 0.5) : Theme.of(context).disabledColor.withValues(alpha: 0.2),
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 10),

            if (totalFiles == 0)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Column(
                    children: [
                      Icon(Icons.folder_open_outlined,
                          size: 56, color: cs.onSurface.withValues(alpha: 0.25)),
                      const SizedBox(height: 12),
                      Text(
                        'Nenhum arquivo encontrado\nneste período.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurface.withValues(alpha: 0.5)),
                      ),
                    ],
                  ),
                ),
              ),

            // Despesas section
            if (_despesasFiles.isNotEmpty) ...[
              _FileSection(
                title: 'Despesas (${_despesasFiles.length})',
                icon: Icons.receipt_long_outlined,
                files: _despesasFiles,
                dateKey: 'data_consumo',
                nameKey: 'user_name',
                onOpen: _openFile,
              ),
              const SizedBox(height: 12),
            ],

            // Viagens section
            if (_viagensFiles.isNotEmpty)
              _FileSection(
                title: 'Viagens (${_viagensFiles.length})',
                icon: Icons.directions_car_outlined,
                files: _viagensFiles,
                dateKey: 'data_viagem',
                nameKey: 'name',
                onOpen: _openFile,
              ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper widgets
// ─────────────────────────────────────────────────────────────────────────────

class _DateButton extends StatelessWidget {
  final String label;
  final String? value;
  final VoidCallback onTap;

  const _DateButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: Border.all(color: cs.outline),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          children: [
            Icon(Icons.calendar_today_outlined, size: 18, color: cs.primary),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                ),
                Text(
                  value ?? 'Selecionar',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: value != null ? cs.onSurface : cs.onSurface.withValues(alpha: 0.4),
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FileSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<dynamic> files;
  final String dateKey;
  final String nameKey;
  final void Function(String url) onOpen;

  const _FileSection({
    required this.title,
    required this.icon,
    required this.files,
    required this.dateKey,
    required this.nameKey,
    required this.onOpen,
  });

  String _displayDate(dynamic raw) {
    if (raw == null) return '—';
    final s = raw.toString();
    if (s.length >= 10) {
      final parts = s.substring(0, 10).split('-');
      if (parts.length == 3) return '${parts[2]}/${parts[1]}/${parts[0]}';
    }
    return s;
  }

  String _displayName(dynamic raw) => raw?.toString() ?? '—';

  String _ext(String filename) {
    final dot = filename.lastIndexOf('.');
    return dot >= 0 ? filename.substring(dot + 1).toUpperCase() : '?';
  }

  IconData _fileIcon(String filename) {
    final ext = _ext(filename).toLowerCase();
    if (['jpg', 'jpeg', 'png', 'heic', 'gif', 'webp'].contains(ext)) {
      return Icons.image_outlined;
    }
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (['doc', 'docx'].contains(ext)) return Icons.description_outlined;
    return Icons.insert_drive_file_outlined;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      color: cs.surface.withValues(alpha: 0.98),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ExpansionTile(
        leading: Icon(icon, color: kPrimary),
        title: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        initiallyExpanded: true,
        childrenPadding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
        children: files.map<Widget>((f) {
          final filename = (f['filename'] ?? '').toString();
          final url = (f['url'] ?? '').toString();
          final date = _displayDate(f[dateKey]);
          final name = _displayName(f[nameKey]);

          return ListTile(
            dense: true,
            leading: Icon(_fileIcon(filename), color: kPrimaryDark, size: 28),
            title: Text(
              filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            subtitle: Text(
              '$date · $name',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.open_in_new_rounded),
              color: kPrimary,
              tooltip: 'Abrir arquivo',
              onPressed: url.isNotEmpty ? () => onOpen(url) : null,
            ),
          );
        }).toList(),
      ),
    );
  }
}

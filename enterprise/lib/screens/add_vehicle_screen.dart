import 'package:flutter/material.dart';
import '../services/enterprise_api_service.dart';

class AddVehicleScreen extends StatefulWidget {
  const AddVehicleScreen({super.key});

  @override
  State<AddVehicleScreen> createState() => _AddVehicleScreenState();
}

class _AddVehicleScreenState extends State<AddVehicleScreen> {
  final _formKey = GlobalKey<FormState>();

  final _plateCtrl = TextEditingController();
  final _producentCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _corCtrl = TextEditingController();
  final _contractCtrl = TextEditingController(text: 'Enterprise');

  String? _selectedType;
  int? _consumo;
  bool _submitting = false;

  final Map<String, int> _typeToConsumo = {'Leve': 8, '4x2': 10, '4x4': 12};

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _selectedType == null) {
      if (_selectedType == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Selecione o tipo de veículo.')),
        );
      }
      return;
    }

    setState(() => _submitting = true);

    try {
      await EnterpriseApiService.registerVehicle(
        registrationPlate: _plateCtrl.text.trim(),
        producent: _producentCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        vehicleType: _selectedType!,
        cor: _corCtrl.text.trim(),
        consumo: _consumo!,
        contract: _contractCtrl.text.trim(),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Veículo cadastrado com sucesso!')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erro: $e')));
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Adicionar Placa')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSectionHeader('Informações Básicas'),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _plateCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Placa',
                      hintText: 'ex: ABC1234',
                      prefixIcon: Icon(Icons.pin),
                    ),
                    textCapitalization: TextCapitalization.characters,
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Obrigatório' : null,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _producentCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Fabricante',
                            prefixIcon: Icon(Icons.factory),
                          ),
                          validator: (v) =>
                              (v == null || v.isEmpty) ? 'Obrigatório' : null,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextFormField(
                          controller: _modelCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Modelo',
                            prefixIcon: Icon(Icons.directions_car),
                          ),
                          validator: (v) =>
                              (v == null || v.isEmpty) ? 'Obrigatório' : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _corCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Cor',
                      prefixIcon: Icon(Icons.palette),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSectionHeader('Especificações e Contrato'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedType,
                    decoration: const InputDecoration(
                      labelText: 'Tipo de Veículo',
                      prefixIcon: Icon(Icons.category),
                    ),
                    items: _typeToConsumo.keys.map((String type) {
                      return DropdownMenuItem<String>(
                        value: type,
                        child: Text(type),
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedType = val;
                        _consumo = val != null ? _typeToConsumo[val] : null;
                      });
                    },
                    validator: (v) => v == null ? 'Obrigatório' : null,
                  ),
                  if (_consumo != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.secondaryContainer.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: cs.secondaryContainer),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.info_outline, color: cs.secondary),
                          const SizedBox(width: 8),
                          Text(
                            'Consumo automático para $_selectedType: $_consumo km/l',
                            style: TextStyle(
                              fontWeight: FontWeight.w500,
                              color: cs.onSecondaryContainer,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _contractCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Contrato',
                      prefixIcon: Icon(Icons.description),
                    ),
                    readOnly: true,
                  ),
                  const SizedBox(height: 40),
                  FilledButton.icon(
                    onPressed: _submitting ? null : _submit,
                    icon: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save),
                    label: const Text(
                      'Salvar Veículo',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 54),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
            color: Colors.grey,
          ),
        ),
        const Divider(height: 16),
      ],
    );
  }
}

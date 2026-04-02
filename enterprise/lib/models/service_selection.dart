import 'service_model.dart';

class ServiceSelection {
  final ServiceModel service;
  DateTime? expectedDate;
  double quantidade; // 👈 new decimal field
  int? assignedUserId;
  bool sobreaviso;

  ServiceSelection({
    required this.service,
    this.expectedDate,
    this.quantidade = 1.0, // 👈 default to 1.0
    this.assignedUserId,
    this.sobreaviso = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'item': service.item,
      'atividade': service.atividade,
      'descricao_detalhada': service.descricaoDetalhada,
      'data_conclusao': expectedDate?.toIso8601String(),
      'quantidade': quantidade, // 👈 include when sending to backend
      'user_id': assignedUserId,
      'sobreaviso': sobreaviso ? 'Sim' : 'Nao',
    };
  }
}

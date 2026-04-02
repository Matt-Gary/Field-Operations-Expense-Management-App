class ServiceModel {
  final String? item;
  final String? atividade;
  final String? descricaoDetalhada;

  ServiceModel({this.item, this.atividade, this.descricaoDetalhada});

  factory ServiceModel.fromJson(Map<String, dynamic> json) => ServiceModel(
    item: json['ITEM'],
    atividade: json['ATIVIDADE'],
    descricaoDetalhada: json['descricao_detalhada'],
  );
}

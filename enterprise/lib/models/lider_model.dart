class Lider {
  final String nome;
  final String sobrenome;

  Lider({required this.nome, required this.sobrenome});

  factory Lider.fromJson(Map<String, dynamic> json) => Lider(
        nome: (json['nome'] ?? '').toString(),
        sobrenome: (json['sobrenome'] ?? '').toString(),
      );

  String get fullName {
    final a = nome.trim();
    final b = sobrenome.trim();
    return (a.isEmpty || b.isEmpty) ? (a + b) : '$a $b';
  }

  Map<String, dynamic> toJson() => {'nome': nome, 'sobrenome': sobrenome};
}

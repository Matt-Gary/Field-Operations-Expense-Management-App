import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show TimeOfDay;
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'dart:convert';
import '../models/service_model.dart';
import '../models/service_selection.dart';
import '../models/lider_model.dart';
import '../models/vehicle.dart';

const String PORT = 'http://localhost:3000';

class EnterpriseApiService {
  // Existing:
  static Future<List<String>> getServiceTypes() async {
    final res = await http.get(Uri.parse('$PORT/service-types'));
    if (res.statusCode == 200) {
      return List<String>.from(json.decode(res.body));
    }
    throw Exception('Failed types: ${res.statusCode}');
  }

  static Future<List<String>> getLiderNames() async {
    final uri = Uri.parse('$PORT/enterprise-lider');
    final res = await http.get(uri);

    if (res.statusCode == 200) {
      final raw = json.decode(res.body);
      // backend returns: [{ "nome": "..." }, ...]
      final names =
          (raw as List)
              .map((e) => (e['nome'] ?? '').toString().trim())
              .where((s) => s.isNotEmpty)
              .toSet() // unique
              .toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      return names;
    }

    throw Exception('Failed to load líderes: ${res.statusCode} ${res.body}');
  }

  /// Fetch all users (for access gate)
  static Future<List<Map<String, dynamic>>> getUserList() async {
    final uri = Uri.parse('$PORT/user-pin');
    final res = await http.get(uri);

    if (res.statusCode == 200) {
      final raw = json.decode(res.body);
      return (raw as List)
          .map(
            (e) => {
              'user_id': e['user_id'],
              'name': e['name'],
              'role': e['role'], // Include role
            },
          )
          .toList();
    }

    throw Exception('Failed to load user list: ${res.statusCode} ${res.body}');
  }

  /// Fetch single user’s name + pin by ID
  static Future<Map<String, dynamic>?> getUserPin(int userId) async {
    final uri = Uri.parse('$PORT/user-pin/$userId');
    final res = await http.get(uri);

    if (res.statusCode == 200) {
      final raw = json.decode(res.body);
      return {
        'name': raw['name'],
        'pin': raw['pin'],
        'role': raw['role'], // Include role
      };
    } else if (res.statusCode == 404) {
      return null; // user not found
    }

    throw Exception('Failed to fetch user pin: ${res.statusCode} ${res.body}');
  }

  /// Verifies PIN and returns user data if correct, null otherwise
  static Future<Map<String, dynamic>?> verifyUserPin(
    int userId,
    String enteredPin,
  ) async {
    final user = await getUserPin(userId);
    if (user == null) return null;
    if (user['pin'] == enteredPin.trim()) {
      return user;
    }
    return null;
  }

  static Future<List<Map<String, dynamic>>> getTasksBulk(List<int> ids) async {
    if (ids.isEmpty) return const [];
    final q = ids.join(',');
    final uri = Uri.parse(
      '$PORT/aprovacao/tasks/bulk',
    ).replace(queryParameters: {'ids': q});
    final res = await http.get(uri);
    if (res.statusCode == 200) {
      final body = json.decode(res.body);
      return List<Map<String, dynamic>>.from(body);
    }
    throw Exception('Failed bulk tasks: ${res.statusCode} ${res.body}');
  }

  // 2️⃣ Record approver + timestamp in formas_enviadas
  static Future<void> recordFormApproval({
    required int taskId,
    required String aprovadoPor,
    required DateTime aprovadoData,
    String? statusForma, // NEW: 'Fechado' | 'Reprovado'
  }) async {
    final body = json.encode({
      'task_id': taskId,
      'aprovado_por': aprovadoPor,
      'aprovado_data': _formatGlpiDate(aprovadoData),
      if (statusForma != null) 'status_forma': statusForma, // <—
    });

    try {
      final res = await http
          .post(
            Uri.parse('$PORT/aprovacao/record'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(const Duration(seconds: 30)); // Add timeout

      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception(
          'HTTP ${res.statusCode}: ${res.body.isEmpty ? "No response body" : res.body}',
        );
      }
    } catch (e) {
      // Re-throw with more context
      throw Exception('Failed to record approval for task $taskId: $e');
    }
  }

  static Future<List<Lider>> getLiders() async {
    final res = await http.get(Uri.parse('$PORT/enterprise-lider'));
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(
        json.decode(res.body),
      ).map((e) => Lider.fromJson(e)).toList();
    }
    throw Exception('Failed types: ${res.statusCode}');
  }

  /// Returns [{id, nome}] from enterprise_liders — used by Survey Solicitante dropdown.
  static Future<List<Map<String, dynamic>>> getLidersWithId() async {
    final res = await http.get(Uri.parse('$PORT/enterprise-lider'));
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed liders-id: ${res.statusCode}');
  }

  /// Returns [{id, site}] from sites_enterprise — used by Survey Site ENTERPRISE dropdown.
  static Future<List<Map<String, dynamic>>> getSitesEnterprise() async {
    final res = await http.get(Uri.parse('$PORT/sites-enterprise'));
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed sites-enterprise: ${res.statusCode}');
  }

  /// POST /survey-enterprise — saves a survey record. Returns inserted id or null.
  static Future<int?> createSurveyEnterprise({
    required int solicitanteId,
    required String projeto,
    required String objetivo,
    required int siteEnterpriseId,
    required DateTime dataDeExecucao,
    required TimeOfDay horarioAgendado,
    required String empresaResponsavel,
    required String entregavelPrevisto,
  }) async {
    final dateStr =
        '${dataDeExecucao.year.toString().padLeft(4, '0')}-'
        '${dataDeExecucao.month.toString().padLeft(2, '0')}-'
        '${dataDeExecucao.day.toString().padLeft(2, '0')}';
    final timeStr =
        '${horarioAgendado.hour.toString().padLeft(2, '0')}:'
        '${horarioAgendado.minute.toString().padLeft(2, '0')}:00';

    final body = json.encode({
      'solicitante': solicitanteId,
      'projeto': projeto,
      'objetivo': objetivo,
      'site_enterprise': siteEnterpriseId,
      'data_de_execucao': dateStr,
      'horario_agendado': timeStr,
      'empresa_responsavel': empresaResponsavel,
      'entregavel_previsto': entregavelPrevisto,
    });

    final res = await http.post(
      Uri.parse('$PORT/survey-enterprise'),
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      final decoded = json.decode(res.body);
      final id = decoded['id'];
      if (id is int) return id;
      if (id is String) return int.tryParse(id);
      return null;
    }
    throw Exception('POST /survey-enterprise failed ${res.statusCode}: ${res.body}');
  }

  static Future<List<ServiceModel>> getServices(String type) async {
    final encoded = Uri.encodeQueryComponent(type);
    final res = await http.get(Uri.parse('$PORT/services?type=$encoded'));
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(
        json.decode(res.body),
      ).map((e) => ServiceModel.fromJson(e)).toList();
    }
    throw Exception('Failed services: ${res.statusCode}');
  }

  static Future<List<Map<String, dynamic>>> getPreAprovadosTarefas({
    required int userId,
  }) async {
    final uri = Uri.parse(
      '$PORT/preaprovados',
    ).replace(queryParameters: {'user_id': '$userId'});
    final res = await http.get(uri);
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed preaprovados: ${res.statusCode} ${res.body}');
  }

  // get info H.h
  static Future<double?> getPreAprovadoTempoPrevisto({
    required int userId,
    required String tarefa,
  }) async {
    final uri = Uri.parse(
      '$PORT/preaprovados/info',
    ).replace(queryParameters: {'user_id': '$userId', 'tarefa': tarefa});
    final res = await http.get(uri);
    if (res.statusCode != 200) return null;

    final Map<String, dynamic> body = json.decode(res.body);
    final v = body['tempo_previsto_h'];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString().replaceAll(',', '.'));
  }

  // get tempo previsto and tipo de evidencia
  static Future<Map<String, dynamic>> getPreAprovadoInfo({
    required int userId,
    required String tarefa,
  }) async {
    final uri = Uri.parse(
      '$PORT/preaprovados/info',
    ).replace(queryParameters: {'user_id': '$userId', 'tarefa': tarefa});
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      return {
        'tempo_previsto_h': null,
        'tipo_de_evidencia': null,
        'fracao_de_us': null,
        'multiplo_de_us': null,
      };
    }
    final Map<String, dynamic> body = json.decode(res.body);
    return {
      'tempo_previsto_h': body['tempo_previsto_h'],
      'tipo_de_evidencia': body['tipo_de_evidencia'],
      'fracao_de_us': body['fracao_de_us'],
      'multiplo_de_us': body['multiplo_de_us'],
    };
  }

  //fetch pending task's time
  static Future<DateTime?> getPendenteStart(int taskId) async {
    final res = await http.get(
      Uri.parse('$PORT/formas-enviadas/pendente/$taskId'),
    );
    if (res.statusCode == 200) {
      final body = json.decode(res.body) as Map<String, dynamic>;
      final raw = body['data_start_pendente'] as String?;
      if (raw == null || raw.trim().isEmpty) return null;
      // backend returns "YYYY-MM-DD HH:mm:ss"
      final iso = raw.replaceFirst(' ', 'T');
      return DateTime.tryParse(iso);
    }
    throw Exception(
      'Falha ao carregar início de Pendente: ${res.statusCode} ${res.body}',
    );
  }

  // User Panel - Get all tasks for a specific user
  static Future<List<Map<String, dynamic>>> getUserTasks(int userId) async {
    final uri = Uri.parse('$PORT/user/tasks/$userId');
    final res = await http.get(uri);

    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed to load user tasks: ${res.statusCode} ${res.body}');
  }

  // #### FAVORITOS
  static Future<List<String>> getPreAprovadosFavoritos({
    required int userId,
  }) async {
    final uri = Uri.parse('$PORT/preaprovados/favoritos?userId=$userId');
    final res = await http.get(uri);

    if (res.statusCode != 200) {
      throw Exception('Erro ao buscar favoritos: ${res.statusCode}');
    }

    final body = json.decode(res.body);
    // Se backend devolver [{ tarefa: 'X' }...]
    if (body is List) {
      if (body.isNotEmpty && body.first is Map) {
        return body
            .map((e) => (e['tarefa'] as String?)?.trim())
            .whereType<String>()
            .toList();
      }
      // se já for lista de strings
      return body.cast<String>();
    }

    return const [];
  }

  static Future<void> addPreAprovadoFavorito({
    required int userId,
    required String tarefa,
  }) async {
    final uri = Uri.parse('$PORT/preaprovados/favoritos');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({'userId': userId, 'tarefa': tarefa}),
    );
    if (res.statusCode != 200) {
      throw Exception('Erro ao favoritar tarefa: ${res.statusCode}');
    }
  }

  static Future<void> removePreAprovadoFavorito({
    required int userId,
    required String tarefa,
  }) async {
    final uri = Uri.parse(
      '$PORT/preaprovados/favoritos?userId=$userId&tarefa=${Uri.encodeQueryComponent(tarefa)}',
    );
    final res = await http.delete(uri);
    if (res.statusCode != 200) {
      throw Exception('Erro ao desfavoritar tarefa: ${res.statusCode}');
    }
  }

  // User Panel - Update user task
  // ADD: two optional params and send them if provided
  static Future<bool> updateUserTask({
    required int taskId,
    String? name,
    String? content,
    DateTime? realStartDate,
    DateTime? realEndDate,
    String? comentario,
    double? quantidadeTarefas,
    int? projectstatesId,
    DateTime? dataStartPendente,
    DateTime? dataEndPendente,
    String? modoDeTrabalho,
    bool isAdmin = false,
  }) async {
    final body = <String, dynamic>{};

    if (name != null) body['name'] = name;
    if (content != null) body['content'] = content;
    if (realStartDate != null) {
      body['real_start_date'] = _formatGlpiDate(realStartDate);
    }
    if (realEndDate != null) {
      body['real_end_date'] = _formatGlpiDate(realEndDate);
    }
    if (comentario != null) body['comentario'] = comentario;
    if (quantidadeTarefas != null) {
      body['quantidade_tarefas'] = quantidadeTarefas;
    }
    if (projectstatesId != null) body['projectstates_id'] = projectstatesId;

    // >>> NEW: pendente dates (stored only in formas_enviadas)
    if (dataStartPendente != null) {
      body['data_start_pendente'] = _formatGlpiDate(dataStartPendente);
    }
    if (dataEndPendente != null) {
      body['data_end_pendente'] = _formatGlpiDate(dataEndPendente);
    }
    if (modoDeTrabalho != null) {
      body['modo_de_trabalho'] = modoDeTrabalho;
    }

    body['is_admin'] = isAdmin;

    final res = await http.put(
      Uri.parse('$PORT/user/tasks/$taskId'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (res.statusCode == 200) {
      final response = json.decode(res.body);
      return response['success'] == true;
    }
    throw Exception(
      'Failed to update user task: ${res.statusCode} ${res.body}',
    );
  }
  // enterprise_api_service.dart (inside EnterpriseApiService)
  // === APROVAÇÃO ===

  static Future<List<Map<String, dynamic>>> getClosedTasks({
    int projectId = 599,
    List<int>? statusIds,
  }) async {
    // Default to status 7 (Aguardando Aprovacao) if not provided
    final statuses = (statusIds == null || statusIds.isEmpty) ? [7] : statusIds;
    final statusesParam = statuses.join(',');

    final uri = Uri.parse('$PORT/aprovacao/closed-tasks').replace(
      queryParameters: {'project_id': '$projectId', 'statuses': statusesParam},
    );
    final res = await http.get(uri);
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed closed tasks: ${res.statusCode} ${res.body}');
  }

  // Update atividade Panel Usuario
  static Future<Map<String, dynamic>> updateTaskAtividade({
    required int taskId,
    required int userId,
    required String tarefa,
    bool isAdmin = false,
  }) async {
    final uri = Uri.parse('$PORT/user/tasks/$taskId/atividade');
    final res = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        'tarefa': tarefa,
        'user_id': userId,
        'is_admin': isAdmin,
      }),
    );
    if (res.statusCode == 200) {
      return json.decode(res.body) as Map<String, dynamic>;
    }
    throw Exception(
      'Falha ao atualizar atividade/item: ${res.statusCode} ${res.body}',
    );
  }

  static Future<Map<String, dynamic>> getTaskDetails(int taskId) async {
    final res = await http.get(Uri.parse('$PORT/aprovacao/tasks/$taskId'));
    if (res.statusCode == 200) {
      return Map<String, dynamic>.from(json.decode(res.body));
    }
    throw Exception('Failed task details: ${res.statusCode} ${res.body}');
  }

  static Future<int> createPreAprovadaTask({
    required String tarefa,
    required int userId, // GLPI user id (Criador)
    required int projectstatesId,
    String? comment,
    required DateTime realStartDate,
    DateTime? userConcludeDate, // required only when status==7
    DateTime? pendenteStart,
    DateTime? pendenteEnd,
    required double quantidadeTarefas,
    bool? considerFhc,
    bool? sobreaviso,
  }) async {
    final body = <String, dynamic>{
      'tarefa': tarefa,
      'user_id': userId,
      'projectstates_id': projectstatesId,
      if (comment != null && comment.trim().isNotEmpty)
        'comment': comment.trim(),
      'real_start_date': _formatGlpiDate(realStartDate),
      if (userConcludeDate != null)
        'user_conclude_date': _formatGlpiDate(userConcludeDate),

      if (pendenteStart != null)
        'data_start_pendente': _formatGlpiDate(pendenteStart),
      if (pendenteEnd != null)
        'data_end_pendente': _formatGlpiDate(pendenteEnd),
      'quantidade_tarefas': quantidadeTarefas,
      if (considerFhc != null) 'consider_fhc': considerFhc,
      if (sobreaviso != null) 'sobreaviso': sobreaviso ? 'Sim' : 'Nao',
    };

    final res = await http.post(
      Uri.parse('$PORT/preaprovados/create-task'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      final decoded = json.decode(res.body);
      final id = decoded['task_id'];
      if (id is int) return id;
      if (id is String) {
        final parsed = int.tryParse(id);
        if (parsed != null) return parsed;
      }
      throw Exception('No task_id in response: ${res.body}');
    }

    throw Exception('Create preaprovada failed ${res.statusCode}: ${res.body}');
  }

  /// GET /user/time-overlap
  /// Returns a map with two keys:
  ///  - 'conflicts': List of tasks whose time window overlaps [start, end)
  ///  - 'inProgress': List of tasks that started on the same day but have no end date yet
  /// All results are for the same [userId]. On any network error returns empty lists.
  static Future<Map<String, dynamic>> checkTimeOverlap({
    required int userId,
    required DateTime start,
    DateTime? end,
  }) async {
    try {
      final params = <String, String>{
        'user_id': '$userId',
        'start': start.toIso8601String(),
        if (end != null) 'end': end.toIso8601String(),
      };
      final uri = Uri.parse(
        '$PORT/user/time-overlap',
      ).replace(queryParameters: params);
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        return json.decode(res.body) as Map<String, dynamic>;
      }
      // Non-critical — silently return empty on server error
      return {'conflicts': [], 'inProgress': []};
    } catch (_) {
      return {'conflicts': [], 'inProgress': []};
    }
  }

  /// GET /vehicle -> [{ registration_plate, vehicle_type }, ...]
  static Future<List<Vehicle>> getVehicles() async {
    final res = await http.get(Uri.parse('$PORT/vehicle'));
    if (res.statusCode == 200) {
      final list = json.decode(res.body) as List;
      return list
          .map((e) => Vehicle.fromJson(e as Map<String, dynamic>))
          .toList();
    }
    throw Exception('Failed to load vehicles: ${res.statusCode}');
  }

  static Future<bool> registerVehicle({
    required String registrationPlate,
    required String producent,
    required String model,
    required String vehicleType,
    String? cor,
    required int consumo,
    String contract = 'Enterprise',
  }) async {
    final body = {
      'registration_plate': registrationPlate,
      'producent': producent,
      'model': model,
      'vehicle_type': vehicleType,
      'cor': cor,
      'consumo': consumo,
      'contract': contract,
    };

    final res = await http.post(
      Uri.parse('$PORT/vehicle'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (res.statusCode == 201) return true;
    if (res.statusCode == 409) {
      throw Exception('Veículo com esta placa já existe.');
    }
    throw Exception('Falha ao registrar veículo: ${res.body}');
  }

  // Delete task in GLPI and formas_enviadas (blocked for Approved/7 by backend)
  static Future<void> deleteTask({
    required int taskId,
    required int userId,
    bool isAdmin = false,
  }) async {
    final uri = Uri.parse('$PORT/user/tasks/$taskId').replace(
      queryParameters: {'user_id': '$userId', if (isAdmin) 'is_admin': 'true'},
    );
    final res = await http.delete(
      uri,
      headers: {'Content-Type': 'application/json'},
    );
    if (res.statusCode != 200) {
      throw Exception('Falha ao remover tarefa: ${res.statusCode} ${res.body}');
    }
  }

  static Future<int?> createViagem({
    required int userId,
    required String name,
    required String plate,
    required String vehicleType,
    required int startKm,
    required int finishKm,
    required String localStart,
    required String localDestination,
    required String reason,
    String? travelDateIso,
  }) async {
    // Build payload
    final body = <String, dynamic>{
      'user_id': userId,
      'name': name,
      'plate': plate,
      'vehicle_type': vehicleType,
      'start_km': startKm,
      'finish_km': finishKm,
      'local_start': localStart,
      'local_destination': localDestination,
      'reason': reason,
    };

    // Add date if provided (convert ISO -> YYYY-MM-DD for MySQL DATE)
    if (travelDateIso != null && travelDateIso.isNotEmpty) {
      final d = DateTime.tryParse(travelDateIso);
      if (d != null) {
        final yyyymmdd =
            '${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}';
        body['data_viagem'] = yyyymmdd; // add to payload
      }
    }

    final res = await http.post(
      Uri.parse('$PORT/registro-viagem'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (res.statusCode == 200 || res.statusCode == 201) {
      final Map<String, dynamic> decoded = json.decode(res.body);
      if (decoded['id'] != null) {
        final idVal = decoded['id'];
        if (idVal is int) return idVal;
        if (idVal is String) return int.tryParse(idVal);
      }
      throw Exception('POST /registro-viagem ok, but no id: ${res.body}');
    }
    throw Exception(
      'POST /registro-viagem failed ${res.statusCode}: ${res.body}',
    );
  }

  // === VIAGEM (KM) CRUD ===

  static Future<List<Map<String, dynamic>>> getViagens({
    int? userId,
    String? fromYmd,
    String? toYmd,
  }) async {
    final uri = Uri.parse('$PORT/registro-viagem').replace(
      queryParameters: {
        if (userId != null) 'user_id': '$userId',
        if (fromYmd != null) 'from': fromYmd,
        if (toYmd != null) 'to': toYmd,
      },
    );

    final res = await http.get(uri);
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed to load viagens: ${res.statusCode}');
  }

  static Future<void> updateViagem({
    required int viagemId,
    String? plate,
    String? vehicleType,
    int? startKm,
    int? finishKm,
    String? localStart,
    String? localDestination,
    String? reason,
    DateTime? dataViagem,
  }) async {
    final uri = Uri.parse('$PORT/registro-viagem/$viagemId');
    final body = <String, dynamic>{};

    if (plate != null) body['plate'] = plate;
    if (vehicleType != null) body['vehicle_type'] = vehicleType;
    if (startKm != null) body['start_km'] = startKm;
    if (finishKm != null) body['finish_km'] = finishKm;
    if (localStart != null) body['local_start'] = localStart;
    if (localDestination != null) body['local_destination'] = localDestination;
    if (reason != null) body['reason'] = reason;
    if (dataViagem != null) {
      body['data_viagem'] =
          '${dataViagem.year}-${dataViagem.month.toString().padLeft(2, '0')}-${dataViagem.day.toString().padLeft(2, '0')}';
    }

    if (body.isEmpty) return;

    final res = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (res.statusCode != 200) {
      throw Exception('Failed to update viagem: ${res.statusCode} ${res.body}');
    }
  }

  static Future<void> deleteViagem(int viagemId) async {
    final uri = Uri.parse('$PORT/registro-viagem/$viagemId');
    final res = await http.delete(uri);
    if (res.statusCode != 200) {
      throw Exception('Failed to delete viagem: ${res.statusCode} ${res.body}');
    }
  }

  //sending despesas to database
  static Future<int?> createDespesa({
    required int userId,
    required String userName,
    required String contrato,
    required String tipoDespesa,
    required double valor,
    required String dataConsumoIso,
    required int quantidade,
    required String justificativa,
  }) async {
    // Convert ISO -> YYYY-MM-DD
    final d = DateTime.parse(dataConsumoIso);
    final yyyymmdd =
        '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';

    final uri = Uri.parse('$PORT/despesas');
    final body = json.encode({
      'user_id': userId,
      'user_name': userName,
      'contrato': contrato,
      'tipo_de_despesa': tipoDespesa,
      'valor_despesa': valor,
      'data_consumo': yyyymmdd,
      'quantidade': quantidade,
      'justificativa': justificativa,
    });

    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (res.statusCode == 200 || res.statusCode == 201) {
      // Try to extract the ID from common shapes: {id}, {despesaId}, {insertId}, {data:{id}}
      int? asInt(dynamic v) =>
          v is int ? v : (v is String ? int.tryParse(v) : null);

      final dynamic decoded = json.decode(res.body);
      if (decoded is Map) {
        final id =
            asInt(decoded['id']) ??
            asInt(decoded['despesaId']) ??
            asInt(decoded['insertId']) ??
            asInt((decoded['data'] is Map) ? decoded['data']['id'] : null);
        if (id != null) return id;
      }
      // If backend already returns just the number/string
      final numOnly = asInt(decoded);
      if (numOnly != null) return numOnly;

      throw Exception(
        'POST /despesas returned 200 but no id in body: ${res.body}',
      );
    }

    throw Exception('POST /despesas failed ${res.statusCode}: ${res.body}');
  }

  /// GET /file-upload-config -> { maxFileSize: int, allowedExtensions: [String] }
  static Future<Map<String, dynamic>> getFileUploadConfig() async {
    final res = await http.get(Uri.parse('$PORT/file-upload-config'));
    if (res.statusCode == 200) {
      return json.decode(res.body) as Map<String, dynamic>;
    }
    throw Exception('Failed file-upload-config: ${res.statusCode}');
  }

  //get despesas
  static Future<List<Map<String, dynamic>>> getDespesasByUser({
    required int userId,
    String? fromYmd, // optional "YYYY-MM-DD"
    String? toYmd,
  }) async {
    final uri = Uri.parse('$PORT/despesas').replace(
      queryParameters: {
        'user_id': '$userId',
        if (fromYmd != null) 'from': fromYmd,
        if (toYmd != null) 'to': toYmd,
      },
    );

    final res = await http.get(uri);
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed despesas: ${res.statusCode}');
  }

  // update despesa (partial; only send fields you want to change)
  static Future<Map<String, dynamic>> updateDespesa({
    required int despesaId,
    String? tipoDespesa,
    double? valor,
    DateTime? dataConsumo,
    int? quantidade,
    String? justificativa,
  }) async {
    final uri = Uri.parse('$PORT/despesas/$despesaId');

    final body = <String, dynamic>{};
    if (tipoDespesa != null) body['tipo_de_despesa'] = tipoDespesa;
    if (valor != null) body['valor_despesa'] = valor;
    if (dataConsumo != null) {
      final y = dataConsumo.year.toString().padLeft(4, '0');
      final m = dataConsumo.month.toString().padLeft(2, '0');
      final d = dataConsumo.day.toString().padLeft(2, '0');
      body['data_consumo'] = '$y-$m-$d';
    }
    if (quantidade != null) body['quantidade'] = quantidade;
    if (justificativa != null) body['justificativa'] = justificativa;

    if (body.isEmpty) {
      throw Exception('Nada para atualizar');
    }

    final res = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );

    if (res.statusCode == 200) {
      return (json.decode(res.body) as Map).cast<String, dynamic>();
    }

    throw Exception(
      'PUT /despesas/$despesaId failed ${res.statusCode}: ${res.body}',
    );
  }

  // Delete a despesa (and its file in GLPI on the backend)
  static Future<void> deleteDespesa(int despesaId) async {
    final uri = Uri.parse('$PORT/despesas/$despesaId');
    final res = await http.delete(uri);
    if (res.statusCode != 200) {
      throw Exception(
        'Falha ao excluir despesa: ${res.statusCode} ${res.body}',
      );
    }
  }

  static Future<void> createMedicaoVeiculo({
    String? mes,
    String? dataInicio,
    String? dataFim,
    String? solicitante,
    String? grupoEnterprise,
    String? tipoVeiculo,
    String? periodoUtiliza,
    int? qtd,
    String? user,
    int? userId,
    String? status,
  }) async {
    final uri = Uri.parse('$PORT/enterprise-medicao-veiculos');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode({
        if (mes != null) 'mes': mes,
        if (dataInicio != null) 'data_inicio': dataInicio,
        if (dataFim != null) 'data_fim': dataFim,
        if (solicitante != null) 'solicitante': solicitante,
        if (grupoEnterprise != null) 'grupo_enterprise': grupoEnterprise,
        if (tipoVeiculo != null) 'tipo_veiculo': tipoVeiculo,
        if (periodoUtiliza != null) 'periodo_utiliza': periodoUtiliza,
        if (qtd != null) 'qtd': qtd,
        if (user != null) 'user': user,
        if (userId != null) 'user_id': userId,
        if (status != null) 'status': status,
      }),
    );
    if (res.statusCode != 201) {
      throw Exception(
        'Falha ao registrar medição: ${res.statusCode} ${res.body}',
      );
    }
  }

  // ADMIN: list despesas to approve (fast, paginated)
  static Future<List<Map<String, dynamic>>> getDespesasAdmin({
    String? tipo, // 'Refeição' | 'Hospedagem'
    int? userId,
    String? status, // 'Aguardando Aprovação' | 'Aprovado' | 'Reprovado'
    String? fromYmd, // YYYY-MM-DD
    String? toYmd, // YYYY-MM-DD
    int limit = 50,
    int offset = 0,
  }) async {
    final uri = Uri.parse('$PORT/despesas/admin').replace(
      queryParameters: {
        if (tipo != null && tipo.isNotEmpty) 'tipo': tipo,
        if (userId != null) 'user_id': '$userId',
        if (status != null && status.isNotEmpty) 'status': status,
        if (fromYmd != null) 'from': fromYmd,
        if (toYmd != null) 'to': toYmd,
        'limit': '$limit',
        'offset': '$offset',
      },
    );

    final res = await http.get(uri);
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed admin despesas: ${res.statusCode} ${res.body}');
  }

  // ADMIN: marcar/ desmarcar "Prestação Realizada"
  static Future<void> setPrestacaoRealizada({
    required int despesaId,
    required bool realizada, // true => 'SIM', false => 'NÃO'
  }) async {
    final uri = Uri.parse('$PORT/despesas/$despesaId/prestacao-realizada');

    final body = <String, dynamic>{
      'prestacao_realizada': realizada ? 'SIM' : 'NÃO',
    };

    final res = await http.put(
      uri,
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (res.statusCode != 200) {
      throw Exception(
        'Falha ao atualizar Prestação Realizada: '
        '${res.statusCode} ${res.body}',
      );
    }
  }

  static Future<void> setDespesaInternal({
    required int despesaId,
    required String internal, // 'sim' ou 'nao'
  }) async {
    final url = Uri.parse('$PORT/despesas/$despesaId/internal');

    final resp = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'internal': internal}),
    );

    if (resp.statusCode != 200) {
      throw Exception('Falha ao atualizar flag Internal: ${resp.body}');
    }
  }

  // ADMIN: approve/reject single
  static Future<void> setDespesaAprovacao({
    required int despesaId,
    required String aprovacao, // 'Aprovado' | 'Reprovado'
    required String aprovadoPor, // líder selecionado
    String? motivo,
  }) async {
    final uri = Uri.parse('$PORT/despesas/$despesaId/aprovacao');
    final body = {
      'aprovacao': aprovacao,
      'aprovado_por': aprovadoPor,
      if (motivo != null) 'aprovacao_motivo': motivo,
    };
    final res = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (res.statusCode != 200) {
      throw Exception('Aprovação falhou: ${res.statusCode} ${res.body}');
    }
  }

  // ADMIN: approve/reject bulk
  static Future<int> setDespesaAprovacaoBulk({
    required List<int> ids,
    required String aprovacao, // 'Aprovado' | 'Reprovado'
    required String aprovadoPor,
    String? motivo,
  }) async {
    final uri = Uri.parse('$PORT/despesas/aprovacao-bulk');
    final body = {
      'ids': ids,
      'aprovacao': aprovacao,
      'aprovado_por': aprovadoPor,
      if (motivo != null) 'aprovacao_motivo': motivo,
    };
    final res = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    if (res.statusCode == 200) {
      final m = json.decode(res.body) as Map<String, dynamic>;
      return (m['affectedRows'] as num?)?.toInt() ?? 0;
    }
    throw Exception('Aprovação em massa falhou: ${res.statusCode} ${res.body}');
  }

  //sent photo from viagem/despesas
  // 2) Ensure optional fields are sent safely (null-check on maxPartBytes)
  //    and support despesaId/viagemId/fotoTipo.
  static Future<Map<String, dynamic>> uploadPhotoBytesToTask({
    required int taskId, // GLPI subtask id
    required Uint8List bytes,
    required String filename,
    String itemtype = 'ProjectTask',
    int? maxPartBytes,
    int? despesaId,
    int? viagemId,
    String? fotoTipo, // 'inicio' | 'fim'
  }) async {
    final uri = Uri.parse('$PORT/upload-documents');
    final req = http.MultipartRequest('POST', uri)
      ..fields['itemtype'] = itemtype
      ..fields['itemsId'] = taskId.toString();

    if (maxPartBytes != null) {
      req.fields['maxPartBytes'] = maxPartBytes
          .toString(); // <-- guard against null
    }
    if (despesaId != null) req.fields['despesaId'] = despesaId.toString();
    if (viagemId != null) req.fields['viagemId'] = viagemId.toString();
    if (fotoTipo != null) req.fields['fotoTipo'] = fotoTipo;

    req.files.add(
      http.MultipartFile.fromBytes(
        'files',
        bytes,
        filename: filename,
        contentType: MediaType('image', 'jpeg'),
      ),
    );

    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode == 200) {
      return (json.decode(resp.body) as Map).cast<String, dynamic>();
    }
    throw Exception('Upload failed: ${resp.statusCode} ${resp.body}');
  }

  /// Uploads multiple files in a single multipart request to /upload-documents.
  /// [fileEntries] is a list of (filename, bytes) pairs.
  static Future<Map<String, dynamic>> uploadManyBytesToDespesa({
    required int despesaId,
    required List<MapEntry<String, Uint8List>> fileEntries,
  }) async {
    final uri = Uri.parse('$PORT/upload-documents');
    final req = http.MultipartRequest('POST', uri)
      ..fields['despesaId'] = despesaId.toString();

    for (final entry in fileEntries) {
      req.files.add(
        http.MultipartFile.fromBytes('files', entry.value, filename: entry.key),
      );
    }

    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode == 200) {
      return (json.decode(resp.body) as Map).cast<String, dynamic>();
    }
    throw Exception('Upload failed: ${resp.statusCode} ${resp.body}');
  }

  static Future<bool> submitForm({
    required String lider,
    required String tipoServico,
    required List<ServiceSelection> servicos,
    required String comentario,
  }) async {
    final data = {
      'lider': lider,
      'tipo_servico': tipoServico,
      'servicos': servicos
          .map(
            (s) => {
              'item': s.service.item,
              'atividade': s.service.atividade,
              'descricao_detalhada': s.service.descricaoDetalhada,
              'data_conclusao': s.expectedDate?.toIso8601String(),
              'quantidade': s.quantidade,
              'user_id': s.assignedUserId, // pode estar null
              'sobreaviso': s.sobreaviso ? 'Sim' : 'Nao',
            },
          )
          .toList(),
      'comentario': comentario,
    };

    // DEBUG
    // ignore: avoid_print
    print('submitForm payload: ${json.encode(data)}');

    final res = await http.post(
      Uri.parse('$PORT/enviar-forma'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(data),
    );

    if (res.statusCode != 200) {
      // ignore: avoid_print
      print('submitForm FAILED: ${res.statusCode} - ${res.body}');
    }
    return res.statusCode == 200;
  }

  //  GLPI Users
  static Future<List<Map<String, dynamic>>> getGlpiUsers() async {
    final res = await http.get(Uri.parse('$PORT/glpi/users'));
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed GLPI users: ${res.statusCode}');
  }

  //  GLPI Activities for a user
  static Future<List<Map<String, dynamic>>> getGlpiActivities(
    int userId,
  ) async {
    final res = await http.get(
      Uri.parse('$PORT/glpi/users/$userId/activities'),
    );
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    throw Exception('Failed GLPI activities: ${res.statusCode}');
  }

  static Future<Map<String, dynamic>> getLeaderFirstCommentWithAuthor(
    int taskId,
  ) async {
    final uri = Uri.parse('$PORT/formas-enviadas/by-task/$taskId');
    final res = await http.get(uri);

    if (res.statusCode == 200) {
      final Map<String, dynamic> body = json.decode(res.body);
      return {
        'author': (body['author_name'] as String?)?.trim(),
        'comment': (body['comentario_inicial'] as String?)?.trim(),
        'quantidade_tarefas': body['quantidade_tarefas'],
        'tempo_previsto_h': body['tempo_previsto_h'],
        'tipo_de_evidencia': body['tipo_de_evidencia'],
        'fracao_de_us': body['fracao_de_us'],
        'multiplo_de_us': body['multiplo_de_us'],
      };
    }
    if (res.statusCode == 404) {
      return {
        'author': null,
        'comment': null,
        'quantidade_tarefas': null,
        'tempo_previsto_h': null,
        'tipo_de_evidencia': null,
        'fracao_de_us': null,
        'multiplo_de_us': null,
      };
    }
    throw Exception(
      'Failed to load líder comment: ${res.statusCode} ${res.body}',
    );
  }

  // Delete a specific file of a despesa
  static Future<void> deleteDespesaFile(int despesaId, int fileId) async {
    final uri = Uri.parse('$PORT/despesas/$despesaId/file/$fileId');
    final res = await http.delete(uri);
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw Exception(
        'Falha ao remover arquivo: ${res.statusCode} ${res.body}',
      );
    }
  }

  // Delete a specific file of a viagem
  static Future<void> deleteViagemFile(int viagemId, int fileId) async {
    final uri = Uri.parse('$PORT/registro-viagem/$viagemId/file/$fileId');
    final res = await http.delete(uri);
    if (res.statusCode != 200 && res.statusCode != 204) {
      throw Exception(
        'Falha ao remover arquivo: ${res.statusCode} ${res.body}',
      );
    }
  }

  static Future<List<Map<String, dynamic>>> getDespesaFiles(
    int despesaId,
  ) async {
    final uri = Uri.parse('$PORT/despesas/$despesaId/files');
    final res = await http.get(uri);
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    return [];
  }

  static Future<List<Map<String, dynamic>>> getViagemFiles(int viagemId) async {
    final uri = Uri.parse('$PORT/registro-viagem/$viagemId/files');
    final res = await http.get(uri);
    if (res.statusCode == 200) {
      return List<Map<String, dynamic>>.from(json.decode(res.body));
    }
    return [];
  }

  static String glpiDocProxyUrl(int docid) => '$PORT/aprovacao/document/$docid';
  // ============ Upload documents to your backend ============
  /// Uploads one or more files directly to the Express endpoint
  static Future<Map<String, dynamic>> uploadDocuments({
    String itemtype = 'ProjectTask',
    int? itemsId,
    int? despesaId,
    int? viagemId,
    required List<PlatformFile> files,
  }) async {
    final uri = Uri.parse('$PORT/upload-documents');
    final req = http.MultipartRequest('POST', uri);

    if (itemsId != null) {
      req.fields['itemtype'] = itemtype;
      req.fields['itemsId'] = itemsId.toString();
    }
    if (despesaId != null) req.fields['despesaId'] = despesaId.toString();
    if (viagemId != null) req.fields['viagemId'] = viagemId.toString();

    for (final f in files) {
      if (kIsWeb) {
        if (f.bytes == null) {
          throw Exception('Arquivo sem bytes no Web: ${f.name}');
        }
        req.files.add(
          http.MultipartFile.fromBytes('files', f.bytes!, filename: f.name),
        );
      } else {
        if (f.path != null) {
          req.files.add(
            await http.MultipartFile.fromPath(
              'files',
              f.path!,
              filename: f.name,
            ),
          );
        } else if (f.bytes != null) {
          req.files.add(
            http.MultipartFile.fromBytes('files', f.bytes!, filename: f.name),
          );
        } else {
          throw Exception('Arquivo inválido: ${f.name}');
        }
      }
    }

    final client = http.Client();
    try {
      final streamed = await client
          .send(req)
          .timeout(const Duration(minutes: 5));
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 200) {
        return (json.decode(resp.body) as Map).cast<String, dynamic>();
      }
      throw Exception('Upload failed: ${resp.statusCode} ${resp.body}');
    } finally {
      client.close();
    }
  }

  static String _formatGlpiDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm:$ss';
  }

  static Future<bool> updateGlpiTaskStatus({
    required int taskId,
    required int projectstatesId,
    required int userId,
    String? comment,
    DateTime? realEndDate,
    DateTime? realStartDate,
    DateTime? dataStartPendente,
    DateTime? dataEndPendente,
    double? quantidadeTarefas,
    bool? considerFhc,
    bool? sobreaviso,
  }) async {
    final body = <String, dynamic>{
      'projectstates_id': projectstatesId,
      'user_id': userId,
      if (comment != null && comment.trim().isNotEmpty)
        'comment': comment.trim(),
      if (realEndDate != null) 'real_end_date': _formatGlpiDate(realEndDate),
      if (realStartDate != null)
        'real_start_date': _formatGlpiDate(realStartDate),
      if (dataStartPendente != null)
        'data_start_pendente': _formatGlpiDate(dataStartPendente),
      if (dataEndPendente != null)
        'data_end_pendente': _formatGlpiDate(dataEndPendente),
      if (quantidadeTarefas != null) 'quantidade_tarefas': quantidadeTarefas,
      if (considerFhc != null) 'consider_fhc': considerFhc,
      if (sobreaviso != null) 'sobreaviso': sobreaviso ? 'Sim' : 'Nao',
    };

    final res = await http.post(
      Uri.parse('$PORT/glpi/projecttasks/$taskId/update'),
      headers: {'Content-Type': 'application/json'},
      body: json.encode(body),
    );
    return res.statusCode >= 200 && res.statusCode < 300;
  }

  static Future<void> syncTaskStatus(int taskId) async {
    try {
      final res = await http.get(Uri.parse('$PORT/sync/task/$taskId'));
      if (res.statusCode != 200) {
        debugPrint(
          'Failed to sync task $taskId: ${res.statusCode} ${res.body}',
        );
      }
    } catch (e) {
      debugPrint('Sync task $taskId error: $e');
    }
  }

  // === DOWNLOAD ARQUIVOS ===

  /// GET /arquivos/download-list?from=YYYY-MM-DD&to=YYYY-MM-DD
  /// Returns { despesas: [...], viagens: [...] } with file metadata + URL.
  static Future<Map<String, dynamic>> getArquivosDownloadList({
    required String from,
    required String to,
  }) async {
    final uri = Uri.parse(
      '$PORT/arquivos/download-list',
    ).replace(queryParameters: {'from': from, 'to': to});

    final res = await http.get(uri);
    if (res.statusCode == 200) {
      return json.decode(res.body) as Map<String, dynamic>;
    }
    throw Exception(
      'Erro ao buscar lista de arquivos: ${res.statusCode} ${res.body}',
    );
  }

  /// Builds the URL for the ZIP download so the user's browser / device
  /// can download it directly (opened via url_launcher).
  static String buildArquivosDownloadZipUrl({
    required String from,
    required String to,
  }) {
    return Uri.parse(
      '$PORT/arquivos/download-zip',
    ).replace(queryParameters: {'from': from, 'to': to}).toString();
  }

  static Future<void> deleteArquivosPeriod({
    required String from,
    required String to,
  }) async {
    final uri = Uri.parse('$PORT/arquivos/delete-period').replace(
      queryParameters: {'from': from, 'to': to},
    );
    final res = await http.delete(uri);
    if (res.statusCode != 200) {
      throw Exception('Falha ao excluir arquivos: ${res.statusCode} ${res.body}');
    }
  }
}

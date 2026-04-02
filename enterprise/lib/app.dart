import 'package:enterprise/screens/access_gate_screen.dart';
import 'package:enterprise/screens/despesas_menu_screen.dart';
import 'package:enterprise/screens/minhas_despesas.dart';
import 'package:enterprise/screens/registrar_despesa.dart';
import 'package:enterprise/screens/aprovacao_screen.dart';
import 'package:enterprise/screens/gestao_despesas_screen.dart';
import 'package:enterprise/screens/panel_usuario.dart';
import 'package:flutter/material.dart';
import 'theme/enterprise_theme.dart';
import 'screens/main_menu_screen.dart';
import 'screens/solicitacao_tab_screen.dart';

import 'screens/registro_screen.dart';
import 'screens/registra_viagem.dart';
import 'screens/km_menu_screen.dart';
import 'screens/meus_kms_screen.dart';
import 'screens/add_vehicle_screen.dart';
import 'screens/medicao_veiculos_screen.dart';
import 'widgets/gradient_background.dart';
import 'screens/baixar_arquivos_screen.dart';

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: enterpriseTheme(),
      debugShowCheckedModeBanner: false,
      initialRoute: '/access',
      onGenerateRoute: (settings) {
        Widget page;
        switch (settings.name) {
          case '/access':
            page = const AccessGateScreen();
          case '/solicitacao':
            page = const SolicitacaoTabScreen();
            break;
          case '/aprovacao':
            page = const AprovacaoScreen();
            break;
          case '/registro':
            page = const RegistroScreen();
            break;
          case '/panel_usuario':
            page = const UserPanelScreen();
            break;
          case '/registra_viagem':
          case '/km/registrar':
            page = const RegistraViagemScreen();
            break;
          case '/km':
            page = const KmMenuScreen();
            break;
          case '/km/meus':
            page = const MeusKmsScreen();
            break;
          case '/vehicle/add':
            page = const AddVehicleScreen();
            break;
          case '/medicao/veiculos':
            page = const MedicaoVeiculosScreen();
            break;
          case '/despesas':
            page = const DespesasMenuScreen();
            break;
          case '/despesas/registrar':
            page = const RegistrarDespesaScreen();
            break;
          case '/despesas/minhas':
            page = const MinhasDespesasScreen();
            break;
          case '/despesas/gestaodedespesas':
            page = const GestaoDespesasScreen();
            break;
          case '/arquivos/baixar':
            page = const BaixarArquivosScreen();
            break;
          default:
            page = const MainMenuScreen();
        }
        // Ensure every route sits above the gradient
        return MaterialPageRoute(
          builder: (_) => GradientBackground(child: page),
          settings: settings,
        );
      },
    );
  }
}

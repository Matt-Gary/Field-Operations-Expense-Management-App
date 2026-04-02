import 'package:flutter/material.dart';
import 'service_contract_screen.dart';
import 'survey_screen.dart';

/// Wrapper screen with two tabs:
///  1. Solicitação de tarefa  (existing ServiceContractScreen content)
///  2. Survey                 (new SurveyScreen)
class SolicitacaoTabScreen extends StatelessWidget {
  const SolicitacaoTabScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Líder Enterprise'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Image.asset('assets/images/tivit_logo.png', height: 28),
            ),
          ],
          bottom: const TabBar(
            // ── Visibility fixes ──────────────────────────────────────
            labelColor: Colors.white,
            unselectedLabelColor: Color(0xCCFFFFFF), // 80% white
            labelStyle: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
            unselectedLabelStyle: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            indicator: UnderlineTabIndicator(
              borderSide: BorderSide(color: Colors.white, width: 3),
              insets: EdgeInsets.symmetric(horizontal: 16),
            ),
            indicatorSize: TabBarIndicatorSize.tab,
            dividerColor: Colors.transparent,
            tabs: [
              Tab(text: 'Solicitação de tarefa'),
              Tab(text: 'Survey'),
            ],
          ),
        ),
        body: const TabBarView(
          children: [ServiceContractBody(), SurveyScreen()],
        ),
      ),
    );
  }
}

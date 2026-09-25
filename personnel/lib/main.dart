import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:intl/intl.dart';

import 'dispatch_alerts.dart';
import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await initializeDispatchAlerts();
  runApp(const FireAlertsApp());
}

class FireAlertsApp extends StatelessWidget {
  const FireAlertsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'RescueLink Fire Alerts',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffbd101a)), useMaterial3: true),
        home: const FireAlertsGate(),
      );
}

class FireAlertsGate extends StatelessWidget {
  const FireAlertsGate({super.key});

  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const FireAlertsSignIn();
          return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection('users').doc(snapshot.data!.uid).snapshots(),
            builder: (context, access) {
              if (access.hasError) return Scaffold(body: Center(child: Text('Unable to check access: ${access.error}')));
              if (!access.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
              final role = access.data!.data()?['role'];
              if (role != 'responder' && role != 'admin') {
                return Scaffold(appBar: AppBar(title: const Text('Fire Alerts access required')),
                  body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.lock_outline, size: 48), const SizedBox(height: 12),
                    const Text('Ask the RescueLink administrator to assign your account the responder role.', textAlign: TextAlign.center),
                    const SizedBox(height: 20), TextButton(onPressed: signOut, child: const Text('Sign out')),
                  ]))));
              }
              return FireAlertsHome(user: snapshot.data!);
            },
          );
        },
      );
}

Future<void> signOut() async {
  await stopDispatchMonitor();
  await GoogleSignIn().signOut();
  await FirebaseAuth.instance.signOut();
}

class FireAlertsSignIn extends StatefulWidget {
  const FireAlertsSignIn({super.key});
  @override
  State<FireAlertsSignIn> createState() => _FireAlertsSignInState();
}

class _FireAlertsSignInState extends State<FireAlertsSignIn> {
  static const webClientId = '1066081578301-4cv8gagv0j393fcq2c512nh003nk9cde.apps.googleusercontent.com';
  bool busy = false;
  String? error;

  Future<void> signIn() async {
    setState(() { busy = true; error = null; });
    try {
      final account = await GoogleSignIn(serverClientId: webClientId).signIn();
      if (account == null) return;
      final auth = await account.authentication;
      await FirebaseAuth.instance.signInWithCredential(GoogleAuthProvider.credential(accessToken: auth.accessToken, idToken: auth.idToken));
    } catch (e) {
      if (mounted) setState(() => error = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Image.asset('assets/images/bfp_logo.png', height: 120),
      const SizedBox(height: 20),
      const Text('RescueLink Fire Alerts', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900), textAlign: TextAlign.center),
      const SizedBox(height: 8),
      const Text('Emergency alarms for authorized fire personnel', textAlign: TextAlign.center),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(error!, style: const TextStyle(color: Colors.red))),
      const SizedBox(height: 24),
      FilledButton.icon(onPressed: busy ? null : signIn, icon: const Icon(Icons.login), label: Text(busy ? 'Signing in…' : 'Sign in with Google')),
    ]))))),
  );
}

class FireAlertsHome extends StatefulWidget {
  const FireAlertsHome({super.key, required this.user});
  final User user;

  @override
  State<FireAlertsHome> createState() => _FireAlertsHomeState();
}

class _FireAlertsHomeState extends State<FireAlertsHome> {
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await startDispatchMonitor();
      } catch (e) {
        if (mounted) setState(() => error = 'Monitoring could not start: $e');
      }
    });
  }

  Future<void> test() async {
    try { await testDispatchAlert(); }
    catch (e) { if (mounted) setState(() => error = 'Alarm test failed: $e'); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Fire Alerts'), actions: [IconButton(tooltip: 'Sign out', onPressed: signOut, icon: const Icon(Icons.logout))]),
    body: SafeArea(child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('incidents').orderBy('createdAt', descending: true).limit(30).snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs.where((d) => !{'resolved', 'cancelled'}.contains(d.data()['status'])).toList() ?? [];
        return ListView(padding: const EdgeInsets.all(18), children: [
          Card(color: Colors.red.shade50, child: Padding(padding: const EdgeInsets.all(18), child: Column(children: [
            const Icon(Icons.notifications_active, color: Colors.red, size: 50),
            const SizedBox(height: 10),
            const Text('EMERGENCY ALERTS', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            const Text('Keep the monitoring notification enabled. New RescueLink emergencies trigger an alarm and vibration.', textAlign: TextAlign.center),
            const SizedBox(height: 8), Text('Signed in: ${widget.user.email ?? 'Fire personnel'}', textAlign: TextAlign.center),
          ]))),
          if (error != null) Padding(padding: const EdgeInsets.all(12), child: Text(error!, style: const TextStyle(color: Colors.red))),
          const SizedBox(height: 12),
          FilledButton.icon(onPressed: test, icon: const Icon(Icons.volume_up), label: const Text('TEST ALARM AND VIBRATION')),
          OutlinedButton.icon(onPressed: () async {
            try { await requestDispatchDndAccess(); }
            catch (e) { if (mounted) setState(() => error = 'Do Not Disturb settings: $e'); }
          }, icon: const Icon(Icons.do_not_disturb_on), label: const Text('ALLOW ALERTS DURING DO NOT DISTURB')),
          const SizedBox(height: 14),
          Text('ACTIVE EMERGENCIES (${docs.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
          if (snapshot.hasError) Padding(padding: const EdgeInsets.only(top: 12), child: Text('Unable to read incidents: ${snapshot.error}')),
          if (!snapshot.hasData && !snapshot.hasError) const Center(child: CircularProgressIndicator()),
          if (snapshot.hasData && docs.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No active emergency reports right now.')),
          for (final doc in docs) Card(child: ListTile(
            leading: const Icon(Icons.warning_amber_rounded, color: Colors.red),
            title: Text('${doc.data()['type'] ?? 'Emergency'}'.toUpperCase()),
            subtitle: Text('${doc.data()['description'] ?? 'Emergency assistance requested'}\n${_time(doc.data()['createdAt'])}'),
            isThreeLine: true,
          )),
          const SizedBox(height: 16),
          const Text('If someone is in immediate danger, call 911. Alerts depend on the phone being online and Android allowing the monitor to run.', textAlign: TextAlign.center),
        ]);
      },
    )),
  );

  String _time(Object? value) => value is Timestamp ? DateFormat('MMM d, h:mm a').format(value.toDate().toLocal()) : 'Time pending';
}

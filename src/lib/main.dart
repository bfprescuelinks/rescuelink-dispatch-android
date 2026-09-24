import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'firebase_options.dart';
import 'dispatch_alerts.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await initializeDispatchAlerts();
  runApp(const DispatchApp());
}

class DispatchApp extends StatelessWidget {
  const DispatchApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'RescueLink Dispatch',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xffa40e18), brightness: Brightness.light),
          scaffoldBackgroundColor: const Color(0xfff4f5f7),
          useMaterial3: true,
          appBarTheme: const AppBarTheme(backgroundColor: Color(0xff8d0b13), foregroundColor: Colors.white),
        ),
        home: const AuthGate(),
      );
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) => StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          if (snapshot.data == null) return const SignInScreen();
          return RoleGate(user: snapshot.data!);
        },
      );
}

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  static const webClientId =
      '1066081578301-4cv8gagv0j393fcq2c512nh003nk9cde.apps.googleusercontent.com';

  bool loading = false;
  String? error;

  Future<void> signIn() async {
    setState(() { loading = true; error = null; });
    try {
      final account = await GoogleSignIn(serverClientId: webClientId).signIn();
      if (account == null) return;
      final auth = await account.authentication;
      final credential = GoogleAuthProvider.credential(accessToken: auth.accessToken, idToken: auth.idToken);
      await FirebaseAuth.instance.signInWithCredential(credential);
    } catch (e) {
      setState(() => error = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Container(
          decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xff65050a), Color(0xffd71920)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
          child: Center(
            child: Card(
              margin: const EdgeInsets.all(28),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Image.asset('assets/images/bfp_logo.png', width: 105),
                  const SizedBox(height: 16),
                  const Text('RescueLink Dispatch', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w900)),
                  const Text('BFP MOBILE COMMAND', style: TextStyle(color: Color(0xffa40e18), fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                  const SizedBox(height: 12),
                  const Text('Authorized dispatch and response personnel only.', textAlign: TextAlign.center),
                  if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.red))),
                  const SizedBox(height: 22),
                  FilledButton.icon(onPressed: loading ? null : signIn, icon: const Icon(Icons.login), label: Text(loading ? 'Signing in…' : 'Sign in with Google')),
                ]),
              ),
            ),
          ),
        ),
      );
}

class RoleGate extends StatelessWidget {
  const RoleGate({super.key, required this.user});
  final User user;

  @override
  Widget build(BuildContext context) => StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          final role = snapshot.data!.data()?['role'] as String?;
          if (!{'dispatcher', 'responder', 'admin'}.contains(role)) {
            return Scaffold(
              appBar: AppBar(title: const Text('Access required')),
              body: Center(child: Padding(padding: const EdgeInsets.all(28), child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock, size: 64, color: Color(0xffa40e18)),
                const SizedBox(height: 16),
                Text(user.email ?? 'Signed-in account', style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('Ask the RescueLink administrator to assign this account the dispatcher role.', textAlign: TextAlign.center),
                const SizedBox(height: 18),
                OutlinedButton(onPressed: () async { await GoogleSignIn().signOut(); await FirebaseAuth.instance.signOut(); }, child: const Text('Sign out')),
              ]))),
            );
          }
          return DispatchHome(user: user, role: role!);
        },
      );
}

class Incident {
  Incident({required this.id, required this.type, required this.description, required this.status, required this.position, required this.accuracy, required this.reporter, this.phone, this.createdAt, this.gpsAt, this.speed = 0, this.heading = 0, this.live = false});
  final String id, type, description, status, reporter;
  final String? phone;
  final LatLng position;
  final double accuracy, speed, heading;
  final bool live;
  final Timestamp? createdAt, gpsAt;

  factory Incident.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    final geo = data['location'] as GeoPoint;
    return Incident(
      id: doc.id,
      type: '${data['type'] ?? 'other'}', description: '${data['description'] ?? ''}', status: '${data['status'] ?? 'submitted'}',
      position: LatLng(geo.latitude, geo.longitude), accuracy: (data['accuracyMeters'] as num?)?.toDouble() ?? 0,
      reporter: '${data['reporterName'] ?? 'Citizen'}', phone: data['reporterPhone'] as String?, createdAt: data['createdAt'] as Timestamp?, gpsAt: data['liveLocationUpdatedAt'] as Timestamp?,
      speed: (data['speedKmh'] as num?)?.toDouble() ?? 0, heading: (data['headingDegrees'] as num?)?.toDouble() ?? 0, live: data['liveTracking'] == true,
    );
  }
}

Incident? incidentById(List<Incident> incidents, String id) {
  for (final incident in incidents) {
    if (incident.id == id) return incident;
  }
  return null;
}

class PhilippineClock extends StatefulWidget {
  const PhilippineClock({super.key});

  @override
  State<PhilippineClock> createState() => _PhilippineClockState();
}

class _PhilippineClockState extends State<PhilippineClock> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Philippine Standard Time is UTC+8 year round.
    final philippineTime = DateTime.now().toUtc().add(const Duration(hours: 8));
    final label = DateFormat('EEE, MMM d, y  •  h:mm:ss a').format(philippineTime);
    return Container(
      width: double.infinity,
      color: const Color(0xff8d0b13),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.access_time, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('PHILIPPINE TIME (PHT)', style: TextStyle(color: Color(0xffffd54f), fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1)),
                Text(label, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class DispatchHome extends StatefulWidget {
  const DispatchHome({super.key, required this.user, required this.role});
  final User user;
  final String role;

  @override
  State<DispatchHome> createState() => _DispatchHomeState();
}

class _DispatchHomeState extends State<DispatchHome> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await startDispatchMonitor();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Incident monitoring could not start: $e')));
      }
    });
  }

  Incident? selected;
  bool history = false;
  final map = MapController();
  String? busy;

  Future<void> setStatus(Incident incident, String status) async {
    setState(() => busy = status);
    await FirebaseFirestore.instance.collection('incidents').doc(incident.id).update({
      'status': status,
      'assignedResponderId': widget.user.uid,
      if (status == 'dispatched') 'dispatchedById': widget.user.uid,
      if (status == 'dispatched') 'dispatchedByEmail': widget.user.email ?? widget.user.uid,
      if (status == 'dispatched') 'dispatchedByName': widget.user.displayName ?? widget.user.email ?? 'Dispatcher',
      if (status == 'dispatched') 'dispatchedAt': FieldValue.serverTimestamp(),
      'liveTracking': status == 'resolved' ? false : incident.live,
      if (status == 'resolved') 'closedAt': FieldValue.serverTimestamp(),
      if (status == 'resolved') 'closedBy': widget.user.email ?? widget.user.uid,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (mounted) setState(() => busy = null);
  }

  String time(Timestamp? value) => value == null ? 'Unavailable' : DateFormat('MMM d, y • h:mm:ss a').format(value.toDate().toLocal());

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('RescueLink Dispatch', style: TextStyle(fontWeight: FontWeight.w900)), Text('BFP MOBILE COMMAND', style: TextStyle(fontSize: 9, letterSpacing: 1.4))]),
          actions: [
            IconButton(tooltip: 'Test sound and vibration', icon: const Icon(Icons.volume_up), onPressed: () async {
              try { await testDispatchAlert(); } catch (e) {
                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Alarm test failed: $e')));
              }
            }),
            IconButton(tooltip: 'Allow emergency alerts during Do Not Disturb', icon: const Icon(Icons.notifications_active), onPressed: () async {
              await requestDispatchDndAccess();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enable Do Not Disturb access for RescueLink Dispatch in Android settings.')));
            }),
            IconButton(tooltip: 'Sign out', onPressed: () async { await stopDispatchMonitor(); await GoogleSignIn().signOut(); await FirebaseAuth.instance.signOut(); }, icon: const Icon(Icons.logout)),
          ],
        ),
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('incidents').orderBy('createdAt', descending: true).snapshots(),
          builder: (context, snapshot) {
            if (snapshot.hasError) return Center(child: Text('Unable to load incidents: ${snapshot.error}'));
            if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
            final all = snapshot.data!.docs.map(Incident.fromDoc).toList();
            final incidents = all.where((i) => history ? {'resolved', 'cancelled'}.contains(i.status) : !{'resolved', 'cancelled'}.contains(i.status)).toList();
            final current = selected == null ? null : incidentById(all, selected!.id);
            if (current != null && selected?.position != current.position) {
              selected = current;
              WidgetsBinding.instance.addPostFrameCallback((_) => map.move(current.position, 16));
            }
            return Column(children: [
              Container(color: const Color(0xffffd54f), padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), child: Row(children: [const Icon(Icons.verified_user, size: 18), const SizedBox(width: 8), Expanded(child: Text('${widget.role.toUpperCase()} • ${widget.user.email}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800)))])),
              const PhilippineClock(),
              SizedBox(
                height: 270,
                child: FlutterMap(
                  mapController: map,
                  options: MapOptions(initialCenter: current?.position ?? const LatLng(7.1907, 124.5300), initialZoom: current == null ? 11 : 16),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.rescuelink.dispatch'),
                    MarkerLayer(markers: incidents.map((i) => Marker(point: i.position, width: 54, height: 54, child: GestureDetector(onTap: () { setState(() => selected = i); map.move(i.position, 16); }, child: Container(decoration: BoxDecoration(color: const Color(0xffd71920), shape: BoxShape.circle, border: Border.all(color: i.live ? const Color(0xffffd54f) : Colors.white, width: 4), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 8)]), child: Icon(i.live ? Icons.gps_fixed : Icons.location_on, color: Colors.white))))).toList()),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Row(children: [
                  Expanded(child: SegmentedButton<bool>(segments: [ButtonSegment(value: false, icon: const Icon(Icons.warning_amber), label: Text('Active (${all.where((i) => !{'resolved', 'cancelled'}.contains(i.status)).length})')), ButtonSegment(value: true, icon: const Icon(Icons.history), label: const Text('History'))], selected: {history}, onSelectionChanged: (value) => setState(() { history = value.first; selected = null; }))),
                ]),
              ),
              Expanded(child: incidents.isEmpty ? const Center(child: Text('No incident records')) : ListView.builder(
                padding: const EdgeInsets.all(10), itemCount: incidents.length, itemBuilder: (context, index) {
                  final i = incidents[index];
                  return Card(child: ListTile(
                    leading: CircleAvatar(backgroundColor: const Color(0xffa40e18), foregroundColor: Colors.white, child: Icon(i.live ? Icons.gps_fixed : Icons.emergency)),
                    title: Text('${i.type.toUpperCase()} • ${i.status.toUpperCase()}', style: const TextStyle(fontWeight: FontWeight.w900)),
                    subtitle: Text('${i.description.isEmpty ? 'Emergency assistance requested' : i.description}\n${time(i.createdAt)}', maxLines: 3),
                    isThreeLine: true, trailing: const Icon(Icons.chevron_right), onTap: () { setState(() => selected = i); map.move(i.position, 16); },
                  ));
                },
              )),
            ]);
          },
        ),
        bottomSheet: selected == null ? null : SafeArea(
          child: Container(
            width: double.infinity, padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            decoration: const BoxDecoration(color: Colors.white, borderRadius: BorderRadius.vertical(top: Radius.circular(20)), boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20)]),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Expanded(child: Text('${selected!.type.toUpperCase()} INCIDENT', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xff8d0b13)))), IconButton(onPressed: () => setState(() => selected = null), icon: const Icon(Icons.close))]),
              Text(selected!.description.isEmpty ? 'Emergency assistance requested' : selected!.description),
              const SizedBox(height: 8),
              Text('Reporter: ${selected!.reporter}'),
              Text('GPS: ${selected!.position.latitude.toStringAsFixed(5)}, ${selected!.position.longitude.toStringAsFixed(5)}'),
              Text('Updated: ${time(selected!.gpsAt)} • ${selected!.speed.round()} km/h • ${selected!.heading.round()}°'),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(onPressed: () => launchUrl(Uri.parse('https://www.google.com/maps/search/?api=1&query=${selected!.position.latitude},${selected!.position.longitude}'), mode: LaunchMode.externalApplication), icon: const Icon(Icons.navigation), label: const Text('Navigate')),
                if (selected!.phone != null && selected!.phone!.isNotEmpty) OutlinedButton.icon(onPressed: () => launchUrl(Uri(scheme: 'tel', path: selected!.phone)), icon: const Icon(Icons.call), label: const Text('Call reporter')),
                if (!{'resolved', 'cancelled'}.contains(selected!.status)) ...[
                  OutlinedButton(onPressed: busy == null ? () => setStatus(selected!, 'acknowledged') : null, child: const Text('Acknowledge')),
                  FilledButton(onPressed: busy == null ? () => setStatus(selected!, 'dispatched') : null, child: const Text('Dispatch')),
                  FilledButton.tonal(onPressed: busy == null ? () => setStatus(selected!, 'resolved') : null, child: const Text('Close incident')),
                ],
              ]),
            ]),
          ),
        ),
      );
}

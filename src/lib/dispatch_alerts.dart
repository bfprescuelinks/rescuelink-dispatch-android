import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

import 'firebase_options.dart';

final dispatchNotifications = FlutterLocalNotificationsPlugin();

Future<void> initializeDispatchAlerts() async {
  if (!Platform.isAndroid) return;
  FlutterForegroundTask.initCommunicationPort();
  await dispatchNotifications.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  ));
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'dispatch_monitor_v1',
      channelName: 'Dispatch monitoring',
      channelDescription: 'Shows when the incident monitor is running.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: true,
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
}

Future<void> requestDispatchPermissions() async {
  if (!Platform.isAndroid) return;
  if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
    await FlutterForegroundTask.requestNotificationPermission();
  }
}

Future<void> requestDispatchDndAccess() async {
  if (!Platform.isAndroid) return;
  await dispatchNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationPolicyAccess();
  await createDispatchAlertChannel();
}

Future<void> createDispatchAlertChannel() async {
  if (!Platform.isAndroid) return;
  final plugin = dispatchNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
  final bypass = await plugin?.hasNotificationPolicyAccess() ?? false;
  await plugin?.createNotificationChannel(AndroidNotificationChannel(
    bypass ? 'dispatch_incidents_dnd_v3' : 'dispatch_incidents_v3',
    'Emergency incidents',
    description: 'New RescueLink incidents needing dispatch.',
    importance: Importance.max,
    playSound: false,
    enableVibration: true,
    vibrationPattern: Int64List.fromList([0, 700, 300, 700, 300, 700]),
    bypassDnd: bypass,
  ));
}

Future<void> startDispatchMonitor() async {
  if (!Platform.isAndroid) return;
  await requestDispatchPermissions();
  if (await FlutterForegroundTask.isRunningService) return;
  await FlutterForegroundTask.startService(
    serviceId: 4511,
    notificationTitle: 'RescueLink Dispatch is monitoring',
    notificationText: 'Listening for new emergency incidents',
    callback: dispatchMonitorCallback,
  );
}

Future<void> stopDispatchMonitor() async {
  if (Platform.isAndroid && await FlutterForegroundTask.isRunningService) {
    await FlutterForegroundTask.stopService();
  }
}

@pragma('vm:entry-point')
void dispatchMonitorCallback() {
  DartPluginRegistrant.ensureInitialized();
  FlutterForegroundTask.setTaskHandler(DispatchMonitorHandler());
}

class DispatchMonitorHandler extends TaskHandler {
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _subscription;
  StreamSubscription<User?>? _authSubscription;
  bool _ready = false;
  final Set<String> _seen = {};

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await dispatchNotifications.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ));
    await createDispatchAlertChannel();
    _authSubscription = FirebaseAuth.instance.authStateChanges().listen((user) async {
      await _subscription?.cancel();
      _subscription = null;
      _ready = false;
      _seen.clear();
      if (user == null) return;
      final role = (await FirebaseFirestore.instance.collection('users').doc(user.uid).get()).data()?['role'];
      if (!{'dispatcher', 'responder', 'admin'}.contains(role)) return;
      _subscription = FirebaseFirestore.instance.collection('incidents')
          .orderBy('createdAt', descending: true).limit(100).snapshots().listen((snapshot) async {
        if (!_ready) {
          _seen.addAll(snapshot.docs.map((doc) => doc.id));
          _ready = true;
          return;
        }
        for (final change in snapshot.docChanges) {
          if (change.type != DocumentChangeType.added || !_seen.add(change.doc.id)) continue;
          final data = change.doc.data();
          if (data == null || {'resolved', 'cancelled'}.contains(data['status'])) continue;
          final type = '${data['type'] ?? 'Emergency'}'.toUpperCase();
          final bypass = await dispatchNotifications.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.hasNotificationPolicyAccess() ?? false;
          await createDispatchAlertChannel();
          await dispatchNotifications.show(
            change.doc.id.hashCode & 0x7fffffff,
            'NEW $type INCIDENT',
            '${data['description'] ?? 'Emergency assistance requested'}',
            NotificationDetails(android: AndroidNotificationDetails(
              bypass ? 'dispatch_incidents_dnd_v3' : 'dispatch_incidents_v3', 'Emergency incidents',
              channelDescription: 'New RescueLink incidents needing dispatch.',
              importance: Importance.max, priority: Priority.max,
              category: AndroidNotificationCategory.alarm,
              channelBypassDnd: bypass, enableVibration: true, playSound: false,
            )),
          );
          // Alarm audio uses the alarm stream, which can sound in silent mode.
          // Android and device DND settings still decide whether it is allowed.
          await FlutterRingtonePlayer().play(android: AndroidSounds.alarm, asAlarm: true, looping: false);
          Timer(const Duration(seconds: 8), () => FlutterRingtonePlayer().stop());
        }
      });
    });
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    await _subscription?.cancel();
    await _authSubscription?.cancel();
  }
}

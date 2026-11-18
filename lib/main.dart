import 'services/step_counter_service.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const SmartHealthSport());
}

const Color navy = Color(0xFF101D35);
const Color background = Color(0xFF0B1426);
const Color cardColor = Color(0xFF172641);
const Color blue = Color(0xFF42A5F5);
const Color muted = Color(0xFF9BAAC1);

const String targetName = 'SMART_HEALTH_ESP32';
const String serviceUuid =
    '12345678-1234-1234-1234-1234567890ab';
const String characteristicUuid =
    'abcdefab-1234-1234-1234-abcdefabcdef';

class SmartHealthSport extends StatelessWidget {
  const SmartHealthSport({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SMART HEALTH SPORT',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: blue,
          brightness: Brightness.dark,
        ),
        fontFamily: 'Roboto',
      ),
      home: const MainDashboard(),
    );
  }
}

class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  int selectedIndex = 0;
  bool english = false;
  final TextEditingController chatController =
    TextEditingController();

final List<Map<String, String>> chatMessages = [];

bool aiLoading = false;
  final StepCounterService stepCounterService = StepCounterService();

  int stepCount = 0;
  int? stepBaseline;
  bool stepCounterActive = false;
  String stepCounterMessage = 'Tekan tombol untuk mulai menghitung langkah.';

  bool scanning = false;
  bool connected = false;
  bool connecting = false;

  String status = 'Belum terhubung';
  String bpm = '--';
  String spo2 = '--';
  String temperature = '--';

  BluetoothDevice? espDevice;
  BluetoothCharacteristic? dataCharacteristic;

  StreamSubscription<List<ScanResult>>? scanSubscription;
  StreamSubscription<List<int>>? dataSubscription;
  StreamSubscription<BluetoothConnectionState>? connectionSubscription;

  final List<ScanResult> scanResults = [];

  // Maps: lokasi hanya diambil saat pengguna menekan tombol.
  final MapController mapController = MapController();
  Position? currentPosition;
  bool locating = false;
  String locationMessage = 'Tekan tombol lokasi untuk menemukan posisi Anda.';

  // GPS activity tracking
  final MapController activityMapController = MapController();
  String selectedActivityType = 'Running';
  bool activityRunning = false;
  bool activityPaused = false;
  bool activityStarting = false;
  String activityMessage = 'Pilih aktivitas lalu tekan Mulai.';
  StreamSubscription<Position>? trackingSubscription;
  Timer? activityTimer;
  DateTime? activeSegmentStartedAt;
  Duration elapsedBeforeCurrentSegment = Duration.zero;
  Duration activityElapsed = Duration.zero;
  double activityDistanceMeters = 0;
  Position? lastTrackedPosition;
  final List<LatLng> routePoints = [];
  final List<Map<String, dynamic>> completedActivities = [];
  final List<Map<String, dynamic>> measurementHistory = [];
  DateTime? lastMeasurementSavedAt;

  @override
  void initState() {
    super.initState();
    _loadHistoryData();
  }

  Future<void> _loadHistoryData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final activityJson = prefs.getString('completed_activities_v1');
      final measurementJson = prefs.getString('measurement_history_v1');

      final loadedActivities = <Map<String, dynamic>>[];
      if (activityJson != null) {
        final decoded = jsonDecode(activityJson) as List<dynamic>;
        for (final value in decoded) {
          final item = Map<String, dynamic>.from(value as Map);
          final route = (item['route'] as List<dynamic>? ?? [])
              .map((point) => LatLng(
                    (point['lat'] as num).toDouble(),
                    (point['lng'] as num).toDouble(),
                  ))
              .toList();
          loadedActivities.add({
            'type': item['type'] ?? 'Activity',
            'distance': (item['distance'] as num?)?.toDouble() ?? 0.0,
            'duration': Duration(seconds: (item['durationSeconds'] as num?)?.toInt() ?? 0),
            'averageSpeed': (item['averageSpeed'] as num?)?.toDouble() ?? 0.0,
            'date': DateTime.tryParse(item['date']?.toString() ?? '') ?? DateTime.now(),
            'route': route,
          });
        }
      }

      final loadedMeasurements = <Map<String, dynamic>>[];
      if (measurementJson != null) {
        final decoded = jsonDecode(measurementJson) as List<dynamic>;
        for (final value in decoded) {
          loadedMeasurements.add(Map<String, dynamic>.from(value as Map));
        }
      }

      if (!mounted) return;
      setState(() {
        completedActivities
          ..clear()
          ..addAll(loadedActivities);
        measurementHistory
          ..clear()
          ..addAll(loadedMeasurements);
        if (measurementHistory.isNotEmpty) {
          lastMeasurementSavedAt = DateTime.tryParse(
            measurementHistory.first['date']?.toString() ?? '',
          );
        }
      });
    } catch (e) {
      debugPrint('Gagal memuat riwayat: $e');
    }
  }

  Future<void> _persistHistoryData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final activitiesToSave = completedActivities.map((item) {
        final route = (item['route'] as List<LatLng>? ?? []);
        return {
          'type': item['type'],
          'distance': item['distance'],
          'durationSeconds': (item['duration'] as Duration).inSeconds,
          'averageSpeed': item['averageSpeed'],
          'date': (item['date'] as DateTime).toIso8601String(),
          'route': route.map((point) => {
            'lat': point.latitude,
            'lng': point.longitude,
          }).toList(),
        };
      }).toList();
      await prefs.setString('completed_activities_v1', jsonEncode(activitiesToSave));
      await prefs.setString('measurement_history_v1', jsonEncode(measurementHistory));
    } catch (e) {
      debugPrint('Gagal menyimpan riwayat: $e');
    }
  }

  Future<void> _maybeSaveMeasurement() async {
    final now = DateTime.now();
    if (lastMeasurementSavedAt != null &&
        now.difference(lastMeasurementSavedAt!) < const Duration(minutes: 1)) {
      return;
    }
    if (bpm == '--' && spo2 == '--' && temperature == '--') return;

    final record = <String, dynamic>{
      'bpm': bpm,
      'spo2': spo2,
      'temperature': temperature,
      'date': now.toIso8601String(),
    };
    measurementHistory.insert(0, record);
    if (measurementHistory.length > 500) {
      measurementHistory.removeRange(500, measurementHistory.length);
    }
    lastMeasurementSavedAt = now;
    await _persistHistoryData();
    if (mounted) setState(() {});
  }

  String t(String indonesia, String englishText) {
    return english ? englishText : indonesia;
  }

  Future<bool> requestBlePermissions() async {
    final scanPermission = await Permission.bluetoothScan.request();
    final connectPermission = await Permission.bluetoothConnect.request();

    return scanPermission.isGranted && connectPermission.isGranted;
  }

  Future<void> scanDevices() async {
    try {
      final permissionGranted = await requestBlePermissions();

      if (!permissionGranted) {
        setState(() {
          status = 'Izin Bluetooth belum diberikan';
        });
        return;
      }

      final adapterState = await FlutterBluePlus.adapterState.first;

      if (adapterState != BluetoothAdapterState.on) {
        setState(() {
          status = 'Aktifkan Bluetooth HP';
        });
        return;
      }

      await FlutterBluePlus.stopScan();

      setState(() {
        scanning = true;
        scanResults.clear();
        status = 'Mencari ESP32...';
      });

      await scanSubscription?.cancel();

      scanSubscription = FlutterBluePlus.onScanResults.listen(
        (results) {
          if (!mounted) return;

          for (final result in results) {
            final name = result.advertisementData.advName.isNotEmpty
                ? result.advertisementData.advName
                : result.device.platformName;

            if (name == targetName &&
                !scanResults.any(
                  (item) => item.device.remoteId == result.device.remoteId,
                )) {
              setState(() {
                scanResults.add(result);
                status = 'ESP32 ditemukan';
              });
            }
          }
        },
        onError: (error) {
          if (!mounted) return;
          setState(() {
            status = 'Scan gagal: $error';
            scanning = false;
          });
        },
      );

      await FlutterBluePlus.startScan(
        withNames: [targetName],
        timeout: const Duration(seconds: 12),
      );

      if (!mounted) return;

      setState(() {
        scanning = false;
        if (scanResults.isEmpty) {
          status = 'ESP32 tidak ditemukan';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        scanning = false;
        status = 'Kesalahan scan: $e';
      });
    }
  }

  Future<void> connectDevice(BluetoothDevice device) async {
    try {
      setState(() {
        connecting = true;
        status = 'Menghubungkan...';
      });

      await FlutterBluePlus.stopScan();

      await device.connect(
  timeout: const Duration(seconds: 15),
  license: License.nonprofit,
);

      espDevice = device;

      connectionSubscription?.cancel();
      connectionSubscription = device.connectionState.listen((state) {
        if (!mounted) return;

        if (state == BluetoothConnectionState.disconnected) {
          setState(() {
            connected = false;
            connecting = false;
            status = 'Terputus dari ESP32';
            dataCharacteristic = null;
          });
        }
      });

      final services = await device.discoverServices();

      BluetoothCharacteristic? foundCharacteristic;

      for (final service in services) {
        if (service.uuid.toString().toLowerCase() ==
            serviceUuid.toLowerCase()) {
          for (final characteristic in service.characteristics) {
            if (characteristic.uuid.toString().toLowerCase() ==
                characteristicUuid.toLowerCase()) {
              foundCharacteristic = characteristic;
              break;
            }
          }
        }
      }

      if (foundCharacteristic == null) {
        throw Exception('Service atau characteristic tidak ditemukan');
      }

      dataCharacteristic = foundCharacteristic;

      await dataSubscription?.cancel();

      dataSubscription = foundCharacteristic.onValueReceived.listen(
        (value) {
          receiveSensorData(value);
        },
        onError: (error) {
          if (!mounted) return;
          setState(() {
            status = 'Gagal membaca data: $error';
          });
        },
      );

      await foundCharacteristic.setNotifyValue(true);

      if (!mounted) return;

      setState(() {
        connected = true;
        connecting = false;
        status = 'Terhubung ke ESP32';
      });
    } catch (e) {
      await dataSubscription?.cancel();
      dataSubscription = null;

      if (mounted) {
        setState(() {
          connected = false;
          connecting = false;
          status = 'Koneksi gagal: $e';
        });
      }

      try {
        await device.disconnect();
      } catch (_) {}
    }
  }

  void receiveSensorData(List<int> value) {
    try {
      final text = utf8.decode(value);
      final Map<String, dynamic> data = jsonDecode(text);

      if (!mounted) return;

      setState(() {
        bpm = data['bpmValid'] == true && data['bpm'] != null
            ? data['bpm'].toString()
            : '--';

        spo2 = data['spo2Valid'] == true && data['spo2'] != null
            ? data['spo2'].toString()
            : '--';

        temperature =
            data['temperatureValid'] == true &&
                    data['temperature'] != null
                ? (data['temperature'] as num).toStringAsFixed(1)
                : '--';
      });
      _maybeSaveMeasurement();
    } catch (e) {
      debugPrint('Data BLE tidak valid: $e');
    }
  }

  Future<void> disconnectDevice() async {
    try {
      await dataSubscription?.cancel();
      dataSubscription = null;

      await espDevice?.disconnect();

      if (!mounted) return;

      setState(() {
        connected = false;
        connecting = false;
        status = 'Belum terhubung';
        bpm = '--';
        spo2 = '--';
        temperature = '--';
        dataCharacteristic = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        status = 'Gagal memutuskan koneksi: $e';
      });
    }
  }

  Future<bool> ensureLocationPermission() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        activityMessage = t('Aktifkan GPS/lokasi ponsel terlebih dahulu.',
            'Turn on phone location services first.');
      });
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() {
        activityMessage = t('Izin lokasi diperlukan untuk merekam rute.',
            'Location permission is required to record a route.');
      });
      return false;
    }
    return true;
  }

  LocationSettings get trackingLocationSettings => const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 5,
      );

  Future<void> startActivity() async {
    if (activityStarting || activityRunning) return;
    setState(() {
      activityStarting = true;
      activityMessage = t('Menyiapkan GPS...', 'Preparing GPS...');
    });
    try {
      final permitted = await ensureLocationPermission();
      if (!permitted) return;

      final firstPosition = await Geolocator.getCurrentPosition(
        locationSettings: trackingLocationSettings,
      );
      if (!mounted) return;

      setState(() {
        routePoints.clear();
        routePoints.add(LatLng(firstPosition.latitude, firstPosition.longitude));
        currentPosition = firstPosition;
        lastTrackedPosition = firstPosition;
        activityDistanceMeters = 0;
        elapsedBeforeCurrentSegment = Duration.zero;
        activityElapsed = Duration.zero;
        activityRunning = true;
        activityPaused = false;
        activeSegmentStartedAt = DateTime.now();
        activityMessage = t('Aktivitas sedang direkam.', 'Activity is recording.');
      });
      activityMapController.move(
        LatLng(firstPosition.latitude, firstPosition.longitude), 16,
      );
      _startActivityTimer();
      _listenToActivityLocation();
    } catch (e) {
      if (mounted) {
        setState(() {
          activityMessage = t('Tidak dapat memulai GPS: $e', 'Could not start GPS: $e');
        });
      }
    } finally {
      if (mounted) setState(() => activityStarting = false);
    }
  }

  void _startActivityTimer() {
    activityTimer?.cancel();
    activityTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || activeSegmentStartedAt == null || activityPaused) return;
      setState(() {
        activityElapsed = elapsedBeforeCurrentSegment +
            DateTime.now().difference(activeSegmentStartedAt!);
      });
    });
  }

  void _listenToActivityLocation() {
    trackingSubscription?.cancel();
    trackingSubscription = Geolocator.getPositionStream(
      locationSettings: trackingLocationSettings,
    ).listen((position) {
      if (!mounted || activityPaused || !activityRunning) return;
      // Abaikan titik GPS dengan akurasi sangat rendah agar jarak tidak melonjak.
      if (position.accuracy > 50) return;

      final previous = lastTrackedPosition;
      if (previous != null) {
        final segment = Geolocator.distanceBetween(
          previous.latitude,
          previous.longitude,
          position.latitude,
          position.longitude,
        );
        // Filter perpindahan GPS yang tidak masuk akal dalam satu pembaruan.
        if (segment > 0 && segment < 500) {
          activityDistanceMeters += segment;
        } else if (segment >= 500) {
          return;
        }
      }

      final point = LatLng(position.latitude, position.longitude);
      setState(() {
        currentPosition = position;
        lastTrackedPosition = position;
        if (routePoints.isEmpty || routePoints.last != point) {
          routePoints.add(point);
        }
      });
      activityMapController.move(point, 16);
    }, onError: (error) {
      if (mounted) setState(() => activityMessage = 'GPS: $error');
    });
  }

  Future<void> pauseActivity() async {
    if (!activityRunning || activityPaused) return;
    if (activeSegmentStartedAt != null) {
      elapsedBeforeCurrentSegment +=
          DateTime.now().difference(activeSegmentStartedAt!);
    }
    activityTimer?.cancel();
    activityTimer = null;
    await trackingSubscription?.cancel();
    trackingSubscription = null;
    if (!mounted) return;
    setState(() {
      activityPaused = true;
      activityElapsed = elapsedBeforeCurrentSegment;
      activeSegmentStartedAt = null;
      activityMessage = t('Aktivitas dijeda.', 'Activity paused.');
    });
  }

  void resumeActivity() {
    if (!activityRunning || !activityPaused) return;
    setState(() {
      activityPaused = false;
      activeSegmentStartedAt = DateTime.now();
      activityMessage = t('Aktivitas dilanjutkan.', 'Activity resumed.');
    });
    _startActivityTimer();
    _listenToActivityLocation();
  }

  Future<void> stopActivity() async {
    if (!activityRunning) return;
    if (!activityPaused && activeSegmentStartedAt != null) {
      elapsedBeforeCurrentSegment +=
          DateTime.now().difference(activeSegmentStartedAt!);
    }
    activityTimer?.cancel();
    activityTimer = null;
    await trackingSubscription?.cancel();
    trackingSubscription = null;

    final duration = elapsedBeforeCurrentSegment;
    final distance = activityDistanceMeters;
    final averageSpeed = duration.inSeconds > 0
        ? (distance / duration.inSeconds) * 3.6
        : 0.0;

    if (!mounted) return;
    setState(() {
      completedActivities.insert(0, {
        'type': selectedActivityType,
        'distance': distance,
        'duration': duration,
        'averageSpeed': averageSpeed,
        'date': DateTime.now(),
        'route': List<LatLng>.from(routePoints),
      });
      activityRunning = false;
      activityPaused = false;
      activeSegmentStartedAt = null;
      activityElapsed = duration;
      elapsedBeforeCurrentSegment = Duration.zero;
      lastTrackedPosition = null;
      activityMessage = t('Aktivitas selesai. Riwayat berhasil disimpan.',
          'Activity finished. History saved.');
    });
    await _persistHistoryData();
  }

  String formatActivityDuration(Duration duration) {
    final hours = duration.inHours.toString().padLeft(2, '0');
    final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return '$hours:$minutes:$seconds';
  }

  double get activityAverageSpeedKmh => activityElapsed.inSeconds > 0
      ? (activityDistanceMeters / activityElapsed.inSeconds) * 3.6
      : 0;

    Future<void> startStepCounter() async {
    setState(() {
      stepCount = 0;
      stepBaseline = null;
      stepCounterMessage = 'Mengaktifkan sensor langkah...';
    });

    await stepCounterService.start(
      onStepCount: (steps) {
        if (!mounted) return;

        setState(() {
          stepBaseline ??= steps;
          stepCount = steps >= stepBaseline!
              ? steps - stepBaseline!
              : 0;
          stepCounterActive = true;
          stepCounterMessage = 'Sensor langkah aktif.';
        });
      },
      onError: (error) {
        if (!mounted) return;

        setState(() {
          stepCounterActive = false;
          stepCounterMessage = error;
        });
      },
    );
  }

  Future<void> stopStepCounter() async {
    await stepCounterService.stop();

    if (!mounted) return;

    setState(() {
      stepCounterActive = false;
      stepCounterMessage = 'Penghitung langkah dihentikan.';
    });
  }

  @override
  void dispose() {
    activityTimer?.cancel();
    trackingSubscription?.cancel();
    scanSubscription?.cancel();
    dataSubscription?.cancel();
    connectionSubscription?.cancel();
    FlutterBluePlus.stopScan();

    stepCounterService.dispose();

    chatController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      homePage(),
      activityPage(),
      mapPage(),
      historyPage(),
      devicePage(),
      aiAssistantPage(),
    ];

    return Scaffold(
      appBar: AppBar(
        backgroundColor: background,
        titleSpacing: 20,
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'SMART HEALTH',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            Text(
              'SPORT',
              style: TextStyle(
                color: blue,
                fontSize: 11,
                letterSpacing: 3,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => setState(() => english = !english),
            child: Text(
              english ? 'EN | ID' : 'ID | EN',
              style: const TextStyle(
                color: blue,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(child: pages[selectedIndex]),
      bottomNavigationBar: NavigationBar(
        backgroundColor: navy,
        indicatorColor: blue.withValues(alpha: 0.2),
        selectedIndex: selectedIndex,
        onDestinationSelected: (index) {
          setState(() => selectedIndex = index);
        },
        destinations: [
  NavigationDestination(
    icon: const Icon(Icons.dashboard_outlined),
    selectedIcon: const Icon(Icons.dashboard),
    label: t('Beranda', 'Home'),
  ),
  NavigationDestination(
    icon: const Icon(Icons.directions_run_outlined),
    selectedIcon: const Icon(Icons.directions_run),
    label: t('Aktivitas', 'Activity'),
  ),
  NavigationDestination(
    icon: const Icon(Icons.map_outlined),
    selectedIcon: const Icon(Icons.map),
    label: t('Maps', 'Maps'),
  ),
  NavigationDestination(
    icon: const Icon(Icons.history),
    label: t('Riwayat', 'History'),
  ),
  NavigationDestination(
    icon: const Icon(Icons.bluetooth),
    label: t('Perangkat', 'Device'),
  ),
  NavigationDestination(
    icon: const Icon(Icons.smart_toy_outlined),
    selectedIcon: const Icon(Icons.smart_toy),
    label: t('AI Assistant', 'AI Assistant'),
  ),
],
      ),
    );
  }

  Widget homePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('Selamat datang!', 'Welcome!'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 25,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t(
              'Pantau kesehatan dan aktivitasmu.',
              'Monitor your health and activity.',
            ),
            style: const TextStyle(color: muted),
          ),
          const SizedBox(height: 22),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF174A80), Color(0xFF17305A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.health_and_safety,
                  size: 43,
                  color: Colors.white,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t('Ringkasan kesehatan', 'Health overview'),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        connected
                            ? t('ESP32 sudah terhubung.',
                                'ESP32 is connected.')
                            : t('Hubungkan perangkat untuk mulai mengukur.',
                                'Connect your device to start measuring.'),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 25),
          sectionTitle(t('Kesehatan', 'Health')),
          const SizedBox(height: 13),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.35,
            children: [
              metricCard(
                t('Detak Jantung', 'Heart Rate'),
                bpm,
                'BPM',
                Icons.favorite,
                Colors.redAccent,
              ),
              metricCard(
                'SpO₂',
                spo2,
                '%',
                Icons.air,
                Colors.lightBlueAccent,
              ),
              metricCard(
                t('Suhu Objek', 'Object Temperature'),
                temperature,
                '°C',
                Icons.thermostat,
                Colors.orangeAccent,
              ),
              metricCard(
                t('Langkah', 'Steps'),
                '0',
                t('langkah', 'steps'),
                Icons.directions_walk,
                Colors.greenAccent,
              ),
            ],
          ),
          const SizedBox(height: 25),
          sectionTitle(t('Aktivitas Hari Ini', "Today's Activity")),
          const SizedBox(height: 13),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                activityRow(Icons.route, t('Jarak', 'Distance'), '0.00 km'),
                const Divider(color: Colors.white12, height: 25),
                activityRow(
                    Icons.timer_outlined, t('Durasi', 'Duration'), '00:00'),
                const Divider(color: Colors.white12, height: 25),
                activityRow(
                  Icons.directions_run,
                  t('Jenis aktivitas', 'Activity type'),
                  t('Belum dimulai', 'Not started'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Center(
            child: Text(
              connected
                  ? t('Data sensor diterima melalui BLE',
                      'Sensor data received through BLE')
                  : t('Hubungkan ESP32 untuk menerima data sensor',
                      'Connect ESP32 to receive sensor data'),
              style: const TextStyle(color: muted, fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

void sendChatMessage() {
  final message = chatController.text.trim();

  if (message.isEmpty || aiLoading) return;

  setState(() {
    chatMessages.add({
      'role': 'user',
      'message': message,
    });

    chatController.clear();
    aiLoading = true;
  });

  Future.delayed(const Duration(milliseconds: 600), () {
    if (!mounted) return;

    final answer = getAiResponse(message);

    setState(() {
      chatMessages.add({
        'role': 'ai',
        'message': answer,
      });

      aiLoading = false;
    });
  });
}
String getAiResponse(String message) {
  final question = message.toLowerCase();

  if (question.contains('bpm') ||
      question.contains('jantung') ||
      question.contains('heart')) {
    return t(
      'BPM adalah jumlah denyut jantung per menit. Nilainya dapat berubah karena aktivitas, kondisi tubuh, dan faktor lainnya. Perhatikan pola pengukuran, bukan hanya satu angka.',
      'BPM means the number of heartbeats per minute. It can change with activity and other factors. Pay attention to measurement patterns, not just one reading.',
    );
  }

  if (question.contains('spo2') ||
      question.contains('oksigen') ||
      question.contains('oxygen')) {
    return t(
      'SpO₂ adalah perkiraan tingkat saturasi oksigen dalam darah. Sensor ini memberikan estimasi, bukan hasil pemeriksaan medis. Jika merasa tidak sehat atau khawatir dengan hasilnya, mintalah bantuan tenaga kesehatan.',
      'SpO₂ is an estimate of blood oxygen saturation. This sensor provides an estimate, not a medical test. If you feel unwell or are concerned about a reading, seek advice from a healthcare professional.',
    );
  }

  if (question.contains('suhu') ||
      question.contains('temperature') ||
      question.contains('demam')) {
    return t(
      'Sensor MLX90614 mengukur suhu permukaan objek. Hasilnya bukan pengukuran suhu inti tubuh, sehingga tidak dapat digunakan sendiri untuk memastikan demam.',
      'The MLX90614 measures an object’s surface temperature. It does not measure core body temperature and cannot independently confirm a fever.',
    );
  }

  if (question.contains('olahraga') ||
      question.contains('kebugaran') ||
      question.contains('fitness') ||
      question.contains('exercise')) {
    return t(
      'Untuk menjaga kebugaran, lakukan aktivitas fisik yang sesuai kemampuan, tingkatkan aktivitas secara bertahap, cukup istirahat, dan jaga asupan air.',
      'To maintain fitness, choose activities suited to your ability, increase activity gradually, get enough rest, and stay hydrated.',
    );
  }

  return t(
    'Terima kasih atas pertanyaan Anda. Saat ini saya masih dalam tahap prototipe dan dapat menjawab pertanyaan dasar tentang BPM, SpO₂, suhu, serta kebugaran.',
    'Thank you for your question. I am currently a prototype and can answer basic questions about BPM, SpO₂, temperature, and fitness.',
  );
}
    Widget aiAssistantPage() {
  return SingleChildScrollView(
    padding: const EdgeInsets.all(20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'AI Health Assistant',
          style: TextStyle(
            color: Colors.white,
            fontSize: 25,
            fontWeight: FontWeight.bold,
          ),
        ),

        const SizedBox(height: 8),

        Text(
          t(
            'Asisten kesehatan pintar SMART HEALTH SPORT.',
            'Your SMART HEALTH SPORT intelligent health assistant.',
          ),
          style: const TextStyle(color: muted),
        ),

        const SizedBox(height: 20),

        // CHAT HEADER
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.smart_toy,
                color: blue,
                size: 42,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AI Health Assistant',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      t(
                        'Siap membantu menjawab pertanyaan Anda',
                        'Ready to help answer your questions',
                      ),
                      style: const TextStyle(
                        color: muted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.circle,
                color: Colors.greenAccent,
                size: 10,
              ),
            ],
          ),
        ),

        const SizedBox(height: 20),

        // CHAT MESSAGES
        if (chatMessages.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Text(
              t(
                'Halo! Silakan tanyakan sesuatu tentang BPM, SpO₂, suhu, atau aktivitas olahraga Anda.',
                'Hello! Ask me something about BPM, SpO₂, temperature, or your exercise activity.',
              ),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
              ),
            ),
          ),

        ...chatMessages.map((chat) {
          final isUser = chat['role'] == 'user';

          return Align(
            alignment: isUser
                ? Alignment.centerRight
                : Alignment.centerLeft,
            child: Container(
              constraints: const BoxConstraints(
                maxWidth: 300,
              ),
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isUser ? blue : cardColor,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Text(
                chat['message'] ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                ),
              ),
            ),
          );
        }),

        if (aiLoading)
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cardColor,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: blue,
                ),
              ),
            ),
          ),

        const SizedBox(height: 12),

        // INPUT CHAT
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 5,
          ),
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: chatController,
                  style: const TextStyle(
                    color: Colors.white,
                  ),
                  decoration: InputDecoration(
                    hintText: t(
                      'Tulis pertanyaan...',
                      'Type a question...',
                    ),
                    hintStyle: const TextStyle(
                      color: muted,
                    ),
                    border: InputBorder.none,
                  ),
                  onSubmitted: (_) => sendChatMessage(),
                ),
              ),

              IconButton(
                onPressed: aiLoading ? null : sendChatMessage,
                icon: const Icon(
                  Icons.send_rounded,
                  color: blue,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),

        Text(
          t(
            'Catatan: Respons saat ini merupakan prototipe berbasis aturan, bukan diagnosis medis atau AI online.',
            'Note: Responses are currently rule-based prototypes, not medical diagnoses or a live AI service.',
          ),
          style: const TextStyle(
            color: muted,
            fontSize: 11,
          ),
        ),
      ],
    ),
  );
}
  Future<void> locateMe() async {
    if (locating) return;

    setState(() {
      locating = true;
      locationMessage = t('Sedang mencari lokasi...', 'Finding your location...');
    });

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() {
          locationMessage = t(
            'Aktifkan layanan lokasi/GPS di ponsel.',
            'Turn on location services/GPS on your phone.',
          );
        });
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        setState(() {
          locationMessage = t(
            'Izin lokasi belum diberikan. Periksa pengaturan aplikasi.',
            'Location permission was not granted. Check app settings.',
          );
        });
        return;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (!mounted) return;

      setState(() {
        currentPosition = position;
        locationMessage = t(
          'Lokasi berhasil ditemukan.',
          'Location found successfully.',
        );
      });

      mapController.move(
        LatLng(position.latitude, position.longitude),
        16,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        locationMessage = t(
          'Gagal mendapatkan lokasi: $e',
          'Could not get location: $e',
        );
      });
    } finally {
      if (mounted) {
        setState(() {
          locating = false;
        });
      }
    }
  }

  Widget mapPage() {
    final userPoint = currentPosition == null
        ? null
        : LatLng(
            currentPosition!.latitude,
            currentPosition!.longitude,
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('Peta & Lokasi', 'Map & Location'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                locationMessage,
                style: const TextStyle(color: muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: locating ? null : locateMe,
                  icon: locating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.my_location),
                  label: Text(
                    locating
                        ? t('Mencari lokasi...', 'Finding location...')
                        : t('Temukan Lokasi Saya', 'Find My Location'),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: userPoint ?? const LatLng(-2.5, 118.0),
              initialZoom: userPoint == null ? 4.5 : 15,
              minZoom: 2,
              maxZoom: 18,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.smarthealth.smart_health_sport',
              ),
              if (routePoints.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePoints,
                      strokeWidth: 5,
                      color: blue,
                    ),
                  ],
                ),
              if (userPoint != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: userPoint,
                      width: 52,
                      height: 52,
                      child: const Icon(
                        Icons.location_pin,
                        color: Colors.redAccent,
                        size: 46,
                      ),
                    ),
                  ],
                ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution('© OpenStreetMap contributors'),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget activityPage() {
    final activityOptions = <String, IconData>{
      'Running': Icons.directions_run,
      'Walking': Icons.directions_walk,
      'Cycling': Icons.directions_bike,
      'Driving': Icons.directions_car,
    };
    final center = currentPosition == null
        ? const LatLng(-2.5, 118.0)
        : LatLng(currentPosition!.latitude, currentPosition!.longitude);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('Pelacakan Aktivitas', 'Activity Tracking'),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            t('Rekam rute dan statistik aktivitas menggunakan GPS.',
                'Record routes and activity statistics using GPS.'),
            style: const TextStyle(color: muted),
          ),
          const SizedBox(height: 16),
          Container(
  width: double.infinity,
  padding: const EdgeInsets.all(16),
  decoration: BoxDecoration(
    color: cardColor,
    borderRadius: BorderRadius.circular(18),
  ),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.directions_walk, color: blue, size: 28),
          const SizedBox(width: 10),
          Text(
            t('Penghitung Langkah', 'Step Counter'),
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
      const SizedBox(height: 12),
      Text(
        '$stepCount',
        style: const TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.bold,
        ),
      ),
      Text(
        t('langkah sesi', 'session steps'),
        style: const TextStyle(color: muted),
      ),
      const SizedBox(height: 8),
      Text(
        stepCounterMessage,
        style: const TextStyle(color: muted, fontSize: 12),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: stepCounterActive
              ? stopStepCounter
              : startStepCounter,
          icon: Icon(
            stepCounterActive ? Icons.stop : Icons.play_arrow,
          ),
          label: Text(
            stepCounterActive
                ? t('Hentikan Penghitung', 'Stop Counter')
                : t('Mulai Menghitung Langkah', 'Start Step Counter'),
          ),
        ),
      ),
    ],
  ),
),
const SizedBox(height: 18),
          sectionTitle(t('Pilih aktivitas', 'Choose activity')),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: activityOptions.entries.map((entry) {
              final selected = selectedActivityType == entry.key;
              return ChoiceChip(
                selected: selected,
                avatar: Icon(entry.value, size: 18,
                    color: selected ? Colors.white : blue),
                label: Text(entry.key),
                onSelected: activityRunning || activityStarting
                    ? null
                    : (_) => setState(() => selectedActivityType = entry.key),
              );
            }).toList(),
          ),
          if (selectedActivityType == 'Driving') ...[
            const SizedBox(height: 10),
            infoCard(
              t('Keselamatan perjalanan', 'Trip safety'),
              t('Jangan mengoperasikan aplikasi saat mengemudi. Mulai atau hentikan rekaman hanya ketika kendaraan berhenti atau minta penumpang mengoperasikannya.',
                  'Do not operate the app while driving. Start or stop tracking only when the vehicle is stopped, or have a passenger operate it.'),
              Icons.safety_check,
            ),
          ],
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: SizedBox(
              height: 240,
              child: FlutterMap(
                mapController: activityMapController,
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: currentPosition == null ? 4.5 : 15,
                  minZoom: 2,
                  maxZoom: 18,
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.smarthealth.smart_health_sport',
                  ),
                  if (routePoints.length > 1)
                    PolylineLayer(
                      polylines: [
                        Polyline(points: routePoints, strokeWidth: 5, color: blue),
                      ],
                    ),
                  if (currentPosition != null)
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: center,
                          width: 42,
                          height: 42,
                          child: const Icon(Icons.location_pin,
                              color: Colors.redAccent, size: 38),
                        ),
                      ],
                    ),
                  RichAttributionWidget(
                    attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(activityMessage,
              style: const TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _activityStatCard(
                  t('Jarak', 'Distance'),
                  (activityDistanceMeters / 1000).toStringAsFixed(2),
                  'km',
                  Icons.route,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _activityStatCard(
                  t('Durasi', 'Duration'),
                  formatActivityDuration(activityElapsed),
                  '',
                  Icons.timer_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _activityStatCard(
            t('Kecepatan rata-rata', 'Average speed'),
            activityAverageSpeedKmh.toStringAsFixed(1),
            'km/jam',
            Icons.speed,
          ),
          const SizedBox(height: 16),
          if (!activityRunning)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: activityStarting ? null : startActivity,
                icon: activityStarting
                    ? const SizedBox(width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_arrow),
                label: Text(activityStarting
                    ? t('Menyiapkan...', 'Preparing...')
                    : t('Mulai Aktivitas', 'Start Activity')),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: activityPaused ? resumeActivity : pauseActivity,
                    icon: Icon(activityPaused ? Icons.play_arrow : Icons.pause),
                    label: Text(activityPaused
                        ? t('Lanjutkan', 'Resume')
                        : t('Jeda', 'Pause')),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: stopActivity,
                    icon: const Icon(Icons.stop),
                    label: Text(t('Selesai', 'Stop')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (completedActivities.isNotEmpty) ...[
            const SizedBox(height: 24),
            sectionTitle(t('Aktivitas terakhir', 'Recent activity')),
            const SizedBox(height: 10),
            ...completedActivities.take(5).map((item) {
              final duration = item['duration'] as Duration;
              final distance = item['distance'] as double;
              return Card(
                color: cardColor,
                child: ListTile(
                  leading: Icon(activityOptions[item['type']] ?? Icons.route,
                      color: blue),
                  title: Text(item['type'] as String),
                  subtitle: Text(
                    '${(distance / 1000).toStringAsFixed(2)} km • ${formatActivityDuration(duration)}',
                  ),
                  trailing: Text('${(item['averageSpeed'] as double).toStringAsFixed(1)} km/jam'),
                ),
              );
            }),
          ],
          const SizedBox(height: 16),
          Text(
            t('Catatan: GPS dapat kurang akurat di dalam ruangan atau area dengan gedung tinggi. Data jarak dan kecepatan adalah perkiraan.',
                'Note: GPS may be less accurate indoors or around tall buildings. Distance and speed are estimates.'),
            style: const TextStyle(color: muted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _activityStatCard(String title, String value, String unit, IconData icon) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(icon, color: blue, size: 24),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: muted, fontSize: 11)),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(value, style: const TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                    ),
                    if (unit.isNotEmpty) ...[
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(unit, style: const TextStyle(color: muted, fontSize: 10)),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget historyPage() {
    String formatDate(dynamic value) {
      final date = value is DateTime
          ? value
          : DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now();
      return '${date.day.toString().padLeft(2, '0')}/'
          '${date.month.toString().padLeft(2, '0')}/${date.year} '
          '${date.hour.toString().padLeft(2, '0')}:'
          '${date.minute.toString().padLeft(2, '0')}';
    }

    final activityOptions = <String, IconData>{
      'Running': Icons.directions_run,
      'Walking': Icons.directions_walk,
      'Cycling': Icons.directions_bike,
      'Driving': Icons.directions_car,
    };

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Text(
          t('Riwayat', 'History'),
          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 6),
        Text(
          t('Catatan aktivitas dan pengukuran kesehatan tersimpan di perangkat ini.',
              'Activity and health measurement records saved on this device.'),
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 22),
        sectionTitle(t('Riwayat Aktivitas', 'Activity History')),
        const SizedBox(height: 10),
        if (completedActivities.isEmpty)
          infoCard(
            t('Belum ada aktivitas', 'No activities yet'),
            t('Aktivitas yang selesai akan muncul di sini.',
                'Completed activities will appear here.'),
            Icons.directions_run,
          )
        else
          ...completedActivities.map((item) {
            final duration = item['duration'] as Duration;
            final distance = item['distance'] as double;
            final route = item['route'] as List<LatLng>? ?? [];
            return Card(
              color: cardColor,
              margin: const EdgeInsets.only(bottom: 10),
              child: ExpansionTile(
                leading: Icon(activityOptions[item['type']] ?? Icons.route, color: blue),
                title: Text(item['type'] as String,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(
                  '${(distance / 1000).toStringAsFixed(2)} km • '
                  '${formatActivityDuration(duration)}\n${formatDate(item['date'])}',
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${t('Kecepatan rata-rata', 'Average speed')}: '
                            '${(item['averageSpeed'] as double).toStringAsFixed(1)} km/jam'),
                        const SizedBox(height: 8),
                        Text('${t('Titik rute tersimpan', 'Route points saved')}: ${route.length}'),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }),
        const SizedBox(height: 18),
        sectionTitle(t('Riwayat Pengukuran Kesehatan', 'Health Measurement History')),
        const SizedBox(height: 10),
        if (measurementHistory.isEmpty)
          infoCard(
            t('Belum ada pengukuran tersimpan', 'No saved measurements'),
            t('Saat ESP32 terhubung dan data valid diterima, aplikasi menyimpan satu catatan setiap menit.',
                'When ESP32 is connected and valid data is received, the app saves one record per minute.'),
            Icons.monitor_heart_outlined,
          )
        else
          ...measurementHistory.map((item) {
            return Card(
              color: cardColor,
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(formatDate(item['date']),
                        style: const TextStyle(color: muted, fontSize: 11)),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: _historyMetric('BPM', '${item['bpm']}', Icons.favorite)),
                        Expanded(child: _historyMetric('SpO₂', '${item['spo2']}%', Icons.bloodtype)),
                        Expanded(child: _historyMetric(t('Suhu', 'Temp'), '${item['temperature']}°C', Icons.thermostat)),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: completedActivities.isEmpty && measurementHistory.isEmpty
              ? null
              : () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: Text(t('Hapus semua riwayat?', 'Delete all history?')),
                      content: Text(t('Catatan aktivitas dan pengukuran akan dihapus dari perangkat ini.',
                          'Activity and measurement records will be deleted from this device.')),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, false),
                          child: Text(t('Batal', 'Cancel')),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext, true),
                          child: Text(t('Hapus', 'Delete')),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    setState(() {
                      completedActivities.clear();
                      measurementHistory.clear();
                      lastMeasurementSavedAt = null;
                    });
                    final prefs = await SharedPreferences.getInstance();
                    await prefs.remove('completed_activities_v1');
                    await prefs.remove('measurement_history_v1');
                  }
                },
          icon: const Icon(Icons.delete_outline),
          label: Text(t('Hapus Semua Riwayat', 'Clear All History')),
        ),
      ],
    );
  }

  Widget _historyMetric(String label, String value, IconData icon) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: blue, size: 18),
        const SizedBox(height: 5),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        Text(label, style: const TextStyle(color: muted, fontSize: 10)),
      ],
    );
  }

  Widget devicePage() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t('Perangkat Saya', 'My Device'),
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 18),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              children: [
                Icon(
                  connected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_searching,
                  color: blue,
                  size: 55,
                ),
                const SizedBox(height: 12),
                const Text(
                  'ESP32 Smart Health Monitor',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: muted),
                ),
                const SizedBox(height: 12),
                Chip(
                  avatar: Icon(
                    Icons.circle,
                    color: connected ? Colors.greenAccent : Colors.orangeAccent,
                    size: 10,
                  ),
                  label: Text(
                    connected ? 'BLE • Connected' : 'BLE • Disconnected',
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: scanning || connecting || connected
                        ? null
                        : scanDevices,
                    icon: scanning
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: Text(
                      scanning
                          ? t('Memindai...', 'Scanning...')
                          : t('Scan ESP32', 'Scan ESP32'),
                    ),
                  ),
                ),
                if (connected) ...[
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: disconnectDevice,
                      icon: const Icon(Icons.bluetooth_disabled),
                      label: Text(t('Putuskan koneksi', 'Disconnect')),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
          if (scanResults.isNotEmpty) ...[
            sectionTitle(t('Perangkat ditemukan', 'Devices found')),
            const SizedBox(height: 10),
            ...scanResults.map((result) {
              return Card(
                color: cardColor,
                child: ListTile(
                  leading: const Icon(Icons.bluetooth, color: blue),
                  title: Text(
                    result.advertisementData.advName.isNotEmpty
                        ? result.advertisementData.advName
                        : result.device.platformName,
                  ),
                  subtitle: Text(result.device.remoteId.toString()),
                  trailing: connecting
                      ? const CircularProgressIndicator()
                      : const Icon(Icons.arrow_forward_ios, size: 16),
                  onTap: connected || connecting
                      ? null
                      : () => connectDevice(result.device),
                ),
              );
            }),
          ],
          const SizedBox(height: 20),
          sectionTitle(t('Data Sensor', 'Sensor Data')),
          const SizedBox(height: 12),
          metricCard(
            t('Detak Jantung', 'Heart Rate'),
            bpm,
            'BPM',
            Icons.favorite,
            Colors.redAccent,
          ),
          const SizedBox(height: 10),
          metricCard(
            'SpO₂',
            spo2,
            '%',
            Icons.air,
            Colors.lightBlueAccent,
          ),
          const SizedBox(height: 10),
          metricCard(
            t('Suhu Objek', 'Object Temperature'),
            temperature,
            '°C',
            Icons.thermostat,
            Colors.orangeAccent,
          ),
        ],
      ),
    );
  }

  Widget sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget metricCard(
    String title,
    String value,
    String unit,
    IconData icon,
    Color iconColor,
  ) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, color: iconColor, size: 20),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(color: muted, fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: const TextStyle(
                  fontSize: 27,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 5),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  unit,
                  style: const TextStyle(color: muted, fontSize: 10),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget activityRow(IconData icon, String title, String value) {
    return Row(
      children: [
        Icon(icon, color: blue, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Text(title, style: const TextStyle(color: muted)),
        ),
        Text(
          value,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  Widget infoCard(String title, String description, IconData icon) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        children: [
          Icon(icon, size: 42, color: blue),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: const TextStyle(color: muted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

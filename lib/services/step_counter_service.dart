import 'dart:async';
import 'package:pedometer/pedometer.dart';
import 'package:permission_handler/permission_handler.dart';

class StepCounterService {
  StreamSubscription<StepCount>? _stepSubscription;

  Future<bool> requestPermission() async {
    final status = await Permission.activityRecognition.request();

    return status.isGranted;
  }

  Future<void> start({
    required Function(int steps) onStepCount,
    required Function(String error) onError,
  }) async {
    final granted = await requestPermission();

    if (!granted) {
      onError('Izin aktivitas fisik belum diberikan');
      return;
    }

    await stop();

    _stepSubscription = Pedometer.stepCountStream.listen(
      (StepCount event) {
        onStepCount(event.steps);
      },
      onError: (error) {
        onError('Sensor langkah tidak tersedia: $error');
      },
    );
  }

  Future<void> stop() async {
    await _stepSubscription?.cancel();
    _stepSubscription = null;
  }

  Future<void> dispose() async {
    await stop();
  }
}
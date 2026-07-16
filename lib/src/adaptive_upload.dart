import 'dart:math';

import 'errors.dart';

enum UploadNetworkType { wifi, cellular, unknown }

enum UploadNetworkSpeed { slow, standard, fast, unknown }

enum UploadDeviceMemory { low, standard, high }

class UploadConditions {
  const UploadConditions({
    this.networkType = UploadNetworkType.unknown,
    this.networkSpeed = UploadNetworkSpeed.unknown,
    this.deviceMemory = UploadDeviceMemory.standard,
  });

  final UploadNetworkType networkType;
  final UploadNetworkSpeed networkSpeed;
  final UploadDeviceMemory deviceMemory;
}

class AdaptiveUploadPreset {
  const AdaptiveUploadPreset({
    required this.name,
    required this.partSizeBytes,
    required this.maxConcurrency,
    required this.maxPartAttempts,
    required this.partTimeout,
  });

  final String name;
  final int partSizeBytes;
  final int maxConcurrency;
  final int maxPartAttempts;
  final Duration partTimeout;
}

abstract final class AdaptiveUploadPolicy {
  static AdaptiveUploadPreset select(
    int sizeBytes,
    UploadConditions conditions,
  ) {
    if (sizeBytes < 0) {
      throw const ValidationException('size_bytes must not be negative');
    }
    final tier = switch (sizeBytes) {
      < 100 * _mib => 'small',
      < _gib => 'medium',
      < 8 * _gib => 'large',
      _ => 'huge',
    };
    final profile = switch (conditions) {
      UploadConditions(deviceMemory: UploadDeviceMemory.low) => 'conservative',
      UploadConditions(
        networkType: UploadNetworkType.cellular,
        networkSpeed: UploadNetworkSpeed.slow,
      ) =>
        'conservative',
      UploadConditions(networkType: UploadNetworkType.cellular) => 'cellular',
      UploadConditions(
        networkType: UploadNetworkType.wifi,
        networkSpeed: UploadNetworkSpeed.slow,
      ) =>
        'conservative',
      UploadConditions(
        networkType: UploadNetworkType.wifi,
        networkSpeed: UploadNetworkSpeed.fast,
        deviceMemory: UploadDeviceMemory.high,
      ) =>
        'fast',
      UploadConditions(networkType: UploadNetworkType.wifi) => 'balanced',
      _ => 'conservative',
    };
    final values = _presets[tier]![profile]!;
    final partSize = max(values[0] * _mib, _minPartSize(sizeBytes));
    return AdaptiveUploadPreset(
      name: '${tier}_$profile',
      partSizeBytes: partSize,
      maxConcurrency: values[1],
      maxPartAttempts: values[2],
      partTimeout: Duration(seconds: values[3]),
    );
  }

  static int _minPartSize(int sizeBytes) {
    if (sizeBytes <= 0) return 5 * _mib;
    final bytes = 1 + (sizeBytes - 1) ~/ 10000;
    return max(5 * _mib, (bytes + _mib - 1) ~/ _mib * _mib);
  }

  static const int _mib = 1024 * 1024;
  static const int _gib = 1024 * _mib;

  static const Map<String, Map<String, List<int>>> _presets =
      <String, Map<String, List<int>>>{
        'small': <String, List<int>>{
          'conservative': <int>[5, 1, 6, 360],
          'cellular': <int>[8, 2, 5, 300],
          'balanced': <int>[16, 3, 4, 240],
          'fast': <int>[32, 4, 3, 180],
        },
        'medium': <String, List<int>>{
          'conservative': <int>[8, 1, 6, 480],
          'cellular': <int>[16, 2, 5, 360],
          'balanced': <int>[32, 3, 4, 300],
          'fast': <int>[64, 4, 3, 240],
        },
        'large': <String, List<int>>{
          'conservative': <int>[16, 1, 7, 720],
          'cellular': <int>[32, 2, 6, 600],
          'balanced': <int>[64, 3, 5, 480],
          'fast': <int>[128, 4, 4, 360],
        },
        'huge': <String, List<int>>{
          'conservative': <int>[32, 1, 8, 900],
          'cellular': <int>[64, 2, 7, 720],
          'balanced': <int>[128, 3, 6, 600],
          'fast': <int>[256, 4, 5, 480],
        },
      };
}

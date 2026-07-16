import 'package:flutter_test/flutter_test.dart';
import 'package:vmodal_sdk_flutter/vmodal_sdk_flutter.dart';

void main() {
  test('Android adaptive preset vectors match exactly', () {
    const mib = 1024 * 1024;
    const gib = 1024 * mib;
    final vectors = <(int, UploadConditions, String, int, int, int, int)>[
      (
        10 * mib,
        const UploadConditions(deviceMemory: UploadDeviceMemory.low),
        'small_conservative',
        5 * mib,
        1,
        6,
        360,
      ),
      (
        100 * mib,
        const UploadConditions(
          networkType: UploadNetworkType.cellular,
          networkSpeed: UploadNetworkSpeed.standard,
        ),
        'medium_cellular',
        16 * mib,
        2,
        5,
        360,
      ),
      (
        gib,
        const UploadConditions(
          networkType: UploadNetworkType.wifi,
          networkSpeed: UploadNetworkSpeed.standard,
        ),
        'large_balanced',
        64 * mib,
        3,
        5,
        480,
      ),
      (
        8 * gib,
        const UploadConditions(
          networkType: UploadNetworkType.wifi,
          networkSpeed: UploadNetworkSpeed.fast,
          deviceMemory: UploadDeviceMemory.high,
        ),
        'huge_fast',
        256 * mib,
        4,
        5,
        480,
      ),
    ];
    for (final vector in vectors) {
      final preset = AdaptiveUploadPolicy.select(vector.$1, vector.$2);
      expect(preset.name, vector.$3);
      expect(preset.partSizeBytes, vector.$4);
      expect(preset.maxConcurrency, vector.$5);
      expect(preset.maxPartAttempts, vector.$6);
      expect(preset.partTimeout.inSeconds, vector.$7);
    }
  });

  test('10,000 part ceiling raises minimum part size', () {
    const mib = 1024 * 1024;
    final preset = AdaptiveUploadPolicy.select(
      10001 * 5 * mib,
      const UploadConditions(),
    );
    expect(
      (10001 * 5 * mib + preset.partSizeBytes - 1) ~/ preset.partSizeBytes,
      lessThanOrEqualTo(10000),
    );
  });

  test('adaptive settings do nothing when multipart is false', () {
    const options = VideoUploadOptions(
      adaptiveConditions: UploadConditions(
        networkType: UploadNetworkType.wifi,
        networkSpeed: UploadNetworkSpeed.fast,
        deviceMemory: UploadDeviceMemory.high,
      ),
    );
    expect(identical(options.resolvedFor(10 * 1024 * 1024), options), isTrue);
  });
}

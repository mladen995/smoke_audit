// test/test_helpers.dart
import 'package:smoke_audit/models/breath_log.dart';
import 'package:smoke_audit/models/user_profile.dart';

UserProfile makeProfile({
  String id = 'p1',
  String name = 'Alex',
  DateTime? quitDate,
  int? cigarettesPerDay = 10,
  int? yearsSmoked = 20,
  double? pricePerPack = 8.5,
}) {
  return UserProfile(
    id: id,
    displayName: name,
    dateOfBirth: DateTime(1985, 6, 15),
    sex: BiologicalSex.female,
    heightCm: 170,
    useImperial: false,
    smokingStatus: SmokingStatus.quit,
    quitDate: quitDate ?? DateTime.utc(2026, 10, 1),
    createdAt: DateTime.utc(2026, 10, 1),
    cigarettesPerDay: cigarettesPerDay,
    yearsSmoked: yearsSmoked,
    pricePerPack: pricePerPack,
  );
}

BreathLog makeLog({
  required String id,
  required DateTime at,
  String profileId = 'p1',
  String kind = LogKind.acousticTest,
  TestContext context = TestContext.standardBaseline,
  double seconds = 0,
  bool isManual = false,
  double? lat,
  double? lng,
}) {
  return BreathLog(
    id: id,
    profileId: profileId,
    kind: kind,
    context: context,
    timestamp: at,
    duration: Duration(milliseconds: (seconds * 1000).round()),
    isManual: isManual,
    latitude: lat,
    longitude: lng,
  );
}

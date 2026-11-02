// lib/models/user_profile.dart

enum BiologicalSex { male, female, unspecified }

enum SmokingStatus {
  /// Already quit (quitDate is in the past / today).
  quit,

  /// Plans to quit on quitDate (in the future). Streak shows 0 until then.
  planningToQuit,
}

class UserProfile {
  /// Minimum age allowed during onboarding.
  static const int minAge = 18;

  final String id;
  final String displayName;
  final DateTime dateOfBirth;
  final BiologicalSex sex;

  /// Height is stored in centimeters; imperial is only a display preference.
  final double heightCm;
  final bool useImperial;

  final SmokingStatus smokingStatus;
  final DateTime quitDate;

  // Optional smoking history
  final int? cigarettesPerDay;
  final int? yearsSmoked;
  final double? pricePerPack;

  final DateTime createdAt;

  const UserProfile({
    required this.id,
    required this.displayName,
    required this.dateOfBirth,
    required this.sex,
    required this.heightCm,
    required this.useImperial,
    required this.smokingStatus,
    required this.quitDate,
    required this.createdAt,
    this.cigarettesPerDay,
    this.yearsSmoked,
    this.pricePerPack,
  });

  int get ageYears {
    final now = DateTime.now();
    int age = now.year - dateOfBirth.year;
    if (now.month < dateOfBirth.month ||
        (now.month == dateOfBirth.month && now.day < dateOfBirth.day)) {
      age--;
    }
    return age;
  }

  double get heightInches => heightCm / 2.54;

  double? get packYears {
    if (cigarettesPerDay == null || yearsSmoked == null) return null;
    return (cigarettesPerDay! / 20.0) * yearsSmoked!;
  }

  UserProfile withQuitDate(DateTime newQuitDate, {SmokingStatus? status}) {
    return UserProfile(
      id: id,
      displayName: displayName,
      dateOfBirth: dateOfBirth,
      sex: sex,
      heightCm: heightCm,
      useImperial: useImperial,
      smokingStatus: status ?? smokingStatus,
      quitDate: newQuitDate,
      createdAt: createdAt,
      cigarettesPerDay: cigarettesPerDay,
      yearsSmoked: yearsSmoked,
      pricePerPack: pricePerPack,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'dateOfBirth': dateOfBirth.toIso8601String(),
        'sex': sex.name,
        'heightCm': heightCm,
        'useImperial': useImperial,
        'smokingStatus': smokingStatus.name,
        'quitDate': quitDate.toIso8601String(),
        'cigarettesPerDay': cigarettesPerDay,
        'yearsSmoked': yearsSmoked,
        'pricePerPack': pricePerPack,
        'createdAt': createdAt.toIso8601String(),
      };

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['id'] as String,
      displayName: (json['displayName'] as String?) ?? '',
      dateOfBirth: DateTime.parse(json['dateOfBirth'] as String),
      sex: BiologicalSex.values.firstWhere(
        (e) => e.name == json['sex'],
        orElse: () => BiologicalSex.unspecified,
      ),
      heightCm: (json['heightCm'] as num?)?.toDouble() ?? 170.0,
      useImperial: (json['useImperial'] as bool?) ?? true,
      smokingStatus: SmokingStatus.values.firstWhere(
        (e) => e.name == json['smokingStatus'],
        orElse: () => SmokingStatus.quit,
      ),
      quitDate: DateTime.parse(json['quitDate'] as String),
      cigarettesPerDay: (json['cigarettesPerDay'] as num?)?.toInt(),
      yearsSmoked: (json['yearsSmoked'] as num?)?.toInt(),
      pricePerPack: (json['pricePerPack'] as num?)?.toDouble(),
      createdAt: DateTime.tryParse((json['createdAt'] as String?) ?? '') ?? DateTime.now(),
    );
  }
}
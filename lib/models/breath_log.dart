class BreathLog {
  final DateTime timestamp;
  final double score;
  final int estimatedLungAge;

  BreathLog({required this.timestamp, required this.score, required this.estimatedLungAge});

  Map toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'score': score,
    'estimatedLungAge': estimatedLungAge,
  };

  factory BreathLog.fromJson(Map json) => BreathLog(
    timestamp: DateTime.parse(json['timestamp']),
    score: json['score'],
    estimatedLungAge: json['estimatedLungAge'],
  );
}
import 'package:flutter/material.dart';

enum MilestoneCategory { acute, respiratory, cardiovascular, longTerm }

class MedicalMilestone {
  final String title;
  final String subtitle;
  final Duration targetDuration;
  final String clinicalSource;
  final IconData icon;
  final MilestoneCategory category;

  MedicalMilestone({
    required this.title,
    required this.subtitle,
    required this.targetDuration,
    required this.clinicalSource,
    required this.icon,
    required this.category,
  });
}

/// Timeline of general-population health benefits of staying smoke-free.
/// Wording follows the American Cancer Society / CDC "benefits of quitting
/// over time" timelines. These are population-level statistics and individual
/// results vary. Review against current ACS/CDC pages before each release.
class MedicalMilestonesData {
  static final List<MedicalMilestone> milestones = [
    MedicalMilestone(
      title: "Heart Rate & Blood Pressure Drop",
      subtitle: "Your heart rate and blood pressure begin to drop toward normal.",
      targetDuration: const Duration(minutes: 20),
      clinicalSource: "American Cancer Society / CDC",
      icon: Icons.favorite_rounded,
      category: MilestoneCategory.acute,
    ),
    MedicalMilestone(
      title: "Carbon Monoxide Back to Normal",
      subtitle: "The carbon monoxide level in your blood drops to normal.",
      targetDuration: const Duration(hours: 12),
      clinicalSource: "American Cancer Society / CDC",
      icon: Icons.air_rounded,
      category: MilestoneCategory.acute,
    ),
    MedicalMilestone(
      title: "Circulation Improves",
      subtitle: "From about 2 weeks to 3 months, circulation improves and lung function begins to increase.",
      targetDuration: const Duration(days: 14),
      clinicalSource: "American Cancer Society",
      icon: Icons.bloodtype_rounded,
      category: MilestoneCategory.respiratory,
    ),
    MedicalMilestone(
      title: "Lungs Begin Clearing Out",
      subtitle: "From about 1 month, cilia start to regain normal function, helping the lungs clear mucus and fight infection.",
      targetDuration: const Duration(days: 30),
      clinicalSource: "American Cancer Society",
      icon: Icons.cleaning_services_rounded,
      category: MilestoneCategory.respiratory,
    ),
    MedicalMilestone(
      title: "Lung Function Gains",
      subtitle: "By around 3 months, the period of improving lung function and circulation is well underway.",
      targetDuration: const Duration(days: 90),
      clinicalSource: "American Cancer Society",
      icon: Icons.speed_rounded,
      category: MilestoneCategory.respiratory,
    ),
    MedicalMilestone(
      title: "Less Coughing & Breathlessness",
      subtitle: "Between 1 and 9 months, coughing and shortness of breath decrease.",
      targetDuration: const Duration(days: 270),
      clinicalSource: "American Cancer Society / CDC",
      icon: Icons.health_and_safety_rounded,
      category: MilestoneCategory.respiratory,
    ),
    MedicalMilestone(
      title: "Heart Disease Risk Cut in Half",
      subtitle: "Your added risk of coronary heart disease is about half that of a person who still smokes.",
      targetDuration: const Duration(days: 365),
      clinicalSource: "American Cancer Society / CDC",
      icon: Icons.monitor_heart_rounded,
      category: MilestoneCategory.cardiovascular,
    ),
    MedicalMilestone(
      title: "Stroke & Cancer Risks Falling",
      subtitle: "Stroke risk keeps dropping (it may reach a non-smoker's level 2–15 years after quitting, depending on the source), "
          "and risk of mouth, throat and esophagus cancers is about halved.",
      targetDuration: const Duration(days: 1825),
      clinicalSource: "American Cancer Society / CDC",
      icon: Icons.shield_rounded,
      category: MilestoneCategory.cardiovascular,
    ),
    MedicalMilestone(
      title: "Lung Cancer Death Risk Halved",
      subtitle: "Your risk of dying from lung cancer is about half that of a person who is still smoking.",
      targetDuration: const Duration(days: 3650),
      clinicalSource: "American Cancer Society / CDC",
      icon: Icons.verified_user_rounded,
      category: MilestoneCategory.longTerm,
    ),
    MedicalMilestone(
      title: "Heart Disease Risk Near Non-Smoker",
      subtitle: "Your risk of coronary heart disease is close to that of someone who has never smoked.",
      targetDuration: const Duration(days: 5475),
      clinicalSource: "American Cancer Society / CDC",
      icon: Icons.emoji_events_rounded,
      category: MilestoneCategory.longTerm,
    ),
  ];
}
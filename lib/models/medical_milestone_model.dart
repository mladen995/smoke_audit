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

class MedicalMilestonesData {
  static final List<MedicalMilestone> milestones = [
    MedicalMilestone(
      title: "Pulse & Blood Pressure Normalization",
      subtitle: "Heart rate and blood pressure drop back to baseline levels.",
      targetDuration: const Duration(minutes: 20),
      clinicalSource: "American Heart Association (AHA)",
      icon: Icons.favorite_rounded,
      category: MilestoneCategory.acute,
    ),
    MedicalMilestone(
      title: "Carbon Monoxide Cleared",
      subtitle: "Blood oxygen levels increase to normal; CO drops to non-smoker levels.",
      targetDuration: const Duration(hours: 12),
      clinicalSource: "CDC / Surgeon General",
      icon: Icons.air_rounded,
      category: MilestoneCategory.acute,
    ),
    MedicalMilestone(
      title: "Nerve Regeneration Begins",
      subtitle: "Damaged nerve endings start regrowing; taste and smell sharpen.",
      targetDuration: const Duration(hours: 48),
      clinicalSource: "WHO Respiratory Guidelines",
      icon: Icons.restaurant_rounded,
      category: MilestoneCategory.acute,
    ),
    MedicalMilestone(
      title: "Bronchial Relaxation",
      subtitle: "Breathing becomes easier as bronchial tubes relax and energy levels rise.",
      targetDuration: const Duration(hours: 72),
      clinicalSource: "American Lung Association",
      icon: Icons.sentiment_satisfied_alt_rounded,
      category: MilestoneCategory.respiratory,
    ),
    MedicalMilestone(
      title: "Ciliary Regeneration",
      subtitle: "Cilia regrow in lungs, actively clearing mucus and reducing infection risk.",
      targetDuration: const Duration(days: 30),
      clinicalSource: "CDC / WHO",
      icon: Icons.cleaning_services_rounded,
      category: MilestoneCategory.respiratory,
    ),
    MedicalMilestone(
      title: "+10% Lung Capacity Increase",
      subtitle: "Circulation improves significantly; overall lung capacity jumps up to 10%.",
      targetDuration: const Duration(days: 90), // 3 months
      clinicalSource: "American Heart Association",
      icon: Icons.speed_rounded,
      category: MilestoneCategory.respiratory,
    ),
    MedicalMilestone(
      title: "Airway Inflammation Cleared",
      subtitle: "Coughing and shortness of breath decrease dramatically as deep inflammation heals.",
      targetDuration: const Duration(days: 270), // 9 months
      clinicalSource: "CDC",
      icon: Icons.health_and_safety_rounded,
      category: MilestoneCategory.respiratory,
    ),
    MedicalMilestone(
      title: "50% Reduced Heart Attack Risk",
      subtitle: "Excess risk of coronary heart disease is halved compared to a continuing smoker.",
      targetDuration: const Duration(days: 365), // 1 year
      clinicalSource: "WHO / AHA",
      icon: Icons.monitor_heart_rounded,
      category: MilestoneCategory.cardiovascular,
    ),
    MedicalMilestone(
      title: "Stroke Risk Normalized",
      subtitle: "Arterial walls heal. Stroke risk drops to that of a non-smoker.",
      targetDuration: const Duration(days: 1825), // 5 years
      clinicalSource: "CDC",
      icon: Icons.shield_rounded,
      category: MilestoneCategory.cardiovascular,
    ),
    MedicalMilestone(
      title: "50% Reduced Lung Cancer Risk",
      subtitle: "Pre-cancerous cells are replaced by healthy tissue; lung cancer death risk halves.",
      targetDuration: const Duration(days: 3650), // 10 years
      clinicalSource: "American Cancer Society",
      icon: Icons.verified_user_rounded,
      category: MilestoneCategory.longTerm,
    ),
    MedicalMilestone(
      title: "Complete Cardiovascular Parity",
      subtitle: "Risk of coronary heart disease is identical to someone who never smoked.",
      targetDuration: const Duration(days: 5475), // 15 years
      clinicalSource: "World Health Organization",
      icon: Icons.emoji_events_rounded,
      category: MilestoneCategory.longTerm,
    ),
  ];
}
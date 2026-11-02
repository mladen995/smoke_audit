// lib/widgets/milestone_progress_card.dart
import 'package:flutter/material.dart';

import '../models/medical_milestone_model.dart';

class MilestoneProgressCard extends StatefulWidget {
  final DateTime quitTimestamp;

  const MilestoneProgressCard({super.key, required this.quitTimestamp});

  @override
  State<MilestoneProgressCard> createState() => _MilestoneProgressCardState();
}

class _MilestoneProgressCardState extends State<MilestoneProgressCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final Duration elapsed = DateTime.now().difference(widget.quitTimestamp);
    final allMilestones = MedicalMilestonesData.milestones;

    // Active milestone = first one not yet completed
    int activeIndex = allMilestones.indexWhere((m) => elapsed < m.targetDuration);
    if (activeIndex == -1) activeIndex = allMilestones.length - 1;

    final activeMilestone = allMilestones[activeIndex];

    double progress = 1.0;
    if (elapsed < activeMilestone.targetDuration) {
      final double previousTargetMs = activeIndex > 0
          ? allMilestones[activeIndex - 1].targetDuration.inMilliseconds.toDouble()
          : 0.0;
      final double currentTargetMs = activeMilestone.targetDuration.inMilliseconds.toDouble();
      final double currentElapsedMs = elapsed.inMilliseconds.toDouble();
      final double span = currentTargetMs - previousTargetMs;

      progress = span <= 0
          ? 1.0
          : ((currentElapsedMs - previousTargetMs) / span).clamp(0.0, 1.0);
    }

    final int percentInt = (progress * 100).toInt();
    final DateTime targetDate = widget.quitTimestamp.add(activeMilestone.targetDuration);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 3),
          )
        ],
        border: Border.all(color: Colors.teal.shade100),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.teal.shade50,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(activeMilestone.icon, color: Colors.teal.shade800, size: 20),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "NEXT CLINICAL MILESTONE",
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.teal.shade700,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                                Text(
                                  activeMilestone.title,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black87,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "$percentInt%",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.teal.shade800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: Colors.teal.shade50,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.teal.shade600),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  activeMilestone.subtitle,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.3),
                ),
                const SizedBox(height: 6),
                Text(
                  "General population data — individual results vary. Relapses reset your streak, not your progress in life.",
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        "Source: ${activeMilestone.clinicalSource}",
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: Colors.grey.shade500),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      "Target: ${_formatDate(targetDate)}",
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.teal.shade900),
                    ),
                  ],
                ),
              ],
            ),
          ),
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: _isExpanded
                    ? BorderRadius.zero
                    : const BorderRadius.vertical(bottom: Radius.circular(16)),
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _isExpanded
                        ? "Hide Full Clinical Timeline"
                        : "View Full Medical Roadmap (${allMilestones.length} Phases)",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.teal.shade800),
                  ),
                  Icon(
                    _isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: Colors.teal.shade800,
                    size: 18,
                  ),
                ],
              ),
            ),
          ),
          if (_isExpanded)
            ClipRRect(
              borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: allMilestones.length,
                separatorBuilder: (context, index) => Divider(height: 1, color: Colors.grey.shade200),
                itemBuilder: (context, index) {
                  final item = allMilestones[index];
                  final bool isPassed = elapsed >= item.targetDuration;
                  final bool isCurrent = index == activeIndex && !isPassed;

                  return ListTile(
                    dense: true,
                    leading: Icon(
                      isPassed
                          ? Icons.check_circle_rounded
                          : (isCurrent ? Icons.play_circle_fill_rounded : Icons.radio_button_unchecked_rounded),
                      color: isPassed
                          ? Colors.teal.shade600
                          : (isCurrent ? Colors.amber.shade700 : Colors.grey.shade400),
                      size: 20,
                    ),
                    title: Text(
                      item.title,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isPassed || isCurrent ? Colors.black87 : Colors.grey.shade500,
                        decoration: isPassed ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    subtitle: Text("${item.clinicalSource} • ${_formatDuration(item.targetDuration)}"),
                    trailing: isPassed
                        ? Icon(Icons.verified_rounded, size: 16, color: Colors.teal.shade400)
                        : null,
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return "${date.month}/${date.day}/${date.year}";
  }

  String _formatDuration(Duration d) {
    if (d.inDays >= 365) {
      return "${(d.inDays / 365).round()} yr";
    } else if (d.inDays >= 30) {
      return "${(d.inDays / 30).round()} mo";
    } else if (d.inDays >= 1) {
      return "${d.inDays} days";
    } else if (d.inHours >= 1) {
      return "${d.inHours} hrs";
    } else {
      // FIX: the 20-minute milestone previously displayed as "0 hrs".
      return "${d.inMinutes} min";
    }
  }
}
import '../models/medical_milestone_model.dart';

import 'package:flutter/material.dart';

class MilestoneProgressCard extends StatefulWidget {
  final DateTime quitTimestamp;

  const MilestoneProgressCard({Key? key, required this.quitTimestamp}) : super(key: key);

  @override
  State<MilestoneProgressCard> createState() => _MilestoneProgressCardState();
}

class _MilestoneProgressCardState extends State<MilestoneProgressCard> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final Duration elapsed = DateTime.now().difference(widget.quitTimestamp);
    final allMilestones = MedicalMilestonesData.milestones;

    // Find active milestone (first one not yet completed)
    int activeIndex = allMilestones.indexWhere((m) => elapsed < m.targetDuration);
    
    // If all completed, lock to last
    if (activeIndex == -1) activeIndex = allMilestones.length - 1;

    final activeMilestone = allMilestones[activeIndex];
    
    // Calculate progress toward active milestone
    double progress = 1.0;
    if (elapsed < activeMilestone.targetDuration) {
      final double previousTargetMs = activeIndex > 0 
          ? allMilestones[activeIndex - 1].targetDuration.inMilliseconds.toDouble() 
          : 0.0;
      final double currentTargetMs = activeMilestone.targetDuration.inMilliseconds.toDouble();
      final double currentElapsedMs = elapsed.inMilliseconds.toDouble();

      progress = ((currentElapsedMs - previousTargetMs) / (currentTargetMs - previousTargetMs)).clamp(0.0, 1.0);
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
          // Active Milestone Header Card
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                    Expanded( // 👈 Wrap this in Expanded to prevent horizontal overflow
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
                        Expanded( // 👈 Also wrap the text column so long titles wrap onto two lines safely
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

                // Linear Progress Bar
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
                const SizedBox(height: 8),

                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Source: ${activeMilestone.clinicalSource}",
                      style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: Colors.grey.shade500),
                    ),
                    Text(
                      "Target: ${_formatDate(targetDate)}",
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.teal.shade900),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Expandable Roadmap Trigger
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                border: Border(top: BorderSide(color: Colors.grey.shade200)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _isExpanded ? "Hide Full Clinical Timeline" : "View Full Medical Roadmap (${allMilestones.length} Phases)",
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

          // Expanded Full List
          if (_isExpanded)
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: allMilestones.length,
              separatorBuilder: (context, index) => Divider(height: 1, color: Colors.grey.shade200),
              itemBuilder: (context, index) {
                final item = allMilestones[index];
                final bool isPassed = elapsed >= item.targetDuration;
                final bool isCurrent = index == activeIndex;

                return ListTile(
                  dense: true,
                  leading: Icon(
                    isPassed ? Icons.check_circle_rounded : (isCurrent ? Icons.play_circle_fill_rounded : Icons.radio_button_unchecked_rounded),
                    color: isPassed ? Colors.teal.shade600 : (isCurrent ? Colors.amber.shade700 : Colors.grey.shade400),
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
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return "${date.month}/${date.day}/${date.year}";
  }

  String _formatDuration(Duration d) {
    if (d.inDays >= 365) {
      return "${(d.inDays / 365).toStringAsFixed(0)} yr";
    } else if (d.inDays >= 30) {
      return "${(d.inDays / 30).toStringAsFixed(0)} mo";
    } else if (d.inDays >= 1) {
      return "${d.inDays} days";
    } else {
      return "${d.inHours} hrs";
    }
  }
}
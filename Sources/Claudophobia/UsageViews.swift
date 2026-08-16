import Charts
import SwiftUI

// MARK: - Ring gauge

struct GaugeRing: View {
   let progress: Double
   let color: Color
   var lineWidth: CGFloat = 12

   var body: some View {
      ZStack {
         Circle()
            .stroke(color.opacity(0.18), lineWidth: lineWidth)
         Circle()
            .trim(from: 0, to: max(0.001, min(progress, 1)))
            .stroke(
               AngularGradient(
                  colors: [color.opacity(0.55), color],
                  center: .center,
                  startAngle: .degrees(-90),
                  endAngle: .degrees(270)
               ),
               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .rotationEffect(.degrees(-90))
            .animation(.spring(response: 0.9, dampingFraction: 0.8), value: progress)
      }
   }
}

/// Small ring used in the menu bar icon and the collapsed notch pill.
struct MiniGauge: View {
   let progress: Double
   let level: UsageLevel
   var size: CGFloat = 16

   var body: some View {
      GaugeRing(progress: progress, color: level.color, lineWidth: max(2, size * 0.18))
         .frame(width: size, height: size)
         .overlay(
            Circle()
               .fill(level.color)
               .frame(width: max(2.5, size * 0.22))
         )
   }
}

// MARK: - Sparkline (history)

struct UsageSparkline: View {
   let samples: [UsageSample]

   var body: some View {
      Chart {
         ForEach(samples, id: \.date) { sample in
            LineMark(
               x: .value("Time", sample.date),
               y: .value("Session %", sample.session),
               series: .value("Series", "session")
            )
            .foregroundStyle(Assets.sessionAccent)
            .interpolationMethod(.catmullRom)

            LineMark(
               x: .value("Time", sample.date),
               y: .value("Weekly %", sample.weekly),
               series: .value("Series", "weekly")
            )
            .foregroundStyle(Assets.weeklyAccent)
            .interpolationMethod(.catmullRom)
         }
      }
      .chartYScale(domain: 0...100)
      .chartYAxis {
         AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
               .foregroundStyle(Color.white.opacity(0.06))
            AxisValueLabel()
               .font(.system(size: 8))
               .foregroundStyle(.tertiary)
         }
      }
      .chartXAxis(.hidden)
      .chartLegend(.hidden)
   }
}

// MARK: - Popover usage card

struct UsageCardView: View {
   let title: String
   let subtitle: String
   let limit: UsageLimit?
   let accent: Color

   var body: some View {
      HStack(spacing: 14) {
         ZStack {
            GaugeRing(progress: limit?.fraction ?? 0, color: accent, lineWidth: 9)
               .frame(width: 58, height: 58)
            Text("\(Int((limit?.utilization ?? 0).rounded()))%")
               .font(.system(size: 13, weight: .bold, design: .rounded))
         }
         VStack(alignment: .leading, spacing: 3) {
            Text(title)
               .font(.system(size: 12, weight: .semibold))
               .foregroundStyle(.secondary)
            Text(limit?.resetDescription ?? "—")
               .font(.system(size: 11))
               .foregroundStyle(.tertiary)
         }
         Spacer()
         if let level = limit?.statusLevel {
            Text(level.rawValue.uppercased())
               .font(.system(size: 9, weight: .bold))
               .foregroundStyle(level.color)
               .padding(.horizontal, 7)
               .padding(.vertical, 3)
               .background(Capsule().fill(level.color.opacity(0.15)))
         }
      }
      .padding(12)
      .background(
         RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Assets.cardFill)
      )
   }
}

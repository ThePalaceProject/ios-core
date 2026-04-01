import SwiftUI
import Charts

/// A reusable bar chart component for reading time data using Swift Charts.
@available(iOS 16.0, *)
struct ReadingChartView: View {
  let dataPoints: [ChartDataPoint]
  let timePeriod: TimePeriod

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Reading Activity")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)

      if dataPoints.isEmpty || dataPoints.allSatisfy({ $0.value == 0 }) {
        emptyState
      } else {
        chart
      }
    }
    .padding()
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private var chart: some View {
    Chart(dataPoints) { point in
      BarMark(
        x: .value("Date", point.label),
        y: .value("Minutes", point.value)
      )
      .foregroundStyle(barGradient)
      .cornerRadius(4)
    }
    .chartYAxisLabel("Minutes")
    .chartYAxis {
      AxisMarks(position: .leading) { value in
        AxisValueLabel {
          if let minutes = value.as(Double.self) {
            Text(formatAxisLabel(minutes))
              .font(.caption2)
          }
        }
        AxisGridLine()
      }
    }
    .chartXAxis {
      AxisMarks { value in
        AxisValueLabel {
          if let label = value.as(String.self) {
            Text(label)
              .font(.caption2)
          }
        }
      }
    }
    .frame(height: 200)
    .accessibilityLabel(chartAccessibilityLabel)
  }

  @ViewBuilder
  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "chart.bar")
        .font(.largeTitle)
        .foregroundStyle(.tertiary)
      Text("No reading data yet")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      Text("Start reading to see your activity chart.")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 200)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("No reading data yet. Start reading to see your activity chart.")
  }

  private var barGradient: LinearGradient {
    LinearGradient(
      colors: [.blue, .blue.opacity(0.7)],
      startPoint: .bottom,
      endPoint: .top
    )
  }

  private func formatAxisLabel(_ minutes: Double) -> String {
    if minutes >= 60 {
      return "\(Int(minutes / 60))h"
    }
    return "\(Int(minutes))m"
  }

  private var chartAccessibilityLabel: String {
    let total = dataPoints.reduce(0.0) { $0 + $1.value }
    let hours = Int(total / 60)
    let mins = Int(total.truncatingRemainder(dividingBy: 60))
    return "Reading activity chart for the past \(timePeriod.rawValue.lowercased()). Total: \(hours) hours and \(mins) minutes."
  }
}

#Preview {
  ReadingChartView(
    dataPoints: [
      ChartDataPoint(label: "Mon", date: Date(), value: 30, format: nil),
      ChartDataPoint(label: "Tue", date: Date(), value: 45, format: nil),
      ChartDataPoint(label: "Wed", date: Date(), value: 0, format: nil),
      ChartDataPoint(label: "Thu", date: Date(), value: 60, format: nil),
      ChartDataPoint(label: "Fri", date: Date(), value: 15, format: nil),
      ChartDataPoint(label: "Sat", date: Date(), value: 90, format: nil),
      ChartDataPoint(label: "Sun", date: Date(), value: 20, format: nil),
    ],
    timePeriod: .week
  )
  .padding()
}

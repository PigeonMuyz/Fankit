import SwiftUI

struct TemperatureSections: View {
    let store: FanControlStore
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Temperatures", systemImage: "thermometer.medium")
                .font(.title3.bold())

            ForEach(ThermalGroup.allCases) { group in
                let sensors = store.temperatures(in: group)
                if !sensors.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        ForEach(sensors) { sensor in
                            HStack {
                                Text(verbatim: sensor.name)
                                Spacer(minLength: 16)
                                Text("\(sensor.celsius, format: .number.precision(.fractionLength(0)))°C")
                                    .monospacedDigit()
                                    .fontWeight(.semibold)
                            }
                        }
                    }

                    if group != ThermalGroup.allCases.last {
                        Divider()
                    }
                }
            }

            if store.temperatures.isEmpty {
                ContentUnavailableView("No Temperature Sensors", systemImage: "thermometer.medium.slash")
                    .frame(maxWidth: .infinity)
                    .frame(height: 120)
            }
        }
        .padding(compact ? 0 : 18)
        .background(compact ? AnyShapeStyle(.clear) : AnyShapeStyle(.regularMaterial), in: .rect(cornerRadius: 14))
    }
}

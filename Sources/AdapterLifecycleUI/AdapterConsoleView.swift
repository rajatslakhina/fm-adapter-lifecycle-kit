#if canImport(SwiftUI)
import AdapterLifecycle
import SwiftUI

/// A console for the adapter lifecycle: what is serving right now, why the alternatives
/// are not, and controls that move the device through the states a real fleet goes
/// through — an OS update, a rollout ramp, a kill switch, storage pressure.
public struct AdapterConsoleView: View {

    @State private var model: AdapterConsoleModel

    public init(configuration: AdapterConsoleConfiguration) {
        _model = State(initialValue: AdapterConsoleModel(configuration: configuration))
    }

    public var body: some View {
        NavigationStack {
            List {
                servingSection
                taskSection
                fleetControlsSection
                catalogSection
                storageSection
                activitySection
            }
            .navigationTitle("Adapter Lifecycle")
            .task { await model.start() }
        }
    }

    // MARK: - Serving

    private var servingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.outcome.map { LifecyclePresentation.headline(for: $0.selection) } ?? "Resolving…")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(servingColor)
                Text(model.outcome.map { LifecyclePresentation.subtitle(for: $0.selection) } ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let base = model.snapshot?.installedBase {
                    Label("Base model \(base.description)", systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)

            if let audit = model.outcome?.audit, !audit.isEmpty {
                DisclosureGroup("Why not the others (\(audit.count))") {
                    ForEach(audit, id: \.adapter) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(entry.adapter.rawValue) · rev \(entry.revision)")
                                .font(.caption.weight(.semibold))
                            Text(LifecyclePresentation.explain(entry.rejection))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        } header: {
            Text("Serving")
        } footer: {
            Text("The app asks for a task, never for a model. Everything below changes the answer.")
        }
    }

    private var servingColor: Color {
        guard let selection = model.outcome?.selection else { return .secondary }
        return selection.usesAdapter ? .green : .orange
    }

    // MARK: - Task

    private var taskSection: some View {
        Section("Task") {
            Picker("Task", selection: taskBinding) {
                ForEach(model.tasks, id: \.rawValue) { task in
                    Text(task.rawValue).tag(task.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var exposureBinding: Binding<Int> {
        Binding(
            get: { model.snapshot?.exposurePercent ?? model.exposureStops.last ?? 100 },
            set: { newValue in Task { await model.setExposure(percent: newValue) } }
        )
    }

    private var taskBinding: Binding<String> {
        Binding(
            get: { model.selectedTask.rawValue },
            set: { raw in
                guard let task = model.tasks.first(where: { $0.rawValue == raw }) else { return }
                Task { await model.select(task: task) }
            }
        )
    }

    // MARK: - Controls

    private var fleetControlsSection: some View {
        Section {
            Button {
                Task { await model.simulateOSUpdate() }
            } label: {
                Label(
                    model.nextBaseModel.map { "Ship OS update → base \($0)" } ?? "No further OS updates",
                    systemImage: "arrow.up.circle"
                )
            }
            .disabled(!model.canSimulateOSUpdate || model.isBusy)

            Button {
                Task { await model.reEvaluateAgainstCurrentBase() }
            } label: {
                Label("Re-run offline eval on this base model", systemImage: "checkmark.seal")
            }
            .disabled(model.isBusy)

            VStack(alignment: .leading, spacing: 6) {
                Text("Rollout exposure").font(.subheadline)
                // Bound to the coordinator's snapshot, not to a local @State copy. The
                // console's claim is that it never keeps its own copy of the decision, and
                // a shadow `exposure` here would have made that claim false.
                Picker("Rollout exposure", selection: exposureBinding) {
                    ForEach(model.exposureStops, id: \.self) { stop in
                        Text("\(stop)%").tag(stop)
                    }
                }
                .pickerStyle(.segmented)
            }

            Button(role: .destructive) {
                Task { await model.revokeServingAdapter() }
            } label: {
                Label("Pull the kill switch on the serving adapter", systemImage: "hand.raised")
            }
            .disabled(model.outcome?.selection.usesAdapter != true || model.isBusy)

            Button {
                Task { await model.clearRevocations() }
            } label: {
                Label("Clear every kill switch", systemImage: "arrow.uturn.backward")
            }
            .disabled(model.isBusy)

            Button {
                Task { await model.reportFailureOnServingAdapter() }
            } label: {
                Label("Report a failure (3 in a row quarantines it)", systemImage: "exclamationmark.triangle")
            }
            .disabled(model.outcome?.selection.usesAdapter != true || model.isBusy)

            Button {
                Task { await model.reportSuccessOnServingAdapter() }
            } label: {
                Label("Report a success (resets the counter)", systemImage: "hand.thumbsup")
            }
            .disabled(model.outcome?.selection.usesAdapter != true || model.isBusy)

            Button {
                Task { await model.fetchPressureCandidate() }
            } label: {
                Label("Fetch \(model.pressureCandidateLabel)", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.canFetchPressureCandidate || model.isBusy)
        } header: {
            Text("Fleet controls")
        } footer: {
            Text("Each button is one call into the library. Nothing here keeps its own copy of the decision.")
        }
    }

    // MARK: - Catalog

    private var catalogSection: some View {
        Section("Installed adapters") {
            let residents = model.snapshot?.residents ?? []
            if residents.isEmpty {
                Text("Nothing resident — every task falls back to the stock base model.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(residents, id: \.descriptor.id) { resident in
                    residentRow(resident)
                }
            }
        }
    }

    private func residentRow(_ resident: AdapterLifecycleCoordinator.ResidentSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(resident.descriptor.id.rawValue).font(.subheadline.weight(.semibold))
                if resident.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.blue)
                }
                Spacer()
                Text(LifecyclePresentation.shortLabel(for: resident.evalVerdict))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(resident.evalVerdict.allowsAdapter ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                    .foregroundStyle(resident.evalVerdict.allowsAdapter ? Color.green : Color.orange)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            Text("\(resident.descriptor.task.rawValue) · rev \(resident.descriptor.revision) · \(LifecyclePresentation.label(for: resident.descriptor.distribution)) · \(LifecyclePresentation.megabytes(resident.descriptor.payloadBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Valid for \(resident.descriptor.compatibility.description) · bucket \(resident.rolloutBucket)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(LifecyclePresentation.explain(resident.evalVerdict))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let revocation = resident.revocation {
                Text(LifecyclePresentation.explain(revocation))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }
            if resident.consecutiveFailures > 0 {
                Text("\(resident.consecutiveFailures) consecutive failures")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section("Storage budget") {
            if let snapshot = model.snapshot {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: storageFraction(snapshot))
                    Text("\(LifecyclePresentation.megabytes(snapshot.usedBytes)) of \(LifecyclePresentation.megabytes(snapshot.budgetBytes)) · \(snapshot.utilisationPercent)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Bundled adapters are excluded — evicting one would not free a byte.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    let divergence = snapshot.divergence
                    if divergence.sampleCount > 0 {
                        Text("Online: \(divergence.adapterWins) adapter / \(divergence.baseWins) base / \(divergence.ties) tie · \(divergence.regressionPercent)% regression")
                            .font(.caption)
                            .foregroundStyle(divergence.regressionPercent > 50 ? .red : .secondary)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
    }

    private func storageFraction(_ snapshot: AdapterLifecycleCoordinator.LifecycleSnapshot) -> Double {
        guard snapshot.budgetBytes > 0 else { return 0 }
        let fraction = Double(snapshot.usedBytes) / Double(snapshot.budgetBytes)
        guard fraction.isFinite else { return 0 }
        return min(1, max(0, fraction))
    }

    // MARK: - Activity

    private var activitySection: some View {
        Section("Activity") {
            if model.log.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                ForEach(model.log) { line in
                    Text(line.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
#endif

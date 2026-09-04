import SwiftUI

/// 连接监控只读取 Rust 快照并触发既有连接的按需探测，不持有凭据或会话内容。
@MainActor
final class ConnectionMonitorStore: ObservableObject {
    typealias SnapshotLoader = @Sendable () throws -> [ConnectionTelemetryRecord]
    typealias HealthChecker = @Sendable (UInt64) throws -> HealthStateEnum

    @Published private(set) var records: [ConnectionTelemetryRecord] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var checkingConnectionIDs: Set<UInt64> = []
    @Published var errorMessage: String?

    private let snapshotLoader: SnapshotLoader
    private let healthChecker: HealthChecker

    init(
        snapshotLoader: @escaping SnapshotLoader = { connectionTelemetryList() },
        healthChecker: @escaping HealthChecker = { try connectionHealthCheck(connectionId: $0) }
    ) {
        self.snapshotLoader = snapshotLoader
        self.healthChecker = healthChecker
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await FFIBackground.run(snapshotLoader)
            let merged = mergedRecords(from: snapshot)
            if merged != records {
                records = merged
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.errorSummary(error)
        }
    }

    /// 以连接 ID 固定排序；未变化的值沿用既有快照，避免无意义地发布整个列表。
    private func mergedRecords(from snapshot: [ConnectionTelemetryRecord]) -> [ConnectionTelemetryRecord] {
        let existingRecords = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return snapshot
            .sorted { $0.id < $1.id }
            .map { record in existingRecords[record.id] == record ? existingRecords[record.id]! : record }
    }

    func checkHealth(connectionID: UInt64) async {
        guard !checkingConnectionIDs.contains(connectionID) else { return }
        checkingConnectionIDs.insert(connectionID)
        defer { checkingConnectionIDs.remove(connectionID) }
        do {
            let state = try await FFIBackground.run { [healthChecker] in
                try healthChecker(connectionID)
            }
            if let index = records.firstIndex(where: { $0.id == connectionID }) {
                records[index].healthState = state
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.errorSummary(error)
        }
    }

    private static func errorSummary(_ error: Error) -> String {
        if let pandaError = error as? PandaError,
           case let PandaError.UnknownConnection(id) = pandaError {
            return "连接 #\(id) 不存在或已结束"
        }
        return error.localizedDescription
    }
}

enum ConnectionMonitorFormatter {
    static func timestamp(_ milliseconds: UInt64) -> String {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            .formatted(date: .abbreviated, time: .standard)
    }

    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB", "EiB"]
        guard value > 0 else { return "0 B" }
        var amount = Double(value)
        var unit = 0
        while amount >= 1_024, unit < units.count - 1 {
            amount /= 1_024
            unit += 1
        }
        if unit == 0 { return "\(value) B" }
        return String(format: "%.1f %@", amount, units[unit])
    }

    static func rate(_ value: UInt64) -> String { "\(bytes(value))/s" }

    static func transport(_ state: ConnectionStateEnum) -> String {
        switch state {
        case .connecting: "Socket 连接中"
        case .active: "Socket 活跃"
        case .idle: "Socket 空闲（正常）"
        case .closed: "Socket 已关闭"
        case .failed: "Socket 异常"
        }
    }

    static func ssh(_ state: SshConnectionStateEnum) -> String {
        switch state {
        case .connecting: "SSH 协商中"
        case .authenticated: "SSH 已认证"
        case .closed: "SSH 已关闭"
        case .failed: "SSH 异常"
        }
    }

    static func health(_ state: HealthStateEnum) -> String {
        switch state {
        case .unknown: "未检查"
        case .healthy: "健康"
        case .unavailable: "不可用"
        }
    }

    static func channelKind(_ kind: ChannelKindEnum) -> String {
        switch kind {
        case .shell: "终端"
        case .sftp: "SFTP"
        case .exec: "命令"
        }
    }

    static func channelState(_ state: ChannelStateEnum) -> String {
        switch state {
        case .open: "可用"
        case .closed: "已关闭"
        case .failed: "不可交互"
        }
    }
}

@MainActor
struct ConnectionMonitorView: View {
    @StateObject private var store: ConnectionMonitorStore

    init() {
        _store = StateObject(wrappedValue: ConnectionMonitorStore())
    }

    init(store: ConnectionMonitorStore) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        Group {
            if store.records.isEmpty, !store.isRefreshing {
                ContentUnavailableView(
                    "暂无连接",
                    systemImage: "network.slash",
                    description: Text("建立终端或 SFTP 会话后，可在这里查看 Socket、SSH、通道和流量状态。")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        explanation
                        ForEach(store.records, id: \.id) { connection in
                            connectionCard(connection)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("连接监控")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshing)
            }
        }
        .overlay {
            if store.isRefreshing, store.records.isEmpty { ProgressView("读取连接状态…") }
        }
        .task {
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .alert(
            "连接监控",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "未知错误")
        }
    }

    private var explanation: some View {
        Label {
            Text("流量为应用层实际读写的加密 SSH 字节与通道逻辑数据，不含 TCP/IP 头和重传。空闲表示近期无数据，不是异常。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func connectionCard(_ connection: ConnectionTelemetryRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(connection.address)
                        .font(.headline)
                    Text("Session #\(connection.id) · \(connection.ownerKind) \(connection.ownerId) · 主机 \(connection.hostId)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.checkHealth(connectionID: connection.id) }
                } label: {
                    if store.checkingConnectionIDs.contains(connection.id) {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("检查", systemImage: "stethoscope")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(store.checkingConnectionIDs.contains(connection.id))
            }

            VStack(alignment: .leading, spacing: 6) { statusBadges(connection) }

            HStack(spacing: 24) {
                trafficMetric("接收", total: connection.receivedBytes, rate: connection.receiveBytesPerSecond)
                trafficMetric("发送", total: connection.sentBytes, rate: connection.sendBytesPerSecond)
                Spacer()
            }

            Text(
                "建立：\(ConnectionMonitorFormatter.timestamp(connection.createdAtMs))  ·  "
                    + "最近活动：\(ConnectionMonitorFormatter.timestamp(connection.lastActivityAtMs))  ·  "
                    + "最近检查：\(connection.lastHealthCheckAtMs.map(ConnectionMonitorFormatter.timestamp) ?? "尚未检查")"
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)

            if let error = connection.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if !connection.channels.isEmpty {
                Divider()
                VStack(spacing: 6) {
                    ForEach(connection.channels, id: \.id) { channel in
                        HStack {
                            Text("\(ConnectionMonitorFormatter.channelKind(channel.kind)) #\(channel.id)")
                                .font(.callout.weight(.medium))
                            Text(ConnectionMonitorFormatter.channelState(channel.state))
                                .font(.caption)
                                .foregroundStyle(channel.state == .failed ? .red : .secondary)
                            Spacer()
                            Text("↓ \(ConnectionMonitorFormatter.bytes(channel.receivedBytes))  ↑ \(ConnectionMonitorFormatter.bytes(channel.sentBytes))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.12)))
    }

    @ViewBuilder
    private func statusBadges(_ connection: ConnectionTelemetryRecord) -> some View {
        statusBadge(
            ConnectionMonitorFormatter.transport(connection.transportState),
            color: transportColor(connection.transportState)
        )
        statusBadge(ConnectionMonitorFormatter.ssh(connection.sshState), color: sshColor(connection.sshState))
        statusBadge(
            "探测：\(ConnectionMonitorFormatter.health(connection.healthState))",
            color: healthColor(connection.healthState)
        )
    }

    private func statusBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func trafficMetric(_ title: String, total: UInt64, rate: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(ConnectionMonitorFormatter.bytes(total)).font(.body.monospacedDigit().weight(.semibold))
            Text(ConnectionMonitorFormatter.rate(rate)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func transportColor(_ state: ConnectionStateEnum) -> Color {
        switch state {
        case .active: .green
        case .idle: .blue
        case .connecting: .orange
        case .closed: .secondary
        case .failed: .red
        }
    }

    private func sshColor(_ state: SshConnectionStateEnum) -> Color {
        switch state {
        case .authenticated: .green
        case .connecting: .orange
        case .closed: .secondary
        case .failed: .red
        }
    }

    private func healthColor(_ state: HealthStateEnum) -> Color {
        switch state {
        case .unknown: .secondary
        case .healthy: .green
        case .unavailable: .red
        }
    }
}

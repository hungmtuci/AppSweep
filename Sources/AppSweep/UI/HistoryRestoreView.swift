import AppKit
import SwiftUI

struct HistoryRestoreView: View {
    @ObservedObject var viewModel: MainViewModel

    private var totalLifetimeBytes: Int64 {
        viewModel.historyRecords
            .filter { !$0.isFullyRestored }
            .reduce(0) { $0 + $1.totalBytesFreed }
    }

    private var restorableCount: Int {
        viewModel.historyRecords.filter(\.canRestore).count
    }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        df.locale = Locale(identifier: "vi_VN")
        return df
    }()

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
            Divider()

            if viewModel.historyRecords.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                    Text("Chưa có lịch sử dọn dẹp")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Nhật ký gỡ ứng dụng, bản sao lưu .zip và các gói có thể khôi phục từ Thùng rác sẽ hiển thị tại đây.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(viewModel.historyRecords) { record in
                            recordCard(record)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var summaryHeader: some View {
        HStack(spacing: 24) {
            metricColumn(title: "Đã giải phóng", value: ByteFormatter.string(totalLifetimeBytes))

            Divider()
                .frame(height: 28)

            metricColumn(title: "Phiên dọn dẹp", value: "\(viewModel.historyRecords.count)")

            Divider()
                .frame(height: 28)

            metricColumn(title: "Có thể hoàn tác", value: "\(restorableCount)")

            Spacer()

            if !viewModel.historyRecords.isEmpty {
                Button("Xóa nhật ký") {
                    viewModel.clearHistoryLog()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func metricColumn(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private func recordCard(_ record: UninstallHistoryRecord) -> some View {
        let isExpanded = viewModel.expandedHistoryRecordIDs.contains(record.id)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(record.targetName)
                            .font(.system(size: 13, weight: .medium))

                        Text(statusSummaryLabel(record))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Text("\(Self.dateFormatter.string(from: record.timestamp))  ·  \(record.removedCount) mục  ·  \(ByteFormatter.string(record.totalBytesFreed))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if let zipPath = record.archiveZipPath, FileManager.default.fileExists(atPath: zipPath) {
                    Button("Bản lưu .zip") {
                        viewModel.revealInFinder(zipPath)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let trashFolder = record.trashContainerPath, FileManager.default.fileExists(atPath: trashFolder) {
                    Button("Xem trong Trash") {
                        viewModel.revealInFinder(trashFolder)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if record.canRestore {
                    Button("Hoàn tác") {
                        viewModel.restoreFromHistory(record.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.isExecutingAction)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                if isExpanded {
                    viewModel.expandedHistoryRecordIDs.remove(record.id)
                } else {
                    viewModel.expandedHistoryRecordIDs.insert(record.id)
                }
            }

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(record.entries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.isRestored ? "arrow.uturn.backward" : "minus")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .frame(width: 12)
                            Text(PathFormatter.prettyPath(entry.originalPath))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteFormatter.string(entry.sizeBytes))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }

    private func statusSummaryLabel(_ record: UninstallHistoryRecord) -> String {
        if record.isFullyRestored {
            return "· Đã hoàn tác khôi phục"
        }
        return record.mode == .moveToTrash ? "· Đã chuyển vào Thùng rác" : "· Đã xóa vĩnh viễn"
    }
}

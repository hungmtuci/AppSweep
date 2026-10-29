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
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Chưa có lịch sử gỡ cài đặt nào")
                        .font(.title3.weight(.semibold))
                    Text("Mọi hoạt động gỡ bỏ ứng dụng, bản sao lưu .zip và gói khôi phục trong Thùng rác sẽ được lưu chi tiết tại đây.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.historyRecords) { record in
                            recordCard(record)
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var summaryHeader: some View {
        HStack(spacing: 16) {
            statTile(
                icon: "externaldrive.badge.checkmark",
                color: .green,
                title: "Tổng dung lượng đã giải phóng",
                value: ByteFormatter.string(totalLifetimeBytes)
            )
            statTile(
                icon: "list.bullet.clipboard.fill",
                color: .blue,
                title: "Phiên dọn dẹp đã thực hiện",
                value: "\(viewModel.historyRecords.count) phiên"
            )
            statTile(
                icon: "arrow.uturn.backward.circle.fill",
                color: .orange,
                title: "Có thể Hoàn tác ngay từ Trash",
                value: "\(restorableCount) mục"
            )

            Spacer()

            if !viewModel.historyRecords.isEmpty {
                Button(role: .destructive) {
                    viewModel.clearHistoryLog()
                } label: {
                    Label("Xóa nhật ký", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
    }

    private func statTile(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.weight(.bold))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
    }

    private func recordCard(_ record: UninstallHistoryRecord) -> some View {
        let isExpanded = viewModel.expandedHistoryRecordIDs.contains(record.id)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: record.isFullyRestored ? "arrow.uturn.backward.circle.fill" : "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(record.isFullyRestored ? .blue : .green)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(record.targetName)
                            .font(.headline)

                        Text(record.mode == .moveToTrash ? "Thùng rác" : "Xóa vĩnh viễn")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(record.mode == .moveToTrash ? .blue : .red)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background((record.mode == .moveToTrash ? Color.blue : Color.red).opacity(0.12), in: Capsule())

                        if record.isFullyRestored {
                            Text("Đã hoàn tác khôi phục")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.13), in: Capsule())
                        }
                    }

                    Text("\(Self.dateFormatter.string(from: record.timestamp))  •  \(record.removedCount) mục  •  \(ByteFormatter.string(record.totalBytesFreed))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let zipPath = record.archiveZipPath, FileManager.default.fileExists(atPath: zipPath) {
                    Button {
                        viewModel.revealInFinder(zipPath)
                    } label: {
                        Label("Mở bản lưu .zip", systemImage: "doc.zipper")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let trashFolder = record.trashContainerPath, FileManager.default.fileExists(atPath: trashFolder) {
                    Button {
                        viewModel.revealInFinder(trashFolder)
                    } label: {
                        Label("Xem trong Trash", systemImage: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if record.canRestore {
                    Button {
                        viewModel.restoreFromHistory(record.id)
                    } label: {
                        Label("Hoàn tác (Khôi phục)", systemImage: "arrow.uturn.backward")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .controlSize(.small)
                    .disabled(viewModel.isExecutingAction)
                }

                Button {
                    if isExpanded {
                        viewModel.expandedHistoryRecordIDs.remove(record.id)
                    } else {
                        viewModel.expandedHistoryRecordIDs.insert(record.id)
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(record.entries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: entry.isRestored ? "arrow.uturn.backward.circle.fill" : "minus.circle.fill")
                                .font(.caption)
                                .foregroundStyle(entry.isRestored ? .green : .secondary)
                            Text(PathFormatter.prettyPath(entry.originalPath))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteFormatter.string(entry.sizeBytes))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

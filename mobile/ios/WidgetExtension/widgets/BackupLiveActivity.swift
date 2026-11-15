import ActivityKit
import SwiftUI
import WidgetKit

// ponytail: duplicated in Runner/Core/BackupLiveActivity.swift; ActivityKit matches by type name + Codable shape.
struct BackupActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var done: Int
    var total: Int
    var paused: Bool
    var detail: String?  // "12.3 MB/s · ~1h 5m left"
    var file: String?  // file uploading now (foreground only)
    var fileProgress: Double?
    var updatedAt: Date?  // when the app last pushed this state
  }
}

private extension BackupActivityAttributes.ContentState {
  var remaining: Int { max(total - done, 0) }
  var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
  var title: String {
    if remaining == 0 { return "Backup complete" }
    return paused ? "Backup paused · open Immich" : "Backing up \(remaining) items"
  }
  var icon: String { remaining == 0 ? "checkmark.icloud" : paused ? "pause.circle" : "icloud.and.arrow.up" }
}

struct BackupLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: BackupActivityAttributes.self) { ctx in
      let s = ctx.state
      HStack(spacing: 12) {
        Image(systemName: s.icon).font(.title2)
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text(s.title).font(.headline)
            Spacer()
            Text("\(s.done) / \(s.total)").font(.caption).monospacedDigit()
          }
          ProgressView(value: s.fraction)
          HStack {
            if let detail = s.detail, !detail.isEmpty, !s.paused {
              Text(detail).monospacedDigit()
            }
            Spacer()
            UpdatedAgo(date: s.updatedAt)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
          if let file = s.file, let p = s.fileProgress, !s.paused {
            FileRow(file: file, progress: p)
          }
        }
      }
      .padding()
    } dynamicIsland: { ctx in
      let s = ctx.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) { Image(systemName: s.icon).font(.title2) }
        DynamicIslandExpandedRegion(.trailing) { Text("\(s.remaining) left").monospacedDigit() }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading) {
            Text(s.title).font(.caption)
            ProgressView(value: s.fraction)
            HStack {
              if let detail = s.detail, !detail.isEmpty, !s.paused {
                Text(detail).monospacedDigit()
              }
              Spacer()
              UpdatedAgo(date: s.updatedAt)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if let file = s.file, let p = s.fileProgress, !s.paused {
              FileRow(file: file, progress: p)
            }
          }
        }
      } compactLeading: {
        Image(systemName: s.icon)
      } compactTrailing: {
        Text("\(s.remaining)").monospacedDigit()
      } minimal: {
        ProgressView(value: s.fraction).progressViewStyle(.circular)
      }
    }
  }
}

/// Second, thinner bar: the file uploading right now.
private struct FileRow: View {
  let file: String
  let progress: Double

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Image(systemName: "doc").font(.caption2)
        Text(progress >= 1 ? "Uploaded \(file)" : file).font(.caption2).lineLimit(1).truncationMode(.middle)
        Spacer()
        if progress >= 1 {
          Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        } else {
          Text("\(Int(progress * 100))%").font(.caption2).monospacedDigit()
        }
      }
      ProgressView(value: progress).tint(.green).scaleEffect(x: 1, y: 0.6, anchor: .center)
    }
    .foregroundStyle(.secondary)
  }
}

/// "Updated 3 min ago": ticks on its own while the app is suspended, so stale numbers are visible as stale.
private struct UpdatedAgo: View {
  let date: Date?

  var body: some View {
    if let date {
      Text("Updated ") + Text(date, style: .relative) + Text(" ago")
    }
  }
}

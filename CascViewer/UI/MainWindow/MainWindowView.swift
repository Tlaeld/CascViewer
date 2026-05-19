import SwiftUI

struct LoadingOverlay: View {
    @ObservedObject var storage: CASCStorageService

    var body: some View {
        if storage.isLoading {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    if storage.loadProgress > 0 {
                        ProgressView(value: storage.loadProgress, total: 1.0)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 200)
                    } else {
                        ProgressView()
                            .scaleEffect(1.2)
                    }
                    
                    Text(L("loading_storage"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.primary)
                    
                    if !storage.loadProgressMessage.isEmpty {
                        Text(storage.loadProgressMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    
                    if storage.loadProgress > 0 {
                        Text("\(Int(storage.loadProgress * 100))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(24)
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(12)
                .shadow(radius: 8)
                .frame(minWidth: 280, maxWidth: 360)
            }
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var settings = AppSettings.shared

    // Horizontal split (left sidebar vs right content)
    @AppStorage("mainWindow.leftWidth") private var leftWidth: Double = 220
    @State private var hDragStartWidth: Double = 220

    // Vertical split (file list vs preview panel)
    @AppStorage("mainWindow.topRatio") private var topRatio: Double = 0.5
    @State private var vDragStartRatio: Double = 0.5

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                ToolbarView()
                Divider()

                GeometryReader { geo in
                    let totalWidth = geo.size.width
                    let totalHeight = geo.size.height
                    let minLeftW: CGFloat = 180
                    let maxLeftW: CGFloat = 400
                    let leftW = CGFloat(min(max(leftWidth, minLeftW), maxLeftW))
                    let rightW = totalWidth - leftW

                    HStack(spacing: 0) {
                        FileTreeView()
                            .frame(width: leftW)

                        // Vertical drag handle
                        ZStack {
                            Rectangle()
                                .fill(Color.primary.opacity(0.2))
                                .frame(width: 1)
                            Rectangle()
                                .fill(Color.clear)
                                .frame(width: 16)
                                .contentShape(Rectangle())
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                .onChanged { value in
                                    let newWidth = hDragStartWidth + Double(value.translation.width)
                                    leftWidth = min(max(newWidth, minLeftW), maxLeftW)
                                }
                                .onEnded { _ in
                                    hDragStartWidth = leftWidth
                                }
                        )
                        .onHover { isHovering in
                            if isHovering {
                                NSCursor.resizeLeftRight.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        }

                        // Right area
                        let minH: CGFloat = 200
                        let minBottomH: CGFloat = 160
                        let minRatio = Double(minH / totalHeight)
                        let maxRatio = Double(max(totalHeight - minBottomH, minH) / totalHeight)
                        let listHeight = totalHeight * CGFloat(min(max(topRatio, minRatio), maxRatio))

                        VStack(spacing: 0) {
                            FileListView()
                                .frame(height: listHeight)

                            // Horizontal drag handle
                            ZStack {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.25))
                                    .frame(height: 1)
                                Rectangle()
                                    .fill(Color.clear)
                                    .frame(height: 8)
                                    .contentShape(Rectangle())
                            }
                            .gesture(
                                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                                    .onChanged { value in
                                        let pixelDelta = Double(value.translation.height)
                                        let ratioDelta = pixelDelta / Double(totalHeight)
                                        let newRatio = vDragStartRatio + ratioDelta
                                        topRatio = min(max(newRatio, minRatio), maxRatio)
                                    }
                                    .onEnded { _ in
                                        vDragStartRatio = topRatio
                                    }
                            )
                            .onHover { isHovering in
                                if isHovering {
                                    NSCursor.resizeUpDown.set()
                                } else {
                                    NSCursor.arrow.set()
                                }
                            }

                            FilePreviewPanel()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(width: rightW)
                    }
                }

                Divider()
                StatusBarView()
            }

            if let storage = appState.currentStorage {
                LoadingOverlay(storage: storage)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .id(settings.language)
        .preferredColorScheme(settings.theme.colorScheme)
        .alert(L("error"), isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button(L("ok")) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }

    }
}

import SwiftUI
import AppKit
import CascBridge

struct OnlineStorageView: View {
    @StateObject private var service = CDNProductService()
    @State private var loadTask: Task<Void, Never>? = nil
    var onOpen: (String, String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Title
            Text(L("open_online_storage"))
                .font(.headline)
                .padding(.top, 16)
                .padding(.bottom, 12)

            // Product table
            productTable
                .frame(height: 360)
                .padding(.horizontal, 16)

            // Bottom controls
            VStack(alignment: .leading, spacing: 12) {
                // Region picker
                HStack {
                    Text(L("region") + ":")
                        .frame(width: 50, alignment: .trailing)

                    Picker("", selection: $service.selectedRegion) {
                        if service.selectedProduct == nil || service.selectedProduct?.regions.isEmpty == true {
                            Text(L("no_regions_available")).tag("")
                        } else {
                            ForEach(service.selectedProduct?.regions ?? [], id: \.self) { region in
                                Text(region.uppercased()).tag(region)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(service.selectedProduct?.regions.isEmpty != false)
                }

                // Cache path
                HStack {
                    Text(L("cache_path") + ":")
                        .frame(width: 50, alignment: .trailing)

                    TextField(L("cache_path_placeholder"), text: $service.cachePath)
                        .textFieldStyle(.roundedBorder)

                    Button("...") {
                        browseCachePath()
                    }
                    .frame(width: 32)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Button bar
            HStack(spacing: 12) {
                Button(L("reload_all")) {
                    CascBridge.CascStorageHandle.setFetchCancellationFlag(true)
                    loadTask?.cancel()
                    loadTask = Task {
                        await service.loadRegions()
                    }
                }
                .disabled(service.isLoading)

                Button(L("reload_selected")) {
                    Task {
                        await service.reloadSelectedProduct()
                    }
                }
                .disabled(service.selectedProduct == nil)

                Spacer()

                Button(L("cancel")) {
                    CascBridge.CascStorageHandle.setFetchCancellationFlag(true)
                    loadTask?.cancel()
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(L("open")) {
                    CascBridge.CascStorageHandle.setFetchCancellationFlag(true)
                    loadTask?.cancel()
                    service.saveCachePath()
                    if let product = service.selectedProduct, !service.selectedRegion.isEmpty {
                        onOpen(product.code, service.selectedRegion)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(service.selectedProduct == nil || service.selectedRegion.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 720, height: 540)
        .onAppear {
            // Only auto-load on first open when no cached regions exist.
            // Otherwise show cached data and let user decide when to reload.
            if !service.hasCachedRegions {
                loadTask = Task {
                    await service.loadRegions()
                }
            }
        }
        .onDisappear {
            CascBridge.CascStorageHandle.setFetchCancellationFlag(true)
            loadTask?.cancel()
            loadTask = nil
        }
    }

    @ViewBuilder
    private var productTable: some View {
        Table(service.products, selection: Binding(
            get: { service.selectedProduct?.id },
            set: { newId in
                if let id = newId, let product = service.products.first(where: { $0.id == id }) {
                    service.selectProduct(product)
                }
            }
        )) {
            TableColumn(L("product_name")) { product in
                Text(product.name)
                    .foregroundColor(product.regions.isEmpty ? .secondary : .primary)
            }
            .width(min: 180, ideal: 250)

            TableColumn(L("product_code")) { product in
                Text(product.code)
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 100, ideal: 120)

            TableColumn(L("regions")) { product in
                if product.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else if product.loadFailed {
                    Text(L("regions_unavailable"))
                        .foregroundColor(.red)
                } else if product.regions.isEmpty {
                    Text("")
                } else {
                    Text(product.regions.joined(separator: " ").uppercased())
                        .lineLimit(1)
                }
            }
            .width(min: 120, ideal: 200)
        }
        .tableStyle(.bordered)
    }

    private func browseCachePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("choose")
        if !service.cachePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: service.cachePath)
        }
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { result in
            if result == .OK, let url = panel.url {
                Task { @MainActor in
                    self.service.cachePath = url.path
                }
            }
        }
    }
}

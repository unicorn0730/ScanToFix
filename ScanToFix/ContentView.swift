//
//  ContentView.swift
//  ScanToFix
//
//  Created by 전장우 on 2/11/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum Screen {
        case start
        case scanner
        case preview
    }

    @State private var screen: Screen = .start
    @StateObject private var lidarManager = LidarScanManager()
    @State private var capturedMesh: ScannedMesh?
    @State private var repairPatch: RepairPatchResult?
    @State private var selectedVersion: RepairVersion = .v1
    @State private var showExportFormatOptions = false
    @State private var showFileExporter = false
    @State private var latestShareURL: URL?
    @State private var exportDocument = MeshFileDocument(data: Data())
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "ScanToFix"
    @State private var alertMessage: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.97, blue: 1.0), Color.white],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            switch screen {
            case .start:
                startScreen
            case .scanner:
                scannerScreen
            case .preview:
                previewScreen
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: screen)
        .onChange(of: selectedVersion) { _, _ in
            regeneratePatch(showError: false)
        }
        .confirmationDialog("Choose Export Format", isPresented: $showExportFormatOptions, titleVisibility: .visible) {
            Button("STL") {
                exportMesh(.stl)
            }
            Button("USDZ") {
                exportMesh(.usdz)
            }
            Button("Cancel", role: .cancel) {}
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                alertMessage = "Export failed: \(error.localizedDescription)"
            }
        }
        .alert(
            "Scan to Fix",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        alertMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var startScreen: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 18)

            VStack(spacing: 8) {
                Text("Scan to Fix")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                Text("Scan damaged objects with LiDAR and rebuild missing parts for 3D printing.")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.88, green: 0.94, blue: 1.0), Color(red: 0.83, green: 0.9, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    ZStack {
                        Circle()
                            .stroke(Color(red: 0.29, green: 0.58, blue: 0.9).opacity(0.35), lineWidth: 2)
                            .frame(width: 160, height: 160)
                        Image(systemName: "gearshape.2.fill")
                            .font(.system(size: 78))
                            .foregroundStyle(Color(red: 0.2, green: 0.53, blue: 0.9))
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color(red: 0.2, green: 0.53, blue: 0.9), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                            .frame(width: 210, height: 130)
                    }
                }
                .frame(height: 250)
                .padding(.horizontal, 20)

            Spacer()

            StartButton(title: "Start Scan") {
                capturedMesh = nil
                repairPatch = nil
                latestShareURL = nil
                withAnimation {
                    screen = .scanner
                }
            }
            .padding(.horizontal, 20)

            Text(lidarManager.isSupported ? "Requires iPhone Pro with LiDAR" : "LiDAR unavailable on this device.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scannerScreen: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.33, green: 0.36, blue: 0.4), Color(red: 0.18, green: 0.19, blue: 0.22)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer(minLength: 8)

                Text("Align object inside frame")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))

                ZStack {
                    LidarScannerView(manager: lidarManager)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                    ScannerFrame()

                    if !lidarManager.isSupported {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                            .overlay {
                                Text("LiDAR scanning requires an iPhone Pro device.")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 18)
                            }
                    }
                }
                .frame(height: 390)
                .padding(.horizontal, 20)

                VStack(spacing: 16) {
                    ProgressBar(value: lidarManager.progress)

                    HStack {
                        Button("Cancel") {
                            cancelScan()
                        }
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))

                        Spacer()

                        DoneButton(isEnabled: lidarManager.isSupported && lidarManager.progress >= 0.2) {
                            finishScan()
                        }
                    }
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 20)

                Text(lidarManager.statusMessage)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.bottom, 8)
            }
            .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            lidarManager.startScanning()
        }
        .onDisappear {
            lidarManager.stopScanning()
        }
    }

    private var previewScreen: some View {
        VStack(spacing: 16) {
            Text("Repair Patch Preview")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.top, 12)

            FilePreviewCard(
                note: selectedVersion.note,
                detail: patchDetailText()
            )
                .padding(.horizontal, 20)

            VStack(alignment: .leading, spacing: 10) {
                Text("Patch Profiles")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                HStack(spacing: 10) {
                    ForEach(RepairVersion.allCases) { version in
                        Button(version.rawValue) {
                            selectedVersion = version
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(selectedVersion == version ? .white : .black.opacity(0.7))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedVersion == version ? Color.blue : Color.white)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)

            ExportButton(title: "Export Repair Patch") {
                showExportFormatOptions = true
            }
            .padding(.horizontal, 20)
            .opacity(repairPatch == nil ? 0.6 : 1.0)
            .disabled(repairPatch == nil)

            Button("Find a local 3D printer") {
                openLocalPrinterSearch()
            }
            .font(.system(size: 18, weight: .medium, design: .rounded))
            .foregroundStyle(Color(red: 0.11, green: 0.47, blue: 0.88))

            if let latestShareURL {
                ShareLink(item: latestShareURL) {
                    Label("Share Last Export", systemImage: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
            }

            Button("Scan Another Object") {
                capturedMesh = nil
                repairPatch = nil
                withAnimation {
                    screen = .start
                }
            }
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishScan() {
        guard lidarManager.isSupported else {
            alertMessage = "This device does not support LiDAR mesh reconstruction."
            return
        }
        guard let mesh = lidarManager.finalizeScan() else {
            alertMessage = "No mesh captured yet. Keep scanning from a few more angles and try again."
            return
        }
        capturedMesh = mesh
        guard regeneratePatch(showError: true) else {
            return
        }
        withAnimation {
            screen = .preview
        }
    }

    private func cancelScan() {
        lidarManager.stopScanning()
        capturedMesh = nil
        repairPatch = nil
        withAnimation {
            screen = .start
        }
    }

    private func exportMesh(_ format: MeshExportFormat) {
        guard let repairPatch else {
            alertMessage = "No repair patch is available to export."
            return
        }

        do {
            let package = try MeshExporter.makePackage(from: repairPatch.patchMesh, version: selectedVersion, format: format)
            exportDocument = MeshFileDocument(data: package.data)
            exportContentType = format.contentType
            exportFilename = package.fileName
            latestShareURL = package.temporaryURL
            showFileExporter = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func patchDetailText() -> String {
        guard let repairPatch else {
            return "No repair patch generated yet."
        }

        let patchMesh = repairPatch.patchMesh
        let perimeterMM = Int((repairPatch.boundaryPerimeter * 1000).rounded())
        return "\(patchMesh.vertexCount) vertices • \(patchMesh.faceCount) triangles • boundary \(perimeterMM) mm • loops \(repairPatch.detectedBoundaryCount)"
    }

    @discardableResult
    private func regeneratePatch(showError: Bool) -> Bool {
        guard let capturedMesh else {
            repairPatch = nil
            return false
        }

        do {
            repairPatch = try RepairPatchGenerator.generate(from: capturedMesh, version: selectedVersion)
            return true
        } catch {
            repairPatch = nil
            if showError {
                alertMessage = error.localizedDescription
            }
            return false
        }
    }

    private func openLocalPrinterSearch() {
        guard let url = URL(string: "http://maps.apple.com/?q=3D+printing+service") else {
            return
        }
        openURL(url)
    }
}

private struct StartButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.2, green: 0.55, blue: 0.95), Color(red: 0.1, green: 0.42, blue: 0.86)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct ScannerFrame: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .stroke(Color(red: 0.48, green: 0.77, blue: 1.0), lineWidth: 5)
            .padding(14)
    }
}

private struct ProgressBar: View {
    let value: Double

    private var normalizedValue: Double {
        min(max(value, 0), 1)
    }

    private var displayPercent: Int {
        if normalizedValue == 0 {
            return 0
        }
        return max(1, Int((normalizedValue * 100).rounded()))
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.4))
                    Capsule()
                        .fill(Color(red: 0.14, green: 0.56, blue: 0.96))
                        .frame(width: proxy.size.width * normalizedValue)
                }
            }
            .frame(height: 10)

            Text("\(displayPercent)% Scanning Progress")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
    }
}

private struct DoneButton: View {
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Done")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 112)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            isEnabled
                            ? LinearGradient(
                                colors: [Color(red: 0.24, green: 0.61, blue: 0.98), Color(red: 0.16, green: 0.49, blue: 0.94)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            : LinearGradient(
                                colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.5)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct FilePreviewCard: View {
    let note: String
    let detail: String

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.white.opacity(0.95))
            .overlay {
                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white, Color(red: 0.85, green: 0.87, blue: 0.9)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 210, height: 210)
                            .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)

                        Image(systemName: "cup.and.saucer.fill")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120)
                            .foregroundStyle(Color(red: 0.72, green: 0.74, blue: 0.77))
                    }

                    Text(note)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)

                    Text(detail)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.16, green: 0.43, blue: 0.73))
                        .padding(.horizontal, 14)

                    HStack {
                        Text("Drag to rotate")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 20)
            }
            .frame(height: 380)
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

private struct ExportButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.22, green: 0.58, blue: 0.98), Color(red: 0.1, green: 0.44, blue: 0.9)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}

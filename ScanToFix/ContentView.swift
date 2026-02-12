//
//  ContentView.swift
//  ScanToFix
//
//  Created by 전장우 on 2/11/26.
//

import SceneKit
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#endif

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
    @State private var boundaryCandidates: [RepairBoundaryCandidate] = []
    @State private var selectedBoundaryCandidateID: String?
    @State private var isBoundaryConfirmed = false
    @State private var selectedVersion: RepairVersion = .v1
    @State private var showExportFormatOptions = false
    @State private var showFileExporter = false
    @State private var latestShareURL: URL?
    @State private var exportDocument = MeshFileDocument(data: Data())
    @State private var exportContentType: UTType = .data
    @State private var exportFilename = "ScanToFix"
    @State private var alertMessage: String?
    @State private var backgroundDrift = false
    @State private var startIntroActive = false
    @State private var scannerIntroActive = false
    @State private var previewIntroActive = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            appBackground

            switch screen {
            case .start:
                startScreen
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            case .scanner:
                scannerScreen
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            case .preview:
                previewScreen
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.snappy(duration: 0.42, extraBounce: 0.08), value: screen)
        .onChange(of: selectedVersion) { _, _ in
            regeneratePatch(showError: false)
        }
        .onChange(of: selectedBoundaryCandidateID) { _, _ in
            isBoundaryConfirmed = false
            regeneratePatch(showError: false)
        }
        .onAppear {
            backgroundDrift = true
        }
        .confirmationDialog(
            "Choose Export Format",
            isPresented: $showExportFormatOptions,
            titleVisibility: .visible
        ) {
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

    private var appBackground: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.95, green: 0.97, blue: 1.0), Color.white],
                startPoint: .top,
                endPoint: .bottom
            )

            Circle()
                .fill(Color(red: 0.4, green: 0.72, blue: 1.0).opacity(0.22))
                .frame(width: 460, height: 460)
                .blur(radius: 80)
                .offset(x: backgroundDrift ? 120 : -140, y: backgroundDrift ? -240 : -150)
                .animation(.easeInOut(duration: 7).repeatForever(autoreverses: true), value: backgroundDrift)
        }
        .ignoresSafeArea()
    }

    private var startScreen: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 20)

            VStack(spacing: 8) {
                Text("Scan to Fix")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                Text("Scan damaged objects with LiDAR and rebuild missing parts for 3D printing.")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.black.opacity(0.74))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .opacity(startIntroActive ? 1 : 0)
            .offset(y: startIntroActive ? 0 : 18)

            StartIllustrationCard()
                .padding(.horizontal, 20)
                .opacity(startIntroActive ? 1 : 0)
                .scaleEffect(startIntroActive ? 1 : 0.96)
                .offset(y: startIntroActive ? 0 : 22)

            Spacer()

            StartButton(title: "Start Scan") {
                capturedMesh = nil
                repairPatch = nil
                boundaryCandidates = []
                selectedBoundaryCandidateID = nil
                isBoundaryConfirmed = false
                latestShareURL = nil
                withAnimation {
                    screen = .scanner
                }
            }
            .padding(.horizontal, 20)
            .opacity(startIntroActive ? 1 : 0)
            .offset(y: startIntroActive ? 0 : 18)

            Text(lidarManager.isSupported ? "Requires iPhone Pro with LiDAR" : "LiDAR unavailable on this device.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
                .opacity(startIntroActive ? 1 : 0)
        }
        .padding(.top, 14)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                startIntroActive = true
            }
        }
        .onDisappear {
            startIntroActive = false
        }
    }

    private var scannerScreen: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.35, green: 0.38, blue: 0.42), Color(red: 0.19, green: 0.2, blue: 0.24)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                Spacer(minLength: 8)

                Text("Align object inside frame")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .opacity(scannerIntroActive ? 1 : 0)
                    .offset(y: scannerIntroActive ? 0 : 10)

                ZStack {
                    LidarScannerView(manager: lidarManager)
                        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

                    ScannerFrame()

                    if lidarManager.isSupported {
                        LiveObjectOverlay(state: lidarManager.liveOverlayState)
                    }

                    if !lidarManager.isSupported {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .fill(Color.black.opacity(0.48))
                            .overlay {
                                Text("LiDAR scanning requires an iPhone Pro device.")
                                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 22)
                            }
                    }
                }
                .frame(height: 405)
                .padding(.horizontal, 20)
                .scaleEffect(scannerIntroActive ? 1 : 0.98)
                .opacity(scannerIntroActive ? 1 : 0)
                .offset(y: scannerIntroActive ? 0 : 18)

                VStack(spacing: 14) {
                    ProgressBar(value: lidarManager.qualityProgress)

                    HStack {
                        Button("Cancel") {
                            cancelScan()
                        }
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .buttonStyle(FluidPressButtonStyle(pressedScale: 0.97, pressedOpacity: 0.84))

                        Spacer()

                        DoneButton(isEnabled: lidarManager.isSupported && lidarManager.canFinalizeScan) {
                            finishScan()
                        }
                    }
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.horizontal, 20)
                .opacity(scannerIntroActive ? 1 : 0)
                .offset(y: scannerIntroActive ? 0 : 14)

                Text(lidarManager.statusMessage)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.84))
                    .padding(.bottom, 10)
                    .opacity(scannerIntroActive ? 1 : 0)
            }
            .padding(.top, 14)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.4)) {
                scannerIntroActive = true
            }
            lidarManager.startScanning()
        }
        .onDisappear {
            scannerIntroActive = false
            lidarManager.stopScanning()
        }
    }

    private var previewScreen: some View {
        VStack(spacing: 16) {
            Text("3D Preview")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
                .padding(.top, 10)
                .opacity(previewIntroActive ? 1 : 0)
                .offset(y: previewIntroActive ? 0 : 10)

            ThreeDFilePreview(
                mesh: repairPatch?.patchMesh ?? capturedMesh,
                note: selectedVersion.note,
                detail: patchDetailText()
            )
            .padding(.horizontal, 20)
            .opacity(previewIntroActive ? 1 : 0)
            .scaleEffect(previewIntroActive ? 1 : 0.98)
            .offset(y: previewIntroActive ? 0 : 14)

            VStack(alignment: .leading, spacing: 8) {
                Text("Versions")
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)

                HStack(spacing: 8) {
                    ForEach(RepairVersion.allCases) { version in
                        Button(version.rawValue) {
                            selectedVersion = version
                        }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(selectedVersion == version ? .white : .black.opacity(0.75))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(selectedVersion == version ? Color.blue : Color.white)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        }
                        .buttonStyle(FluidPressButtonStyle(pressedScale: 0.95, pressedOpacity: 0.9))
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(0.9))
                )
                .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: selectedVersion)
            }
            .padding(.horizontal, 20)
            .opacity(previewIntroActive ? 1 : 0)
            .offset(y: previewIntroActive ? 0 : 14)

            BoundarySelectionCard(
                candidates: boundaryCandidates,
                selectedCandidateID: $selectedBoundaryCandidateID,
                isBoundaryConfirmed: isBoundaryConfirmed,
                confirmAction: confirmSelectedBoundary
            )
            .padding(.horizontal, 20)
            .opacity(previewIntroActive ? 1 : 0)
            .offset(y: previewIntroActive ? 0 : 14)

            ExportButton(title: "Export 3D File") {
                showExportFormatOptions = true
            }
            .padding(.horizontal, 20)
            .opacity(exportableMesh == nil ? 0.68 : 1.0)
            .disabled(exportableMesh == nil)
            .opacity(previewIntroActive ? 1 : 0)
            .offset(y: previewIntroActive ? 0 : 14)

            if !isBoundaryConfirmed {
                Text("Confirm fracture boundary to unlock export.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.72, green: 0.5, blue: 0.15))
                    .opacity(previewIntroActive ? 1 : 0)
                    .offset(y: previewIntroActive ? 0 : 14)
            }

            Button("Find a local 3D printer") {
                openLocalPrinterSearch()
            }
            .font(.system(size: 19, weight: .medium, design: .rounded))
            .foregroundStyle(Color(red: 0.11, green: 0.47, blue: 0.88))
            .buttonStyle(FluidPressButtonStyle(pressedScale: 0.97, pressedOpacity: 0.86))
            .opacity(previewIntroActive ? 1 : 0)
            .offset(y: previewIntroActive ? 0 : 14)

            if let latestShareURL {
                ShareLink(item: latestShareURL) {
                    Label("Share last export", systemImage: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                .opacity(previewIntroActive ? 1 : 0)
                .offset(y: previewIntroActive ? 0 : 14)
            }

            Button("Scan another object") {
                capturedMesh = nil
                repairPatch = nil
                boundaryCandidates = []
                selectedBoundaryCandidateID = nil
                isBoundaryConfirmed = false
                withAnimation {
                    screen = .start
                }
            }
            .font(.system(size: 16, weight: .semibold, design: .rounded))
            .padding(.top, 2)
            .buttonStyle(FluidPressButtonStyle(pressedScale: 0.97, pressedOpacity: 0.86))
            .opacity(previewIntroActive ? 1 : 0)
            .offset(y: previewIntroActive ? 0 : 14)

            Spacer()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                previewIntroActive = true
            }
        }
        .onDisappear {
            previewIntroActive = false
        }
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
        boundaryCandidates = RepairPatchGenerator.detectBoundaryCandidates(from: mesh)
        selectedBoundaryCandidateID = nil
        isBoundaryConfirmed = false

        guard !boundaryCandidates.isEmpty else {
            repairPatch = nil
            alertMessage = RepairPatchGenerationError.noRepairBoundaryFound.localizedDescription
            return
        }

        if let topCandidate = boundaryCandidates.first, topCandidate.confidence >= 0.45 {
            selectedBoundaryCandidateID = topCandidate.id
            _ = regeneratePatch(showError: true)
        } else {
            repairPatch = nil
        }

        withAnimation {
            screen = .preview
        }
    }

    private func cancelScan() {
        lidarManager.stopScanning()
        capturedMesh = nil
        repairPatch = nil
        boundaryCandidates = []
        selectedBoundaryCandidateID = nil
        isBoundaryConfirmed = false
        withAnimation {
            screen = .start
        }
    }

    private func exportMesh(_ format: MeshExportFormat) {
        guard let mesh = exportableMesh else {
            alertMessage = "Confirm a fracture boundary before exporting the repair mesh."
            return
        }

        do {
            let package = try MeshExporter.makePackage(
                from: mesh,
                version: selectedVersion,
                format: format
            )
            exportDocument = MeshFileDocument(data: package.data)
            exportContentType = format.contentType
            exportFilename = package.fileName
            latestShareURL = package.temporaryURL
            showFileExporter = true
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private var exportableMesh: ScannedMesh? {
        guard isBoundaryConfirmed else {
            return nil
        }
        return repairPatch?.patchMesh
    }

    private var selectedBoundaryCandidate: RepairBoundaryCandidate? {
        guard let selectedBoundaryCandidateID else {
            return nil
        }
        return boundaryCandidates.first { $0.id == selectedBoundaryCandidateID }
    }

    private func patchDetailText() -> String {
        guard let repairPatch else {
            if let capturedMesh {
                return "Scan mesh: \(capturedMesh.vertexCount) vertices • \(capturedMesh.faceCount) triangles. Select and confirm a fracture boundary."
            }
            return "No repair patch generated yet."
        }

        let patchMesh = repairPatch.patchMesh
        let perimeterMM = Int((repairPatch.boundaryPerimeter * 1000).rounded())
        let confirmationTag = isBoundaryConfirmed ? "confirmed" : "not confirmed"
        return "\(patchMesh.vertexCount) vertices • \(patchMesh.faceCount) triangles • boundary \(perimeterMM) mm • candidates \(boundaryCandidates.count) • \(confirmationTag)"
    }

    @discardableResult
    private func regeneratePatch(showError: Bool) -> Bool {
        guard let capturedMesh, let selectedBoundaryCandidate else {
            repairPatch = nil
            return false
        }

        do {
            repairPatch = try RepairPatchGenerator.generate(
                from: capturedMesh,
                version: selectedVersion,
                candidate: selectedBoundaryCandidate
            )
            return true
        } catch {
            repairPatch = nil
            if showError {
                alertMessage = error.localizedDescription
            }
            return false
        }
    }

    private func confirmSelectedBoundary() {
        guard selectedBoundaryCandidate != nil else {
            alertMessage = "Select a fracture boundary candidate first."
            return
        }

        guard regeneratePatch(showError: true), repairPatch != nil else {
            alertMessage = "Could not generate a repair patch from this boundary. Try another candidate or rescan."
            return
        }

        isBoundaryConfirmed = true
    }

    private func openLocalPrinterSearch() {
        guard let url = URL(string: "http://maps.apple.com/?q=3D+printing+service") else {
            return
        }
        openURL(url)
    }
}

private struct StartIllustrationCard: View {
    @State private var floatActive = false

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.86, green: 0.92, blue: 1.0), Color(red: 0.82, green: 0.9, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                ZStack {
                    Circle()
                        .stroke(Color(red: 0.28, green: 0.56, blue: 0.9).opacity(0.32), lineWidth: 2)
                        .frame(width: 164, height: 164)

                    Image(systemName: "gearshape.2.fill")
                        .font(.system(size: 78))
                        .foregroundStyle(Color(red: 0.22, green: 0.52, blue: 0.9))

                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            Color(red: 0.22, green: 0.52, blue: 0.9),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 7])
                        )
                        .frame(width: 212, height: 132)
                }
            }
            .frame(height: 250)
            .offset(y: floatActive ? -4 : 4)
            .scaleEffect(floatActive ? 1.01 : 0.99)
            .animation(.easeInOut(duration: 2.8).repeatForever(autoreverses: true), value: floatActive)
            .onAppear {
                floatActive = true
            }
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
                                colors: [Color(red: 0.2, green: 0.56, blue: 0.96), Color(red: 0.1, green: 0.43, blue: 0.87)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
        }
        .buttonStyle(FluidPressButtonStyle(pressedScale: 0.98, pressedOpacity: 0.88))
    }
}

private enum ScannerCornerPosition {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

private struct ScannerCorner: View {
    let position: ScannerCornerPosition
    let length: CGFloat

    var body: some View {
        Path { path in
            switch position {
            case .topLeft:
                path.move(to: CGPoint(x: length, y: 0))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: length))
            case .topRight:
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: length, y: 0))
                path.addLine(to: CGPoint(x: length, y: length))
            case .bottomLeft:
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: length))
                path.addLine(to: CGPoint(x: length, y: length))
            case .bottomRight:
                path.move(to: CGPoint(x: length, y: 0))
                path.addLine(to: CGPoint(x: length, y: length))
                path.addLine(to: CGPoint(x: 0, y: length))
            }
        }
        .stroke(
            Color(red: 0.56, green: 0.82, blue: 1.0),
            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        )
        .frame(width: length, height: length)
    }
}

private struct ScannerFrame: View {
    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = 16
            let cornerLength = min(proxy.size.width, proxy.size.height) * 0.19

            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(Color(red: 0.56, green: 0.82, blue: 1.0).opacity(0.35), lineWidth: 2)
                    .padding(inset)

                VStack {
                    HStack {
                        ScannerCorner(position: .topLeft, length: cornerLength)
                        Spacer()
                        ScannerCorner(position: .topRight, length: cornerLength)
                    }
                    Spacer()
                    HStack {
                        ScannerCorner(position: .bottomLeft, length: cornerLength)
                        Spacer()
                        ScannerCorner(position: .bottomRight, length: cornerLength)
                    }
                }
                .padding(inset + 2)
            }
        }
    }
}

private struct LiveObjectOverlay: View {
    let state: LiveScanOverlayState

    private var accentColor: Color {
        switch state.trackingState {
        case .searching:
            return Color(red: 1.0, green: 0.76, blue: 0.31)
        case .locking, .tracking:
            return Color(red: 0.42, green: 0.84, blue: 1.0)
        case .ready:
            return Color(red: 0.43, green: 0.9, blue: 0.5)
        }
    }

    private var statusTitle: String {
        switch state.trackingState {
        case .searching:
            return "Searching"
        case .locking:
            return "Locking"
        case .tracking:
            return "Tracking"
        case .ready:
            return "Ready"
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let overlayRect = denormalizedRect(in: proxy.size)

            ZStack(alignment: .topLeading) {
                if state.hasTrackedRect {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineJoin: .round))
                        .frame(width: overlayRect.width, height: overlayRect.height)
                        .position(x: overlayRect.midX, y: overlayRect.midY)
                        .shadow(color: accentColor.opacity(0.45), radius: 8, x: 0, y: 0)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                    Text("Lock \(Int((state.lockConfidence * 100).rounded()))% • Coverage \(Int((state.coverage * 100).rounded()))%")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                    Text(String(format: "%.2fm • %,d triangles", state.distanceMeters, state.triangleCount))
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(accentColor.opacity(0.6), lineWidth: 1)
                }
                .padding(12)

                if !state.hasTrackedRect {
                    Text("Center object and move closer")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.35), in: Capsule())
                        .position(x: proxy.size.width * 0.5, y: proxy.size.height * 0.78)
                }
            }
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func denormalizedRect(in size: CGSize) -> CGRect {
        CGRect(
            x: state.normalizedRect.minX * size.width,
            y: state.normalizedRect.minY * size.height,
            width: state.normalizedRect.width * size.width,
            height: state.normalizedRect.height * size.height
        )
    }
}

private struct BoundarySelectionCard: View {
    let candidates: [RepairBoundaryCandidate]
    @Binding var selectedCandidateID: String?
    let isBoundaryConfirmed: Bool
    let confirmAction: () -> Void

    private var selectedCandidate: RepairBoundaryCandidate? {
        guard let selectedCandidateID else {
            return nil
        }
        return candidates.first { $0.id == selectedCandidateID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fracture Boundary")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(.black)

            if candidates.isEmpty {
                Text("No fracture boundary candidates detected. Rescan the broken edge more closely.")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        let isSelected = selectedCandidateID == candidate.id
                        Button {
                            selectedCandidateID = candidate.id
                        } label: {
                            VStack(spacing: 3) {
                                Text("Loop \(index + 1)")
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                Text("\(Int((candidate.perimeter * 1000).rounded()))mm • \(Int((candidate.confidence * 100).rounded()))%")
                                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                            }
                            .foregroundStyle(isSelected ? .white : .black.opacity(0.8))
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(isSelected ? Color.blue : Color.white)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
                            }
                        }
                        .buttonStyle(FluidPressButtonStyle(pressedScale: 0.96, pressedOpacity: 0.88))
                    }
                }
            }

            Button(isBoundaryConfirmed ? "Boundary Confirmed" : "Confirm Boundary") {
                confirmAction()
            }
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isBoundaryConfirmed ? Color(red: 0.2, green: 0.66, blue: 0.4) : Color(red: 0.16, green: 0.52, blue: 0.92))
            )
            .buttonStyle(FluidPressButtonStyle(pressedScale: 0.97, pressedOpacity: 0.88))
            .disabled(selectedCandidate == nil || candidates.isEmpty)
            .opacity((selectedCandidate == nil || candidates.isEmpty) ? 0.6 : 1.0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.92))
        )
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
                        .fill(Color.white.opacity(0.45))
                    Capsule()
                        .fill(Color(red: 0.15, green: 0.57, blue: 0.97))
                        .frame(width: proxy.size.width * normalizedValue)
                        .animation(.easeOut(duration: 0.24), value: normalizedValue)
                }
            }
            .frame(height: 10)

            Text("\(displayPercent)% Scanning Progress")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.97))
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
        .buttonStyle(FluidPressButtonStyle(pressedScale: 0.97, pressedOpacity: 0.88))
        .disabled(!isEnabled)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
    }
}

private struct ThreeDFilePreview: View {
    let mesh: ScannedMesh?
    let note: String
    let detail: String
    @State private var breathing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(Color.white.opacity(0.95))
            .overlay {
                VStack(spacing: 10) {
                    previewCanvas
                        .frame(height: 286)

                    Text(note)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)

                    Text(detail)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 0.16, green: 0.44, blue: 0.74))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10)

                    HStack {
                        Text("Drag to rotate")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)

                    Capsule()
                        .fill(Color.black.opacity(0.15))
                        .frame(width: 34, height: 4)
                        .padding(.top, 2)
                }
                .padding(14)
            }
            .frame(height: 420)
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
            .scaleEffect(breathing ? 1 : 0.992)
            .animation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true), value: breathing)
            .onAppear {
                breathing = true
            }
    }

    @ViewBuilder
    private var previewCanvas: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.95, green: 0.96, blue: 0.97), Color(red: 0.89, green: 0.9, blue: 0.92)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                if let mesh, !mesh.isEmpty {
                    SceneView(
                        scene: MeshSceneBuilder.makeScene(from: mesh),
                        pointOfView: nil,
                        options: [.allowsCameraControl, .autoenablesDefaultLighting]
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "cube.transparent")
                            .font(.system(size: 54))
                            .foregroundStyle(Color.black.opacity(0.35))
                        Text("Complete scanning to preview the 3D file.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
    }
}

private enum MeshSceneBuilder {
    static func makeScene(from mesh: ScannedMesh) -> SCNScene {
        let scene = SCNScene()
        guard !mesh.isEmpty else {
            return scene
        }

        let vertices = mesh.vertices.map { vertex in
            SCNVector3(vertex.x, vertex.y, vertex.z)
        }
        let vertexSource = SCNGeometrySource(vertices: vertices)
        let indexData = mesh.faces.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: mesh.faceCount,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        #if os(iOS)
        material.diffuse.contents = UIColor(white: 0.96, alpha: 1)
        material.specular.contents = UIColor(white: 0.62, alpha: 1)
        #else
        material.diffuse.contents = NSColor(white: 0.96, alpha: 1)
        material.specular.contents = NSColor(white: 0.62, alpha: 1)
        #endif
        material.roughness.contents = 0.42
        material.metalness.contents = 0.04
        material.isDoubleSided = true
        geometry.materials = [material]

        let meshNode = SCNNode(geometry: geometry)
        let (minBounds, maxBounds) = geometry.boundingBox
        let center = SIMD3<Float>(
            (minBounds.x + maxBounds.x) * 0.5,
            (minBounds.y + maxBounds.y) * 0.5,
            (minBounds.z + maxBounds.z) * 0.5
        )
        let size = SIMD3<Float>(
            maxBounds.x - minBounds.x,
            maxBounds.y - minBounds.y,
            maxBounds.z - minBounds.z
        )
        let longest = max(size.x, max(size.y, size.z))
        let scale: Float = longest > 0 ? 0.2 / longest : 1

        meshNode.scale = SCNVector3(scale, scale, scale)
        meshNode.position = SCNVector3(
            -center.x * scale,
            -center.y * scale,
            -center.z * scale
        )
        scene.rootNode.addChildNode(meshNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 42
        cameraNode.position = SCNVector3(0, 0, 0.33)
        scene.rootNode.addChildNode(cameraNode)

        let keyLightNode = SCNNode()
        keyLightNode.light = SCNLight()
        keyLightNode.light?.type = .omni
        keyLightNode.light?.intensity = 900
        keyLightNode.position = SCNVector3(0.2, 0.22, 0.45)
        scene.rootNode.addChildNode(keyLightNode)

        let fillLightNode = SCNNode()
        fillLightNode.light = SCNLight()
        fillLightNode.light?.type = .ambient
        fillLightNode.light?.intensity = 460
        scene.rootNode.addChildNode(fillLightNode)

        return scene
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
        .buttonStyle(FluidPressButtonStyle(pressedScale: 0.98, pressedOpacity: 0.88))
    }
}

private struct FluidPressButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.97
    var pressedOpacity: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(
                .interactiveSpring(response: 0.22, dampingFraction: 0.72, blendDuration: 0.1),
                value: configuration.isPressed
            )
    }
}

#Preview {
    ContentView()
}

import AVFoundation
import SwiftUI

struct PairingScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (URL) -> Void
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                PairingCameraView { value in
                    guard let url = URL(string: value), PairingPayload(url: url) != nil else {
                        errorMessage = "这不是有效的 Relay 配对二维码。"
                        return
                    }
                    onScan(url)
                    dismiss()
                } onError: { message in
                    errorMessage = message
                }
                .ignoresSafeArea()

                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.9), lineWidth: 2)
                    .frame(width: 246, height: 246)
                    .shadow(color: .black.opacity(0.35), radius: 12)

                VStack {
                    Spacer()
                    Text("对准 Relay Desktop 中的配对二维码")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 42)
                        .background(.black.opacity(0.58))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 38)
                }
            }
            .navigationTitle("扫描配对二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("取消") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .relayDarkNavigationBar()
            .alert("无法扫描", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("关闭", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "请重试。")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

private struct PairingCameraView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> CameraScannerViewController {
        let controller = CameraScannerViewController()
        controller.onScan = onScan
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraScannerViewController, context: Context) {}
}

private final class CameraScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasDeliveredResult = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func configureCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.startSession() : self?.reportPermissionError()
                }
            }
        default:
            reportPermissionError()
        }
    }

    private func startSession() {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            onError?("当前设备没有可用的相机。")
            return
        }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard session.canAddInput(input) else { throw ScannerError.configuration }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { throw ScannerError.configuration }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = view.bounds
            view.layer.insertSublayer(preview, at: 0)
            previewLayer = preview
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
        } catch {
            onError?("相机初始化失败，请稍后重试。")
        }
    }

    private func reportPermissionError() {
        onError?("请在系统设置中允许 Relay 使用相机。")
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDeliveredResult,
              let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = code.stringValue,
              let url = URL(string: value),
              PairingPayload(url: url) != nil else { return }
        hasDeliveredResult = true
        session.stopRunning()
        onScan?(value)
    }

    private enum ScannerError: Error { case configuration }
}

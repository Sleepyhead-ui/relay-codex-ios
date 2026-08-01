import SwiftUI
import UIKit

struct ImagePreviewView: View {
    let preview: ImagePreviewPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var zoomScale: CGFloat = 1
    @State private var showingShare = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomablePreviewImage(image: image, zoomScale: $zoomScale)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("关闭图片预览")

                Spacer()

                Text(preview.path.lastPathComponentForDisplay)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.82))

                Spacer()

                Button { showingShare = true } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("分享图片")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .background(.black.opacity(0.72))
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    guard zoomScale <= 1.01,
                          value.translation.height > 110,
                          abs(value.translation.width) < value.translation.height * 0.7 else { return }
                    dismiss()
                }
        )
        .task(id: preview.url) {
            image = await MessageImageDecoder.image(at: preview.url, maxPixelSize: 4_096)
        }
        .sheet(isPresented: $showingShare) {
            ShareSheet(items: [preview.url])
        }
        .statusBarHidden()
    }
}

private struct ZoomablePreviewImage: UIViewRepresentable {
    let image: UIImage
    @Binding var zoomScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.backgroundColor = .black

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        if context.coordinator.imageView.image !== image {
            context.coordinator.imageView.image = image
            scrollView.setZoomScale(1, animated: false)
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        private var zoomScale: Binding<CGFloat>

        init(zoomScale: Binding<CGFloat>) {
            self.zoomScale = zoomScale
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            zoomScale.wrappedValue = scrollView.zoomScale
        }

        @objc func doubleTapped(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView = recognizer.view as? UIScrollView else { return }
            if scrollView.zoomScale > 1.01 {
                scrollView.setZoomScale(1, animated: true)
                return
            }
            let point = recognizer.location(in: imageView)
            let scale: CGFloat = 2.5
            let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
            scrollView.zoom(to: CGRect(
                x: point.x - size.width / 2,
                y: point.y - size.height / 2,
                width: size.width,
                height: size.height
            ), animated: true)
        }
    }
}

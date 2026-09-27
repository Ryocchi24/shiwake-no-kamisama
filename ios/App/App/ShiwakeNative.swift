import UIKit
import Vision
import VisionKit
import Capacitor

/// アプリの画面（Webアプリ）を表示する画面。独自の機能（ShiwakeNative）をここで登録する
class MainViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        bridge?.registerPluginInstance(ShiwakeNativePlugin())
    }
}

/// Webアプリから呼び出す iPhone 独自の機能
/// - recognizeText: iPhone標準の文字認識（Vision）で画像の文字を読む。端末内で処理し、無料
/// - shareFile: 共有シートでファイルを保存・送信する（「ファイルに保存」など）
/// - scanDocument: iPhone標準の書類スキャンでレシートを撮る（四隅の自動検出・傾き補正・影の除去）
@objc(ShiwakeNativePlugin)
public class ShiwakeNativePlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "ShiwakeNative"
    public let jsName = "ShiwakeNative"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "recognizeText", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "shareFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "scanDocument", returnType: CAPPluginReturnPromise),
    ]

    /// スキャン画面の結果を受け取る係（画面が閉じるまで保持しておく）
    private var scanDelegate: ScanDelegate?

    /// 入力: { image: base64 の JPEG/PNG }
    /// 出力: { items: [{ text, confidence, x, y, w, h }] }
    ///   座標は画像の左上を (0,0)、右下を (1,1) とした割合
    @objc func recognizeText(_ call: CAPPluginCall) {
        guard let base64 = call.getString("image"),
              let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let cgImage = UIImage(data: data)?.cgImage else {
            call.reject("画像を読み込めませんでした")
            return
        }

        let request = VNRecognizeTextRequest { request, error in
            if let error = error {
                call.reject("文字認識に失敗しました: \(error.localizedDescription)")
                return
            }
            let observations = request.results as? [VNRecognizedTextObservation] ?? []
            let width = Double(cgImage.width), height = Double(cgImage.height)
            let items: [[String: Any]] = observations.compactMap { obs in
                guard let top = obs.topCandidates(1).first else { return nil }
                let box = obs.boundingBox // 左下原点なので、左上原点に直して返す
                // 文字の傾き（ラジアン、左上原点・右回りが正）。斜めに撮った写真で行をそろえるのに使う
                let dx = (obs.topRight.x - obs.topLeft.x) * width
                let dy = (obs.topRight.y - obs.topLeft.y) * height
                return [
                    "text": top.string,
                    "confidence": top.confidence,
                    "x": box.minX,
                    "y": 1 - box.maxY,
                    "w": box.width,
                    "h": box.height,
                    "angle": -atan2(dy, dx),
                ]
            }
            call.resolve(["items": items, "width": width, "height": height])
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ja-JP", "en-US"]
        request.usesLanguageCorrection = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                call.reject("文字認識に失敗しました: \(error.localizedDescription)")
            }
        }
    }

    /// 入力: { data: base64, filename: "〜.csv" }
    /// 出力: { completed: 保存・送信したら true、閉じたら false }
    @objc func shareFile(_ call: CAPPluginCall) {
        guard let base64 = call.getString("data"),
              let data = Data(base64Encoded: base64),
              let filename = call.getString("filename") else {
            call.reject("ファイルを作れませんでした")
            return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            call.reject("ファイルを作れませんでした: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let presenter = self?.bridge?.viewController else {
                call.reject("画面を開けませんでした")
                return
            }
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.completionWithItemsHandler = { _, completed, _, _ in
                call.resolve(["completed": completed])
            }
            // iPad では吹き出し形式で表示するため、表示位置の指定が必要
            if let popover = sheet.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            presenter.present(sheet, animated: true)
        }
    }

    /// 出力: { images: [base64 の JPEG, ...] }（1回のスキャンで複数枚撮れる。閉じた場合は空）
    @objc func scanDocument(_ call: CAPPluginCall) {
        guard VNDocumentCameraViewController.isSupported else {
            call.reject("この端末では書類スキャンを使えません")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let presenter = self.bridge?.viewController else {
                call.reject("画面を開けませんでした")
                return
            }
            let scanner = VNDocumentCameraViewController()
            let delegate = ScanDelegate { [weak self] result in
                scanner.dismiss(animated: true)
                self?.scanDelegate = nil
                switch result {
                case .success(let images): call.resolve(["images": images])
                case .failure(let error): call.reject("スキャンに失敗しました: \(error.localizedDescription)")
                }
            }
            self.scanDelegate = delegate
            scanner.delegate = delegate
            presenter.present(scanner, animated: true)
        }
    }
}

/// 書類スキャン画面の結果を、読み取りに十分な大きさの JPEG（base64）にして返す
final class ScanDelegate: NSObject, VNDocumentCameraViewControllerDelegate {
    private let completion: (Result<[String], Error>) -> Void
    /// 読み取り用の画像の長い辺の上限（小さい文字もつぶれない大きさ）
    private let maxSide: CGFloat = 3000

    init(completion: @escaping (Result<[String], Error>) -> Void) {
        self.completion = completion
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
        let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
        DispatchQueue.global(qos: .userInitiated).async {
            let images = pages.compactMap { self.jpegBase64($0) }
            DispatchQueue.main.async { self.completion(.success(images)) }
        }
    }

    func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
        completion(.success([]))
    }

    func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
        completion(.failure(error))
    }

    private func jpegBase64(_ image: UIImage) -> String? {
        let longest = max(image.size.width, image.size.height)
        var target = image
        if longest > maxSide {
            let scale = maxSide / longest
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            target = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        return target.jpegData(compressionQuality: 0.9)?.base64EncodedString()
    }
}

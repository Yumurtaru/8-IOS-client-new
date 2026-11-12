import SwiftUI
import Vision
import VisionKit

/// Сканер штрихкодов на VisionKit (iOS 16). Кнопку показываем только при isAvailable.
enum BarcodeScanner {
    /// Телефон умеет сканировать, камера разрешена и не запрещена родительским контролем.
    /// @MainActor: DataScannerViewController.isSupported/isAvailable изолированы главным потоком (Swift 6 / Xcode 26 —
    /// ошибка сборки из неизолированного контекста). Вызывается из body экрана — он и так на главном потоке.
    @MainActor static var isAvailable: Bool {
        if #available(iOS 16.0, *) {
            return DataScannerViewController.isSupported && DataScannerViewController.isAvailable
        }
        return false
    }
}

/// Экран сканера: камера + подсказка + «Закрыть». Найденный код возвращается через onCode, экран закрывается.
struct BarcodeScannerScreen: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .bottom) {
            if #available(iOS 16.0, *) {
                BarcodeScannerRepresentable(onCode: { code in
                    onCode(code)
                    dismiss()
                })
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            VStack(spacing: 12) {
                Text("Наведите камеру на штрихкод товара")
                    .font(YMFont.callout)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.6), in: Capsule())
                Button("Закрыть") { dismiss() }
                    .font(.custom(YMFont.golosName(.bold), fixedSize: 16))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.6), in: Capsule())
            }
            .padding(.bottom, 36)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

@available(iOS 16.0, *)
private struct BarcodeScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let symbologies: [VNBarcodeSymbology] = [.ean13, .ean8, .upce, .code128, .code39, .itf14]
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: symbologies)],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems { take(item) }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            take(item)
        }

        private func take(_ item: RecognizedItem) {
            guard !done else { return }
            if case .barcode(let code) = item,
               let value = code.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                done = true
                onCode(value)
            }
        }
    }
}

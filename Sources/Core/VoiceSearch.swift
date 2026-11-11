import AVFoundation
import Foundation
import Speech

/// Голосовой ввод для строки поиска: Speech (ru-RU) + AVAudioEngine.
/// Класс намеренно без @MainActor: обработчики микрофона вызываются на служебных потоках,
/// поэтому всё, что меняет состояние экрана, переносится на главную очередь вручную.
final class VoiceSearcher: ObservableObject {
    @Published private(set) var listening = false
    /// Понятное сообщение для человека (нет доступа, нет распознавания). Экран показывает и сбрасывает.
    @Published var message: String?
    /// Распознанный текст получает экран через эту функцию (в том числе частичный).
    var onText: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Номер записи: таймер автоостановки относится к своей записи, а не к следующей.
    private var sessionNo = 0

    /// Нажатие на микрофон: начать или закончить слушать.
    func toggle() {
        if listening { stop() } else { requestAccessAndStart() }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        if listening { listening = false }
    }

    // MARK: - Доступ

    private func requestAccessAndStart() {
        message = nil
        guard recognizer != nil else {
            message = "Голосовой поиск недоступен: русский язык не поддерживается на этом телефоне"
            return
        }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard status == .authorized else {
                    self.message = "Нет доступа к распознаванию речи. Разрешите его в Настройки → Yumurta."
                    return
                }
                self.requestMicrophone()
            }
        }
    }

    private func requestMicrophone() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if granted {
                    self.start()
                } else {
                    self.message = "Нет доступа к микрофону. Разрешите его в Настройки → Yumurta."
                }
            }
        }
    }

    // MARK: - Запись и распознавание

    private func start() {
        guard let recognizer = recognizer, recognizer.isAvailable else {
            message = "Голосовой поиск сейчас недоступен. Попробуйте позже."
            return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
            listening = true
            // Фраза для поиска короткая: сами выключаем микрофон через 12 секунд.
            sessionNo += 1
            let mine = sessionNo
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let self = self, self.listening, self.sessionNo == mine else { return }
                self.stop()
            }

            task = recognizer.recognitionTask(with: req) { [weak self] result, error in
                let text = result?.bestTranscription.formattedString
                let finished = (result?.isFinal ?? false) || error != nil
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if let text = text, !text.isEmpty { self.onText?(text) }
                    if finished { self.stop() }
                }
            }
        } catch {
            stop()
            message = "Не удалось включить микрофон. Попробуйте ещё раз."
        }
    }
}

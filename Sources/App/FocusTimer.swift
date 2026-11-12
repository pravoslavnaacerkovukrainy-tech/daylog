import AppKit
import Combine
import Foundation

@MainActor
final class FocusTimer: ObservableObject {
    enum Phase: String, Codable {
        case focus, shortBreak, longBreak

        var title: String {
            switch self {
            case .focus: return "Фокус"
            case .shortBreak: return "Короткий перерыв"
            case .longBreak: return "Длинный перерыв"
            }
        }

        var duration: TimeInterval {
            switch self {
            case .focus: return 25 * 60
            case .shortBreak: return 5 * 60
            case .longBreak: return 15 * 60
            }
        }
    }

    struct Session: Codable, Equatable {
        var phase: Phase = .focus
        var taskTitle: String?
        var completedFocuses = 0
        var deadline: Date?
        var pausedRemaining: TimeInterval?
    }

    @Published private(set) var session: Session?
    @Published private(set) var secondsRemaining = 0
    @Published private(set) var storageError = false
    private var ticker: AnyCancellable?
    private let fileURL: URL
    private let signal: () -> Void

    init(directory: URL, now: Date = Date(), signal: @escaping () -> Void = { NSSound.beep() }) {
        fileURL = directory.appendingPathComponent("focus-timer.json")
        self.signal = signal
        if let data = try? Data(contentsOf: fileURL) {
            session = try? JSONDecoder().decode(Session.self, from: data)
        }
        refresh(now: now, notify: false)
        watchDeadline()
    }

    var timeText: String {
        String(format: "%02d:%02d", secondsRemaining / 60, secondsRemaining % 60)
    }

    func start(taskTitle: String? = nil, now: Date = Date()) {
        guard session == nil else { return }
        save(Session(taskTitle: taskTitle, deadline: now.addingTimeInterval(Phase.focus.duration)), now: now)
    }

    func pause(now: Date = Date()) {
        refresh(now: now)
        guard var current = session, let deadline = current.deadline else { return }
        current.pausedRemaining = deadline.timeIntervalSince(now)
        current.deadline = nil
        save(current, now: now)
    }

    func resumeOrStartPhase(now: Date = Date()) {
        guard var current = session, current.deadline == nil else { return }
        current.deadline = now.addingTimeInterval(current.pausedRemaining ?? current.phase.duration)
        current.pausedRemaining = nil
        save(current, now: now)
    }

    func stop(now: Date = Date()) {
        save(nil, now: now)
    }

    func refresh(now: Date = Date(), notify: Bool = true) {
        if var current = session, let deadline = current.deadline, deadline <= now {
            switch current.phase {
            case .focus:
                current.completedFocuses = (current.completedFocuses % 4 + 1) % 4
                current.phase = current.completedFocuses == 0 ? .longBreak : .shortBreak
            case .shortBreak, .longBreak:
                current.phase = .focus
            }
            current.deadline = nil
            current.pausedRemaining = nil
            save(current, now: now)
            if notify { signal() }
        } else {
            updateRemaining(now: now)
        }
    }

    private func updateRemaining(now: Date) {
        let remaining = session.map {
            $0.deadline?.timeIntervalSince(now) ?? $0.pausedRemaining ?? $0.phase.duration
        } ?? 0
        let bounded = min(max(remaining, 0), Phase.focus.duration)
        let seconds = Int(ceil(bounded))
        if secondsRemaining != seconds { secondsRemaining = seconds }
    }

    private func watchDeadline() {
        ticker?.cancel()
        ticker = nil
        if session?.deadline != nil {
            ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] now in
                self?.refresh(now: now)
            }
        }
    }

    private func save(_ current: Session?, now: Date) {
        session = current
        updateRemaining(now: now)
        watchDeadline()
        do {
            if let current {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(current).write(to: fileURL, options: .atomic)
            } else {
                do { try FileManager.default.removeItem(at: fileURL) }
                catch let error as CocoaError where error.code == .fileNoSuchFile {}
            }
            storageError = false
        } catch {
            storageError = true
        }
    }
}

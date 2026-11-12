import SwiftUI

struct FocusTimerButton: View {
    @ObservedObject var timer: FocusTimer
    @State private var showControls = false

    var body: some View {
        Button { showControls.toggle() } label: {
            Label(buttonTitle,
                  systemImage: timer.session?.pausedRemaining == nil ? "timer" : "pause.circle")
                .monospacedDigit()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(timer.session == nil ? Theme.quiet : Theme.accent)
        .accessibilityLabel("Таймер помодоро")
        .accessibilityValue(timer.session.map { "\($0.phase.title), \(timer.timeText)" } ?? "Выключен")
        .help("Таймер помодоро")
        .popover(isPresented: $showControls, arrowEdge: .bottom) {
            controls
        }
    }

    private var buttonTitle: String {
        guard let session = timer.session else { return "Фокус" }
        if session.pausedRemaining != nil { return "Пауза \(timer.timeText)" }
        return session.phase == .focus ? timer.timeText : "Перерыв \(timer.timeText)"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(timer.session?.phase.title ?? "Таймер помодоро").font(Theme.groupTitle)
                .accessibilityAddTraits(.isHeader)
            if let session = timer.session {
                if let task = session.taskTitle {
                    Text(task).font(Theme.text).lineLimit(2)
                }
                Text(timer.timeText).font(Theme.display).monospacedDigit()
                    .accessibilityLabel("Осталось \(timer.timeText)")
                HStack {
                    Button("Завершить", action: { timer.stop() })
                    Spacer()
                    if session.deadline != nil {
                        Button("Пауза") { timer.pause() }
                    } else {
                        Button(session.pausedRemaining != nil ? "Продолжить" :
                                session.phase == .focus ? "Начать фокус" : "Начать перерыв") {
                            timer.resumeOrStartPhase()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                    }
                }
            } else {
                Text("25 минут работы и 5 минут перерыва. После четырёх отрезков перерыв длится 15 минут.")
                    .font(Theme.text).foregroundStyle(Theme.quiet)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Начать фокус") { timer.start() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            if timer.storageError {
                Text("Не удалось сохранить состояние таймера.").font(Theme.caption).foregroundStyle(Theme.signal)
            }
        }
        .padding(18)
        .frame(width: 290, alignment: .leading)
    }
}

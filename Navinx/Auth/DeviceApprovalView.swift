import DeviceIdentity
import SwiftUI

/// A server that approves each device (C45): the invite's code, then a waiting screen with four words
/// the person reads to the server's owner, then the app. Shown over everything while
/// `AccountModel.approval` is set. Not in the Flutter app (an approved difference); native parts (D140).
struct DeviceApprovalView: View {
    @Environment(AccountModel.self) private var account
    @Environment(\.scenePhase) private var scenePhase
    @Bindable var flow: DeviceEnrolment
    @FocusState private var focus: Field?

    private enum Field: Hashable { case code, name }

    private var isWaiting: Bool {
        if case .waiting = flow.step { true } else { false }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 56))
                        .foregroundStyle(Palette.accent)
                        .padding(.top, 24)
                    Text("This server approves each device.")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    content
                }
                .frame(maxWidth: 480)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Palette.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { leaveButton }
            }
        }
        // Waiting: asks now and every few seconds; leaving keeps the request, coming back asks again.
        .task(id: isWaiting) {
            if isWaiting { await flow.waitForApproval() }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active, isWaiting { Task { await flow.poll() } }
        }
        .accessibilityIdentifier("deviceApproval")
    }

    @ViewBuilder private var leaveButton: some View {
        if flow.rule == .optional {
            Button("Not Now") { Task { await account.skipApproval() } }
                .accessibilityIdentifier("deviceApprovalNotNow")
        } else {
            Button("Cancel", role: .cancel) { account.cancelApproval() }
                .accessibilityIdentifier("deviceApprovalCancel")
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .checking, .sending, .approved:
            ProgressView().controlSize(.large).padding(.top, 16)
        case .noInvite:
            message("Ask the server's owner for an invite.")
            checkAgainButton("Check Again")
        case .enterCode(let sentTo):
            codeForm(sentTo: sentTo)
        case .waiting(let words):
            waiting(words)
        case .denied:
            message("The server's owner didn't approve this device.")
            Button("Done") { account.cancelApproval() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        case .expired:
            message("This invite has expired. Ask the server's owner for a new one.")
            checkAgainButton("Check Again")
        case .unreachable:
            message("Can't reach the server. Check your connection and try again.")
            checkAgainButton("Try Again")
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    private func checkAgainButton(_ title: String) -> some View {
        Button {
            Task { await flow.checkAgain() }
        } label: {
            Label(title, systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .accessibilityIdentifier("deviceApprovalCheckAgain")
    }

    private func codeForm(sentTo: String?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(sentTo.map { "Enter the code sent to \($0)" } ?? "Enter the code from your invite.")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 6) {
                Text("Code").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                TextField("XXXX-XXXX", text: $flow.code)
                    .font(.title3.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .textContentType(.oneTimeCode)
                    .focused($focus, equals: .code)
                    .submitLabel(.next)
                    .onSubmit { focus = .name }
                    .padding(12)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("deviceApprovalCode")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Device Name").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Device Name", text: $flow.deviceName)
                    .focused($focus, equals: .name)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(12)
                    .background(.fill.tertiary, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("deviceApprovalName")
                // What `EnrollApplication` sends besides the code and the keys (C54, the second App Store check).
                Text("Sent to your server for approval: this name, your iPhone's model and iOS version, the app's version and an ID made for this installation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let notice = flow.notice {
                Label(Self.text(for: notice), systemImage: "exclamationmark.circle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Palette.accentRed)
                    .accessibilityIdentifier("deviceApprovalNotice")
            }
            Button(action: send) {
                Text("Send").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(!flow.canSend)
            .accessibilityIdentifier("deviceApprovalSend")
        }
    }

    private func send() {
        guard flow.canSend else { return }
        focus = nil
        Task { await flow.send() }
    }

    private func waiting(_ words: [String]) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                    Text(word)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(.fill.tertiary, in: .rect(cornerRadius: 20))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("deviceApprovalWords")
            message("Read these words to the server's owner. This screen moves on when they approve.")
            ProgressView()
        }
    }

    static func text(for notice: DeviceEnrolment.Notice) -> String {
        switch notice {
        case .wrongCode(let triesLeft?):
            triesLeft == 1 ? "That code isn't right. 1 try left." : "That code isn't right. \(triesLeft) tries left."
        case .wrongCode(nil): "That code isn't right."
        case .wrongPlace: "This invite can't be used on this network."
        case .notAccepted: "The server didn't take this request. Try again."
        case .unreachable: "Can't reach the server. Try again."
        }
    }
}

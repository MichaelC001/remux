import SwiftUI

struct TerminalPreviewView: View {
    @ObservedObject var session: TerminalPreviewSession
    let terminalTheme: TerminalTheme

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(terminalTheme.terminalSurfaceBackground)
        .preferredColorScheme(terminalTheme.terminalChromeColorScheme)
        .environment(\.ghosttyTerminalChromeStyle, terminalTheme.terminalChromeStyle)
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 16) {
                Button(action: session.close) {
                    Label("Terminal", systemImage: "chevron.left")
                }
                .accessibilityIdentifier("terminal.preview.back")

                Spacer(minLength: 80)

                Button("Refresh", action: session.refresh)
                    .accessibilityIdentifier("terminal.preview.refresh")

                if case .ready(_, let resource) = session.state {
                    if let shareURL = resource.shareURL {
                        ShareLink(item: shareURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share")
                        .accessibilityIdentifier("terminal.preview.share")
                    }
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(terminalTheme.terminalChromeStyle.accent)

            VStack(spacing: 1) {
                Text(session.currentCandidate?.filename ?? "Preview")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(session.serverDisplayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 104)
        }
        .frame(height: 48)
        .padding(.horizontal, 16)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle:
            EmptyView()
        case .loading:
            ProgressView("Opening preview…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("terminal.preview.loading")
        case .ready(_, let resource):
            Group {
                switch resource {
                case .file(let file):
                    GhosttyQuickLookPreview(resource: file)
                case .staticHTML(let html):
                    TerminalPreviewStaticHTMLView(resource: html)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("terminal.preview.content")
        case .failed(_, let message):
            VStack(spacing: 14) {
                Image(systemName: "doc.questionmark")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Preview unavailable")
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry", action: session.refresh)
                    .buttonStyle(.borderedProminent)
                    .tint(terminalTheme.terminalChromeStyle.accent)
                    .accessibilityIdentifier("terminal.preview.retry")
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("terminal.preview.failure")
        }
    }
}

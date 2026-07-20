import SwiftUI

struct TerminalPreviewView: View {
    @ObservedObject var session: TerminalPreviewSession
    let terminalTheme: TerminalTheme

    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(terminalTheme.terminalSurfaceBackground)
                .navigationTitle(session.currentCandidate?.filename ?? "Preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: session.close) {
                            HStack(spacing: 5) {
                                Image(systemName: "chevron.left")
                                    .font(.body.weight(.semibold))
                                Text("Terminal")
                            }
                        }
                        .accessibilityIdentifier("terminal.preview.back")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: session.refresh) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh")
                        .accessibilityIdentifier("terminal.preview.refresh")
                    }
                    if case .ready(_, let resource) = session.state,
                       let shareURL = resource.shareURL {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(item: shareURL) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .accessibilityLabel("Share")
                            .accessibilityIdentifier("terminal.preview.share")
                        }
                    }
                }
                .toolbarBackground(
                    terminalTheme.terminalSurfaceBackground,
                    for: .navigationBar
                )
                .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(.primary)
        .preferredColorScheme(terminalTheme.terminalChromeColorScheme)
        .environment(\.ghosttyTerminalChromeStyle, terminalTheme.terminalChromeStyle)
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
                case .liveWeb(let liveWeb):
                    TerminalPreviewLiveWebView(resource: liveWeb)
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

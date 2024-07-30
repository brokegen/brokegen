import MarkdownUI
import Splash
import SwiftUI

struct TextOutputFormat: OutputFormat {
    private let theme: Splash.Theme

    init(theme: Splash.Theme) {
        self.theme = theme
    }

    func makeBuilder() -> Builder {
        Builder(theme: self.theme)
    }
}

extension TextOutputFormat {
    struct Builder: OutputBuilder {
        private let theme: Splash.Theme
        private var accumulatedText: [Text]

        fileprivate init(theme: Splash.Theme) {
            self.theme = theme
            self.accumulatedText = []
        }

        mutating func addToken(_ token: String, ofType type: TokenType) {
            let color = self.theme.tokenColors[type] ?? self.theme.plainTextColor
            self.accumulatedText.append(Text(token).foregroundColor(.init(color)))
        }

        mutating func addPlainText(_ text: String) {
            self.accumulatedText.append(
                Text(text).foregroundColor(.init(self.theme.plainTextColor))
            )
        }

        mutating func addWhitespace(_ whitespace: String) {
            self.accumulatedText.append(Text(whitespace))
        }

        func build() -> Text {
            self.accumulatedText.reduce(Text(""), +)
        }
    }
}

fileprivate struct SplashCodeSyntaxHighlighter: CodeSyntaxHighlighter {
  private let syntaxHighlighter: SyntaxHighlighter<TextOutputFormat>

  init(theme: Splash.Theme) {
    self.syntaxHighlighter = SyntaxHighlighter(format: TextOutputFormat(theme: theme))
  }

  func highlightCode(_ content: String, language: String?) -> Text {
    guard language != nil else {
      return Text(content)
    }

    return self.syntaxHighlighter.highlight(content)
  }
}

extension CodeSyntaxHighlighter where Self == SplashCodeSyntaxHighlighter {
  static func splash(theme: Splash.Theme) -> Self {
    SplashCodeSyntaxHighlighter(theme: theme)
  }
}

/// Renders a MarkdownUI code block with a non-greedy Divider.
fileprivate struct MVCodeBlock: View {
    let configuration: CodeBlockConfiguration
    let theme: Splash.Theme

    // Set an initial value because we can't figure out the render pass details
    @State var blockWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(configuration.language ?? "plain text")
                    .fontWeight(.semibold)
                    .foregroundColor(Color(theme.plainTextColor))

                Spacer()

                Button(action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(configuration.content, forType: .string)
                }, label: {
                    Image(systemName: "clipboard")
                })
                .background(Color(.clear))
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: blockWidth)

            Divider()
                .frame(maxWidth: blockWidth)

            configuration.label
                .monospaced()
                .padding()
                .markdownMargin(top: .zero, bottom: .em(0.8))
        }
        .overlay {
            // Read the target width of this entire block,
            // so we can apply it to Divider() which is otherwise greedy
            GeometryReader { geometry in
                Spacer()
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            blockWidth = geometry.size.width
                            print("[TRACE] MVCodeBlock width: \(blockWidth)")
                        }
                    }
            }
        }
        .background(Color(theme.backgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct MarkdownView: View {
    @Environment(\.colorScheme) private var colorScheme

    let content: MarkdownContent
    let enableHorizontalScroll: Bool = false
    let messageFontSize: CGFloat

    var body: some View {
        Markdown(content)
            .markdownTextStyle {
                FontSize(messageFontSize * 1.5)
                BackgroundColor(nil)
            }
            .markdownBlockStyle(\.paragraph) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(6)
                // Can't use regular .padding, because the last paragraph will then always have bottom padding.
                    .markdownMargin(top: 0, bottom: messageFontSize * 2.333)
            }
            .markdownBlockStyle(\.listItem) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownMargin(top: messageFontSize * 0.5)
            }
            .markdownBlockStyle(\.blockquote) { configuration in
                HStack(spacing: 0) {
                    RoundedRectangle(cornerRadius: messageFontSize * 0.5)
                        .fill(Color(.disabledControlTextColor))
                        .relativeFrame(width: .em(0.2))
                    configuration.label
                        .relativePadding(.horizontal, length: .em(0.75))
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: messageFontSize * 0.5)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                if enableHorizontalScroll {
                    ScrollView(.horizontal) {
                        MVCodeBlock(configuration: configuration, theme: self.theme)
                    }
                }
                else {
                    MVCodeBlock(configuration: configuration, theme: self.theme)
                }
            }
            .markdownCodeSyntaxHighlighter(.splash(theme: self.theme))
            .textSelection(.enabled)
            .padding(messageFontSize * 4/3)
            .background(
                RoundedRectangle(cornerRadius: messageFontSize, style: .continuous)
                    .fill(Color(.controlBackgroundColor))
            )
    }

    private var theme: Splash.Theme {
        // NOTE: We are ignoring the Splash theme font
        switch self.colorScheme {
        case .dark:
            return .wwdc17(withFont: .init(size: messageFontSize * 1.5))
        default:
            return .sunset(withFont: .init(size: messageFontSize * 1.5))
        }
    }
}


#Preview(traits: .fixedLayout(width: 800, height: 800)) {
    ScrollView {
        MarkdownView(content: MarkdownContent("""
            ```swift
            var body: some View {
              Markdown(self.content)
                .markdownCodeSyntaxHighlighter(.splash(theme: .sunset(withFont: .init(size: 16))))
            }
            ```

            1.  Indented block

                ```cpp
                #include <iostream>
                #include <vector>

                int main() {
                    std::vector<std::string> fruits = {"apple", "banana", "orange"};
                    for (const std::string& fruit : fruits) {
                        std::cout << "I love " << fruit << "s!" << std::endl;
                    }
                    return 0;
                }
                ```

            2.  Here's a really long paragraph that extends past the edge of the 800 point preview screen width, because it's crucial to test text and line spacing for a given paragraph.
            3.  And an indented blockquote sub-item!
                > We should probably just use a real list of markdown samples from somewhere.

            Your input will help me generate more targeted and valuable responses. Let's collaborate to create something exciting together!

            > Thanks.
            """), messageFontSize: 18)
    }
}

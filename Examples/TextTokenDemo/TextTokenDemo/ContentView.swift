import Combine
import Dropdown
import SwiftUI
import TextTokenField

struct ContentView: View {

    @StateObject private var dataManager = DataManager()
    @FocusState private var isTextFieldFocused
    @StateObject private var textManager = TextTokenFieldManager(
        triggers: "@", "#",
        triggerCancellers: .newlines,
        defaultTypingAttributes: AttributeContainer().font(UIFont.systemFont(ofSize: UIFont.systemFontSize))
    )

    @State private var messages = [(UUID, AttributedString)]()
    @State private var scrolledMessageID: UUID?
    @State private var nextScrolledMessageID = UUID()
    @Namespace private var messagesNamespace
    @State private var pendingMessage: (UUID, AttributedString)?

    var body: some View {
        NavigationView {
            ScrollViewReader { scrollViewProxy in
                ScrollView(.vertical, showsIndicators: true) {
                    messageList
                }
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: .zero) {
                    VStack(spacing: .zero) {
                        Divider()
                            .ignoresSafeArea(.all, edges: .horizontal)
                        inputControls
                    }
                    .background(.ultraThinMaterial, ignoresSafeAreaEdges: [.horizontal, .bottom])
                }
                // Scroll to the new message on insertion, or message composer expands height with more lines.
                .onChange(of: scrolledMessageID.hashValue & textManager.contentSize.height.hashValue) { _ in
                    if let scrolledMessageID {
                        withAnimation {
                            scrollViewProxy.scrollTo(scrolledMessageID)
                        }
                    }
                }
                // Scroll to the last message after keyboard popped, or give the scroll view another chance
                // to scroll to the view that is supposed to be visible.
                .onChange(of: isTextFieldFocused.hashValue & scrolledMessageID.hashValue & textManager.contentSize.height.hashValue) { _ in
                    if isTextFieldFocused, let scrolledMessageID {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation {
                                scrollViewProxy.scrollTo(scrolledMessageID)
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(
                        action: {
                            let user = User(name: "You")
                            let text = "Hi \(user.name). This is an example of how to preset the field with text with a token included..."
                            let tokenRange = text.range(of: user.name)!
                            textManager.setText(text, with: [(user, tokenRange)])
                        },
                        label: { Image(systemName: "sparkles") }
                    )
                }
            }
        }
    }

    @ViewBuilder private var messageList: some View {
        LazyVStack(alignment: .trailing, spacing: .zero) {
            ForEach(messages, id: \.0) { t in
                message(for: t)
                    .padding(.vertical, 5)
                    // Some extra space after the last message.
                    .padding(.bottom, messages.last?.0 == t.0 ? 10 : 0)
            }
        }
        .padding(.horizontal,  10)
    }

    @ViewBuilder private func message(for t: (UUID, AttributedString)) -> some View {
        Text(t.1)
            .padding(8)
            .background(Color(white: 0.95))
            .cornerRadius(12)
            .matchedGeometryEffect(id: t.0, in: messagesNamespace)
    }

    @ViewBuilder private var inputControls: some View {
        HStack(alignment: .bottom, spacing: 8) {
            userTrigger
            textField
            submitButton
        }
        .padding(10)
    }

    // An example of explicit "@" trigger or its cancellation. Cancelling explicit trigger will delete current phrase.
    @ViewBuilder private var userTrigger: some View {
        if isTextFieldFocused {
            Button(
                action: {
                    if isActiveUserTTI {
                        textManager.cancelTriggering()
                    } else {
                        textManager.trigger(with: "@")
                    }
                },
                label: {
                    Image(systemName: "at")
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .foregroundColor(isActiveUserTTI ? .white : .accentColor)
                        .padding(4)
                        .background(
                            (isActiveUserTTI ? Color.accentColor: Color.clear).cornerRadius(8)
                        )
                        .frame(height: textManager.estimatedHeight(forNumberOfLines: 1))
                }
            )
        }
    }

    private var isActiveUserTTI: Bool { textManager.isTextTokenInputActive?.trigger == "@" }

    @ViewBuilder private var textField: some View {
        TextTokenField(manager: textManager)
            .frame(
                height: max(
                    min(
                        textManager.contentSize.height,
                        textManager.estimatedHeight(forNumberOfLines: 4)
                    ),
                    textManager.estimatedHeight(forNumberOfLines: 1)
                )
            )
            .overlay(alignment: .topLeading) {
                Group {
                    if let pendingMessage {
                        message(for: pendingMessage)
                            .onAppear {
                                withAnimation(.easeInOut) {
                                    messages.append(pendingMessage)
                                    scrolledMessageID = nextScrolledMessageID
                                    nextScrolledMessageID = UUID()
                                    textManager.setText(String())
                                    self.pendingMessage = nil
                                }
                            }
                    }
                }
                .id(pendingMessage?.0)
            }
            .frame(maxWidth: .infinity)
            .focused($isTextFieldFocused)
            .cornerRadius(8)
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color(.separator), style: .init(lineWidth: 1 / 3)) }
            .dropdown(
                isPresented: isTextFieldFocused && textManager.isTextTokenInputActive != nil,
                offset: 4,
                maxLength: 100,
                cornerRadius: 8
            ) {
                dropdownContent
            }
    }

    @ViewBuilder private var submitButton: some View {
        if case let text = textManager.text, !text.isEmpty {
            Button(
                action: {
                    var s = AttributedString(text, attributes: textManager.defaultTypingAttributes)
                    textManager.tokens.forEach {
                        s[Range($0.1, in: s)!].mergeAttributes($0.0.visualAttributes)
                    }
                    pendingMessage = (nextScrolledMessageID, s)
                },
                label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .resizable()
                        .aspectRatio(1, contentMode: .fit)
                        .padding(2)
                        .frame(height: textManager.estimatedHeight(forNumberOfLines: 1))
                }
            )
            .disabled(textManager.isTextTokenInputActive != nil)
        }
    }

    @ViewBuilder private var dropdownContent: some View {
        if let search = textManager.isTextTokenInputActive {
            Group {
                switch search.trigger {
                    case "@": usersDropdown(for: search.phrase)
                    case "#": tagsDropdown(for: search.phrase)
                    default: fatalError()
                }
            }
            .padding(.horizontal, 8)
            .overlay(alignment: .topTrailing) {
                // An example of how to cancel active text token input from the input view.
                let size = CGFloat(22)
                Button(
                    action: { textManager.cancelTriggering() },
                    label: { Image(systemName: "xmark.circle.fill").resizable() }
                )
                .frame(width: size, height: size)
                .offset(x: size / 2, y: -size / 2)
            }
        }
    }

    @ViewBuilder private func usersDropdown(for phrase: String) -> some View {
        let users = phrase.isEmpty
        ? dataManager.users
        : dataManager.users.filter {
            $0.name.localizedCaseInsensitiveContains(phrase)
        }
        if !users.isEmpty {
            ViewThatFits {
                usersStack(users)
                ScrollView { usersStack(users) }
            }
        } else {
            VStack {
                Text("Sorry, haven't found anything for \"\(phrase)\"...")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .font(.footnote)
            }
        }
    }

    @ViewBuilder private func usersStack(_ users: [User]) -> some View {
        VStack {
            ForEach(users, id: \.id) { user in
                Button(
                    action: { textManager.insertToken(user, representedBy: user.name, appendCharacter: " ") },
                    label: { Text(user.name).frame(maxWidth: .infinity, alignment: .leading) }
                )
            }
        }
    }

    @ViewBuilder private func tagsDropdown(for phrase: String) -> some View {
        let tags = phrase.isEmpty
        ? dataManager.tags
        : dataManager.tags.filter {
            $0.term.localizedCaseInsensitiveContains(phrase)
        }
        VStack(spacing: .zero) {
            if !phrase.isEmpty, !dataManager.tags.contains(where: { $0.term == phrase }) {
                let tag = Tag(term: phrase)
                Button(
                    action: {
                        dataManager.tags.append(tag)
                        textManager.insertToken(tag, representedBy: "#\(tag.term)", appendCharacter: nil)
                    },
                    label: {
                        Text("Create \"\(tag.term)\"")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                )
                Divider()
            }
            ViewThatFits {
                tagsStack(tags)
                ScrollView { tagsStack(tags) }
            }
        }
    }

    @ViewBuilder private func tagsStack(_ tags: [Tag]) -> some View {
        VStack {
            ForEach(tags, id: \.id) { tag in
                Button(
                    action: { textManager.insertToken(tag, representedBy: "#\(tag.term)", appendCharacter: nil) },
                    label: { Text(tag.term).frame(maxWidth: .infinity, alignment: .leading) }
                )
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

extension TextToken {
    var visualAttributes: AttributeContainer {
        Self.attributes
    }
}

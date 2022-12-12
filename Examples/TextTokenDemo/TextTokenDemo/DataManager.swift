import Foundation
import TextTokenField
import UIKit

struct User {
    let name: String
    let id = UUID()
}

extension User: TextToken {

    static var attributes: AttributeContainer {
        AttributeContainer()
            .foregroundColor(UIColor.blue)
    }

    var text: String {
        name
    }
}

struct Tag {
    let term: String
    let id = UUID()
}

extension Tag: TextToken {

    static var attributes: AttributeContainer {
        AttributeContainer()
            .foregroundColor(UIColor.blue)
            .font(UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize, weight: .bold))
    }

    var text: String {
        "#\(term)"
    }
}

final class DataManager: ObservableObject {

    init() {
        users = [
            User(name: "John Doe"),
            User(name: "Wok Dok"),
            User(name: "Jenny Hull"),
            User(name: "Peter Duck"),
            User(name: "Julia Rock"),
            User(name: "Julia \"GiGi\" Westgoose"),
            User(name: "Robert Donovan"),
            User(name: "John Duck"),
            User(name: "Peter Bush"),
            User(name: "Peter Dupont"),
        ]
        tags = [
            Tag(term: "fa"),
            Tag(term: "fashion"),
            Tag(term: "f ths"),
        ]
    }

    @Published var users: [User]
    @Published var tags: [Tag]
}

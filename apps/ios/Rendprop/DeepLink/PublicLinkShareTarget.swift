import UIKit

struct PublicLinkShareTarget: Identifiable {
    let id = UUID()
    let url: URL
    let subject: String
    let message: String

    var activityItems: [Any] {
        [PublicLinkActivityItem(url: url, subject: subject), message]
    }
}

private final class PublicLinkActivityItem: NSObject, UIActivityItemSource {
    let url: URL
    let subject: String

    init(url: URL, subject: String) {
        self.url = url
        self.subject = subject
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { subject }
}

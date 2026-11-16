import Foundation

@main struct NativeLeadPrivacyTests {
    @MainActor static func main() async throws {
        var checks = 0
        func expect(_ value: @autoclosure () -> Bool, _ name: String) {
            checks += 1; if !value() { fatalError("FAILED: \(name)") }
        }
        let org = UUID(), listingID = UUID(), leadID = UUID()
        AuthStore.shared.userID = "named-owner"; WorkspaceContext.selectedOrgID = org
        var contact = ListingClientContact(listingID: listingID, enabled: true, publicCard: .init(name: "Client"), recipientEmail: "client@example.invalid")
        expect(!contact.hasVerifiedRecipient, "missing verification stays pending")
        contact.recipientVerifiedEmail = contact.recipientEmail; contact.recipientVerifiedAt = "not-a-date"
        expect(!contact.hasVerifiedRecipient, "malformed timestamp is unverified")
        contact.recipientVerifiedAt = "2026-10-05T12:00:00Z"
        expect(contact.hasVerifiedRecipient, "trusted matching valid verification")
        contact.recipientEmail = "new@example.invalid"
        expect(!contact.hasVerifiedRecipient, "changed recipient invalidates previous verification")
        expect(contact.writeBody["recipient_verified_email"] == nil && contact.writeBody["recipient_verified_at"] == nil, "client cannot write verification authority")

        let model = ModelFixture(listingID: listingID, org: org)
        let editor = EditorFixture(model: model, contact: contact)
        model.api.response = Data(#"{"ok":true,"state":"queued"}"#.utf8)
        await editor.verifyRecipient()
        expect(model.saved == 1 && model.api.requests.count == 1, "verification explicitly saves before one request")
        expect(editor.verificationRequested && !editor.contact.hasVerifiedRecipient, "queued response never claims verified")
        let request = model.api.requests[0]
        expect(request.httpMethod == "POST" && request.url?.path == "/leads/client-recipient-verification", "verification endpoint")
        expect(request.value(forHTTPHeaderField: "X-Org-Id") == org.uuidString.lowercased(), "verification pins private workspace")
        let verificationBody = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String:String]
        expect(verificationBody?["listing_id"] == listingID.uuidString.lowercased(), "verification targets confirmed server listing")

        model.api.requests = []; editor.saveFailure = true
        await editor.verifyRecipient()
        expect(model.api.requests.isEmpty, "failed contact save prevents verification request")
        editor.saveFailure = false; editor.error = nil
        model.api.wait = true
        let queued = Task { await editor.verifyRecipient() }
        await settle()
        WorkspaceContext.selectedOrgID = UUID()
        model.api.resume()
        await queued.value
        expect(editor.contact.recipientVerifiedAt == nil, "late verification cannot activate another workspace contact")
        WorkspaceContext.selectedOrgID = org

        let lead = Lead(id: leadID, name: "Synthetic buyer", createdAt: Date())
        let inbox = InboxFixture(model: model, leads: [lead])
        model.api.response = try JSONSerialization.data(withJSONObject: ["ok":true,"lead_id":leadID.uuidString,"deleted":true,"cleanup_pending":true])
        await inbox.deleteSavedLead(lead, expected: inbox.currentDeletionContext)
        expect(inbox.leads.isEmpty && inbox.errorMessage != nil, "only durable valid receipt removes cached lead")
        let deletion = model.api.requests.last!
        expect(deletion.httpMethod == "DELETE" && deletion.url?.path == "/leads/" + leadID.uuidString.lowercased(), "lead DELETE exact endpoint")
        expect(deletion.value(forHTTPHeaderField: "X-Org-Id") == org.uuidString.lowercased(), "delete pins original workspace")
        inbox.leads = [lead]
        model.api.response = try JSONSerialization.data(withJSONObject: ["ok":true,"lead_id":UUID().uuidString,"deleted":true,"cleanup_pending":false])
        await inbox.deleteSavedLead(lead, expected: inbox.currentDeletionContext)
        expect(inbox.leads.count == 1, "wrong-lead receipt cannot erase cached inquiry")
        model.api.response = Data(#"{"ok":true,"deleted":true}"#.utf8)
        await inbox.deleteSavedLead(lead, expected: inbox.currentDeletionContext)
        expect(inbox.leads.count == 1, "incomplete receipt cannot erase cached inquiry")
        let stale = inbox.currentDeletionContext
        WorkspaceContext.selectedOrgID = UUID()
        let calls = model.api.requests.count
        await inbox.deleteSavedLead(lead, expected: stale)
        expect(model.api.requests.count == calls, "stale confirmation cannot delete in another workspace")
        WorkspaceContext.selectedOrgID = org
        model.api.response = try JSONSerialization.data(withJSONObject: ["ok":true,"lead_id":leadID.uuidString,"deleted":true,"cleanup_pending":false])
        model.api.wait = true
        let deleting = Task { await inbox.deleteSavedLead(lead, expected: inbox.currentDeletionContext) }
        await settle()
        AuthStore.shared.userID = "different-user"
        model.api.resume()
        await deleting.value
        expect(inbox.leads.count == 1, "late deletion receipt cannot mutate another account inbox")
        print("Native client verification and lead deletion: \(checks) assertions passed")
    }
    @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() } }
}

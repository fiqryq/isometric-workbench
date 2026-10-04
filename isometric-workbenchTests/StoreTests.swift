import Foundation
import StoreKit
import StoreKitTest
import Testing
@testable import isometric_workbench

private final class BundleToken {}

@MainActor
struct StoreTests {
    @Test("Buying Workbench Pro unlocks clean exports, and a refund locks them again")
    func proUnlock() async throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Workbench", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
        defer { session.clearTransactions() }

        let store = Store.shared
        await store.refreshEntitlements()
        #expect(!store.isPro)

        await store.loadProduct()
        let product = try #require(store.product)
        #expect(product.type == .nonConsumable)
        #expect(product.displayPrice.contains("39.99"))

        let transaction = try await session.buyProduct(identifier: Store.proID)
        await store.refreshEntitlements()
        #expect(store.isPro)

        try session.refundTransaction(identifier: UInt(transaction.id))
        await store.refreshEntitlements()
        #expect(!store.isPro)
    }
}

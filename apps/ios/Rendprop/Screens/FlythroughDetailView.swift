import SwiftUI
import UIKit

struct FlythroughDetailView: View {
    let listing: Listing

    private var shareURL: URL {
        URL(string: "https://rendprop.app/f/\(listing.id.uuidString.prefix(8).lowercased())")!
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.spacing) {
                // Flythrough preview — the actual scroll-scrub player
                VStack(alignment: .leading, spacing: 8) {
                    Text("FLYTHROUGH").font(.rpKicker).foregroundStyle(Theme.inkDim)
                    PlayerWebView()
                        .frame(height: 460)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08))
                        )
                    Text("Scroll inside the preview to fly through.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }

                // Share actions
                VStack(spacing: 10) {
                    ShareLink(item: shareURL,
                              subject: Text(listing.address),
                              message: Text("Fly through \(listing.address) — scroll to walk the home.")) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share flythrough").fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    HStack(spacing: 10) {
                        Button {
                            UIPasteboard.general.url = shareURL
                            Haptics.success()
                        } label: {
                            Label("Copy link", systemImage: "link")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                        ShareLink(item: shareURL) {
                            Label("QR / More", systemImage: "qrcode")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .font(.rpBody)
                }

                // Mock analytics (real beacons in Phase 2 — master spec Part 13)
                VStack(alignment: .leading, spacing: 12) {
                    Text("PERFORMANCE").font(.rpKicker).foregroundStyle(Theme.inkDim)
                    HStack(spacing: 10) {
                        statCard("3,214", "Views", "eye")
                        statCard("1:42", "Avg watch", "clock")
                    }
                    HStack(spacing: 10) {
                        statCard("78%", "Scroll depth", "arrow.down.circle")
                        statCard("12", "Leads", "person.crop.circle.badge.checkmark")
                    }
                    Text("Sample data — live analytics arrive with the beacon pipeline.")
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                }
                .card()

                // Listing info
                VStack(alignment: .leading, spacing: 6) {
                    Text(listing.address).font(.rpTitle)
                    Text("\(listing.metaLine) · \(listing.price.formatted)")
                        .font(.rpBody)
                        .foregroundStyle(Theme.inkDim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
            }
            .padding()
        }
        .background(Theme.bg)
        .navigationTitle("Flythrough")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func statCard(_ value: String, _ label: String, _ icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Theme.accent)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.rpCaption)
                .foregroundStyle(Theme.inkDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

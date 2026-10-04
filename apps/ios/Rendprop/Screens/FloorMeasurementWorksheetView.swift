import SwiftUI
import UIKit

enum FloorMeasurementFormat {
    static func area(_ value: Double, unit: FloorMeasurementUnit) -> String {
        unit == .feet ? String(format: "%.1f sq ft", value / 0.09290304) : String(format: "%.2f m²", value)
    }
}

/// Each floor uses outlines when present, otherwise its rectangular room areas.
/// These two bases are never added together or written into advertised living area.
struct FloorMeasurementWorksheetView: View {
    let plan: FloorMeasurementPlan
    let floor: Int
    private var rows: [FloorMeasurementWorksheetRow] { ((try? plan.worksheet()) ?? []).filter { $0.floor == floor } }
    private var outlined: Bool { plan.outlines.contains { $0.floor == floor } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Area worksheet", systemImage: "tablecells").font(.rpHeadline).foregroundStyle(Theme.ink)
            Text(outlined ? "Outline areas on this floor. Room rectangles are listed separately and are not added to these totals." : "Entered rectangular room areas on this floor. These are room totals, not a measured building area.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(row.name).font(.rpBody.weight(.semibold))
                        Spacer()
                        Text(row.category.label).font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                    if row.category == .openBelow {
                        let parentName = plan.outlines.first { $0.id == plan.outlines.first(where: { $0.id == row.id })?.deductionFromID }?.name ?? "linked area"
                        Text("\(area(row.grossAreaMeters2)) deducted from \(parentName)")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    } else {
                        Text("\(area(row.grossAreaMeters2)) − \(area(row.deductionAreaMeters2)) deductions = \(area(row.netAreaMeters2))")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                        if row.category != .finished {
                            Text("Reported separately from finished area").font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                    }
                    Text("Perimeter: \(FloorMeasurementInput.displayPerimeter(row.perimeterMeters, unit: plan.unit)) · \(row.source == .phoneEstimate ? "Phone estimate" : "Entered measurements")")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    if plan.outlines.first(where: { $0.id == row.id })?.closingWallCalculated == true {
                        Label("Calculated closing wall — verify its length", systemImage: "exclamationmark.circle")
                            .font(.rpCaption).foregroundStyle(Theme.warn)
                    }
                }.foregroundStyle(Theme.ink)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("measurements.worksheetRow.\(row.id.uuidString)")
                Divider()
            }
            let finished = rows.filter { $0.category == .finished }.reduce(0) { $0 + $1.netAreaMeters2 }
            Text("\(outlined ? "Finished outline area" : "Room area total"): \(area(finished))")
                .font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("measurements.finishedAreaTotal")
            Text("A worksheet from entered dimensions. It does not set advertised square footage or certify appraisal living area.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private func area(_ value: Double) -> String { FloorMeasurementFormat.area(value, unit: plan.unit) }
}

struct FloorMeasurementDrawing: View {
    let plan: FloorMeasurementPlan
    let floor: Int
    var showWallLengths = true

    private struct Part {
        let id: UUID
        let parentID: UUID?
        let name: String
        let points: [FloorMeasurementPoint]
        let category: FloorMeasurementAreaCategory
        let calculatedClosingWall: Bool
    }
    private var parts: [Part] {
        let outlines = plan.outlines.filter { $0.floor == floor }
        if !outlines.isEmpty {
            return outlines.sorted { ($0.category == .openBelow ? 1 : 0) < ($1.category == .openBelow ? 1 : 0) }.map {
                Part(id: $0.id, parentID: $0.deductionFromID, name: $0.name, points: $0.vertices, category: $0.category, calculatedClosingWall: $0.closingWallCalculated)
            }
        }
        return plan.rooms.filter { $0.floor == floor }.map {
            let x = $0.xMeters, y = $0.yMeters, w = $0.rotatedWidthMeters, h = $0.rotatedLengthMeters
            return Part(id: $0.id, parentID: nil, name: $0.name, points: [.init(x: x, y: y), .init(x: x + w, y: y), .init(x: x + w, y: y + h), .init(x: x, y: y + h)], category: .finished, calculatedClosingWall: false)
        }
    }

    var body: some View {
        Canvas { context, size in
            let polygons = parts
            let points = polygons.flatMap(\.points)
            let minX = points.map(\.x).min() ?? 0, minY = points.map(\.y).min() ?? 0
            let width = max(0.1, (points.map(\.x).max() ?? 1) - minX)
            let height = max(0.1, (points.map(\.y).max() ?? 1) - minY)
            let padding: CGFloat = 38
            let scale = min(max(1, size.width - padding * 2) / width, max(1, size.height - padding * 2) / height)
            let offset = CGPoint(x: (size.width - width * scale) / 2, y: (size.height - height * scale) / 2)
            func location(_ p: FloorMeasurementPoint) -> CGPoint {
                CGPoint(x: offset.x + (p.x - minX) * scale, y: offset.y + (p.y - minY) * scale)
            }
            for polygon in polygons where polygon.points.count >= 3 {
                var path = Path(); path.move(to: location(polygon.points[0]))
                for point in polygon.points.dropFirst() { path.addLine(to: location(point)) }
                path.closeSubpath()
                let color = polygon.category == .openBelow ? Theme.warn : Theme.accent
                context.fill(path, with: .color(polygon.category == .openBelow ? Theme.bg : Theme.accentSoft))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, dash: polygon.category == .openBelow ? [5, 4] : []))
                let p = labelPoint(polygon.points, excluding: polygons.filter { $0.parentID == polygon.id }.map(\.points))
                context.draw(Text(polygon.name).font(.system(size: min(18, max(10, size.width / 35)), weight: .semibold)).foregroundColor(Theme.ink), at: location(p))
                for i in polygon.points.indices {
                    let a = polygon.points[i], b = polygon.points[(i + 1) % polygon.points.count]
                    if polygon.calculatedClosingWall && i == polygon.points.count - 1 {
                        var closing = Path(); closing.move(to: location(a)); closing.addLine(to: location(b))
                        context.stroke(closing, with: .color(Theme.warn), style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
                    }
                    if showWallLengths {
                        let length = hypot(b.x - a.x, b.y - a.y)
                        let mid = location(.init(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
                        context.draw(Text(FloorMeasurementInput.display(length, unit: plan.unit)).font(.system(size: min(14, max(9, size.width / 55)))).foregroundColor(Theme.ink), at: CGPoint(x: mid.x, y: mid.y - 10))
                    }
                }
            }
        }.accessibilityLabel("Measured plan for \(FloorMeasurementPlan.floorName(floor))")
    }

    /// Place labels inside concave areas rather than in an L-shaped notch.
    private func labelPoint(_ points: [FloorMeasurementPoint], excluding holes: [[FloorMeasurementPoint]]) -> FloorMeasurementPoint {
        let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
        var best = points[0], bestDistance = -Double.infinity
        for ix in 0..<15 { for iy in 0..<15 {
            let p = FloorMeasurementPoint(x: minX + (maxX - minX) * (Double(ix) + 0.5) / 15,
                                          y: minY + (maxY - minY) * (Double(iy) + 0.5) / 15)
            var inside = false, distance = Double.infinity
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                let dx = b.x - a.x, dy = b.y - a.y
                let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(0.000001, dx * dx + dy * dy)))
                distance = min(distance, hypot(p.x - a.x - t * dx, p.y - a.y - t * dy))
            }
            let inHole = holes.contains { hole in
                var contained = false
                for i in hole.indices {
                    let a = hole[i], b = hole[(i + 1) % hole.count]
                    if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { contained.toggle() }
                }
                return contained
            }
            if inside && !inHole && distance > bestDistance { best = p; bestDistance = distance }
        } }
        return best
    }
}

@MainActor
enum FloorMeasurementExport {
    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func make(plan: FloorMeasurementPlan, floor: Int, address: String) throws -> (image: UIImage, pdfURL: URL) {
        try plan.validate()
        let allRows = try plan.worksheet(), rows = allRows.filter { $0.floor == floor }
        guard !rows.isEmpty else { throw ExportError(message: "Add an area on this floor before exporting.") }
        let title = address.isEmpty ? "Floor plan and measurements" : address
        let outlined = plan.outlines.contains { $0.floor == floor }
        let totals = FloorMeasurementAreaCategory.allCases.filter { $0 != .openBelow }.map { category in
            "\(category.label): \(FloorMeasurementFormat.area(rows.filter { $0.category == category }.reduce(0) { $0 + $1.netAreaMeters2 }, unit: plan.unit))"
        }
        let content = VStack(alignment: .leading, spacing: 22) {
            Text(title).font(.system(size: 36, weight: .semibold)).lineLimit(2).foregroundStyle(Theme.ink)
            Text(FloorMeasurementPlan.floorName(floor)).font(.system(size: 25)).foregroundStyle(Theme.inkDim)
            FloorMeasurementDrawing(plan: plan, floor: floor).frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(totals.joined(separator: "   ·   ")).font(.system(size: 20)).foregroundStyle(Theme.ink)
            Text(outlined ? "Entered outlines · open-below areas are deducted only from their linked finished area" : "Entered rectangular room areas · not a measured building area")
                .font(.system(size: 20)).foregroundStyle(Theme.inkDim)
            Text("Dashed highlighted closing walls are calculated and need verification. Full area worksheet and wall lengths are in the PDF.")
                .font(.system(size: 19)).foregroundStyle(Theme.inkDim)
        }.padding(48).frame(width: 1600, height: 1200).background(Theme.bg).environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content); renderer.scale = 1
        guard let image = renderer.uiImage else { throw ExportError(message: "Couldn't create the plan image. Try again.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("measurement-plan-\(UUID().uuidString).pdf")
        let floors = Array(Set(allRows.map(\.floor))).sorted()
        var floorImages = [floor: image]
        for value in floors where value != floor {
            let drawing = VStack(spacing: 14) {
                Text(title).font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(FloorMeasurementPlan.floorName(value)).font(.system(size: 25)).foregroundStyle(Theme.inkDim)
                FloorMeasurementDrawing(plan: plan, floor: value)
            }.padding(48).frame(width: 1600, height: 1200).background(Theme.bg).environment(\.colorScheme, .light)
            let pageRenderer = ImageRenderer(content: drawing); pageRenderer.scale = 1
            guard let rendered = pageRenderer.uiImage else {
                throw ExportError(message: "Couldn't render \(FloorMeasurementPlan.floorName(value)). Try exporting again.")
            }
            floorImages[value] = rendered
        }
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 842, height: 632))
        try pdf.writePDF(to: url) { context in
            for value in floors {
                let floorRows = allRows.filter { $0.floor == value }
                context.beginPage(); floorImages[value]!.draw(in: CGRect(x: 21, y: 16, width: 800, height: 600))
                for start in stride(from: 0, to: floorRows.count, by: 7) {
                    context.beginPage()
                    drawText(title, x: 30, y: 24, width: 780, size: 19, bold: true)
                    drawText("\(FloorMeasurementPlan.floorName(value)) · Area worksheet", x: 30, y: 84, width: 780, size: 17, bold: true)
                    drawText(plan.outlines.contains { $0.floor == value } ? "Outline areas; rectangular rooms are not added to these totals." : "Room rectangles only; not a measured building area.", x: 30, y: 112, width: 780, size: 12)
                    drawText("Area / category", x: 30, y: 143, width: 270, size: 13, bold: true)
                    drawText("Gross area", x: 310, y: 143, width: 150, size: 13, bold: true)
                    drawText("Deductions", x: 470, y: 143, width: 150, size: 13, bold: true)
                    drawText("Net area", x: 650, y: 143, width: 150, size: 13, bold: true)
                    for (index, row) in floorRows.dropFirst(start).prefix(7).enumerated() {
                        let y = CGFloat(173 + index * 48)
                        drawText(row.name + " · " + row.category.label, x: 30, y: y, width: 270, size: 12)
                        drawText(FloorMeasurementFormat.area(row.grossAreaMeters2, unit: plan.unit), x: 310, y: y, width: 150, size: 12)
                        let parentID = plan.outlines.first(where: { $0.id == row.id })?.deductionFromID
                        let parentName = plan.outlines.first(where: { $0.id == parentID })?.name ?? "linked area"
                        drawText(row.category == .openBelow ? "From \(parentName)" : FloorMeasurementFormat.area(row.deductionAreaMeters2, unit: plan.unit), x: 470, y: y, width: 150, size: 11)
                        drawText(row.category == .openBelow ? "Not added" : FloorMeasurementFormat.area(row.netAreaMeters2, unit: plan.unit), x: 650, y: y, width: 150, size: 12)
                    }
                    let finished = floorRows.filter { $0.category == .finished }.reduce(0) { $0 + $1.netAreaMeters2 }
                    drawText("\(plan.outlines.contains { $0.floor == value } ? "Finished outline area" : "Room area total"): \(FloorMeasurementFormat.area(finished, unit: plan.unit))", x: 30, y: 520, width: 780, size: 15, bold: true)
                    drawText("Gross minus explicitly linked open-below deductions equals net. Garage, porch and unfinished areas are separate.\nEntered measurements require verification; this report does not set advertised square footage or certify appraisal living area.", x: 30, y: 556, width: 780, size: 11)
                }
                for outline in plan.outlines.filter({ $0.floor == value }) {
                    for start in stride(from: 0, to: outline.vertices.count, by: 20) {
                        context.beginPage()
                        drawText("\(outline.name) · \(FloorMeasurementPlan.floorName(value))", x: 30, y: 24, width: 780, size: 19, bold: true)
                        drawText("Wall calculation record · \(outline.source == .phoneEstimate ? "Phone estimate" : "Entered measurements")", x: 30, y: 60, width: 780, size: 13)
                        drawText("Wall", x: 30, y: 100, width: 70, size: 13, bold: true)
                        drawText("Length", x: 110, y: 100, width: 190, size: 13, bold: true)
                        drawText("Direction (clockwise from right)", x: 320, y: 100, width: 300, size: 13, bold: true)
                        drawText("Basis", x: 640, y: 100, width: 165, size: 13, bold: true)
                        for index in start..<min(start + 20, outline.vertices.count) {
                            let a = outline.vertices[index], b = outline.vertices[(index + 1) % outline.vertices.count]
                            let angle = (atan2(b.y - a.y, b.x - a.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
                            let y = CGFloat(129 + (index - start) * 20)
                            drawText(String(index + 1), x: 30, y: y, width: 70, size: 12)
                            drawText(FloorMeasurementInput.display(hypot(b.x - a.x, b.y - a.y), unit: plan.unit), x: 110, y: y, width: 190, size: 12)
                            drawText(String(format: "%.1f°", angle), x: 320, y: y, width: 300, size: 12)
                            drawText(outline.closingWallCalculated && index == outline.vertices.count - 1 ? "Calculated — verify" : "Entered", x: 640, y: y, width: 165, size: 12)
                        }
                        drawText("Polygon area from the closed wall outline: \(FloorMeasurementFormat.area(outline.areaMeters2, unit: plan.unit)).\nPerimeter: \(FloorMeasurementInput.displayPerimeter(outline.perimeterMeters, unit: plan.unit)). Units and full-precision coordinates are retained in the saved plan.", x: 30, y: 555, width: 780, size: 11)
                    }
                }
            }
        }
        return (image, url)
    }

    private static func drawText(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, size: CGFloat, bold: Bool = false) {
        let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
        (text as NSString).draw(in: CGRect(x: x, y: y, width: width, height: 60), withAttributes: [.font: font, .foregroundColor: UIColor.black])
    }
}

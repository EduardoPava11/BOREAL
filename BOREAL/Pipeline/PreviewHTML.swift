import Foundation

/// PreviewHTML — THE PREVIEW (TF1.1): one self-contained page per
/// bundle. All images base64-embedded, zero dependencies, no JS — it
/// must render in a Files-app tap or a Mac double-click forever. The
/// page is the bundle's front door: verdict lights, the animating
/// product, the ladder, the palette, the σ/σ_time heat story, the perf
/// Gantt, and the per-frame facts — the analysis, not the homework.
enum PreviewHTML {

    // ── page assembly ───────────────────────────────────────────────────

    static func cyclePage(json: [String: Any], dir: URL) -> String {
        var body = header(json, title: "BOREAL cycle")
        body += verdicts(json)
        if let gif = b64(dir, "cycle.gif", "image/gif") {
            body += section("The product — 4 frames, portrait",
                            "<img class=hero src='\(gif)'>")
        }
        var ladder = ""
        for r in [16, 32, 64, 128, 256, 512] {
            if let png = b64(dir, "rung_\(r).png", "image/png") {
                ladder += "<figure><img class=rung src='\(png)'><figcaption>\(r)</figcaption></figure>"
            }
        }
        if !ladder.isEmpty { body += section("The ladder", "<div class=row>\(ladder)</div>") }
        var grids = ""
        if let pal = json["palette"] as? [String: Any],
           let rgb = pal["rgb8"] as? [Any] {
            grids += figureBlock("palette (the seed IS the image)",
                                 paletteGrid(rgb.compactMap { ($0 as? NSNumber)?.intValue }))
        }
        if let sig = json["sigma"] as? [Any] {
            grids += figureBlock("σ — scale disagreement",
                                 heatGrid(sig.compactMap { ($0 as? NSNumber)?.doubleValue }))
        }
        if let t = json["temporal"] as? [String: Any], let st = t["sigmaTime"] as? [Any] {
            grids += figureBlock("σ_time — motion / alias",
                                 heatGrid(st.compactMap { ($0 as? NSNumber)?.doubleValue }))
        }
        if !grids.isEmpty { body += section("16×16 heads", "<div class=row>\(grids)</div>") }
        body += framesTable(json)
        body += perfSection(json)
        return page(body)
    }

    static func burstPage(json: [String: Any], dir: URL) -> String {
        var body = header(json, title: "BOREAL burst")
        body += verdicts(json)
        if let gif = b64(dir, "burst.gif", "image/gif") {
            body += section("The product — the burst, portrait",
                            "<img class=hero src='\(gif)'>")
        }
        if let cycles = json["cycles"] as? [[String: Any]] {
            var rows = "<tr><th>cycle</th><th>fuse</th><th>NT</th><th>actual EV</th><th>ĝ</th></tr>"
            for c in cycles {
                let ev = (c["actualRatios"] as? [Any])?
                    .compactMap { ($0 as? NSNumber)?.doubleValue }
                    .map { String(format: "%.1f", $0) }.joined(separator: "/") ?? ""
                let g = ((c["temporal"] as? [String: Any])?["gain"] as? NSNumber)?.doubleValue
                rows += "<tr><td>\((c["index"] as? NSNumber)?.intValue ?? -1)</td>"
                    + "<td>\(c["fuse"] as? String ?? "?")</td>"
                    + "<td>\(fmtE((c["ntSpread"] as? NSNumber)?.doubleValue))</td>"
                    + "<td>\(ev)</td><td>\(fmtE(g))</td></tr>"
            }
            body += section("Cycles", "<table>\(rows)</table>")
        }
        body += perfSection(json)
        return page(body)
    }

    // ── verdict lights ──────────────────────────────────────────────────

    private static func verdicts(_ json: [String: Any]) -> String {
        var lights: [(String, Bool?, String)] = []
        if let nt = (json["ntSpread"] as? NSNumber)?.doubleValue {
            lights.append(("NT", nt < 1e-5, fmtE(nt)))
        }
        if let fuse = json["fuse"] as? String {
            lights.append(("fuse", fuse == "mle", fuse))
        }
        let perf = json["perf"] as? [String: Any]
        if let fp = (perf?["peakFootprintMB"] as? NSNumber)?.doubleValue {
            lights.append(("footprint", fp < 350, String(format: "%.0f MB", fp)))
        }
        if let therm = perf?["thermal"] as? [[String: Any]],
           let last = therm.last?["state"] as? String {
            lights.append(("thermal", last == "nominal" || last == "fair", last))
        }
        if let frames = json["frames"] as? [[String: Any]] {
            let hi = frames.compactMap { ($0["clipHiFrac"] as? NSNumber)?.doubleValue }.max() ?? 0
            let lo = frames.compactMap { ($0["subBlackFrac"] as? NSNumber)?.doubleValue }.max() ?? 0
            lights.append(("rails", nil, String(format: "clip %.1f%% · sub %.1f%%",
                                                hi * 100, lo * 100)))
        }
        if let g = ((json["temporal"] as? [String: Any])?["gain"] as? NSNumber)?.doubleValue {
            lights.append(("ĝ", nil, fmtE(g)))
        }
        let chips = lights.map { (name, ok, detail) -> String in
            let cls = ok == nil ? "info" : (ok! ? "ok" : "bad")
            return "<span class='chip \(cls)'><b>\(name)</b> \(detail)</span>"
        }.joined()
        return "<div class=chips>\(chips)</div>"
    }

    // ── sections ────────────────────────────────────────────────────────

    private static func header(_ json: [String: Any], title: String) -> String {
        let stampKeys = ["capturedAt", "device", "os", "build", "schema"]
        let meta = stampKeys.compactMap { k -> String? in
            guard let v = json[k] else { return nil }
            return "\(k) \(v)"
        }.joined(separator: " · ")
        return "<h1>\(title)</h1><p class=meta>\(meta)</p>"
    }

    private static func framesTable(_ json: [String: Any]) -> String {
        guard let frames = json["frames"] as? [[String: Any]], !frames.isEmpty
        else { return "" }
        var rows = "<tr><th>#</th><th>ISO</th><th>shutter</th><th>S</th><th>O</th>"
            + "<th>blExp</th><th>clipHi</th><th>subBlack</th></tr>"
        for (i, f) in frames.enumerated() {
            func d(_ k: String) -> Double { (f[k] as? NSNumber)?.doubleValue ?? 0 }
            let et = d("exposureTime")
            rows += "<tr><td>\(i + 1)</td><td>\(Int(d("iso")))</td>"
                + "<td>1/\(et > 0 ? Int((1 / et).rounded()) : 0)</td>"
                + "<td>\(fmtE(d("noiseS")))</td><td>\(fmtE(d("noiseO")))</td>"
                + String(format: "<td>%.2f</td><td>%.3f%%</td><td>%.3f%%</td></tr>",
                         d("baselineExposure"), d("clipHiFrac") * 100,
                         d("subBlackFrac") * 100)
        }
        return section("Frames", "<table>\(rows)</table>")
    }

    private static func perfSection(_ json: [String: Any]) -> String {
        guard let perf = json["perf"] as? [String: Any] else { return "" }
        var out = ""
        if let stages = perf["stages"] as? [String: [String: Any]] {
            var rows = "<tr><th>stage</th><th>n</th><th>median ms</th><th>total ms</th></tr>"
            for (name, s) in stages.sorted(by: {
                (($0.value["totalMs"] as? NSNumber)?.doubleValue ?? 0)
                    > (($1.value["totalMs"] as? NSNumber)?.doubleValue ?? 0) }) {
                rows += "<tr><td>\(name)</td><td>\((s["n"] as? NSNumber)?.intValue ?? 0)</td>"
                    + String(format: "<td>%.1f</td><td>%.0f</td></tr>",
                             (s["medianMs"] as? NSNumber)?.doubleValue ?? 0,
                             (s["totalMs"] as? NSNumber)?.doubleValue ?? 0)
            }
            out += "<table>\(rows)</table>"
        }
        if let tl = perf["timeline"] as? [String: [[Any]]] { out += gantt(tl) }
        return out.isEmpty ? "" : section("Perf", out)
    }

    /// Inline SVG Gantt of the per-call timeline — the serial-vs-parallel
    /// picture, in every bundle.
    private static func gantt(_ timeline: [String: [[Any]]]) -> String {
        var spans: [(stage: String, t: Double, ms: Double)] = []
        for (stage, calls) in timeline {
            for c in calls where c.count == 2 {
                spans.append((stage, (c[0] as? NSNumber)?.doubleValue ?? 0,
                              (c[1] as? NSNumber)?.doubleValue ?? 0))
            }
        }
        guard !spans.isEmpty else { return "" }
        let total = spans.map { $0.t + $0.ms }.max() ?? 1
        func firstStart(_ name: String) -> Double {
            spans.first(where: { $0.stage == name })?.t ?? 0
        }
        let stages = Array(Set(spans.map(\.stage)))
            .sorted { a, b in firstStart(a) < firstStart(b) }
        let rowH = 18.0
        let width = 700.0
        let height = Double(stages.count) * rowH + 22
        var svg = "<svg viewBox='0 0 \(Int(width + 150)) \(Int(height))' "
        svg += "xmlns='http://www.w3.org/2000/svg' style='width:100%;max-width:860px'>"
        for (i, stage) in stages.enumerated() {
            let y = Double(i) * rowH + 14
            svg += "<text x=0 y=\(Int(y + 10)) class=sl>\(stage)</text>"
            for s in spans where s.stage == stage {
                let x = Int(150 + s.t / total * width)
                let w = Int(max(1, s.ms / total * width))
                var rect = "<rect x='\(x)' y='\(Int(y))' width='\(w)' "
                rect += "height='\(Int(rowH - 5))' rx=2 class=bar>"
                rect += "<title>\(stage): \(Int(s.ms)) ms @ \(Int(s.t)) ms</title></rect>"
                svg += rect
            }
        }
        svg += "<text x=150 y=\(Int(height) - 2) class=sl>0 … \(Int(total)) ms</text></svg>"
        return svg
    }

    // ── 16×16 grids ─────────────────────────────────────────────────────

    private static func paletteGrid(_ rgb: [Int]) -> String {
        guard rgb.count >= 768 else { return "" }
        var rows = ""
        for y in 0..<16 {
            rows += "<tr>"
            for x in 0..<16 {
                let p = (y * 16 + x) * 3
                rows += "<td style='background:rgb(\(rgb[p]),\(rgb[p + 1]),\(rgb[p + 2]))'></td>"
            }
            rows += "</tr>"
        }
        return "<table class=grid>\(rows)</table>"
    }

    private static func heatGrid(_ values: [Double]) -> String {
        guard values.count >= 256 else { return "" }
        let mx = max(values.max() ?? 1, 1e-9)
        var rows = ""
        for y in 0..<16 {
            rows += "<tr>"
            for x in 0..<16 {
                let a = min(1, values[y * 16 + x] / mx)
                rows += String(format: "<td style='background:rgba(255,64,220,%.3f)' title='%.2f'></td>",
                               a, values[y * 16 + x])
            }
            rows += "</tr>"
        }
        return "<table class=grid>\(rows)</table>"
    }

    // ── plumbing ────────────────────────────────────────────────────────

    private static func b64(_ dir: URL, _ name: String, _ mime: String) -> String? {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent(name))
        else { return nil }
        return "data:\(mime);base64,\(d.base64EncodedString())"
    }

    private static func section(_ title: String, _ inner: String) -> String {
        "<h2>\(title)</h2>\(inner)"
    }

    private static func figureBlock(_ caption: String, _ inner: String) -> String {
        "<figure>\(inner)<figcaption>\(caption)</figcaption></figure>"
    }

    private static func fmtE(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.2e", v)
    }

    private static func page(_ body: String) -> String {
        """
        <!doctype html><meta charset=utf-8>
        <meta name=viewport content='width=device-width,initial-scale=1'>
        <title>BOREAL bundle</title>
        <style>
        body{background:#101014;color:#e8e8ee;font:14px/1.5 ui-monospace,Menlo,monospace;
             margin:0 auto;max-width:900px;padding:20px}
        h1{font-size:19px;margin:0 0 2px} h2{font-size:14px;margin:26px 0 8px;color:#9a9ab0}
        .meta{color:#7a7a90;font-size:12px;margin:0 0 14px}
        .chips{display:flex;flex-wrap:wrap;gap:6px;margin:10px 0}
        .chip{padding:4px 10px;border-radius:20px;font-size:12px;border:1px solid #333}
        .chip.ok{background:#0d2818;border-color:#1e5c38}
        .chip.bad{background:#2f1013;border-color:#7c2830}
        .chip.info{background:#16161e}
        .hero{width:100%;max-width:512px;image-rendering:pixelated;border-radius:8px}
        .row{display:flex;flex-wrap:wrap;gap:12px;align-items:flex-end}
        .rung{image-rendering:pixelated;height:96px;border-radius:4px}
        figure{margin:0} figcaption{font-size:11px;color:#7a7a90;text-align:center}
        table{border-collapse:collapse;font-size:12px}
        td,th{border:1px solid #26262e;padding:3px 8px;text-align:right}
        th{color:#9a9ab0}
        .grid{border-collapse:collapse}
        .grid td{width:13px;height:13px;padding:0;border:1px solid #1a1a22}
        .sl{fill:#9a9ab0;font-size:10px;font-family:ui-monospace,Menlo,monospace}
        .bar{fill:#5aa0e0}
        </style>
        \(body)
        """
    }
}
